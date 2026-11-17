#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/03-common.sh"
source "$SCRIPT_DIR/03-build-business-images.sh"

usage() {
  printf '用法: bash 03-start-business.sh [--skip-build|--verify-deploy]\n'
}

skip_build=false
verify_deploy=false
case "${1:-}" in
  '') ;;
  --skip-build) skip_build=true ;;
  --verify-deploy) verify_deploy=true ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || fail "只接受一个参数"

require_commands docker jq curl flock timeout sha256sum openssl awk
load_business_settings
check_engine
lock_deployment

verify_gateway_runtime_env() {
  local env_json container_password_sha expected_password_sha
  env_json="$(docker inspect --format '{{if .State.Running}}{{json .Config.Env}}{{end}}' platform-opc-gateway 2>/dev/null)" || true
  [[ -n "$env_json" && "$env_json" != null ]] ||
    fail "platform-opc-gateway 未运行，请先执行 03 启动业务服务"
  jq -e --arg url "$DEPLOY_OPC_URL" --arg domain "$APP_ROOT_DOMAIN" '
    (map(select(startswith("APP_DEPLOY_CAPROVER_URL=")) | sub("^APP_DEPLOY_CAPROVER_URL=";""))[0] // "") == $url and
    (map(select(startswith("APP_DEPLOY_INTRANET_ROOT_DOMAIN=")) | sub("^APP_DEPLOY_INTRANET_ROOT_DOMAIN=";""))[0] // "") == $domain
  ' >/dev/null <<< "$env_json" ||
    fail "platform-opc-gateway 运行中 Deploy 地址或根域名与 03-business.env 不一致，请先重跑 03（或 --skip-build）"
  container_password_sha="$(jq -j 'map(select(startswith("APP_DEPLOY_CAPROVER_PASSWORD=")) | sub("^APP_DEPLOY_CAPROVER_PASSWORD=";""))[0] // ""' <<< "$env_json" | openssl dgst -sha256)"
  expected_password_sha="$(printf '%s' "$CAPROVER_PASSWORD" | openssl dgst -sha256)"
  [[ "$container_password_sha" == "$expected_password_sha" ]] ||
    fail "platform-opc-gateway 运行中 Deploy 口令与 03-business.env 不一致，请先重跑 03（或 --skip-build）"
}

verify_platform_deploy_path() {
  local response token
  response="$(printf '%s' "$CAPROVER_PASSWORD" | jq -Rs '{password:.}' |
    docker exec -i platform-opc-gateway curl --noproxy '*' --fail --silent --show-error --max-time 8 \
      -H 'Content-Type: application/json' --data-binary @- "$DEPLOY_OPC_URL/api/v2/login/")" ||
    fail "Platform 容器无法访问 04 的 Deploy 管理端口"
  token="$(jq -er 'select(.status == 100) | .data.token | select(type == "string" and length > 0)' <<< "$response")" ||
    fail "Platform 访问 Deploy 的管理认证未通过，请检查两机口令"
  printf 'x-captain-auth: %s\n' "$token" |
    docker exec -i platform-opc-gateway curl --noproxy '*' --fail --silent --show-error --max-time 8 \
      --header @- "$DEPLOY_OPC_URL/api/v2/user/apps/appDefinitions/" |
    jq -e '.status == 100 and (.data.appDefinitions | type == "array")' >/dev/null ||
    fail "Platform 读取 Deploy 应用列表失败"
}

verify_platform_proxy_path() {
  local direct proxied proxy_url
  proxy_url="http://$DEPLOY_OPC_HOST:$DEPLOY_OPC_PROXY_PORT"
  direct="$(docker exec platform-opc-gateway curl --noproxy '*' --fail --silent --show-error --max-time 8 \
    "$DEPLOY_OPC_URL/checkhealth")" || return 1
  proxied="$(docker exec platform-opc-gateway curl --noproxy '*' --fail --silent --show-error --max-time 8 \
    -H "Host: captain.$APP_ROOT_DOMAIN" "$proxy_url/checkhealth")" || return 1
  [[ -n "$direct" && "$direct" == "$proxied" ]]
}

verify_dynamic_application() {
  local app_url="http://$acceptance_slug.$APP_ROOT_DOMAIN"
  local -a curl_opts=(--noproxy '*' --fail --silent --show-error --max-time 10
    --location --max-redirs 3 --proto-redir '=http,https')
  docker exec platform-opc-gateway curl "${curl_opts[@]}" "$app_url/healthz" |
    jq -e 'type == "object" and length > 0' >/dev/null || return 1
  docker exec platform-opc-gateway curl "${curl_opts[@]}" "$app_url$acceptance_path" |
    jq -e --argjson expected "$acceptance_expected" '
      . as $actual | type == "object" and
      all($expected | to_entries[]; . as $entry |
        ($actual | has($entry.key)) and $actual[$entry.key] == $entry.value)
    ' >/dev/null
}

if "$verify_deploy"; then
  acceptance_slug="$(setting APP_ACCEPTANCE_SLUG)"
  acceptance_path="$(setting APP_ACCEPTANCE_READ_PATH)"
  acceptance_expected="$(setting APP_ACCEPTANCE_EXPECTED_JSON)"
  if [[ -n "$acceptance_slug$acceptance_path$acceptance_expected" ]]; then
    [[ "$acceptance_slug" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ &&
       "$acceptance_path" =~ ^/[a-zA-Z0-9._~/-]*$ && "$acceptance_path" != //* &&
       "$acceptance_path" != /healthz ]] ||
      fail "请填写有效的验收应用名和独立的只读 API 路径"
    jq -e 'type == "object" and length > 0' >/dev/null <<< "$acceptance_expected" ||
      fail "APP_ACCEPTANCE_EXPECTED_JSON 需要非空 JSON 对象"
  fi
  verify_gateway_runtime_env
  verify_platform_deploy_path
  wait_for "Platform 到 04 的 captain-nginx Host 路由" verify_platform_proxy_path
  printf '[OK] 03 → 04 管理认证、应用列表和代理路由通过\n'
  if [[ -n "$acceptance_slug" ]]; then
    wait_for "动态应用 $acceptance_slug 的 /healthz 和只读 API" verify_dynamic_application
    printf '[OK] 动态应用 %s 的真实域名和只读 API 通过\n' "$acceptance_slug"
  fi
  exit 0
fi

deployment_stage=preflight
knowledge_migration=""
receipt=""
release_attempt() {
  local rc=$? pending service details containers=""
  trap - EXIT
  if [[ -n "$receipt" ]]; then rm -f -- "$receipt"; fi
  for service in knowledge-opc-app platform-opc-gateway knowledge-opc-frontend; do
    details="$(docker ps -a --filter "label=com.docker.compose.project=opc-business" \
      --filter "label=com.docker.compose.service=$service" \
      --format '{{json .}}' 2>/dev/null || true)"
    containers="$containers"$'\n'"$details"
  done
  pending="$(mktemp "$STATE_DIR/.last-attempt.XXXXXX")" || return "$rc"
  if jq -n --arg stage "$deployment_stage" --arg migration "$knowledge_migration" --argjson exitCode "$rc" \
      --arg at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --arg containers "$containers" '
    {finished_at:$at, stage:$stage, exit_code:$exitCode,
     knowledge_migration:(if $migration=="" then null else $migration end),
     compose:[$containers | split("\n")[] | fromjson? | {id:.ID, image:.Image, state:.State, status:.Status}]}
  ' > "$pending"; then
    mv -f -- "$pending" "$STATE_DIR/last-attempt.json" || true
  fi
  rm -f -- "$pending"
  if (( rc != 0 )); then
    printf '[ERROR] 03 在 %s 阶段停止，查看 %s/last-attempt.json\n' "$deployment_stage" "$STATE_DIR" >&2
  fi
  return "$rc"
}
trap release_attempt EXIT

[[ "$(docker network inspect root_default --format '{{.Driver}}/{{.Scope}}')" == bridge/local ]] ||
  fail "需要 00–02 已创建的 root_default 本地网桥"

account_center_url="$(setting ACCOUNT_CENTER_GRAPHQL_URL)"
wecom_corp_id="$(setting WECOM_CORP_ID)"
wecom_agent_id="$(setting WECOM_AGENT_ID)"
wecom_app_secret="$(setting WECOM_APP_SECRET)"
[[ -z "$wecom_agent_id" || "$wecom_agent_id" =~ ^[0-9]+$ ]] ||
  fail "WECOM_AGENT_ID 必须为纯数字（企微自建应用 AgentId）"
KNOWLEDGE_OIDC_ENABLED=false
KNOWLEDGE_OIDC_SSRF_HOSTS=""
if [[ -n "$wecom_corp_id$wecom_app_secret" ]]; then
  [[ -n "${wecom_corp_id//[[:space:]]/}" && -n "${wecom_app_secret//[[:space:]]/}" ]] ||
    fail "启用企微需要同时配置 WECOM_CORP_ID 和 WECOM_APP_SECRET"
  [[ -n "$account_center_url" ]] || fail "启用企微需要 ACCOUNT_CENTER_GRAPHQL_URL"
  KNOWLEDGE_OIDC_ENABLED=true
  KNOWLEDGE_OIDC_SSRF_HOSTS=",platform-opc-gateway,$MAIN_DOMAIN"
fi
export KNOWLEDGE_OIDC_ENABLED KNOWLEDGE_OIDC_SSRF_HOSTS
if [[ -n "$account_center_url" ]]; then
  [[ "$account_center_url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/[a-zA-Z0-9._~/-]*)?$ &&
    ! "$account_center_url" =~ ^https?://(127\.[0-9.]+|localhost|platform-opc-gateway)(:|/|$) ]] ||
    fail "企微账户中心需要 Platform 容器可达的 ACCOUNT_CENTER_GRAPHQL_URL"
fi
deployment_stage=images
if ! "$skip_build"; then build_images; fi
load_manifest

yaml_quote() {
  jq -rn --arg v "$1" '$v | tojson'
}

url_encode() {
  jq -rn --arg v "$1" '$v | @uri'
}

resolve_infra_host() {
  local host target_ip route_out
  host="$(setting INFRA_HOST)"
  if [[ -n "${host//[[:space:]]/}" ]]; then
    [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ &&
       "$host" != localhost && "$host" != 127.* &&
       "$host" != host.docker.internal && "$host" != 0.0.0.0 ]] ||
      fail "INFRA_HOST 需要填写 01/03 主机的内网 IPv4 或 DNS 名"
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
    fail "无法自动识别本机内网 IP 供 04 Swarm 应用连接 01 基础设施，请在 03-business.env 填写 INFRA_HOST"
  printf '%s' "$host"
}

prepare_platform_config() {
  local candidate checksum infra_host="" pg_user_enc pg_pass_enc redis_pass_enc
  [[ -s "$CONFIG_PLATFORM_FILE" ]] || fail "Platform 配置模板不存在或为空"
  if [[ -n "$account_center_url" ]]; then
    grep -Fq '@ACCOUNT_CENTER_GRAPHQL_URL@' "$CONFIG_PLATFORM_FILE" ||
      fail "Platform 配置模板缺少 @ACCOUNT_CENTER_GRAPHQL_URL@"
  fi
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

runtime_image_matches() {
  local service="$1" image_name="$2" container expected actual
  container="$(compose ps -q "$service")" || return 1
  [[ -n "$container" ]] || return 1
  expected="$(jq -er --arg name "$image_name" '.images[$name].id' "$MANIFEST")" || return 1
  actual="$(docker inspect --format '{{.Image}}' "$container")" || return 1
  [[ "$actual" == "$expected" ]]
}

json_health() {
  http_200 "$1" 2>/dev/null | jq -e '.status == "ok"' >/dev/null
}

knowledge_schema_ready() {
  local expected state
  expected="$(compose exec -T knowledge-opc-app bash -euc '
    shopt -s nullglob
    files=(/app/migrations/versioned/*.up.sql)
    (( ${#files[@]} ))
    for file in "${files[@]}"; do
      name="${file##*/}"
      printf "%s\n" "${name%%_*}"
    done | sort -n | tail -n 1
  ')" || fail "无法读取 Knowledge 镜像的 PostgreSQL 迁移版本"
  [[ "$expected" =~ ^[0-9]+$ ]] || fail "Knowledge 镜像的迁移版本无效"
  expected="$((10#$expected))"
  state="$(compose exec -T knowledge-opc-app sh -euc '
    export PGPASSWORD="$DB_PASSWORD" PGCONNECT_TIMEOUT=5
    psql -XqAt -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
      -c "SELECT version, dirty FROM schema_migrations"
  ')" || fail "无法读取 Knowledge 数据库迁移状态"
  knowledge_migration="$state"
  [[ "$state" == "$expected|f" ]] ||
    fail "Knowledge 迁移未达到镜像预期版本 $expected 或处于 dirty 状态（当前：${state}）"
}

verify_platform_dependencies() {
  local ready query probe_token
  ready="$(compose exec -T knowledge-opc-app sh -euc '
    export PGPASSWORD="$DB_PASSWORD" PGCONNECT_TIMEOUT=5 PGOPTIONS="-c statement_timeout=5000 -c default_transaction_read_only=on"
    psql -XqAt -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d deploy-opc \
      -c "SELECT true FROM (SELECT count(*) FROM deployed_apps WHERE false) a,
          (SELECT count(*) FROM app_deployment_versions WHERE false) v,
          (SELECT count(*) FROM deploy_resources WHERE false) r,
          (SELECT count(*) FROM dockerfile_templates WHERE false) t"
  ')" || fail "独立部署库 deploy-opc 或业务表不可读"
  [[ "$ready" == t ]] || fail "独立部署库检查未通过"
  probe_token="$(setting PLATFORM_DEPLOY_PROBE_TOKEN)"
  if [[ -n "$probe_token" ]]; then
    printf 'Authorization: Bearer %s\n' "$probe_token" |
      http_200 --header @- "http://127.0.0.1:$PLATFORM_GATEWAY_PORT/admin/api/deploy/apps" |
      jq -e '.apps | type == "array"' >/dev/null ||
      fail "Platform 应用列表只读验收失败，请检查短期管理令牌和部署库"
    platform_deploy_acceptance=passed
  fi
  if [[ -n "$account_center_url" ]]; then
    query='{"query":"query { sysUsers(paging: {first: 1}, filter: {unionNo: {eq: \"aiwork04-readiness-probe\"}, isDeleted: {eq: 0}}) { edges { node { id } } } }"}'
    printf '%s' "$query" |
      compose exec -T platform-opc-gateway curl --noproxy '*' --fail --silent --show-error --max-time 8 \
        -H 'Content-Type: application/json' --data-binary @- "$account_center_url" |
      jq -e '((.errors // []) | length == 0) and (.data.sysUsers.edges | type == "array")' >/dev/null ||
      fail "Platform 容器的账户中心 GraphQL 只读查询失败"
  fi
}

start_compose_service() {
  local service="$1" image="$2"
  printf '启动 %s\n' "$service"
  compose up -d --no-deps --no-build --pull never "$service"
  runtime_image_matches "$service" "$image" || fail "$service 实际镜像与制品清单不一致"
}

verify_knowledge_front() {
  local front_url="http://127.0.0.1:$KNOWLEDGE_FRONTEND_PORT"
  local html
  html="$(http_200 "$front_url/" 2>/dev/null)" || return 1
  [[ "$html" == *'<html'* || "$html" == *'<HTML'* ]] || return 1
  http_200 "$front_url/api/v1/auth/oidc/config" 2>/dev/null |
    jq -e --argjson enabled "$KNOWLEDGE_OIDC_ENABLED" '.success == true and .enabled == $enabled' >/dev/null
}

deployment_stage=compose-config
prepare_platform_config
compose config --quiet
deployment_stage=knowledge-backend
start_compose_service knowledge-opc-app knowledge-opc-app
wait_for "Knowledge 后端（docker logs knowledge-opc-app）" json_health "http://127.0.0.1:$KNOWLEDGE_APP_PORT/health"
knowledge_schema_ready
printf '[OK] Knowledge 后端、PostgreSQL 迁移版本通过\n'

deployment_stage=platform
platform_deploy_acceptance=not_run
start_compose_service platform-opc-gateway platform-opc
wait_for "Platform（docker logs platform-opc-gateway）" json_health "http://127.0.0.1:$PLATFORM_GATEWAY_PORT/health"
verify_platform_dependencies
printf '[OK] Platform 健康和独立部署库检查通过\n'

deployment_stage=knowledge-frontend
KNOWLEDGE_UPSTREAM_ID="$(compose ps -q knowledge-opc-app)"
[[ -n "$KNOWLEDGE_UPSTREAM_ID" ]] || fail "无法取得 Knowledge 后端容器 ID"
export KNOWLEDGE_UPSTREAM_ID
start_compose_service knowledge-opc-frontend knowledge-opc-ui
wait_for "Knowledge 前端及后端代理（docker logs knowledge-opc-frontend）" verify_knowledge_front
printf '[OK] Knowledge 页面和前端到后端的 API 路由通过\n'

deployment_stage=release-receipt
receipt="$(mktemp "$STATE_DIR/.active-release.XXXXXX")"
jq --arg deployedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg config "$PLATFORM_CONFIG_PATH" --arg rootDomain "$APP_ROOT_DOMAIN" \
  --arg platform "$platform_deploy_acceptance" \
  '. + {verified_at:$deployedAt, platform_config:$config, app_root_domain:$rootDomain,
    platform_deploy_api:$platform}' "$MANIFEST" > "$receipt"
if [[ -f "$STATE_DIR/active-release.json" ]] &&
    ! jq -e --slurpfile current "$receipt" '.images == $current[0].images and .platform_config == $current[0].platform_config' \
    "$STATE_DIR/active-release.json" >/dev/null; then
  cp -- "$STATE_DIR/active-release.json" "$STATE_DIR/previous-release.json"
fi
mv -f -- "$receipt" "$STATE_DIR/active-release.json"
deployment_stage=complete
printf '03 业务 Compose 验收通过。记录：%s/active-release.json\n' "$STATE_DIR"
printf '在 Swarm 机执行 04 后，回到业务机运行 bash 03-start-business.sh --verify-deploy。\n'
