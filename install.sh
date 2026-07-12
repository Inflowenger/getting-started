#!/usr/bin/env bash
#
# Inflowenger one-liner installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Inflowenger/getting-started/main/install.sh | bash
#
# Stands up the platform (Infra + one Fractal) and, if you agree, the inspector
# panel (inflow-inspector-api + inflow-inspector). All images are pulled from
# Docker Hub as multi-arch manifests; the two inspector images are self-building
# — their entrypoint clones + compiles the source at container START, native to
# your CPU (amd64 or arm64), so nothing is built at image time. It writes real
# docker compose stacks into an install directory so you can manage them like
# the walkthrough in README.md.
#
# It works both interactively (prompts read from /dev/tty even when piped through
# curl) and non-interactively (drive it entirely with the env vars below).
#
# Env vars (all optional — prompted for when a TTY is available, else defaulted):
#   INFLOW_DIR          install directory                 (default: $HOME/inflowenger)
#   API_JWT_SECRET      Infra API Secret Key / shared JWT secret (default: generated)
#   OPERATOR_SEED       NATS operator seed                (default: Infra generates one)
#   INFRA_CLUSTER       cluster name for a paid license   (default: empty / free use)
#   FRACTAL_TAGS        comma-separated Fractal tags       (default: default)
#   FRACTAL_NAME        Fractal container name             (default: fractal-1)
#   INSTALL_INSPECTOR   1/0 — install the inspector panel  (default: prompted, else 0)
#   IMAGE_NS            Docker Hub namespace for all images (default: mehdishokohi)
#   IMAGE_TAG           tag for all pulled images           (default: latest)
#   INSPECTOR_API_REF   branch/tag the api image builds at runtime  (default: master)
#   INSPECTOR_REF       branch/tag the panel image builds at runtime (default: master)
#   ASSUME_YES          1 — accept all defaults, no prompts (default: 0)
#
set -euo pipefail

# ── config / defaults ─────────────────────────────────────────────────────────
INFLOW_DIR="${INFLOW_DIR:-$HOME/inflowenger}"
API_JWT_SECRET="${API_JWT_SECRET:-}"
OPERATOR_SEED="${OPERATOR_SEED:-}"
INFRA_CLUSTER="${INFRA_CLUSTER:-}"
FRACTAL_TAGS="${FRACTAL_TAGS:-default}"
FRACTAL_NAME="${FRACTAL_NAME:-fractal-1}"
INSTALL_INSPECTOR="${INSTALL_INSPECTOR:-}"
IMAGE_NS="${IMAGE_NS:-mehdishokohi}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
ASSUME_YES="${ASSUME_YES:-0}"

# ── pretty output ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'; RST=$'\033[0m'
else
  B=''; DIM=''; GRN=''; YLW=''; RED=''; CYN=''; RST=''
fi
step() { printf '\n%s==>%s %s%s%s\n' "$CYN" "$RST" "$B" "$*" "$RST"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '    %s!%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '\n%serror:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ── interactive helpers (read from /dev/tty so `curl | bash` still prompts) ────
have_tty() { [ "$ASSUME_YES" != "1" ] && [ -e /dev/tty ]; }

ask() { # <prompt> <default> -> echoes answer
  local prompt="$1" def="${2:-}" reply
  if ! have_tty; then printf '%s' "$def"; return; fi
  if [ -n "$def" ]; then printf '%s%s%s [%s]: ' "$B" "$prompt" "$RST" "$def" >/dev/tty
  else printf '%s%s%s: ' "$B" "$prompt" "$RST" >/dev/tty; fi
  IFS= read -r reply </dev/tty || reply=""
  printf '%s' "${reply:-$def}"
}

ask_secret() { # <prompt> -> echoes answer (input hidden)
  local prompt="$1" reply
  if ! have_tty; then printf ''; return; fi
  printf '%s%s%s: ' "$B" "$prompt" "$RST" >/dev/tty
  IFS= read -rs reply </dev/tty || reply=""
  printf '\n' >/dev/tty
  printf '%s' "$reply"
}

confirm() { # <prompt> <default y|n> -> exit status
  local prompt="$1" def="${2:-n}" reply hint="[y/N]"
  [ "$def" = y ] && hint="[Y/n]"
  if ! have_tty; then [ "$def" = y ]; return; fi
  printf '%s%s%s %s ' "$B" "$prompt" "$RST" "$hint" >/dev/tty
  IFS= read -r reply </dev/tty || reply=""
  reply="${reply:-$def}"
  case "$reply" in [Yy]*) return 0;; *) return 1;; esac
}

gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 60
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 60
  fi
}

# ── prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH."
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  die "the Docker Compose v2 plugin is required (\`docker compose version\`)."
fi
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon — is it running / do you have permission?"
ok "docker + compose available ($DC)"

# ── banner ────────────────────────────────────────────────────────────────────
printf '\n%s  Inflowenger installer%s\n' "$B" "$RST"
printf '%s  platform (Infra + Fractal)%s + optional developer panel\n' "$DIM" "$RST"

# ── collect parameters ────────────────────────────────────────────────────────
step "Configuration"
INFLOW_DIR="$(ask "Install directory" "$INFLOW_DIR")"

# API Secret Key — the HMAC secret Infra uses and the panel shares.
if [ -z "$API_JWT_SECRET" ] && have_tty; then
  info "Infra needs an API Secret Key (shared with the panel). Leave blank to auto-generate."
  API_JWT_SECRET="$(ask_secret "API Secret Key (blank = generate)")"
fi
GENERATED_SECRET=0
if [ -z "$API_JWT_SECRET" ]; then
  API_JWT_SECRET="$(gen_secret)"
  GENERATED_SECRET=1
  ok "Generated an API Secret Key."
fi

FRACTAL_TAGS="$(ask "Fractal tags (comma-separated)" "$FRACTAL_TAGS")"
FRACTAL_NAME="$(ask "Fractal container name" "$FRACTAL_NAME")"
if have_tty && confirm "Set advanced options (operator seed, cluster name)?" n; then
  OPERATOR_SEED="$(ask "OPERATOR_SEED (blank = Infra generates one)" "$OPERATOR_SEED")"
  INFRA_CLUSTER="$(ask "INFRA_CLUSTER (blank = free use)" "$INFRA_CLUSTER")"
fi

# Decide about the inspector panel up front so the whole run is unattended after this.
if [ -z "$INSTALL_INSPECTOR" ]; then
  if confirm "Also install the inspector developer panel?" y; then INSTALL_INSPECTOR=1; else INSTALL_INSPECTOR=0; fi
fi
# All four images are pulled from Docker Hub as multi-arch manifests. The two
# inspector images are self-building: their entrypoint clones + compiles the
# source at container START (native to this CPU), so nothing builds at image
# time. INSPECTOR_*_REF picks the branch/tag each one checks out at runtime.
INFRA_IMAGE="$IMAGE_NS/inflow-infra:$IMAGE_TAG"
FRACTAL_IMAGE="$IMAGE_NS/fractal:$IMAGE_TAG"
INSPECTOR_API_IMAGE="$IMAGE_NS/inflow-inspector-api:$IMAGE_TAG"
INSPECTOR_IMAGE="$IMAGE_NS/inflow-inspector:$IMAGE_TAG"
INSPECTOR_API_REF="${INSPECTOR_API_REF:-master}"
INSPECTOR_REF="${INSPECTOR_REF:-master}"

# ── write the platform stack ──────────────────────────────────────────────────
step "Writing platform stack -> $INFLOW_DIR/platform"
mkdir -p "$INFLOW_DIR/platform"

cat > "$INFLOW_DIR/platform/docker-compose.yml" <<'YAML'
# Inflowenger platform — Infra + a Fractal runtime. Generated by install.sh.
name: inflow-platform

