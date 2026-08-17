# Docker Deployment

DeepSeek Harness ships a Docker image and a docker-compose orchestration for one-shot build and run.

## Deliverables

| File | Purpose |
| --- | --- |
| `Dockerfile` | Multi-stage build (base → builder → optional python-builder → runtime) |
| `.dockerignore` | Build-context filter; excludes secrets and irrelevant artifacts |
| `docker-compose.yml` | Orchestration: named volumes, env, ports, privilege drop |
| `docker/entrypoint.sh` | Entrypoint: volume init + nginx start + non-root drop + forward to built CLI |
| `docker/nginx.conf` | nginx reverse proxy template: LAN allowlist + WebSocket/SSE passthrough |
| `.env.example` | Environment template (placeholders, no real secrets) |

## Quick start

Boots the Web UI (`web` profile) by default. The web app binds `127.0.0.1` (it rejects `--host 0.0.0.0` for RCE safety); an in-container nginx reverse proxy binds `0.0.0.0:3080`, restricts clients to `DSH_ALLOW_CIDR` (default `192.168.0.0/24`), and proxies to the loopback backend. Docker maps host port 3080 to nginx:

```sh
cp .env.example .env          # fill in DEEPSEEK_API_KEY
docker compose up --build     # build and start the Web UI
docker compose down           # stop, keep volume data
```

The UI is reachable at `http://<host-ip>:3080` from any machine in the allowed CIDR.

> `crypto.randomUUID` is only available in browser secure contexts (HTTPS or localhost). Since LAN access uses plain HTTP, nginx injects a `crypto.randomUUID` polyfill (backed by `crypto.getRandomValues`) into the served HTML via `sub_filter`, so the UI works without HTTPS certificates.

> To restrict access to a different LAN, set `DSH_ALLOW_CIDR=10.0.0.0/8` (or your CIDR) in `.env`. To disable nginx and expose loopback-only on the host, set `DSH_ALLOW_CIDR=` (empty) and switch `docker-compose.yml` to `network_mode: host`.

## Build variants

`INCLUDE_WEB` and `INCLUDE_PYTHON` orthogonally combine into 4 variants:

| Tag | INCLUDE_WEB | INCLUDE_PYTHON | Description |
| --- | --- | --- | --- |
| `dsh:<tag>` | false | false | Base runtime |
| `dsh:<tag>-web` | true | false | With web frontend assets (compose default) |
| `dsh:<tag>-python` | false | true | With Python SDK runtime |
| `dsh:<tag>-web-python` | true | true | Full variant |

```sh
docker build -t dsh:dev .
docker build --build-arg INCLUDE_WEB=true -t dsh:dev-web .
docker build --build-arg INCLUDE_PYTHON=true -t dsh:dev-python .
```

## Build ARGs

| Arg | Default | Description |
| --- | --- | --- |
| `NODE_VERSION` | `22` | Node major; must satisfy `^22.19 \|\| >=24` |
| `PNPM_VERSION` | `11.7.0` | Must match `package.json` packageManager |
| `INCLUDE_PYTHON` | `false` | Bundle the Python SDK runtime |
| `INCLUDE_WEB` | `false` | Bundle the web frontend `dist/` (compose default `true`) |
| `IMAGE_TAG` | `dev` | OCI image version label |
| `DSH_UID` | `1001` | Non-root runtime user UID |
| `GIT_SHA` | `unknown` | git short SHA for OCI labels |

## Multi-arch build

landlock native binaries are native-only; buildx runs an independent builder per platform:

```sh
docker buildx build --platform linux/amd64,linux/arm64 -t dsh:dev .
```

## Environment variables

| Variable | Required | Description |
| --- | --- | --- |
| `DEEPSEEK_API_KEY` | yes | DeepSeek API key; inject at runtime, never bake into the image |
| `DEEPSEEK_BASE_URL` | no | API endpoint override (self-hosted gateway) |
| `DSH_PROFILE` | no | Profile name to boot (equiv. `--profile <name>`), default `web` |
| `DSH_WEB_PORT` | no | External port nginx listens on (mapped 1:1 to host), default `3080` |
| `DSH_ALLOW_CIDR` | no | CIDR allowed through nginx (empty disables nginx; use `network_mode: host`), default `192.168.0.0/24` |
| `DSH_SESSIONS_DIR` | no | Sessions dir, default `/app/.sessions` |
| `DSH_STORAGES_DIR` | no | Storages dir, default `/app/.storages` |

## Volumes

| Container path | Purpose |
| --- | --- |
| `/app/.sessions` | Session persistence (named volume `dsh-sessions`) |
| `/app/.storages` | Storage persistence (named volume `dsh-storages`) |
| `/app/profiles` | Optional: profile dir (mount to `$DSH_HOME/profiles/<name>`) |
| `/app/cordis.yml` | Optional: custom profile, read-only mount |

## Security constraints

- The runtime process runs as non-root user `dsh` (UID 1001); the entrypoint starts as root to chown volumes, then drops privileges via `gosu`.
- The web app binds `127.0.0.1` only; it rejects `--host 0.0.0.0` to avoid exposing remote code execution to the network. nginx fronts it with a CIDR allowlist (`allow`/`deny`).
- `privileged: true` is forbidden; mounting the host Docker socket is forbidden.
- `DEEPSEEK_API_KEY` is injected at runtime only (`-e` or `env_file`); no image layer contains the secret.
- `.dockerignore` excludes `.env`, `.git/`, `node_modules/`, `.sessions/`, etc.

## Integration with the existing build

- The image reuses `pnpm run build` (`build:lib:host` + `build:lib:client` + `build:web`); no existing build script is modified.
- The runtime entrypoint points at the built artifact `apps/cli/lib/bin.js` (artifact plane), not `src/bin.ts`.
- Artifact paths match local builds (`lib/`, `types/`, `apps/web/dist/`); no path drift.

## OCI provenance

The image carries these labels, readable via `docker inspect`:

- `org.opencontainers.image.revision` — git short SHA (`GIT_SHA`)
- `org.opencontainers.image.version` — `IMAGE_TAG`
- `org.opencontainers.image.variant` — `web=<bool>,python=<bool>`
