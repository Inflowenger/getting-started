# Inflowenger — Getting Started

From zero to a running Inflowenger ecosystem **plus** the developer panel, in two
`docker compose` stacks.

If you just want to read the conceptual install story, see the website's
[Installation page](../inflow-vue/inflow-nuxt/app/pages/installation.vue). This
folder is the hands-on, copy-paste version that also stands up the inspector panel.

---

## Quick install (one-liner)

The fastest path. This asks a few questions, brings up Infra + Fractal, and —
if you agree — the inspector panel, then prints your API Secret Key and the
panel URL:

```bash
curl -fsSL https://raw.githubusercontent.com/Inflowenger/getting-started/main/install.sh | bash
```

It writes real `docker compose` stacks into `~/inflowenger/` (override with
`INFLOW_DIR`), so afterward you manage them exactly like the manual steps below.
The prompts read from your terminal even through the pipe; to run it unattended,
drive it with env vars instead — e.g. accept every default and skip the panel:

```bash
curl -fsSL https://raw.githubusercontent.com/Inflowenger/getting-started/main/install.sh \
  | ASSUME_YES=1 INSTALL_INSPECTOR=0 API_JWT_SECRET=my-shared-secret bash
```

<details>
<summary>All installer environment variables</summary>

| Var | Default | Purpose |
|-----|---------|---------|
| `INFLOW_DIR` | `~/inflowenger` | Where the compose stacks are written. |
| `API_JWT_SECRET` | *generated* | Infra API Secret Key / shared JWT secret. |
| `OPERATOR_SEED` | *Infra generates* | NATS operator seed. |
| `INFRA_CLUSTER` | *(empty)* | Cluster name for a paid/sponsored license. |
| `FRACTAL_TAGS` | `default` | Comma-separated Fractal tags. |
| `FRACTAL_NAME` | `fractal-1` | Fractal container name. |
| `INSTALL_INSPECTOR` | *prompted* | `1`/`0` — install the inspector panel. |
| `IMAGE_NS` | `mehdishokohi` | Docker Hub namespace for all images. |
| `IMAGE_TAG` | `latest` | Image tag for all images. |
| `INSPECTOR_API_REF` | `master` | Branch/tag the backend image builds at runtime. |
| `INSPECTOR_REF` | `master` | Branch/tag the frontend image builds at runtime. |
| `ASSUME_YES` | `0` | `1` — accept all defaults, no prompts. |

</details>

> Prefer to see every step? The manual walkthrough below does exactly what the
> script automates, one stack at a time.

---

## What you're standing up

An Inflowenger ecosystem is built from two headless services, and then a UI on
top for development:

- **Infra** — bootstraps and coordinates everything. Runs an embedded NATS
  server; mints accounts, credentials, and the onboarding portal. *Everything
  starts here.*
- **Fractal** — the runtime that actually executes workflow graphs. It attaches
  to Infra.
- **Dev panel** — Infra and Fractal are headless by design. The panel
  (`inflow-inspector-api` + the `inflow-inspector` Vue frontend) is your visual
  window: inspect context, workflows, and Fractals as they run. It is itself
  built on Inflowenger (via `inflow-fusion`).

```
                          ┌───────────────────────────────────────────┐
    Browser  ─────────►   │  Dev panel frontend (Vue)      :8080       │
                          └──────────────────┬────────────────────────┘
                                             │ HTTP + WebSocket (logs)
                          ┌──────────────────▼────────────────────────┐
                          │  inflow-inspector-api (Go/Fiber)  :8025    │
                          │  flows · context · logs · /infra/* proxy   │
                          └──────────────────┬────────────────────────┘
                                             │ NATS + HTTP  (inflow_net)
      ┌──────────────────────────────────────▼────────────────────────────┐
      │                       Platform  (network: inflow_net)               │
      │   ┌─────────────────────────┐   register   ┌────────────────────┐   │
      │   │  Infra   :8022 / :4222  │◄────────────►│  Fractal (runtime) │   │
      │   │  NATS + coordinator     │              │  executes flows    │   │
      │   └─────────────────────────┘              └────────────────────┘   │
      └─────────────────────────────────────────────────────────────────────┘
```

The two stacks are deliberately separate — the platform is the product; the dev
panel is optional tooling on top. They meet on a shared Docker network,
`inflow_net`.

---

## Prerequisites

- **Docker** with the **Compose v2** plugin (`docker compose version`).
- Free host ports: `8022`, `8222`, `4222` (platform) and `8025`, `8080`
  (inspector panel).
