# syntax=docker/dockerfile:1.7
# DeepSeek Harness — multi-stage Docker image.
#
# Stages:  base (toolchain+pnpm) -> builder (install+build+prune)
#          -> python-builder (optional hatch wheel) -> runtime (non-root).
#
# Build args:
#   NODE_VERSION    Node major/minor (must satisfy ^22.19 || >=24).  Default 22.
#   PNPM_VERSION    pnpm version; must match package.json packageManager.
#   INCLUDE_PYTHON  "true" to bundle the Python SDK runtime.        Default false.
#   INCLUDE_WEB     "true" to bundle the web frontend dist.          Default false.
#   IMAGE_TAG       version label stamped into OCI labels.           Default dev.
#   DSH_UID         unprivileged user UID inside the runtime image.   Default 1001.
#   GIT_SHA         short git revision for OCI labels.                Default unknown.
#
# Variants (via -t):  dsh:<tag>[-web][-python]
#   docker build -t dsh:dev .
#   docker build --build-arg INCLUDE_WEB=true  -t dsh:dev-web .
#   docker build --build-arg INCLUDE_PYTHON=true -t dsh:dev-python .
#   docker build --build-arg INCLUDE_WEB=true --build-arg INCLUDE_PYTHON=true -t dsh:dev-web-python .

ARG NODE_VERSION=22
ARG PNPM_VERSION=11.7.0
ARG INCLUDE_PYTHON=false
ARG INCLUDE_WEB=false
ARG IMAGE_TAG=dev
ARG DSH_UID=1001
ARG GIT_SHA=unknown

# ============================================================================
# base — compiler toolchain + pnpm
# ============================================================================
FROM node:${NODE_VERSION}-bookworm AS base
ARG PNPM_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
        make g++ python3 musl-tools gosu ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable \
    && corepack prepare pnpm@${PNPM_VERSION} --activate \
    && pnpm --version

# ============================================================================
# builder — install, compile native addons, build all artifacts, prune dev deps
# ============================================================================
FROM base AS builder
ARG INCLUDE_WEB
WORKDIR /app
# CI=true lets pnpm purge dev modules without an interactive TTY prompt.
ENV CI=true
COPY . ./
RUN pnpm install --frozen-lockfile
# Compile landlock native binaries (musl-gcc -static; native-only, Linux builder).
RUN pnpm --filter @deepseek-ai/node-addon-landlock-run-workspace run build:native
# Build lib/ (host+client), types/, and web dist/ via the existing pipeline.
RUN pnpm run build
# pnpm has no `prune` subcommand; reinstall prod-only to drop devDependencies.
# --ignore-scripts avoids re-running native builds already produced above.
RUN pnpm install --prod --frozen-lockfile --ignore-scripts
# Strip dev-only sources from the artifact plane; keep lib/, types/, node_modules.
RUN find /app -type d \( -name src -o -name tests -o -name test -o -name __tests__ \) \
        -not -path '*/node_modules/*' -prune -exec rm -rf {} + \
    && find /app -maxdepth 6 -name '*.ts' -not -path '*/node_modules/*' -delete \
    && rm -rf /app/docs /app/website /app/examples /app/scripts /app/docker \
              /app/.git /app/coverage /app/.codeartsdoer \
    && if [ "$INCLUDE_WEB" != "true" ]; then rm -rf /app/apps/web/dist; fi

# ============================================================================
# python-builder — optional Python SDK runtime wheel (hatch)
# ============================================================================
FROM base AS python-builder
ARG INCLUDE_PYTHON
WORKDIR /work
RUN if [ "$INCLUDE_PYTHON" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends python3-venv pipx \
        && rm -rf /var/lib/apt/lists/* \
        && pipx install uv && pipx install hatch; \
    fi
COPY --from=builder /app/python ./python
RUN if [ "$INCLUDE_PYTHON" = "true" ]; then \
        cd python/sdk-runtime \
        && uv sync \
        && hatch build \
        && mkdir -p /out/python && cp -a dist /out/python/; \
    else \
        mkdir -p /out/python; \
    fi

# ============================================================================
# runtime — non-root, artifact-plane only
# ============================================================================
FROM node:${NODE_VERSION}-bookworm-slim AS runtime
ARG DSH_UID
ARG INCLUDE_PYTHON
ARG INCLUDE_WEB
ARG IMAGE_TAG
ARG GIT_SHA

LABEL org.opencontainers.image.title="DeepSeek Harness" \
      org.opencontainers.image.source="https://github.com/deepseek-ai/deepseek-harness" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.version="${IMAGE_TAG}" \
      org.opencontainers.image.variant="web=${INCLUDE_WEB},python=${INCLUDE_PYTHON}"

# gosu for privilege drop; python3 only when the Python variant is requested.
RUN apt-get update && apt-get install -y --no-install-recommends gosu ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && if [ "$INCLUDE_PYTHON" = "true" ]; then \
           apt-get update && apt-get install -y --no-install-recommends python3 python3-venv \
           && rm -rf /var/lib/apt/lists/*; \
       fi

RUN groupadd -g ${DSH_UID} dsh \
    && useradd -u ${DSH_UID} -g dsh -m -d /home/dsh -s /bin/sh dsh

WORKDIR /app
COPY --from=builder /app ./
COPY --from=python-builder /out/python ./python-runtime

ENV DSH_HOME=/app \
    DSH_SESSIONS_DIR=/app/.sessions \
    DSH_STORAGES_DIR=/app/.storages \
    DSH_UID=${DSH_UID}

RUN mkdir -p /app/.sessions /app/.storages && chown -R dsh:dsh /app

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# The entrypoint starts as root to chown mounted volumes, then execs gosu dsh.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
