#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/03-common.sh"
source "$SCRIPT_DIR/03-build-business-images.sh"

usage() {
  cat >&2 <<'EOF'
用法:
  bash update-business.sh [--only <targets>] [--full-build] [--verify-deploy]

参数说明:
  --only           要更新的服务（逗号分隔）:
                   auto（默认，自动检测版本有变化的项目）
                   platform-opc | knowledge-opc | knowledge-opc-app | knowledge-opc-ui | all
  --full-build     强制重编 knowledge-opc-app 底座镜像（等价 AIWORK_FULL_BUILD=1）
  --verify-deploy  更新完成后执行 03 -> 04 联调验收（03-start-business.sh --verify-deploy）
EOF
}

only_arg="auto"
verify_deploy=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) only_arg="${2:-}"; shift 2 ;;
    --full-build) export AIWORK_FULL_BUILD=1; shift ;;
    --verify-deploy) verify_deploy=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "未知参数: $1" ;;
  esac
done

require_commands docker jq curl flock timeout sha256sum openssl awk
load_business_settings
check_engine
lock_deployment

[[ -r "$MANIFEST" ]] || fail "缺少 $MANIFEST，请先完成首次部署（03-build-business-images.sh + 03-start-business.sh）"
exec 8<"$SCRIPT_DIR/.source.lock" || fail "缺少源码同步记录，请先运行 00-prepare-source.sh 或 update-sync.sh"
flock -sn 8 || fail "源码正在同步中，请稍后重试"
[[ -f "$SCRIPT_DIR/.source-ready" ]] || fail "源码分发未完成，请重新同步源码"

platform_source="$SCRIPT_DIR/src/platform-opc"
knowledge_source="$SCRIPT_DIR/src/knowledge-opc"
platform_sha="$(source_revision "$platform_source")"
knowledge_sha="$(source_revision "$knowledge_source")"

want_platform=0
want_k_app=0
want_k_ui=0

if [[ "$only_arg" == "auto" ]]; then
  cur_platform="$(jq -r '.images["platform-opc"].revision // ""' "$MANIFEST")"
  cur_k_app="$(jq -r '.images["knowledge-opc-app"].revision // ""' "$MANIFEST")"
  cur_k_ui="$(jq -r '.images["knowledge-opc-ui"].revision // ""' "$MANIFEST")"
  [[ "$platform_sha" != "$cur_platform" ]] && want_platform=1
  [[ "$knowledge_sha" != "$cur_k_app" ]] && want_k_app=1
  [[ "$knowledge_sha" != "$cur_k_ui" ]] && want_k_ui=1
else
  IFS=',' read -r -a targets <<< "$only_arg"
  for item in "${targets[@]}"; do
    case "$item" in
      platform-opc) want_platform=1 ;;
      knowledge-opc) want_k_app=1; want_k_ui=1 ;;
      knowledge-opc-app) want_k_app=1 ;;
      knowledge-opc-ui) want_k_ui=1 ;;
      all) want_platform=1; want_k_app=1; want_k_ui=1 ;;
      *) fail "不支持的更新目标: $item" ;;
    esac
  done
fi

if (( want_platform == 0 && want_k_app == 0 && want_k_ui == 0 )); then
  printf '[OK] 所有业务镜像均已是最新源码版本（platform=%s, knowledge=%s），无需重新编译。\n' \
    "${platform_sha:0:8}" "${knowledge_sha:0:8}"
  if [[ "$verify_deploy" == true ]]; then
    exec bash "$SCRIPT_DIR/03-start-business.sh" --verify-deploy
  fi
  exit 0
fi

printf '[INFO] 本次待更新组件: platform-opc=%d, knowledge-opc-app=%d, knowledge-opc-ui=%d\n' \
  "$want_platform" "$want_k_app" "$want_k_ui"

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiwork-update-biz.XXXXXX")"
pending="$(mktemp "$STATE_DIR/.images.XXXXXX")"
trap 'rm -rf -- "$BUILD_DIR" "$pending"' EXIT

