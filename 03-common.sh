#!/usr/bin/env bash
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
COMPOSE_FILE="$SCRIPT_DIR/03-docker-compose.business.yml"

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || fail "缺少命令: $cmd"
  done
}

parse_env_file() {
  local file="$1"
  if [[ -e "$file" && ! -r "$file" ]]; then
    fail "无法读取 ${file}，请使用 sudo 或检查文件权限"
  fi
  [[ -r "$file" ]] || return 0
  env -i PATH="$PATH" docker compose --project-directory "$SCRIPT_DIR" --env-file "$file" \
    -f - config --environment <<<'services: {}'
}

load_settings() {
  CONFIG_ENV="${AIWORK_BUSINESS_ENV:-$SCRIPT_DIR/03-business.env}"
  INFRA_ENV="${AIWORK_INFRA_ENV:-$SCRIPT_DIR/01-infra.env}"
  PLATFORM_ENV="${AIWORK_PLATFORM_ENV:-$SCRIPT_DIR/02-platform-components.env}"
  [[ -r "$CONFIG_ENV" ]] || fail "无法读取 ${CONFIG_ENV}，请检查 03 的 env 路径和权限"
  SETTINGS="$(parse_env_file "$CONFIG_ENV")" || fail "无法解析 $CONFIG_ENV"
  INFRA_SETTINGS="$(parse_env_file "$INFRA_ENV")" || fail "无法解析 $INFRA_ENV"
  PLATFORM_SETTINGS="$(parse_env_file "$PLATFORM_ENV")" || fail "无法解析 $PLATFORM_ENV"
  DATA_DIR="$(setting AIWORK_DATA_DIR)"
  if [[ -z "${DATA_DIR//[[:space:]]/}" ]]; then
    DATA_DIR="$(setting_from "$INFRA_SETTINGS" AIWORK_DATA_DIR /data/aiwork)"
  fi
  [[ "$DATA_DIR" == /* && "$DATA_DIR" != / && "$DATA_DIR" != *,* ]] ||
    fail "AIWORK_DATA_DIR 须为非根绝对路径且不能含逗号"
  STATE_DIR="$DATA_DIR/business-03"
  MANIFEST="$STATE_DIR/images.json"
  export AIWORK_DATA_DIR="$DATA_DIR"
}

setting_from() {
  local blob="$1" key="$2" fallback="${3:-}" line
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s' "${line#*=}"; return ;;
    esac
  done <<< "$blob"
  printf '%s' "$fallback"
}

setting() {
  setting_from "$SETTINGS" "$1" "${2:-}"
}

inherit_and_export() {
  local target_key="$1" source_blob="$2" source_key="$3" fallback="${4:-}" val
  val="$(setting "$target_key")"
  if [[ -z "${val//[[:space:]]/}" ]]; then
    val="$(setting_from "$source_blob" "$source_key" "$fallback")"
  fi
  [[ -n "${val//[[:space:]]/}" ]] || fail "缺少 $target_key（请检查 03-business.env 或同机 01/02 env）"
  printf -v "$target_key" '%s' "$val"
  export "${target_key?}"
}

port_setting() {
  local value
  value="$(setting "$1" "$2")"
  [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] && (( value <= 65535 )) || fail "$1 必须是有效端口"
  printf '%s' "$value"
}

load_business_settings() {
  local key val jwt_secret bridge_key LC_ALL=C
  load_settings
  # 默认复用同机 01/02 的基础设施与 Langfuse 配置，03-business.env 显式填写时可覆盖。
  inherit_and_export POSTGRES_USER "$INFRA_SETTINGS" POSTGRES_USER postgres
  inherit_and_export POSTGRES_PASSWORD "$INFRA_SETTINGS" POSTGRES_PASSWORD
  inherit_and_export POSTGRES_PORT "$INFRA_SETTINGS" POSTGRES_PORT 5432
  inherit_and_export REDIS_PASSWORD "$INFRA_SETTINGS" REDIS_PASSWORD
  inherit_and_export REDIS_PORT "$INFRA_SETTINGS" REDIS_PORT 6379
  inherit_and_export MINIO_ROOT_USER "$INFRA_SETTINGS" MINIO_ROOT_USER minioadmin
  inherit_and_export MINIO_ROOT_PASSWORD "$INFRA_SETTINGS" MINIO_ROOT_PASSWORD
  inherit_and_export MINIO_S3_PORT "$INFRA_SETTINGS" MINIO_S3_PORT 9000
  inherit_and_export NEO4J_PASSWORD "$INFRA_SETTINGS" NEO4J_PASSWORD
  inherit_and_export LANGFUSE_PUBLIC_KEY "$PLATFORM_SETTINGS" LANGFUSE_INIT_PROJECT_PUBLIC_KEY
  inherit_and_export LANGFUSE_SECRET_KEY "$PLATFORM_SETTINGS" LANGFUSE_INIT_PROJECT_SECRET_KEY
  for key in POSTGRES_PORT REDIS_PORT MINIO_S3_PORT; do
    val="${!key}"
    [[ "$val" =~ ^[1-9][0-9]{0,4}$ ]] && (( val <= 65535 )) || fail "$key 必须是有效端口"
  done

  for key in JWT_SECRET SYSTEM_AES_KEY PLATFORM_ADMIN_KEY \
      PLATFORM_AUTH_KEY OIDC_CLIENT_SECRET; do
    val="$(setting "$key")"
    [[ -n "${val//[[:space:]]/}" ]] || fail "缺少 $key"
  done
  val="$(setting SYSTEM_AES_KEY)"
  [[ "$(LC_ALL=C printf '%s' "$val" | wc -c | tr -d ' ')" == 32 ]] || fail "SYSTEM_AES_KEY 须为 32 字节"
  jwt_secret="$(setting JWT_SECRET)"
  bridge_key="$(setting PLATFORM_BRIDGE_KEY)"
  if [[ -n "${bridge_key//[[:space:]]/}" ]]; then
    [[ "$bridge_key" == "$jwt_secret" ]] ||
      fail "PLATFORM_BRIDGE_KEY 须与 Knowledge JWT_SECRET 一致，供 Knowledge 验签"
  else
    bridge_key="$jwt_secret"
  fi
  export PLATFORM_BRIDGE_KEY="$bridge_key"

  MAIN_DOMAIN="$(setting MAIN_DOMAIN)"
  if [[ -z "${MAIN_DOMAIN//[[:space:]]/}" ]]; then
    MAIN_DOMAIN="$(setting_from "$PLATFORM_SETTINGS" MAIN_DOMAIN)"
  fi
  APP_ROOT_DOMAIN="$(setting APP_ROOT_DOMAIN)"
  APP_ROOT_DOMAIN="${APP_ROOT_DOMAIN:-$MAIN_DOMAIN}"
  for val in "$MAIN_DOMAIN" "$APP_ROOT_DOMAIN"; do
    [[ "$val" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] ||
      fail "MAIN_DOMAIN 和 APP_ROOT_DOMAIN 需要有效的完整域名"
  done

  READY_TIMEOUT="$(setting READY_TIMEOUT 180)"
  [[ "$READY_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] || fail "READY_TIMEOUT 须为正整数秒"
  KNOWLEDGE_APP_PORT="$(port_setting KNOWLEDGE_APP_PORT 3001)"
  PLATFORM_GATEWAY_PORT="$(port_setting PLATFORM_GATEWAY_PORT 3002)"
  KNOWLEDGE_FRONTEND_PORT="$(port_setting KNOWLEDGE_FRONTEND_PORT 3003)"
  [[ "$(printf '%s\n' "$KNOWLEDGE_APP_PORT" "$PLATFORM_GATEWAY_PORT" "$KNOWLEDGE_FRONTEND_PORT" |
    sort -u | wc -l | tr -d ' ')" == 3 ]] || fail "03 宿主机端口不能重复"
  DEPLOY_OPC_HOST="$(setting DEPLOY_OPC_HOST)"
  [[ "$DEPLOY_OPC_HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ &&
     "$DEPLOY_OPC_HOST" != localhost && "$DEPLOY_OPC_HOST" != 127.* &&
     "$DEPLOY_OPC_HOST" != host.docker.internal && "$DEPLOY_OPC_HOST" != 0.0.0.0 ]] ||
    fail "DEPLOY_OPC_HOST 需要填写 04 主机的内网 IPv4 或 DNS 名"
  load_deploy_ports_and_password
  export DEPLOY_OPC_URL="http://$DEPLOY_OPC_HOST:$DEPLOY_OPC_ADMIN_PORT"
  CONFIG_PLATFORM_FILE="$(setting CONFIG_PLATFORM_FILE 03-config.platform-opc.yaml)"
  if [[ "$CONFIG_PLATFORM_FILE" == config.platform-opc.yaml && ! -e "$SCRIPT_DIR/$CONFIG_PLATFORM_FILE" ]]; then
    CONFIG_PLATFORM_FILE=03-config.platform-opc.yaml
  fi
  case "$CONFIG_PLATFORM_FILE" in
    /*) ;;
    *) CONFIG_PLATFORM_FILE="$SCRIPT_DIR/$CONFIG_PLATFORM_FILE" ;;
  esac
  export MAIN_DOMAIN APP_ROOT_DOMAIN
  export KNOWLEDGE_APP_PORT PLATFORM_GATEWAY_PORT KNOWLEDGE_FRONTEND_PORT
  export AIWORK_DATA_DIR="$DATA_DIR"
}

load_deploy_ports_and_password() {
  local LC_ALL=C
  CAPROVER_PASSWORD="$(setting CAPROVER_PASSWORD)"
  CAPROVER_PASSWORD="${CAPROVER_PASSWORD:-captain42}"
  export CAPROVER_PASSWORD
  [[ "$CAPROVER_PASSWORD" =~ ^[[:graph:]]{8,29}$ ]] ||
    fail "CAPROVER_PASSWORD 需要 8–29 个可打印 ASCII 字符且不含空格"

  DEPLOY_OPC_ADMIN_PORT="$(port_setting DEPLOY_OPC_ADMIN_PORT 3008)"
  DEPLOY_OPC_PROXY_PORT="$(port_setting DEPLOY_OPC_PROXY_PORT 3009)"
}

check_engine() {
  local server
  server="$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')" || fail "Docker Engine 不可用"
  [[ "$server" == linux/amd64 ]] || fail "本方案使用 linux/amd64 镜像，当前 Docker Engine 为 $server"
}

lock_deployment() {
  mkdir -p -- "$STATE_DIR"
  exec 9>"$STATE_DIR/.lock"
  flock -n 9 || fail "03 已有构建或部署正在运行"
}

compose() {
  docker compose --project-name opc-business --project-directory "$SCRIPT_DIR" --env-file "$CONFIG_ENV" \
    -f "$COMPOSE_FILE" "$@"
}

image_id_for_revision() {
  local image="$1" revision="$2" details
  details="$(docker image inspect "$image" 2>/dev/null)" || return 1
  jq -er --arg revision "$revision" '
    .[0] | select(.Os == "linux" and .Architecture == "amd64" and
      .Config.Labels["org.opencontainers.image.revision"] == $revision) | .Id
    | select(test("^sha256:[a-f0-9]{64}$"))
  ' <<< "$details"
}

load_manifest() {
  local name revision image expected actual knowledge_revision
  [[ -r "$MANIFEST" ]] || fail "缺少 $MANIFEST，请先构建或导入制品"
  knowledge_revision="$(jq -er '.images["knowledge-opc-app"].revision' "$MANIFEST")" || fail "无效的发布清单"
  [[ "$knowledge_revision" == "$(jq -er '.images["knowledge-opc-ui"].revision' "$MANIFEST")" ]] ||
    fail "Knowledge 前后端的完整 SHA 不一致"
  for name in platform-opc knowledge-opc-app knowledge-opc-ui; do
    revision="$(jq -er --arg name "$name" '.images[$name].revision | select(test("^[a-f0-9]{40}$"))' "$MANIFEST")" ||
      fail "清单中的 $name SHA 无效"
    expected="$(jq -er --arg name "$name" '.images[$name].id' "$MANIFEST")" || fail "清单缺少 $name 的镜像 ID"
    image="$name:${revision:0:8}"
    actual="$(image_id_for_revision "$image" "$revision")" || fail "缺少或无法验证 $image"
    [[ "$actual" == "$expected" ]] || fail "$image 的本地镜像 ID 与发布清单不符"
    case "$name" in
      platform-opc) export IMAGE_PLATFORM_OPC="$image" ;;
      knowledge-opc-app) export IMAGE_KNOWLEDGE_APP="$image" ;;
      knowledge-opc-ui) export IMAGE_KNOWLEDGE_UI="$image" ;;
    esac
  done
}

http_200() {
  local work code
  work="$(mktemp)" || return 1
  if ! code="$(curl --noproxy '*' --silent --show-error --max-time 8 -o "$work" -w '%{http_code}' "$@")" ||
    [[ "$code" != 200 ]]; then
    rm -f -- "$work"
    return 1
  fi
  cat "$work"
  rm -f -- "$work"
}

wait_for() {
  local label="$1" deadline=$((SECONDS + READY_TIMEOUT))
  shift
  until "$@"; do
    (( SECONDS < deadline )) || fail "$label 在 ${READY_TIMEOUT} 秒内未就绪"
    sleep 2
  done
}