services:
  infra:
    image: ${INFRA_IMAGE}
    container_name: inflow-infra
    restart: unless-stopped
    environment:
      OPERATOR_SEED: ${OPERATOR_SEED:-}
      API_JWT_SECRET: ${API_JWT_SECRET:-}
      INFRA_CLUSTER: ${INFRA_CLUSTER:-}
    volumes:
      - ./store:/data
    ports:
      - "8022:8022"   # HTTP API / onboarding portal
      - "8222:8222"   # NATS HTTP monitor
      - "4222:4222"   # NATS client (only needed to connect from the host)
    networks:
      - inflow_net

  fractal:
    image: ${FRACTAL_IMAGE}
    container_name: ${FRACTAL_NAME:-fractal-1}
    restart: unless-stopped
    depends_on:
      - infra
    environment:
      TAGS: ${FRACTAL_TAGS:-default}
      REGISTER_URL: ${FRACTAL_REGISTER_URL:-http://inflow-infra:8022/register/abc}
    networks:
      - inflow_net

networks:
  # Created by install.sh (docker network create inflow_net) so the inspector
  # stack and the `curl | bash` Fractal installer attach to the exact same net.
  inflow_net:
    external: true
YAML

# .env carries the concrete values (real secret) into the compose stack above.
{
  printf 'INFRA_IMAGE=%s\n'    "$INFRA_IMAGE"
  printf 'FRACTAL_IMAGE=%s\n'  "$FRACTAL_IMAGE"
  printf 'OPERATOR_SEED=%s\n'  "$OPERATOR_SEED"
  printf 'API_JWT_SECRET=%s\n' "$API_JWT_SECRET"
  printf 'INFRA_CLUSTER=%s\n'  "$INFRA_CLUSTER"
  printf 'FRACTAL_TAGS=%s\n'   "$FRACTAL_TAGS"
  printf 'FRACTAL_NAME=%s\n'   "$FRACTAL_NAME"
} > "$INFLOW_DIR/platform/.env"
chmod 600 "$INFLOW_DIR/platform/.env"
ok "platform/docker-compose.yml + .env written"

# Ensure the shared external network exists. The platform stack would create it
# on its own, but the inspector stack (and the `curl | bash` Fractal installer)
# declare `inflow_net` as external and fail if it's missing — so make it
# idempotently here, before anything comes up.
step "Ensuring the shared network (inflow_net) exists"
if docker network inspect inflow_net >/dev/null 2>&1; then
  ok "network inflow_net already exists"
else
  docker network create inflow_net >/dev/null
  ok "created network inflow_net"
fi

step "Starting the platform (Infra + Fractal)"
( cd "$INFLOW_DIR/platform" && $DC pull --quiet 2>/dev/null || true; $DC up -d )

# Wait for Infra to finish booting (it logs "Infra Started" on a healthy start).
info "Waiting for Infra to become ready..."
ready=0
for _ in $(seq 1 60); do
  if ( cd "$INFLOW_DIR/platform" && $DC logs infra 2>/dev/null ) | grep -q "Infra Started"; then
    ready=1; break
  fi
  sleep 2
done
if [ "$ready" = "1" ]; then ok "Infra is up (http://localhost:8022)"; else
  warn "Infra didn't report ready within ~2 min. Check: (cd $INFLOW_DIR/platform && $DC logs -f infra)"
fi

# ── optionally, the developer panel (built from source) ───────────────────────
if [ "$INSTALL_INSPECTOR" = "1" ]; then
  step "Writing inspector panel stack -> $INFLOW_DIR/inspector"
  mkdir -p "$INFLOW_DIR/inspector"

  cat > "$INFLOW_DIR/inspector/docker-compose.yml" <<'YAML'
# Inflowenger inspector panel — inflow-inspector-api + inflow-inspector.
# Self-building images: the entrypoint clones + compiles the source at container
# START, native to this CPU. Joins the platform's external `inflow_net`.
# Generated by install.sh.
name: inflow-inspector

services:
  inflow-inspector-api:
    image: ${INSPECTOR_API_IMAGE}
    container_name: inflow-inspector-api
    restart: unless-stopped
    environment:
      INSPECTOR_API_REF: ${INSPECTOR_API_REF:-master}
      PORT: "8025"
      DB_STORE_PATH: /data
      INFLOW_INFRA_API: http://inflow-infra:8022
      INFLOW_INFRA_JWT_SECRET: ${INFLOW_INFRA_JWT_SECRET:?set INFLOW_INFRA_JWT_SECRET in .env}
    volumes:
      - ./backend-data:/data       # BadgerDB store
      - inspector-api-src:/src     # cached checkout + build
    ports:
      - "8025:8025"
    networks:
      - inflow_net

  inflow-inspector:
    image: ${INSPECTOR_IMAGE}
    container_name: inflow-inspector
    restart: unless-stopped
    depends_on:
      - inflow-inspector-api
    environment:
      INSPECTOR_REF: ${INSPECTOR_REF:-master}
    volumes:
      - inspector-src:/src         # cached checkout + node_modules + dist
    # Static assets, no backend URL baked in — enter the Base Server URL in the
    # panel's Auth dialog at runtime (Swagger-style).
    ports:
      - "8080:80"

networks:
  inflow_net:
    external: true

volumes:
  inspector-api-src:
  inspector-src:
YAML

  {
    printf 'INSPECTOR_API_IMAGE=%s\n'   "$INSPECTOR_API_IMAGE"
    printf 'INSPECTOR_IMAGE=%s\n'       "$INSPECTOR_IMAGE"
    printf 'INSPECTOR_API_REF=%s\n'     "$INSPECTOR_API_REF"
    printf 'INSPECTOR_REF=%s\n'         "$INSPECTOR_REF"
    printf 'INFLOW_INFRA_JWT_SECRET=%s\n' "$API_JWT_SECRET"
  } > "$INFLOW_DIR/inspector/.env"
  chmod 600 "$INFLOW_DIR/inspector/.env"
  ok "inspector/docker-compose.yml + .env written"

  step "Starting the inspector panel"
  info "First start clones + compiles inside the container — this can take a few minutes."
  ( cd "$INFLOW_DIR/inspector" && $DC pull --quiet 2>/dev/null || true; $DC up -d )
  ok "panel starting (http://localhost:8080) — watch the build with:"
  info "  (cd $INFLOW_DIR/inspector && $DC logs -f)"
fi

# ── summary ───────────────────────────────────────────────────────────────────
step "Done"
printf '\n%s  Platform%s\n' "$B" "$RST"
info "Infra API / portal   http://localhost:8022"
info "NATS HTTP monitor    http://localhost:8222"
info "Fractal              $FRACTAL_NAME  (tags: $FRACTAL_TAGS)"
printf '\n%s  API Secret Key%s  %s(save this — it is your admin credential)%s\n' "$B" "$RST" "$DIM" "$RST"
printf '    %s%s%s\n' "$YLW" "$API_JWT_SECRET" "$RST"
[ "$GENERATED_SECRET" = "1" ] && info "(auto-generated; also stored in $INFLOW_DIR/platform/.env)"

if [ "$INSTALL_INSPECTOR" = "1" ]; then
  printf '\n%s  Developer panel%s\n' "$B" "$RST"
  info "Open                 http://localhost:8080"
  info "In the Auth dialog:  Base Server URL = http://localhost:8025  (or wherever your browser reaches inflow-inspector-api)"
  info "                     Shared Secret   = the API Secret Key above"
fi

printf '\n%s  Files & management%s\n' "$B" "$RST"
info "Stacks live in        $INFLOW_DIR"
info "Add more Fractals      curl -fsSL http://localhost:8022/fractal/11/install.sh | bash"
info "Stop platform          (cd $INFLOW_DIR/platform && $DC down)"
[ "$INSTALL_INSPECTOR" = "1" ] && info "Stop panel             (cd $INFLOW_DIR/inspector && $DC down)"
[ "$INSTALL_INSPECTOR" = "1" ] && info "Rebuild from source    (cd $INFLOW_DIR/inspector && $DC restart)   # re-clones + recompiles"
printf '\n'
