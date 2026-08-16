# Docker Deployment

DeepSeek Harness ships a Docker image and a docker-compose orchestration for one-shot build and run.

## Deliverables

| File | Purpose |
| --- | --- |
| `Dockerfile` | Multi-stage build (base → builder → optional python-builder → runtime) |
| `.dockerignore` | Build-context filter; excludes secrets and irrelevant artifacts |
| `docker-compose.yml` | Orchestration: named volumes, env, ports, privilege drop |
| `docker/entrypoint.sh` | Entrypoint: volume init + non-root drop + forward to built CLI |
| `.env.example` | Environment template (placeholders, no real secrets) |

## Quick start

```sh
cp .env.example .env          # fill in DEEPSEEK_API_KEY
docker compose up --build     # build and start
docker compose down           # stop, keep volume data
```

## Build variants

`INCLUDE_WEB` and `INCLUDE_PYTHON` orthogonally combine into 4 variants:

| Tag | INCLUDE_WEB | INCLUDE_PYTHON | Description |
| --- | --- | --- | --- |
| `dsh:<tag>` | false | false | Base runtime (default) |
| `dsh:<tag>-web` | true | false | With web frontend assets |
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
| `INCLUDE_WEB` | `false` | Bundle the web frontend `dist/` |
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
| `DSH_SESSIONS_DIR` | no | Sessions dir, default `/app/.sessions` |
| `DSH_STORAGES_DIR` | no | Storages dir, default `/app/.storages` |
| `WEB_PORT` | no | Web UI host port (compose), default `3000` |

## Volumes

| Container path | Purpose |
| --- | --- |
| `/app/.sessions` | Session persistence (named volume `dsh-sessions`) |
| `/app/.storages` | Storage persistence (named volume `dsh-storages`) |
| `/app/cordis.yml` | Optional: custom profile, read-only mount |

## Security constraints

- The runtime process runs as non-root user `dsh` (UID 1001); the entrypoint starts as root to chown volumes, then drops privileges via `gosu`.
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