- **Network access.** All four images are pulled from Docker Hub as multi-arch
  (amd64 + arm64) manifests. The two platform images (`mehdishokohi/inflow-infra`,
  `mehdishokohi/fractal`) run immediately. The two inspector images
  (`mehdishokohi/inflow-inspector-api`, `mehdishokohi/inflow-inspector`) are
  **self-building**: their entrypoint clones the source and compiles it *inside
  the container at first start*, native to your CPU — so that first start also
  reaches GitHub, the Go module proxy, and the npm registry and takes a few
  minutes. A named volume then caches the checkout so later restarts are quick.

---

## Part 1 — Platform (Infra + Fractal)

Everything starts with Infra.

```bash
cd platform
cp .env.example .env
```

Infra needs an **API Secret Key** — the shared HMAC secret the inspector panel
uses to authenticate later. You have two choices:

- **Let Infra generate it** (leave `API_JWT_SECRET` blank) and copy the value it
  prints on first boot — see [Confirm a healthy start](#confirm-a-healthy-start).
- **Set it yourself** (recommended, predictable across restarts) by putting a
  value in `.env`:

  ```bash
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 60; echo
  ```

Either way, you'll reuse this key in Part 2. Both stacks share an external
Docker network, `inflow_net` — create it once per host, then bring the platform
up:

```bash
docker network create inflow_net   # once per host; skip if it already exists
docker compose up -d
docker compose logs -f infra
```

### Confirm a healthy start

On a healthy first boot Infra logs the accounts it bootstrapped, the secrets it
generated, and the onboarding address — something like:

```
{"level":"info","msg":"System Account Loaded"}
{"level":"info","msg":"Inflow Infrastructure Account is ready"}
{"level":"info","msg":"API Secret Key is : <...>"}
{"level":"info","msg":"you can add inflow resource by  'curl -fsSL http://<host>:8022/fractal/11/install.sh | bash'"}
{"level":"info","msg":"Infra Server on NatsIO is ready on port 4222"}
{"level":"info","msg":"Infra Started"}
```

> If you left `API_JWT_SECRET` blank, copy the **API Secret Key** value from
> these logs — you'll need it in Part 2. (Setting it yourself is easier.)

The **Fractal** service registers itself automatically against Infra's built-in
default portal (`/register/abc`) over `inflow_net` — no manual `curl | bash`
needed for this first runtime. Confirm it:

```bash
docker compose logs fractal        # should show a successful registration
docker compose ps                  # infra + fractal both "running"
```

That's the whole platform. See [Adding more Fractals](#adding-more-fractals)
and [Security & persistence](#security--persistence) below when you go past a
trial.

---

## Part 2 — Inspector panel (backend + frontend)

The panel joins the **same** `inflow_net`, so the platform must be running first.

```bash
cd ../inspector
cp .env.example .env
```

Edit `.env` and set **`INFLOW_INFRA_JWT_SECRET`** to Infra's **API Secret Key**
(what you set as `API_JWT_SECRET`, or the value Infra printed in its logs). Then:

```bash
docker compose up -d
docker compose logs -f          # watch the first-start clone + compile
```

Both images pull instantly, but they're **self-building**: rather than shipping
a prebuilt binary, each image's entrypoint clones its source and **compiles it
inside the container at start**, native to your CPU (amd64 or arm64). So the
first `up` takes a few minutes while it clones + builds; a named volume caches
the checkout afterward. The two components:

- **inflow-inspector-api** (`mehdishokohi/inflow-inspector-api`) — the panel
  backend, source at
  [github.com/Inflowenger/inflow-inspector-api](https://github.com/Inflowenger/inflow-inspector-api).
  Reaches Infra at `http://inflow-infra:8022` over the shared network, and
  reverse-proxies `/infra/*` to it for the panel's infra views.
- **inflow-inspector** (`mehdishokohi/inflow-inspector`) — the Vue panel, source
  at [github.com/Inflowenger/inflow-inspector](https://github.com/Inflowenger/inflow-inspector).
  Static assets with **no** backend URL baked in — you point it at the backend
  from the Auth dialog at runtime (see below).

> **Which ref it builds.** By default each image checks out and compiles the
> `master` branch. Pin a release tag for reproducible restarts by setting
> `INSPECTOR_API_REF` / `INSPECTOR_REF` in `.env`. To re-pull the latest source
> and recompile, `docker compose restart` (the entrypoint re-fetches + rebuilds).

### Sign in to the panel

`inflow-inspector` authenticates exactly like an **OpenAPI / Swagger UI**: the
frontend is just static assets with **no** credentials and **no** backend URL
baked in, and there's no server-side session. Nothing is stored on a server —
you *authorize your own browser* at runtime, the same way you click "Authorize"
in Swagger. That's a deliberate design choice, not a shortcut: because the panel
carries no secrets, the same build is safe to serve from anywhere its address is
reachable, and each viewer supplies their own credentials.

1. Go to `http://localhost:8080`.
2. The **Auth** dialog opens (it opens automatically until you're
   authenticated). Fill in the **Base Server URL** —
   `http://localhost:8025` (the inflow-inspector-api) — then pick one tab:
   - **Shared Secret** — enter Infra's **API Secret Key** (the same value as
     `INFLOW_INFRA_JWT_SECRET`). The panel signs an HS256 `{ admin: true }` JWT
     from it **in your browser** and sends that as the bearer token; the backend
     verifies the signature with the matching secret.
   - **Bearer Token** — paste a ready-made JWT to use directly (handy for a
     token minted elsewhere, or a non-admin/scoped token).

The chosen URL + token are saved in your browser's `localStorage`
(`inflow_auth_url` / `inflow_auth_token`), so you authenticate once per browser.
Re-open the dialog and hit **Log Out** to clear them.

> **Security — read before exposing this.** The panel being reachable is *not*
> access: every request still carries a JWT that the inflow-inspector-api
> verifies against its `INFLOW_INFRA_JWT_SECRET`. The real gate is that shared
> secret — anyone who can reach the backend **and** holds the secret gets
> `admin: true`. So treat the API Secret Key as a credential (never commit it,
> never put it in `VITE_*`/frontend build args), and don't expose the
> inflow-inspector-api on an untrusted network without something in front of it.
> A public-facing panel with a locked-down/unreachable backend is fine; a
> public-facing backend is what you must guard.

### Verify end-to-end

- `http://localhost:8025` — inflow-inspector-api is up (Fiber responds).
- After signing in, the panel lists/creates flows and context, and the **Spaces
  / Resources** views load (proving the `/infra/*` proxy → Infra works).
- Running a flow streams logs into the panel's log drawer over WebSocket — that
  confirms the whole chain (inflow-inspector → inflow-inspector-api → NATS →
  Fractal) is wired.

---

## Ports

| Port   | Service          | Purpose                                  |
|--------|------------------|------------------------------------------|
| `8022` | Infra            | HTTP API / onboarding portal             |
| `8222` | Infra            | NATS HTTP monitor                        |
| `4222` | Infra            | NATS client (only if connecting locally) |
| `8025` | inflow-inspector-api | REST + WebSocket log feed             |
| `8080` | inflow-inspector | The inspector panel UI                   |

## Environment variables

**Platform** (`platform/.env`):

| Var              | Purpose                                                            |
|------------------|--------------------------------------------------------------------|
| `OPERATOR_SEED`  | NATS operator key signing all JWTs. Blank → generated & persisted. |
| `API_JWT_SECRET` | Infra API secret. **Share this with the inspector panel.**         |
| `INFRA_CLUSTER`  | Cluster name for a paid/sponsored license. Blank for free use.     |
| `FRACTAL_TAGS`   | Comma-separated tags for the Fractal runtime.                      |

**Inspector panel** (`inspector/.env`):

| Var                       | Purpose                                                     |
|---------------------------|-------------------------------------------------------------|
| `INFLOW_INFRA_JWT_SECRET` | Infra's API Secret Key (from its logs / `API_JWT_SECRET`).   |
| `INSPECTOR_API_REF`       | Branch/tag the backend image clones + builds at start (default `master`). |
| `INSPECTOR_REF`           | Branch/tag the frontend image clones + builds at start (default `master`). |

---

## Adding more Fractals

The compose file starts one Fractal. To add more against a running Infra, use
the scoped one-liner from Infra's logs (it goes through the default portal, no
token required):

```bash
curl -fsSL http://localhost:8022/fractal/11/install.sh | bash
```

It prompts for a container name and tags, ensures the `inflow_net` network
exists, and joins the new Fractal to it. Copy the exact URL from *your* Infra
logs — the portal id is instance-specific.

## Security & persistence

- **Persist Infra state.** The platform stack mounts `./store:/data` so the
  operator seed and API key survive restarts. Without persistence, every restart
  mints new keys and invalidates existing Fractals, plugins, and panels.
- **Bring your own operator seed.** For real deployments, generate the NATS
  operator key yourself (`nats nkey`) and set `OPERATOR_SEED` rather than relying
  on a generated one.
- **Close the default portal.** The `/register/abc` default portal accepts
  unauthenticated Fractal installs for easy onboarding. Once you've added the
  runtimes you need, disable it from the admin panel.

---

## Teardown

```bash
# inspector panel (add -v to also drop the cached source-build volumes)
cd inspector && docker compose down

# platform (add -v to also delete Infra's persisted keys in ./store)
cd ../platform && docker compose down
```

## Troubleshooting

- **`network inflow_net declared as external, but could not be found`** — the
  shared network doesn't exist yet. Create it once with
  `docker network create inflow_net` (the one-liner installer does this for you).
- **Panel says unauthorized / 401** — the **Shared Secret** you entered in the
  Auth dialog, the backend's `INFLOW_INFRA_JWT_SECRET`, and Infra's API Secret
  Key must all be the same value. If you changed the secret, restart
  inflow-inspector-api and re-authenticate in the dialog.
- **Fractal keeps restarting** — it retries until Infra is reachable. Check
  `docker compose logs infra`; confirm Infra finished booting and the
  `REGISTER_URL` portal path (`abc` by default) is correct.
- **Frontend points at the wrong API** — the backend URL isn't baked into the
  image; it's whatever you entered as **Base Server URL** in the Auth dialog
  (saved in `localStorage`). Re-open the dialog, hit **Log Out**, and sign in
  again with the correct URL.
- **Port already in use** — edit the `ports:` mapping in the relevant compose
  file (e.g. `"18080:80"`).

---

## Layout

```
getting-started/
├── README.md                     ← you are here
├── install.sh                    one-liner installer (curl | bash)
├── platform/
│   ├── docker-compose.yml        infra + fractal
│   └── .env.example
└── inspector/
    ├── docker-compose.yml        inflow-inspector-api + inflow-inspector
    └── .env.example
```

This folder is just the orchestration and the tutorial that ties everything
together — it pulls images and stands them up. The panel's two components each
live in (and are published from) their own repos:

- **inflow-inspector-api** — https://github.com/Inflowenger/inflow-inspector-api
  (published as `mehdishokohi/inflow-inspector-api`).
- **inflow-inspector** — https://github.com/Inflowenger/inflow-inspector
  (published as `mehdishokohi/inflow-inspector`).

## For maintainers — publishing the images

All four images are pulled from Docker Hub, so all four must be published there
as **multi-arch manifests** (so `docker compose pull` resolves amd64 or arm64
automatically). They split into two kinds:

| Image | Kind | What the image contains |
|-------|------|-------------------------|
| `mehdishokohi/inflow-infra` | prebuilt binary | The compiled Infra service (embedded NATS + coordinator). |
| `mehdishokohi/fractal` | prebuilt binary | The compiled Fractal runtime. |
| `mehdishokohi/inflow-inspector-api` | **self-building** | Go toolchain + git + an entrypoint that clones & compiles the source at container start. No app binary baked in. |
| `mehdishokohi/inflow-inspector` | **self-building** | node + pnpm + git + a static server + an entrypoint that clones & builds the SPA at container start. No assets baked in. |

The two self-building images are cheap to publish multi-arch — they contain no
compiled artifacts, so buildx just layers the base image + entrypoint per arch;
the actual compile happens on the user's machine at run time:

```bash
# platform binaries (built however you build them, then pushed multi-arch)
docker buildx build --platform linux/amd64,linux/arm64 -t mehdishokohi/inflow-infra:latest --push .
docker buildx build --platform linux/amd64,linux/arm64 -t mehdishokohi/fractal:latest       --push .

# self-building panel images — context is irrelevant, so build straight from the Dockerfile
docker buildx build --platform linux/amd64,linux/arm64 -t mehdishokohi/inflow-inspector-api:latest --push - < path/to/inflow-inspector-api/Dockerfile
docker buildx build --platform linux/amd64,linux/arm64 -t mehdishokohi/inflow-inspector:latest     --push - < path/to/inflow-inspector/Dockerfile
```

Because the panel images fetch source over HTTPS at run time, both repos must be
**publicly cloneable** (or users must supply Git credentials to the containers).
