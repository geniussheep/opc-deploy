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

account_center_url="$(setting ACCOUNT_CENTER_GRAPHQL_URL)"
wecom_agent_id="$(setting WECOM_AGENT_ID)"
[[ -z "$wecom_agent_id" || "$wecom_agent_id" =~ ^[0-9]+$ ]] || fail "WECOM_AGENT_ID 须为非负整数"

yaml_quote() {
  jq -Rr '@json' <<< "$1"
}

url_encode() {
  jq -Rr '@uri' <<< "$1"
}

resolve_infra_host() {
  local host target_ip route_out
  host="$(setting INFRA_HOST)"
  if [[ -n "${host//[[:space:]]/}" ]]; then
    printf '%s' "$host"
    return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    target_ip="$DEPLOY_OPC_HOST"
    if [[ ! "$target_ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && command -v getent >/dev/null 2>&1; then
      target_ip="$(getent ahostsv4 "$DEPLOY_OPC_HOST" 2>/dev/null | awk 'NR==1{print $1}')"
      target_ip="${target_ip:-$DEPLOY_OPC_HOST}"
    fi
    route_out="$(ip -4 route get "$target_ip" 2>/dev/null || true)"
    host="$(awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' <<< "$route_out")"
  fi
  if [[ -z "${host//[[:space:]]/}" ]] && command -v hostname >/dev/null 2>&1; then
    host="$(hostname -I 2>/dev/null | awk '
      {
        fallback = ""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^127\./ || $i ~ /:/) continue
          if ($i !~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) { print $i; exit }
          if (fallback == "") fallback = $i
        }
        if (fallback != "") print fallback
      }
    ')"
  fi
  [[ -n "${host//[[:space:]]/}" && "$host" != 127.* && "$host" != 0.0.0.0 ]] ||
    fail "无法自动识别本机内网 IP，请在 03-business.env 填写 INFRA_HOST"
  printf '%s' "$host"
}

prepare_platform_config() {
  local candidate checksum infra_host="" pg_user_enc pg_pass_enc redis_pass_enc
  [[ -s "$CONFIG_PLATFORM_FILE" ]] || fail "Platform 配置模板不存在或为空"
  if grep -Eq '@(INFRA_HOST_JSON|SHARED_PG_.*|SHARED_REDIS_.*|SHARED_OSS_.*|SHARED_S3_.*|POSTGRES_.*_JSON|REDIS_.*_JSON|MINIO_.*_JSON)@' "$CONFIG_PLATFORM_FILE"; then
    infra_host="$(resolve_infra_host)"
  fi
  pg_user_enc="$(url_encode "$POSTGRES_USER")"
  pg_pass_enc="$(url_encode "$POSTGRES_PASSWORD")"
  redis_pass_enc="$(url_encode "$REDIS_PASSWORD")"

  mkdir -p -- "$STATE_DIR/platform-config" "$DATA_DIR/knowledge/files"
  chmod 700 "$STATE_DIR/platform-config"
  candidate="$(mktemp "$STATE_DIR/platform-config/.config.XXXXXX")"
  chmod 600 "$candidate"
  (
    export \
      AIW_T0="@MAIN_DOMAIN@"               AIW_V0="$MAIN_DOMAIN" \
      AIW_T1="@WECOM_AGENT_ID@"            AIW_V1="${wecom_agent_id:-0}" \
      AIW_T2="@ACCOUNT_CENTER_GRAPHQL_URL@" AIW_V2="$(yaml_quote "$account_center_url")" \
      AIW_T3="@INFRA_HOST_JSON@"           AIW_V3="$(yaml_quote "$infra_host")" \
      AIW_T4="@POSTGRES_PORT_JSON@"        AIW_V4="$(yaml_quote "$POSTGRES_PORT")" \
      AIW_T5="@POSTGRES_USER_JSON@"        AIW_V5="$(yaml_quote "$POSTGRES_USER")" \
      AIW_T6="@POSTGRES_PASSWORD_JSON@"    AIW_V6="$(yaml_quote "$POSTGRES_PASSWORD")" \
      AIW_T7="@REDIS_PORT_JSON@"           AIW_V7="$(yaml_quote "$REDIS_PORT")" \
      AIW_T8="@REDIS_PASSWORD_JSON@"       AIW_V8="$(yaml_quote "$REDIS_PASSWORD")" \
      AIW_T9="@MINIO_ROOT_USER_JSON@"      AIW_V9="$(yaml_quote "$MINIO_ROOT_USER")" \
      AIW_T10="@MINIO_ROOT_PASSWORD_JSON@" AIW_V10="$(yaml_quote "$MINIO_ROOT_PASSWORD")" \
      AIW_T11="@SHARED_PG_DESC@"           AIW_V11="$(yaml_quote "共享 PostgreSQL 数据库服务 (${infra_host}:${POSTGRES_PORT})")" \
      AIW_T12="@SHARED_PG_DATABASE_URL@"   AIW_V12="$(yaml_quote "postgresql://${pg_user_enc}:${pg_pass_enc}@${infra_host}:${POSTGRES_PORT}/opc_apps?sslmode=disable")" \
      AIW_T13="@SHARED_REDIS_DESC@"        AIW_V13="$(yaml_quote "共享 Redis 缓存服务 (${infra_host}:${REDIS_PORT})")" \
      AIW_T14="@SHARED_REDIS_URL@"         AIW_V14="$(yaml_quote "redis://:${redis_pass_enc}@${infra_host}:${REDIS_PORT}/0")" \
      AIW_T15="@SHARED_OSS_DESC@"          AIW_V15="$(yaml_quote "共享 S3/MinIO 对象存储服务 (http://${infra_host}:${MINIO_S3_PORT})")" \
      AIW_T16="@SHARED_S3_ENDPOINT@"       AIW_V16="$(yaml_quote "http://${infra_host}:${MINIO_S3_PORT}")" \
      AIW_N=17
    exec awk '
      BEGIN {
        n = ENVIRON["AIW_N"] + 0
        for (i = 0; i < n; i++) {
          tok[i] = ENVIRON["AIW_T" i]
          val[i] = ENVIRON["AIW_V" i]
          tlen[i] = length(tok[i])
        }
      }
      {
        line = $0
        for (i = 0; i < n; i++) {
          if (tlen[i] == 0) continue
          out = ""
          while ((pos = index(line, tok[i])) > 0) {
            out = out substr(line, 1, pos - 1) val[i]
            line = substr(line, pos + tlen[i])
          }
          line = out line
        }
        print line
      }
    ' "$CONFIG_PLATFORM_FILE"
  ) > "$candidate"
  checksum="$(sha256sum "$candidate" | awk '{print $1}')"
  PLATFORM_CONFIG_PATH="$STATE_DIR/platform-config/$checksum.yaml"
  mv -f -- "$candidate" "$PLATFORM_CONFIG_PATH"
  export PLATFORM_CONFIG_PATH
}

prepare_platform_config

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
    http_200 "http://127.0.0.1:$KNOWLEDGE_FRONTEND_PORT/" >/dev/null 2>&1 &&
      http_200 "http://127.0.0.1:$KNOWLEDGE_FRONTEND_PORT/api/v1/system/info" | jq -e '.success == true' >/dev/null 2>&1
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
  exec 9>&-
  exec bash "$SCRIPT_DIR/03-start-business.sh" --verify-deploy
fi
