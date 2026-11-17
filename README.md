# OPC 2.0 生产部署手册（aiwork-bl）

> **给首次接手的运维**：本手册按 **`00 → 01 → 02 → 03 → 04 → 05 → 06`** 顺序编写。每一步都会标明 **在哪台机器执行、改哪几个配置、复制哪条命令、看到什么算通过**。

---

## 快速导航

| 我要做什么 | 直接去这里 |
| --- | --- |
| 全新安装整套 OPC 2.0 | 按顺序执行 [00](#step-00) → [01](#step-01) → [02](#step-02) → [03](#step-03) → [04](#step-04) → [05](#step-05) → [06](#step-06) |
| 更新代码、配置或环境变量 | [日常更新与重跑](#ops-update) |
| 升级失败或版本回退 | [版本回退](#ops-rollback) |
| 旧环境 / 旧 Deploy 迁入 | [旧环境迁移前必查](#ops-migrate) |
| 服务器不能连外网构建镜像 | [离线构建机打包与导入（`--skip-build`）](#ops-offline) |
| 报错定位 / 目录备份 | [常用排查与数据备份](#ops-troubleshooting) |

---

## 1. 机器分工与端口总览

整套系统涉及三类节点（其中准备机可以是运维电脑或能连 GitHub 的跳板机）：

```text
[源码准备机]  00-prepare-source.sh ──▶ SSH + rsync 分发到两台服务器 /data/aiwork-bl
                                           │
                   ┌───────────────────────┴───────────────────────┐
                   ▼                                               ▼
        [业务机]（root_default 网桥）                     [Swarm 机]（单节点 Swarm）
        ├── 01 基础层（compose: opc-infra）               └── 04 Deploy 与应用代理
        │   ├── infra-postgres   :5432                        ├── deploy-opc          :3008 → 3000
        │   ├── infra-redis      :6379                        ├── captain-nginx       :3009 → 80 / :3443 → 443
        │   ├── infra-minio      :9000 / :9001                ├── deploy-opc-console  :3010 → 80
        │   ├── infra-etcd       内网                         └── captain-certbot     证书辅助
        │   ├── infra-milvus     内网
        │   └── infra-neo4j      :7474 / :7687
        ├── 02 平台组件（compose: opc-platform）
        │   ├── opc-clickhouse       内网
        │   ├── opc-llm-gateway      :3004 → 4000
        │   ├── opc-mcp-gateway      :3005 → 80 / :3006 → 5235
        │   ├── opc-langfuse-web     :3000 → 3000
        │   ├── opc-langfuse-worker  内网
        │   ├── opc-docreader        内网 50051
        │   └── opc-paddleocr        :8088 → 8080
        └── 03 业务层（compose: opc-business）
            ├── knowledge-opc-app      :3001 → 8080
            ├── platform-opc-gateway   :3002 → 3002
            └── knowledge-opc-frontend :3003 → 80
```

关键说明：
- **为什么有两处 `3000`**：业务机宿主机 `3000` 是 Langfuse Web；Swarm 机 `deploy-opc` 容器内部监听 `3000`，发布到 Swarm 机宿主机 `3008`，互不冲突。
- **动态应用与控制台分流**：动态应用默认使用 `<appslug>.<MAIN_DOMAIN>`，Deploy 控制台使用 `captain.<MAIN_DOMAIN>`。统一入口把 `captain.<MAIN_DOMAIN>` 转到 Swarm 机 `3010`（`deploy-opc-console`），把其他 `*.<MAIN_DOMAIN>` 转到 Swarm 机 `3009`（`captain-nginx`），并保留原始 `Host`。
- **服务名区分**：新装 Swarm 机服务名是 `deploy-opc`、`captain-nginx`、`deploy-opc-console`；`captain-captain` 仅用于识别旧版本地遗留实例。

---

## 2. 首次部署前准备

### 2.1 先收集这些现场信息

| 信息 | 示例 | 说明 |
| --- | --- | --- |
| 业务机内网 IP | `10.101.103.129` | 跑 00 网桥、01、02、03 |
| Swarm 机内网 IP | `10.101.103.131` | 跑 04（业务机需能访问其 `3008`/`3009`） |
| 主域名 `MAIN_DOMAIN` | `aiwork.example.com` | 主入口域名，动态应用为 `<appslug>.<MAIN_DOMAIN>`，控制台为 `captain.<MAIN_DOMAIN>` |
| 独立应用根域 `APP_ROOT_DOMAIN` | 留空 | 默认留空即沿用 `MAIN_DOMAIN`；仅当需要给动态应用单独根域时填写 |
| 企微配置（按需） | 企业 ID、应用密钥、账户中心 GraphQL 地址 | 不启用企微可先留空 |

### 2.2 两台服务器装好软件与系统参数

在 **业务机** 和 **Swarm 机** 上都确认满足以下条件（Linux x86_64，Ubuntu 24.04 已验证）：
- 已安装 **Docker Engine 25.0+**（支持 API v1.44）、`docker compose` 插件、Docker Buildx
- 已安装基础命令：`git`、`jq`、`curl`、`rsync`、`flock`、`openssl`（Ubuntu 可执行 `sudo apt-get update && sudo apt-get install -y git jq curl rsync util-linux openssl`）
- 建议磁盘 `/data` ≥ 100GB，业务机内存 ≥ 16GB
- 准备好部署目录并保证运维 SSH 账号可写：

```bash
sudo mkdir -p /data/aiwork-bl
sudo chown -R "$(id -un):$(id -gn)" /data/aiwork-bl
```

仅在 **业务机** 额外执行一次内核参数配置（Milvus 必需）：

```bash
printf '%s\n' 'vm.max_map_count=2000000' | sudo tee /etc/sysctl.d/99-milvus.conf
sudo sysctl --system
sysctl -n vm.max_map_count
```

> 看到输出 `2000000` 即通过。如使用华为云 SWR 私有镜像（01/02 含 OCR），提前用部署时相同的用户（例如 `sudo docker login`）登录镜像仓库。

---

## 3. 首次部署（00 → 06 照做）

<a id="step-00"></a>
### 00 准备源码并创建共享网桥

#### 00.1–00.3 拉取源码并分发到两台机器 `[源码准备机]`

在能访问 GitHub、且能 SSH 登录两台服务器的机器上，进入本目录执行：

```bash
bash 00-prepare-source.sh <运维账号@业务机> <运维账号@Swarm机>
# 示例：bash 00-prepare-source.sh ops@10.101.103.129 ops@10.101.103.131
```

脚本会自动完成以下事情（无需手工拷贝）：
1. 从 `https://github.com/shtokendance/*.git` 拉取 `platform-opc`、`knowledge-opc`、`deploy-opc` 的 `release` 分支，并按 `deploy-opc/release/release.conf` 中的 `RELEASE_FRONTEND_COMMIT` 拉取 `caprover-frontend` 固定提交到 `src/`（可通过修改脚本顶部 `DEPLOY_OPC_CONSOLE_REF` 指定特定提交或 tag）。
2. 把脚本、Compose、YAML 与 `src/` 同步到两台服务器 `/data/aiwork-bl`，并写入 `.source-ready` 校验标记。
3. **保护现场配置**：`01-infra.env`、`02-platform-components.env`、`03-business.env`（发往业务机）和 `04-deploy.env`（发往 Swarm 机）只在目标机不存在时首次发放，**不会覆盖已改好的现场 env**；`paddleocr/*` 与你自己新建的自定义 YAML（如 `03-config.platform-opc.local.yaml`）也会保留。

**看到什么算通过**：终端最后输出 `源码和部署文件已同步。首次部署请按 README 在业务机继续 00.4。`

#### 00.4 创建共享网桥 `[业务机]`

登录 **业务机** 执行：

```bash
cd /data/aiwork-bl
chmod +x 00-start-network.sh 01-start-infra.sh 02-start-platform-components.sh
sudo bash 00-start-network.sh
```

**看到什么算通过**：
```bash
sudo docker network inspect root_default --format '{{.Driver}}/{{.Scope}}'
```
输出 `bridge/local` 即通过。

---

<a id="step-01"></a>
### 01 启动数据库等基础服务 `[业务机]`

`01-infra.env` 和 `02-platform-components.env` 内已预置好配套的 PostgreSQL、Redis、MinIO、Neo4j 账号与密码，**全新安装无需修改 `01-infra.env` 内的密码**（如确需自定义，必须在首次启动前同时修改 `01-infra.env` 与 `02-platform-components.env` 中的同名变量）。

在 **业务机** 直接启动：

```bash
cd /data/aiwork-bl
sudo bash 01-start-infra.sh
```

> **重要提醒**：`01-start-infra.sh` 会导入 `01-init-databases.sql`。以后 **03 跑过数据库迁移后，日常重启 01 只能用 `docker compose` 命令，禁止再次运行 `01-start-infra.sh`**，以免覆盖迁移表结构或重置序列。

**看到什么算通过**：

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

6 个容器（`infra-postgres`、`infra-redis`、`infra-minio`、`infra-etcd`、`infra-milvus`、`infra-neo4j`）均为 `Up` 且健康；初始化出的 7 个库为 `weknora`、`weknora_gateway_state`、`deploy-opc`、`opc_apps`、`litellm`、`langfuse`、`opc_code`，MinIO 桶为 `weknora`、`langfuse`、`opc-apps`。

---

<a id="step-02"></a>
### 02 启动平台组件并添加模型 `[业务机 + 浏览器]`

#### 02.1 启动平台组件 `[业务机]`

`02-platform-components.env` 已与 `01-infra.env` 对齐密码，直接启动即可（如需补充 `OPENAI_API_KEY` / `DEEPSEEK_API_KEY` 等环境变量，可先编辑 `02-platform-components.env`）：

```bash
cd /data/aiwork-bl
sudo bash 02-start-platform-components.sh
```

脚本首次启动会自动把 `02-config.litellm.yaml` 复制到 `/data/aiwork/litellm/config.yaml`、把 `paddleocr/server.py` 复制到 `/data/aiwork/paddleocr/server.py`（后续重跑不覆盖线上修改）。

**看到什么算通过**：

```bash
sudo docker exec opc-docreader grpc_health_probe -addr=localhost:50051
curl -fsS http://127.0.0.1:3000/api/public/health && echo
curl -fsS http://127.0.0.1:3004/health/liveliness && echo
curl -fsS -o /dev/null -w 'MCP Admin HTTP %{http_code}\n' http://127.0.0.1:3005/
curl -fsS http://127.0.0.1:8088/health && echo
```

以上命令均返回正常响应（无报错 / HTTP 200）。

#### 02.2 在 LiteLLM 添加模型 `[浏览器]`

1. 浏览器打开 `http://<业务机IP>:3004/ui`（账号名按界面提示，密码见 `02-platform-components.env` 的 `LITELLM_UI_PASSWORD`）。
2. 在 **Models** 页面添加至少 1 个聊天模型和 1 个嵌入（Embedding）模型，并用界面上的 Test 功能测试连通（模型配置保存在 PostgreSQL 中）。
3. 记下模型名和调用 Key（`02-platform-components.env` 的 `LITELLM_MASTER_KEY`），第 06 步在 Knowledge 里要用。

---

<a id="step-03"></a>
### 03 交接数据库并启动业务服务 `[业务机]`

#### 03.1 首次数据库交接（仅全新首装执行一次）

`01-init-databases.sql` 预置了根租户 `10001`（带示例 Key `opc-root-tenant-key`），并将序列 `tenants_id_seq` 初始设为 `10000`。在第一次启动 03 前，先在 **业务机** 检查并修正序列起点、清空示例 Key：

```bash
sudo docker exec -i infra-postgres sh -c 'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d weknora' <<'SQL'
SELECT max(id) AS max_tenant_id FROM public.tenants;
SELECT last_value, is_called FROM public.tenants_id_seq;
SQL
```

确认最大租户 ID 为 `10001` 后（如果已有其他租户，请把下面 `10002` 改为 `max_tenant_id + 1`），执行交接：

```bash
sudo docker exec -i infra-postgres sh -c 'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d weknora' <<'SQL'
ALTER SEQUENCE public.tenants_id_seq RESTART WITH 10002;
UPDATE public.tenants SET api_key = '' WHERE id = 10001 AND api_key = 'opc-root-tenant-key';
SQL
```

#### 03.2 填写 `03-business.env` 与 `03-config.platform-opc.yaml`

> **已自动复用，不用重复抄**：`01-infra.env` 的 PostgreSQL / Redis / MinIO / Neo4j 账号密码、`AIWORK_DATA_DIR`，以及 `02-platform-components.env` 的 `LANGFUSE_INIT_PROJECT_PUBLIC_KEY` / `SECRET_KEY` 都会在 03 启动时**自动读取复用**；`PLATFORM_BRIDGE_KEY` 也会**自动复用下面的 `JWT_SECRET`**，都不用在 `03-business.env` 重填（若某台机器已有手填旧值也会优先兼容）。

1. `03-business.env` 已预填下面 5 个独立随机密钥的默认值（若需重新生成可执行下条命令；若环境已有旧实例，请沿用原密钥不要更换）：

```bash
printf 'JWT_SECRET=%s\nSYSTEM_AES_KEY=%s\nPLATFORM_ADMIN_KEY=%s\nPLATFORM_AUTH_KEY=%s\nOIDC_CLIENT_SECRET=%s\n' \
  "$(openssl rand -hex 32)" "$(openssl rand -hex 16)" "$(openssl rand -hex 32)" \
  "$(openssl rand -hex 32)" "$(openssl rand -hex 32)"
```

2. 编辑 `/data/aiwork-bl/03-business.env` 并收紧权限（`chmod 600`）：

```bash
cd /data/aiwork-bl
chmod 600 03-business.env
vim 03-business.env
```

只需关注以下配置（值中含有 `$` 或 `#` 时用单引号 `'...'` 包裹）：

- **第 1 组：域名与主机构通（必填）**
  - `MAIN_DOMAIN`：主域名（如 `aiwork.example.com`）
  - `APP_ROOT_DOMAIN`：默认留空即可（自动使用 `MAIN_DOMAIN`，即动态应用为 `<appslug>.<MAIN_DOMAIN>`、控制台为 `captain.<MAIN_DOMAIN>`）
  - `DEPLOY_OPC_HOST`：填写 **Swarm 机内网 IP**（不带 `http://` 和端口；即使 04 尚未启动也要提前填好）
  - `INFRA_HOST`：默认留空（启动 03 时自动用 `ip -4 route get <DEPLOY_OPC_HOST>` 识别本机内网 IP，连同 `01-infra.env` 的 PG/Redis/MinIO 账号密码一起渲染进 `online_resources`，供 04 动态应用绑定共享数据库/Redis/对象存储；仅多网卡冲突或需指定域名时填写）
  - `CONFIG_PLATFORM_FILE`：默认 `03-config.platform-opc.yaml`；若现场修改了模板内容，建议复制成独立文件名（如 `03-config.platform-opc.local.yaml`）再填到这里，避免 `00-prepare-source.sh` 覆盖（自定义模板内必须保留 `@ACCOUNT_CENTER_GRAPHQL_URL@` 占位符）
- **第 2 组：03 新增业务密钥（模板已预填默认值）**
  - `JWT_SECRET`、`SYSTEM_AES_KEY`（32 位 ASCII）、`PLATFORM_ADMIN_KEY`、`PLATFORM_AUTH_KEY`、`OIDC_CLIENT_SECRET`（不启用企微也要保留；模板已预填随机默认值，接管旧实例时替换为原密钥）
  - `CAPROVER_PASSWORD`：**默认留空**（自动使用 CapRover 原始默认密码 `captain42`）；如需自定义则填 8–29 个可打印 ASCII 字符且不含空格，并与第 04 步 Swarm 机保持一致（建议公网开放控制台后在 Deploy 中或通过该变量修改密码）
- **第 3 组：企微与按需选填项**
  - **启用企微时填写**：`ACCOUNT_CENTER_GRAPHQL_URL`（Platform 容器可达的账户中心地址，如 `http://omni-router.benlai.com/graphql`）以及 `WECOM_CORP_ID`、`WECOM_AGENT_ID`、`WECOM_APP_SECRET`、`WECOM_TOKEN`、`WECOM_ENCODING_AES_KEY`（`WECOM_CONTACT_SECRET` 留空时会自动回退复用 `WECOM_APP_SECRET`）
  - **首次部署保持留空（不阻塞编译与启动）**：
    - `WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL`：等页面注册首个账号后回填邮箱并重跑 `03-start-business.sh --skip-build` 升为系统管理员
    - `WEKNORA_API_KEY`：留空时会由 Platform 自动为系统管理员签发临时 Token 同步技能目录，无需预填固定值
    - `PLATFORM_DEPLOY_PROBE_TOKEN`：仅临时探针用，首次部署保持留空
    - `PLATFORM_SERVICE_TOKEN`：仅对接外部服务（如 `code` 后端）时按双方约定填写
    - `APP_ACCEPTANCE_SLUG` / `APP_ACCEPTANCE_READ_PATH` / `APP_ACCEPTANCE_EXPECTED_JSON`：第 06 步验证已有动态应用时按需填写，首次部署全留空

#### 03.3 构建并启动业务服务

确保 `/data/aiwork-bl/03-business.env` 权限为 `0600`，按需二选一执行：

- **一步完成（构建镜像 + 渲染配置 + 启动 + 迁移与健康验收）**：

```bash
cd /data/aiwork-bl
sudo bash 03-start-business.sh
```

- **或拆成两步（先看编译、再启动）**：

```bash
cd /data/aiwork-bl
sudo bash 03-build-business-images.sh
sudo bash 03-start-business.sh --skip-build
```

脚本会检查 `.source-ready`、按 `platform-opc` → `knowledge-opc-app` → `knowledge-opc-ui` 构建镜像（标签取 `release` 提交前 8 位），然后按 **Knowledge 后端 (`:3001`) → Platform 网关 (`:3002`) → Knowledge 前端 (`:3003`)** 顺序启动并校验迁移（若配置了 `ACCOUNT_CENTER_GRAPHQL_URL` 还会顺带执行只读 GraphQL 探测）。

**看到什么算通过**：
- 终端输出：`03 业务 Compose 验收通过。记录：/data/aiwork/business-03/active-release.json`
- 运行检查命令均返回正常：

```bash
curl -fsS http://127.0.0.1:3001/health && echo
curl -fsS http://127.0.0.1:3002/health && echo
curl -fsS http://127.0.0.1:3003/api/v1/auth/oidc/config && echo
sudo docker exec -i infra-postgres sh -c 'exec psql -U "$POSTGRES_USER" -d weknora -tAc "SELECT version || '\''|'\'' || dirty FROM schema_migrations;"'
```

- 前三条接口均返回 `200`（启用企微时 `/api/v1/auth/oidc/config` 中 `"enabled"` 为 `true`）；
- 最后一条命令输出 `133|f`（表示全部 134 个迁移已完成且无脏状态）。

> 注意：若启用了企微「接收消息服务器配置」，需等第 `04` 步完成以及第 `05` 步公网 Nginx 把 `/wecom/` 反代到业务机 `:3002` 后，再去企微后台点击保存校验回调 URL。

---

<a id="step-04"></a>
### 04 启动 Deploy 与单节点 Swarm `[Swarm 机]`

#### 04.1 填写 `04-deploy.env`

登录 **Swarm 机**，确认两机内网互通（业务机需能访问 Swarm 机 `3008`/`3009`；若动态应用要连接 `01` 的共享 PG/Redis/MinIO，Swarm 机需能访问业务机 `5432`/`6379`/`9000`）。阅读 [CapRover 条款](https://github.com/caprover/caprover/blob/master/TERMS_AND_CONDITIONS.md) 后编辑 `/data/aiwork-bl/04-deploy.env`：

```bash
cd /data/aiwork-bl
chmod 600 04-deploy.env
vim 04-deploy.env
```

只需确认以下几项（其余端口默认 `3008`/`3009`/`3010`/`3443` 一般无需改动）：
- `MAIN_DOMAIN`：**必须与业务机 `03-business.env` 的 `MAIN_DOMAIN` 一致**（`APP_ROOT_DOMAIN` 保持留空即沿用 `MAIN_DOMAIN`；若 03 单独设置了 `APP_ROOT_DOMAIN`，这里也填相同值）
- `SWARM_ADVERTISE_ADDR`：填写 **Swarm 机内网 IPv4**
- `CAPROVER_ACCEPT_TERMS`：确认同意条款后改为 `true`
- `CAPROVER_PASSWORD`：**默认留空**（自动使用 CapRover 原始默认密码 `captain42`，必须与业务机 `03-business.env` 保持一致；如需自定义则两机填写相同的 8–29 位 ASCII 口令）
- `CAPTAIN_DATA_PATH`：全新安装留空（默认 `/data/aiwork/captain`）；接管旧实例时填旧数据实际挂载目录

#### 04.2 构建并启动

二选一执行即可：

- **一步完成（构建镜像 + 初始化 Swarm + 启动服务 + 初始化口令与根域名）**：

```bash
cd /data/aiwork-bl
sudo bash 04-start-deploy-opc-swarm.sh
```

- **或拆成两步（先看编译、再启动 Swarm）**：

```bash
cd /data/aiwork-bl
sudo bash 04-build-deploy-image.sh
sudo bash 04-start-deploy-opc-swarm.sh --skip-build
```

脚本会构建 `deploy-opc:<sha12>` 与 `deploy-opc-console:<sha12>-<配置摘要>`，自动初始化单节点 Swarm、创建 `deploy-opc`（`:3008`）、`captain-nginx`（`:3009`/`:3443`）与 `deploy-opc-console`（`:3010`），并将首装随机引导口令轮换为你设置的 `CAPROVER_PASSWORD`（留空时默认为 `captain42`）、初始化根域名；最终写出回执 `/data/aiwork/deploy-04/active-release.json`。

**看到什么算通过**：

```bash
curl -fsS http://127.0.0.1:3008/checkhealth && echo
curl -fsS -H "Host: captain.<你的MAIN_DOMAIN>" http://127.0.0.1:3010/ | head -n 5
sudo docker service ls
```

- `/checkhealth` 返回 36 位 UUID；
- `3010` 返回 HTML 页面内容；
- `docker service ls` 中 `deploy-opc`、`captain-nginx`、`deploy-opc-console` 的 `REPLICAS` 均为 `1/1`。

> 04 验收通过后，按第 `05` 步配置公网入口 Nginx，并回业务机运行第 `06` 步 `sudo bash /data/aiwork-bl/03-start-business.sh --verify-deploy` 验证 `03 → 04` 联调。

---

<a id="step-05"></a>
### 05 配置 DNS、证书与统一入口 `[统一入口机]`

#### 05.1 DNS 与 HTTPS 证书

向 DNS 与证书负责人确认两条解析与通配符证书：
- `MAIN_DOMAIN`（如 `aiwork.example.com`）→ 解析到统一入口 IP，配置主域名证书
- `*.<MAIN_DOMAIN>`（如 `*.aiwork.example.com`，覆盖 `<appslug>.<MAIN_DOMAIN>` 与 `captain.<MAIN_DOMAIN>`）→ 解析到统一入口 IP，配置通配符证书

#### 05.2 统一入口 Nginx 转发规则

在统一入口 Nginx 配置以下分流（注意 `captain.<MAIN_DOMAIN>` 走 Swarm 机 **`3010`**，其余 `*.<MAIN_DOMAIN>` 走 Swarm 机 **`3009`**，且都必须透传 `Host` 与 `Upgrade` 头；支持 WebSocket、SSE 与 `client_max_body_size 256m;`）：

**1. 主域名 `MAIN_DOMAIN`（上游全部指向 `<业务机内网IP>`）**：

| 访问路径 | 上游端口 | 说明 |
| --- | --- | --- |
| `/admin`、`/admin/` 下所有路径 | `3002` | Platform 管理端 |
| `/wecom/`、`/oidc/`、`/integration/v1/` | `3002` | 企微回调、OIDC、集成接口 |
| `/api/v1/apps` 及 `/api/v1/apps/` 下所有路径 | `3002` | Platform 动态应用接口（必须前缀匹配） |
| `/api/v1/auth/` | `3001` | Knowledge 认证（透传 `X-Forwarded-Proto https`） |
| 其余路径 `/` | `3003` | Knowledge 前端 Nginx |

**2. 动态应用与控制台域名（上游全部指向 `<Swarm机内网IP>`）**：

| 域名匹配 | 上游端口 | 说明 |
| --- | --- | --- |
| `captain.<MAIN_DOMAIN>` | `3010` | Deploy 控制台（`deploy-opc-console`，精确域名优先匹配） |
| `*.<MAIN_DOMAIN>`（其余子域 `<appslug>.<MAIN_DOMAIN>`） | `3009` | 已发布动态应用入口（`captain-nginx`） |

参考 Nginx 配置片段（替换域名、证书路径与内网 IP 后使用）：

```nginx
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}

# 1. 主域名：Knowledge + Platform
server {
  listen 443 ssl http2;
  server_name aiwork.example.com;
  ssl_certificate     /etc/nginx/ssl/aiwork.example.com.pem;
  ssl_certificate_key /etc/nginx/ssl/aiwork.example.com.key;
  client_max_body_size 256m;

  proxy_http_version 1.1;
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection $connection_upgrade;
  proxy_buffering off;

  location = /admin                { proxy_pass http://<业务机IP>:3002; }
  location ^~ /admin/              { proxy_pass http://<业务机IP>:3002; }
  location ^~ /wecom/              { proxy_pass http://<业务机IP>:3002; }
  location ^~ /oidc/               { proxy_pass http://<业务机IP>:3002; }
  location ^~ /integration/v1/     { proxy_pass http://<业务机IP>:3002; }
  location = /api/v1/apps          { proxy_pass http://<业务机IP>:3002; }
  location ^~ /api/v1/apps/        { proxy_pass http://<业务机IP>:3002; }
  location ^~ /api/v1/auth/        { proxy_pass http://<业务机IP>:3001; }
  location /                       { proxy_pass http://<业务机IP>:3003; }
}

# 2. Deploy 控制台（走 3010，精确匹配优先于 *.aiwork.example.com）
server {
  listen 443 ssl http2;
  server_name captain.aiwork.example.com;
  ssl_certificate     /etc/nginx/ssl/wildcard.aiwork.example.com.pem;
  ssl_certificate_key /etc/nginx/ssl/wildcard.aiwork.example.com.key;
  client_max_body_size 256m;

  location / {
    proxy_pass http://<Swarm机IP>:3010;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
  }
}

# 3. 动态应用泛域名 <appslug>.aiwork.example.com（走 3009，如应用仅走 HTTP 可按需开启 80 转发或 301 到 HTTPS）
server {
  listen 80;
  listen 443 ssl http2;
  server_name *.aiwork.example.com;
  ssl_certificate     /etc/nginx/ssl/wildcard.aiwork.example.com.pem;
  ssl_certificate_key /etc/nginx/ssl/wildcard.aiwork.example.com.key;
  client_max_body_size 256m;

  location / {
    proxy_pass http://<Swarm机IP>:3009;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_buffering off;
  }
}
```

重载入口 Nginx 后，在任意机器验证（替换成你的真实域名）：

```bash
sudo nginx -t && sudo nginx -s reload
curl -fsS https://<MAIN_DOMAIN>/api/v1/auth/oidc/config && echo
curl -fsS https://captain.<MAIN_DOMAIN>/checkhealth && echo
```

---

<a id="step-06"></a>
### 06 整体验收 `[业务机 + 浏览器]`

#### 06.1 验证 03 到 04 连通与认证 `[业务机]`

回到 **业务机** 执行：

```bash
cd /data/aiwork-bl
sudo bash 03-start-business.sh --verify-deploy
```

**看到什么算通过**：输出 `[OK] 03 → 04 管理认证、应用列表和代理路由通过`。

#### 06.2 业务功能验收 `[浏览器]`

1. **Knowledge 登录与设置管理员**：
   - 打开 `https://<MAIN_DOMAIN>` 注册并登录账号。
   - 如需将第一个账号设为系统管理员：把该账号邮箱填入业务机 `/data/aiwork-bl/03-business.env` 的 `WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL`，在业务机运行 `sudo bash 03-start-business.sh --skip-build`，重新登录后「设置」页应出现系统管理区。
   - **配置模型**：进入 Knowledge 系统模型设置，选择 **OpenAI 兼容**，Base URL 填 **`http://opc-llm-gateway:4000/v1`**，API Key 填 02 `02-platform-components.env` 的 `LITELLM_MASTER_KEY`，模型名填第 02.2 步添加的模型名；如用 PaddleOCR-VL，地址填 `http://opc-paddleocr:8080`；MCP 内网地址填 `http://opc-mcp-gateway:5235`。
   - 上传一篇测试文档等待解析完成后，进行一次知识问答。
2. **Deploy 控制台与动态应用发布**：
   - 打开 `https://captain.<MAIN_DOMAIN>`，使用 `CAPROVER_PASSWORD`（默认留空时为 `captain42`）登录 Deploy 控制台，确认应用面板可正常加载。
   - 发布一个带 `/healthz` 和只读 JSON 接口的测试应用（或通过 Work / Platform 发起一次发布），验证 `https://<appslug>.<MAIN_DOMAIN>/healthz` 访问正常。
   - 如需自动化验证：将 `APP_ACCEPTANCE_SLUG`、`APP_ACCEPTANCE_READ_PATH`、`APP_ACCEPTANCE_EXPECTED_JSON` 填入业务机 `03-business.env` 后执行 `sudo bash 03-start-business.sh --verify-deploy`，输出 `[OK] 动态应用 ... 的真实域名和只读 API 通过` 即完成全部验收。

---

<a id="ops-update"></a>
## 4. 日常更新与重跑

### 更新前必做备份

变更 03 / 04 或升级前，建议先逻辑备份三个核心数据库：

```bash
# 在业务机执行
bak="/data/aiwork/backup-$(date +%Y%m%d-%H%M%S)"
sudo mkdir -p "$bak"
for db in weknora platform deploy_opc; do
  sudo docker exec infra-postgres sh -c "pg_dump -U \"\$POSTGRES_USER\" -Fc \"$db\"" |
    sudo tee "$bak/$db.dump" >/dev/null
done
```

### 按改了什么选择命令

| 变更场景 | 执行步骤 |
| --- | --- |
| **更新源码（Platform / Knowledge / Deploy）** | 1. `[准备机]` 重跑 `bash 00-prepare-source.sh <账号@业务机> <账号@Swarm机>`<br>2. `[业务机]` `sudo bash 03-start-business.sh`<br>3. `[Swarm 机]` `sudo bash 04-start-deploy-opc-swarm.sh`<br>4. `[业务机]` `sudo bash 03-start-business.sh --verify-deploy` |
| **只改了 `03-business.env` 或 Platform YAML** | `[业务机]` `sudo bash 03-start-business.sh --skip-build`，再跑 `--verify-deploy` |
| **只改了 `04-deploy.env`** | `[Swarm 机]` `sudo bash 04-start-deploy-opc-swarm.sh --skip-build`，再回业务机跑 `--verify-deploy` |
| **日常重启 01 / 02 某容器** | `[业务机]` `sudo docker compose -f /data/aiwork-bl/01-docker-compose.infra.yml --env-file /data/aiwork-bl/01-infra.env restart infra-postgres`（**禁止重跑 `01-start-infra.sh`**） |

---

<a id="ops-rollback"></a>
## 5. 版本回退

> **注意**：回退前确认 PostgreSQL 迁移版本与目标 Knowledge 镜像一致且 `dirty=false`；如升级过程已改库且不兼容，须先用更新前备份恢复数据库，脚本不会自动回退数据库。

**回退目标选择**：
- 本次更新途中失败：通常回退到 `/data/aiwork/<阶段目录>/active-release.json`（上一次验收通过的版本）。
- 更新已完成但上线后需回撤：回退到上一次保存的发布记录（03 目录 `/data/aiwork/business-03/previous-release.json`）。

**业务机回退 03 示例（以 `active-release.json` 为例）**：

```bash
cd /data/aiwork-bl
state_dir=/data/aiwork/business-03
sudo jq -e '{images}' "$state_dir/active-release.json" |
  sudo install -m 0600 /dev/stdin "$state_dir/images.json"
sudo bash 03-start-business.sh --skip-build
```

**Swarm 机回退 04 示例**：

```bash
cd /data/aiwork-bl
state_dir=/data/aiwork/deploy-04
sudo jq -e '{images}' "$state_dir/active-release.json" |
  sudo install -m 0600 /dev/stdin "$state_dir/images.json"
sudo bash 04-start-deploy-opc-swarm.sh --skip-build
```

---

<a id="ops-migrate"></a>
## 6. 旧环境迁移前必查

- **旧主机把密钥放在 `/etc/aiwork/03-secrets.env` 或 `04-secrets.env`**：新版不再读取 `/etc/aiwork/`，请把里面的现场配置合并到业务机 `/data/aiwork-bl/03-business.env` 与 Swarm 机 `/data/aiwork-bl/04-deploy.env`。
- **旧主机改过 `/data/aiwork/platform-opc/config.yaml`**：将改动整理为独立模板（如 `/data/aiwork-bl/03-config.platform-opc.local.yaml`，保留 `@ACCOUNT_CENTER_GRAPHQL_URL@`），并在 `03-business.env` 中设置 `CONFIG_PLATFORM_FILE`。
- **已有旧 `captain-captain` 在同一台 Swarm 机**：先备份数据目录，把实际数据路径填到 `04-deploy.env` 的 `CAPTAIN_DATA_PATH`，再运行 04；若旧实例要跨主机迁移到新 Swarm 机，须先用 Deploy 控制台原生备份在新机恢复实例、迁好应用持久卷与镜像后再执行 04。
- **已有数据的 01 PostgreSQL**：绝不重跑 `01-start-infra.sh`，以免 `01-init-databases.sql` 冲突或重置租户序列。
- **已有旧 `deploy-opc.deploy_resources` 空资源行**：`platform-opc` 启动仅在 `id` 不存在时初始化默认共享资源；若旧库已写入过不含 `env_vars` 的 `shared-pg-main` / `shared-redis-main`，需删除这两条旧行后重启 `platform-opc-gateway` 或在管理页补录连接信息。

---

<a id="ops-offline"></a>
## 7. 离线构建机打包与导入（`--skip-build`）

适用场景：生产业务机和 Swarm 机无法访问外网下载 Go / Rust / npm 依赖。注意 01/02 的镜像及 04 首装用到的 `nginx:1.31`、`caprover/caprover-placeholder-app:latest`、`caprover/certbot-sleeping:v2.11.0` 仍需现场 Docker 可拉取或提前导入。

1. 找一台能联网构建的 Linux x86_64 **构建机**（已装 Docker 与基础工具），在 **准备机** 把 `src/` 和构建脚本同步过去：

```bash
build_host=ops@build-host
ssh "$build_host" 'mkdir -p /data/aiwork-bl && cd /data/aiwork-bl && rm -f .source-ready' &&
rsync -rlpcR --chmod=go-w --delete-delay --exclude='.git' src 03-business.env 03-common.sh \
  03-build-business-images.sh 04-deploy.env 04-common.sh \
  04-build-deploy-image.sh 04-Dockerfile.deploy-console \
  04-nginx.deploy-opc-console.conf "$build_host:/data/aiwork-bl/" &&
ssh "$build_host" 'cd /data/aiwork-bl && touch .source.lock .source-ready'
```

2. 在 **构建机** 编译并导出镜像包和清单：

```bash
cd /data/aiwork-bl
sudo bash 03-build-business-images.sh
sudo bash 04-build-deploy-image.sh

artifact_dir="$(mktemp -d /tmp/aiwork-images.XXXXXX)"
for pair in "03:/data/aiwork/business-03" "04:/data/aiwork/deploy-04"; do
  stage="${pair%%:*}" dir="${pair#*:}"
  sudo jq -er '.images[].image' "$dir/images.json" |
    xargs sudo docker save -o "$artifact_dir/images-$stage.tar"
  sudo chmod 0644 "$artifact_dir/images-$stage.tar"
  sudo install -m 0644 "$dir/images.json" "$artifact_dir/images-$stage.json"
done
printf '打包输出目录：%s\n' "$artifact_dir"
```

3. 传到目标服务器导入，并改用 **`--skip-build`** 启动：
   - **业务机**：
     ```bash
     sudo docker load -i images-03.tar
     sudo install -D -m 0600 images-03.json /data/aiwork/business-03/images.json
     cd /data/aiwork-bl && sudo bash 03-start-business.sh --skip-build
     ```
   - **Swarm 机**：
     ```bash
     sudo docker load -i images-04.tar
     sudo install -D -m 0600 images-04.json /data/aiwork/deploy-04/images.json
     cd /data/aiwork-bl && sudo bash 04-start-deploy-opc-swarm.sh --skip-build
     ```

---

<a id="ops-troubleshooting"></a>
## 8. 常用排查与数据备份

### 常见问题一眼定位

| 现象 | 在哪台机器查 | 先跑什么命令 |
| --- | --- | --- |
| 00 分发报错 | 准备机 / 目标机 | 确认目标机 `/data/aiwork-bl` 当前 SSH 用户可写，且已安装 `rsync` 和 `flock` |
| 01 起不来 / Milvus 重启 | 业务机 | `sysctl -n vm.max_map_count`（须为 `2000000`）；`sudo docker logs --tail 100 infra-postgres` |
| 02 不健康 | 业务机 | `sudo docker logs --tail 100 opc-clickhouse`、`opc-langfuse-web`、`opc-llm-gateway` |
| 03 迁移或启动卡住 | 业务机 | `sudo jq . /data/aiwork/business-03/last-attempt.json` 与 `sudo docker logs --tail 100 knowledge-opc-app`、`platform-opc-gateway` |
| 04 服务始终非 `1/1` | Swarm 机 | `sudo docker service ps --no-trunc deploy-opc`、`sudo docker service logs --tail 100 deploy-opc` |
| 05 访问 502 / 证书错 | 统一入口机 | `sudo nginx -t`、`sudo tail -n 100 /var/log/nginx/error.log`，核对 `3010`/`3009` 端口与 `Host` 透传 |
| 06 `--verify-deploy` 失败 | 业务机 / Swarm 机 | 核对两机 `MAIN_DOMAIN`（及 `APP_ROOT_DOMAIN`）与 `CAPROVER_PASSWORD` 是否完全一致、业务机到 Swarm 机 `3008`/`3009` 是否互通；改完 env 需重跑 `03-start-business.sh --skip-build` |

### 主要持久化数据目录

```text
/data/aiwork/
├── postgres / redis / minio / neo4j / milvus / etcd   # 01 基础设施数据
├── clickhouse / litellm / mcp-gateway / paddleocr     # 02 平台组件数据
├── knowledge/files                                    # 03 Knowledge 上传文件
├── business-03                                        # 03 镜像清单、配置快照与发布记录
├── deploy-04                                          # 04 Deploy 镜像清单与发布记录（Swarm 机）
└── captain                                            # 04 Deploy 状态与配置（Swarm 机，或 CAPTAIN_DATA_PATH）
```

> 停机维护顺序：先停动态应用与 04 Swarm 服务，再停 03 业务 Compose，最后停 02 和 01（执行 `docker compose down` 时**切勿加 `-v`**）。
