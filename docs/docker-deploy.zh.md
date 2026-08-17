# Docker 部署

DeepSeek Harness 提供 Docker 镜像与 docker-compose 编排，支持一键构建与运行。

## 交付物

| 文件 | 作用 |
| --- | --- |
| `Dockerfile` | 多阶段镜像构建（base → builder → 可选 python-builder → runtime） |
| `.dockerignore` | 构建上下文过滤，排除敏感文件与无关产物 |
| `docker-compose.yml` | 服务编排：命名卷、环境变量、端口、降权 |
| `docker/entrypoint.sh` | 入口脚本：卷初始化 + nginx 启动 + 非 root 降权 + 转发构建产物 |
| `docker/nginx.conf` | nginx 反向代理模板：局域网白名单 + WebSocket/SSE 透传 |
| `.env.example` | 环境变量模板（占位，不含密钥） |

## 快速开始

默认启动 Web UI（`web` profile）。Web app 绑定 `127.0.0.1`（出于安全拒绝 `--host 0.0.0.0`）；容器内 nginx 反向代理绑定 `0.0.0.0:3080`，通过 `DSH_ALLOW_CIDR`（默认 `192.168.0.0/24`）限制客户端，并代理到回环后端。Docker 将宿主机 3080 端口映射到 nginx：

```sh
cp .env.example .env          # 填入 DEEPSEEK_API_KEY
docker compose up --build     # 构建并启动 Web UI
docker compose down           # 停止并保留卷数据
```

允许 CIDR 内任意机器通过 `http://<宿主机IP>:3080` 访问 UI。

> 如需限制为其他局域网，在 `.env` 中设置 `DSH_ALLOW_CIDR=10.0.0.0/8`（或你的 CIDR）。如需禁用 nginx、仅允许宿主机回环访问，设置 `DSH_ALLOW_CIDR=`（留空）并将 `docker-compose.yml` 改为 `network_mode: host`。

## 构建变体

通过 `INCLUDE_WEB` 与 `INCLUDE_PYTHON` 两个构建参数正交组合出 4 种变体：

| 变体标签 | INCLUDE_WEB | INCLUDE_PYTHON | 说明 |
| --- | --- | --- | --- |
| `dsh:<tag>` | false | false | 基础运行时 |
| `dsh:<tag>-web` | true | false | 含 Web 前端静态资源（compose 默认） |
| `dsh:<tag>-python` | false | true | 含 Python SDK 运行时 |
| `dsh:<tag>-web-python` | true | true | 全量变体 |

```sh
docker build -t dsh:dev .
docker build --build-arg INCLUDE_WEB=true -t dsh:dev-web .
docker build --build-arg INCLUDE_PYTHON=true -t dsh:dev-python .
```

## Build ARG

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `NODE_VERSION` | `22` | Node 主版本，须满足 `^22.19 \|\| >=24` |
| `PNPM_VERSION` | `11.7.0` | 须与 `package.json` 的 `packageManager` 一致 |
| `INCLUDE_PYTHON` | `false` | 是否打包 Python SDK 运行时 |
| `INCLUDE_WEB` | `false` | 是否打包 Web 前端 `dist/`（compose 默认 `true`） |
| `IMAGE_TAG` | `dev` | OCI 镜像版本标签 |
| `DSH_UID` | `1001` | 运行时非 root 用户 UID |
| `GIT_SHA` | `unknown` | git short SHA，写入 OCI labels |

## 多架构构建

landlock 原生二进制为 native-only 编译，buildx 为每个平台运行独立 builder：

```sh
docker buildx build --platform linux/amd64,linux/arm64 -t dsh:dev .
```

## 环境变量

| 变量 | 必需 | 说明 |
| --- | --- | --- |
| `DEEPSEEK_API_KEY` | 是 | DeepSeek API 密钥，运行时注入，禁止烘焙进镜像 |
| `DEEPSEEK_BASE_URL` | 否 | API 端点覆盖（自建网关） |
| `DSH_PROFILE` | 否 | 启动 profile 名（等价 `--profile <name>`），默认 `web` |
| `DSH_WEB_PORT` | 否 | nginx 监听的外部端口（与宿主机 1:1 映射），默认 `3080` |
| `DSH_ALLOW_CIDR` | 否 | 允许通过 nginx 的 CIDR（留空禁用 nginx；改用 `network_mode: host`），默认 `192.168.0.0/24` |
| `DSH_SESSIONS_DIR` | 否 | 会话目录，默认 `/app/.sessions` |
| `DSH_STORAGES_DIR` | 否 | 存储目录，默认 `/app/.storages` |

## 卷挂载

| 容器路径 | 用途 |
| --- | --- | --- |
| `/app/.sessions` | 会话持久化（命名卷 `dsh-sessions`） |
| `/app/.storages` | 存储持久化（命名卷 `dsh-storages`） |
| `/app/profiles` | 可选：profile 目录（挂载到 `$DSH_HOME/profiles/<name>`） |
| `/app/cordis.yml` | 可选：自定义 profile 只读挂载 |

## 安全约束

- 运行时进程以非 root 用户 `dsh`（UID 1001）运行；入口脚本以 root 初始化卷属权后通过 `gosu` 降权。
- Web app 仅绑定 `127.0.0.1`；拒绝 `--host 0.0.0.0` 以避免将远程代码执行暴露到网络。nginx 通过 CIDR 白名单（`allow`/`deny`）前置代理。
- 禁止 `privileged: true`，禁止挂载宿主机 Docker Socket。
- `DEEPSEEK_API_KEY` 仅运行时注入（`-e` 或 `env_file`），镜像层不含密钥明文。
- `.dockerignore` 排除 `.env`、`.git/`、`node_modules/`、`.sessions/` 等敏感与无关路径。

## 与现有构建流程衔接

- 镜像构建复用 `pnpm run build`（`build:lib:host` + `build:lib:client` + `build:web`），不修改任何存量构建脚本。
- 运行时入口指向构建产物 `apps/cli/lib/bin.js`（artifact plane），而非源码 `src/bin.ts`。
- 产物路径与本地构建一致（`lib/`、`types/`、`apps/web/dist/`），无路径漂移。

## OCI 可追溯性

镜像携带以下 labels，可通过 `docker inspect` 读取：

- `org.opencontainers.image.revision` — git short SHA（`GIT_SHA`）
- `org.opencontainers.image.version` — `IMAGE_TAG`
- `org.opencontainers.image.variant` — `web=<bool>,python=<bool>`