apt_mirror="$(build_mirror BUILD_APT_MIRROR mirrors.aliyun.com)"
pip_index_url="$(build_mirror BUILD_PIP_INDEX_URL https://mirrors.aliyun.com/pypi/simple/)"
npm_registry="$(build_mirror BUILD_NPM_REGISTRY https://registry.npmmirror.com)"
goproxy="$(build_mirror BUILD_GOPROXY https://goproxy.cn,direct)"

# 先保留现有清单中的所有条目，仅替换本次编译的组件。
for existing in platform-opc knowledge-opc-app knowledge-opc-ui; do
  jq -e --arg k "$existing" '.images[$k]' "$MANIFEST" > "$BUILD_DIR/$existing.json" ||
    fail "$MANIFEST 缺少 $existing 记录，请先执行一次全量 03 构建"
done

if (( want_platform )); then
  prepare_platform_dockerfile "$platform_source"
  build_image platform-opc "$platform_sha" https://github.com/shtokendance/platform-opc.git "$platform_source" \
    "$BUILD_DIR/Platform.Dockerfile" \
    --build-arg "GOPROXY_ARG=$goproxy" --build-arg "APK_MIRROR_ARG=$apt_mirror"
fi

if (( want_k_app )); then
  build_knowledge_app_image "$knowledge_sha" https://github.com/shtokendance/knowledge-opc.git \
    "$knowledge_source" "$apt_mirror" "$pip_index_url" "$goproxy"
fi

if (( want_k_ui )); then
  build_image knowledge-opc-ui "$knowledge_sha" https://github.com/shtokendance/knowledge-opc.git "$knowledge_source/frontend" \
    "$knowledge_source/frontend/Dockerfile" \
    --build-arg "VITE_FRONTEND_COMMIT=$knowledge_sha" --build-arg "NPM_REGISTRY=$npm_registry"
fi

jq -s '{images: (map({(.image | split(":")[0]): .}) | add)}' "$BUILD_DIR/"*.json > "$pending"
mv -f -- "$pending" "$MANIFEST"

load_manifest
PLATFORM_CONFIG_PATH="$STATE_DIR/config.platform-opc.yaml"
export PLATFORM_CONFIG_PATH

yaml_quote() {
  jq -Rr '@json' <<< "$1"
}

url_encode() {
  jq -Rr '@uri' <<< "$1"
}

resolve_infra_host() {
  local service="$1" ip
  ip="$(docker inspect -f '{{range $net, $cfg := .NetworkSettings.Networks}}{{if eq $net "aiwork_net"}}{{$cfg.IPAddress}}{{end}}{{end}}' "$service" 2>/dev/null)" || true
  [[ -n "$ip" ]] || fail "基础设施容器 $service 未加入 aiwork_net，请检查 01 和 02"
  printf '%s' "$ip"
}

if (( want_platform )); then
  local_pg_host="$(resolve_infra_host aiwork-postgres)"
  local_redis_host="$(resolve_infra_host aiwork-redis)"
  platform_dsn="postgres://${POSTGRES_USER}:$(url_encode "$POSTGRES_PASSWORD")@${local_pg_host}:5432/platform_opc?sslmode=disable"
  redis_addr="${local_redis_host}:6379"
  tmp_cfg="$(mktemp "$STATE_DIR/.config.platform.XXXXXX")"
  awk \
    -v port="$(yaml_quote "$PLATFORM_GATEWAY_PORT")" \
    -v dsn="$(yaml_quote "$platform_dsn")" \
    -v redis_addr="$(yaml_quote "$redis_addr")" \
    -v redis_pw="$(yaml_quote "$REDIS_PASSWORD")" \
    -v admin_key="$(yaml_quote "$PLATFORM_ADMIN_KEY")" \
    -v auth_key="$(yaml_quote "$PLATFORM_AUTH_KEY")" \
    -v bridge_key="$(yaml_quote "$PLATFORM_BRIDGE_KEY")" \
    -v oidc_secret="$(yaml_quote "$OIDC_CLIENT_SECRET")" \
    -v app_root="$(yaml_quote "$APP_ROOT_DOMAIN")" \
    -v deploy_url="$(yaml_quote "$DEPLOY_API_URL")" \
    -v deploy_token="$(yaml_quote "$DEPLOY_API_TOKEN")" \
    '
    {
      gsub(/__PORT__/, port)
      gsub(/__POSTGRES_DSN__/, dsn)
      gsub(/__REDIS_ADDR__/, redis_addr)
      gsub(/__REDIS_PASSWORD__/, redis_pw)
      gsub(/__PLATFORM_ADMIN_KEY__/, admin_key)
      gsub(/__PLATFORM_AUTH_KEY__/, auth_key)
      gsub(/__PLATFORM_BRIDGE_KEY__/, bridge_key)
      gsub(/__OIDC_CLIENT_SECRET__/, oidc_secret)
      gsub(/__APP_ROOT_DOMAIN__/, app_root)
      gsub(/__DEPLOY_API_URL__/, deploy_url)
      gsub(/__DEPLOY_API_TOKEN__/, deploy_token)
      print
    }
    ' "$SCRIPT_DIR/03-config.platform-opc.yaml" > "$tmp_cfg"
  chmod 0600 "$tmp_cfg"
  mv -f -- "$tmp_cfg" "$PLATFORM_CONFIG_PATH"
