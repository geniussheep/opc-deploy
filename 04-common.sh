#!/usr/bin/env bash
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

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

load_settings() {
  local output
  CONFIG_ENV="${AIWORK_DEPLOY_ENV:-$SCRIPT_DIR/04-deploy.env}"
  [[ -r "$CONFIG_ENV" ]] || fail "无法读取 ${CONFIG_ENV}，请检查 04 的 env 路径和权限"
  output="$(docker compose --project-directory "$SCRIPT_DIR" --env-file "$CONFIG_ENV" -f - config --environment <<<'services: {}')" ||
    fail "无法解析 $CONFIG_ENV"
  SETTINGS="$output"
  DATA_DIR="$(setting AIWORK_DATA_DIR /data/aiwork)"
  [[ "$DATA_DIR" == /* && "$DATA_DIR" != / && "$DATA_DIR" != *,* ]] ||
    fail "AIWORK_DATA_DIR 须为非根绝对路径且不能含逗号"
  STATE_DIR="$DATA_DIR/deploy-04"
  MANIFEST="$STATE_DIR/images.json"
  export AIWORK_DATA_DIR="$DATA_DIR"
}

setting() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "$1="*) printf '%s' "${line#*=}"; return ;;
    esac
  done <<< "$SETTINGS"
  printf '%s' "${2:-}"
}

port_setting() {
  local value
  value="$(setting "$1" "$2")"
  [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] && (( value <= 65535 )) || fail "$1 必须是有效端口"
  printf '%s' "$value"
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

load_swarm_settings() {
  load_settings
  load_deploy_ports_and_password
  MAIN_DOMAIN="$(setting MAIN_DOMAIN)"
  APP_ROOT_DOMAIN="$(setting APP_ROOT_DOMAIN)"
  APP_ROOT_DOMAIN="${APP_ROOT_DOMAIN:-$MAIN_DOMAIN}"
  [[ "$APP_ROOT_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] ||
    fail "请填写 MAIN_DOMAIN（或 APP_ROOT_DOMAIN），须为与 03 一致的完整域名"
  READY_TIMEOUT="$(setting READY_TIMEOUT 180)"
  [[ "$READY_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] || fail "READY_TIMEOUT 须为正整数秒"
  DEPLOY_OPC_HTTPS_PORT="$(port_setting DEPLOY_OPC_HTTPS_PORT 3443)"
  DEPLOY_OPC_CONSOLE_PORT="$(port_setting DEPLOY_OPC_CONSOLE_PORT 3010)"
  [[ "$(printf '%s\n' "$DEPLOY_OPC_ADMIN_PORT" "$DEPLOY_OPC_PROXY_PORT" "$DEPLOY_OPC_HTTPS_PORT" "$DEPLOY_OPC_CONSOLE_PORT" |
    sort -u | wc -l | tr -d ' ')" == 4 ]] || fail "04 宿主机端口不能重复"
  CAPTAIN_PATH="$(setting CAPTAIN_DATA_PATH)"
  CAPTAIN_PATH="${CAPTAIN_PATH:-$DATA_DIR/captain}"
  [[ "$CAPTAIN_PATH" == /* && "$CAPTAIN_PATH" != / && "$CAPTAIN_PATH" != *,* ]] ||
    fail "CAPTAIN_DATA_PATH 须为非根绝对路径且不能含逗号"
}

check_engine() {
  local server
  server="$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')" || fail "Docker Engine 不可用"
  [[ "$server" == linux/amd64 ]] || fail "本方案使用 linux/amd64 镜像，当前 Docker Engine 为 $server"
}

lock_deployment() {
  mkdir -p -- "$STATE_DIR"
  exec 9>"$STATE_DIR/.lock"
  flock -n 9 || fail "04 已有构建或部署正在运行"
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
  local name revision expected image actual base_image
  [[ -r "$MANIFEST" ]] || fail "缺少 $MANIFEST，请先构建或导入制品"
  for name in deploy-opc deploy-opc-console; do
    revision="$(jq -er --arg name "$name" '.images[$name].revision | select(test("^[a-f0-9]{40}$"))' "$MANIFEST")" ||
      fail "清单缺少 $name 或提交 SHA 无效，请重新构建或导入两份 04 镜像"
    expected="$(jq -er --arg name "$name" '.images[$name].id' "$MANIFEST")" || fail "清单缺少 $name 的镜像 ID"
    image="$(jq -er --arg name "$name" '.images[$name].image | strings' "$MANIFEST")" || fail "清单缺少 $name 的镜像标签"
    base_image="$name:${revision:0:8}"
    [[ "$image" == "$base_image" ||
       ( "$name" == deploy-opc-console && "$image" =~ ^${base_image}-[a-f0-9]{8}$ ) ]] ||
      fail "清单中的 $name 镜像标签与提交 SHA 不符"
    actual="$(image_id_for_revision "$image" "$revision")" || fail "缺少或无法验证 $image"
    [[ "$actual" == "$expected" ]] || fail "$image 的本地镜像 ID 与发布清单不符"
    case "$name" in
      deploy-opc) IMAGE_DEPLOY_OPC="$image" ;;
      deploy-opc-console) IMAGE_DEPLOY_OPC_CONSOLE="$image" ;;
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