fi

compose() {
  docker compose --project-directory "$SCRIPT_DIR" -f "$COMPOSE_FILE" "$@"
}

json_health() {
  http_200 "$1" | jq -e '.status == "ok"' >/dev/null 2>&1
}

if (( want_k_app )); then
  printf '[INFO] 更新 knowledge-opc-app -> %s ...\n' "$IMAGE_KNOWLEDGE_APP"
  compose up -d --no-deps --force-recreate knowledge-opc-app
  wait_for "Knowledge 后端" json_health "http://127.0.0.1:$KNOWLEDGE_APP_PORT/health"
  printf '[OK] Knowledge 后端健康检查通过\n'
fi

if (( want_platform )); then
  printf '[INFO] 更新 platform-opc-gateway -> %s ...\n' "$IMAGE_PLATFORM_OPC"
  compose up -d --no-deps --force-recreate platform-opc-gateway
  wait_for "Platform 网关" json_health "http://127.0.0.1:$PLATFORM_GATEWAY_PORT/health"
  printf '[OK] Platform 网关健康检查通过\n'
fi

if (( want_k_ui || want_k_app )); then
  KNOWLEDGE_UPSTREAM_ID="$(compose ps -q knowledge-opc-app)"
  [[ -n "$KNOWLEDGE_UPSTREAM_ID" ]] || fail "无法取得 Knowledge 后端容器 ID"
  export KNOWLEDGE_UPSTREAM_ID
  printf '[INFO] 更新 knowledge-opc-frontend -> %s ...\n' "$IMAGE_KNOWLEDGE_UI"
  compose up -d --no-deps --force-recreate knowledge-opc-frontend
  verify_front() {
    http_200 "http://127.0.0.1:$KNOWLEDGE_WEB_PORT/" >/dev/null 2>&1 &&
      http_200 "http://127.0.0.1:$KNOWLEDGE_WEB_PORT/api/v1/system/info" | jq -e '.success == true' >/dev/null 2>&1
  }
  wait_for "Knowledge 前端" verify_front
  printf '[OK] Knowledge 前端及代理健康检查通过\n'
fi

receipt="$(mktemp "$STATE_DIR/.active-release.XXXXXX")"
jq --arg deployedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg config "$PLATFORM_CONFIG_PATH" --arg rootDomain "$APP_ROOT_DOMAIN" \
  '. + {verified_at:$deployedAt, platform_config:$config, app_root_domain:$rootDomain}' "$MANIFEST" > "$receipt"
if [[ -f "$STATE_DIR/active-release.json" ]] &&
    ! jq -e --slurpfile current "$receipt" '.images == $current[0].images and .platform_config == $current[0].platform_config' \
    "$STATE_DIR/active-release.json" >/dev/null; then
  cp -- "$STATE_DIR/active-release.json" "$STATE_DIR/previous-release.json"
fi
mv -f -- "$receipt" "$STATE_DIR/active-release.json"
printf '[OK] 业务增量更新完成。当前清单: %s\n' "$STATE_DIR/active-release.json"

if [[ "$verify_deploy" == true ]]; then
  exec bash "$SCRIPT_DIR/03-start-business.sh" --verify-deploy
fi
