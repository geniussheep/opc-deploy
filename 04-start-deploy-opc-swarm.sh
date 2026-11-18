#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/04-common.sh"
source "$SCRIPT_DIR/04-build-deploy-image.sh"

ADMIN_URL=""
DEPLOY_SERVICE_NAME=deploy-opc
CONSOLE_SERVICE_NAME=deploy-opc-console
CONSOLE_NETWORK=captain-overlay-network

swarm_preflight() {
  local state nodes daemon local_daemon api_range api_version min_api_version
  daemon="$(docker info --format '{{.ID}}')" || return 1
  local_daemon="$(docker --host unix:///var/run/docker.sock info --format '{{.ID}}')" ||
    fail "Deploy 需要可访问的宿主机 /var/run/docker.sock"
  [[ -n "$daemon" && "$daemon" == "$local_daemon" ]] || fail "04 需要操作挂载给 Deploy 的本机 Docker Engine"
  api_range="$(docker version --format '{{.Server.APIVersion}} {{.Server.MinAPIVersion}}')" || return 1
  read -r api_version min_api_version <<< "$api_range"
  [[ "$api_version" =~ ^1\.[0-9]+$ && "$min_api_version" =~ ^1\.[0-9]+$ ]] &&
    (( 10#${api_version#1.} >= 44 && 10#${min_api_version#1.} <= 44 )) ||
    fail "Deploy 需要 Docker Engine 支持 API v1.44，当前范围：${min_api_version:-?} 至 ${api_version:-?}"
  state="$(docker info --format '{{.Swarm.LocalNodeState}}')" || return 1
  case "$state" in
    inactive)
      [[ "$(setting SWARM_ADVERTISE_ADDR)" =~ ^[0-9]+(\.[0-9]+){3}$ ]] ||
        fail "初始化 Swarm 前请设置宿主机内网 SWARM_ADVERTISE_ADDR"
      [[ "$(setting CAPROVER_ACCEPT_TERMS)" == true ]] || fail "首次安装前请阅读条款并设置 CAPROVER_ACCEPT_TERMS=true"
      check_first_install_data
      ;;
    active)
      [[ "$(docker info --format '{{.Swarm.ControlAvailable}}')" == true ]] ||
        fail "请在 Swarm manager 上执行 04"
      nodes="$(docker node ls -q)" || return 1
      [[ -n "$nodes" && "$nodes" != *$'\n'* ]] || fail "本地制品仅支持单节点 Swarm"
      [[ "$(docker node inspect self --format '{{.Status.State}}/{{.Spec.Availability}}')" == ready/active ]] ||
        fail "Swarm manager 节点需要为 ready/active"
      find_deploy_service
      if [[ -z "$DEPLOY_SERVICE" ]]; then
        [[ "$(setting CAPROVER_ACCEPT_TERMS)" == true ]] || fail "首次安装前请阅读条款并设置 CAPROVER_ACCEPT_TERMS=true"
        check_first_install_data
      else
        verify_existing_deploy
      fi
      ;;
    *) fail "不支持当前 Swarm 状态 $state" ;;
  esac
}

check_first_install_data() {
  [[ ! -e "$CAPTAIN_PATH/backup.tar" && ! -e "$CAPTAIN_PATH/data/config-captain.json" ]] ||
    fail "发现既有 Deploy 数据或备份，请按 README 恢复原实例并验证后再执行 04"
}

find_deploy_service() {
  local names
  names="$(docker service ls --format '{{.Name}}')" || return 1
  DEPLOY_SERVICE=""
  if grep -Fxq "$DEPLOY_SERVICE_NAME" <<< "$names"; then DEPLOY_SERVICE="$DEPLOY_SERVICE_NAME"; fi
  if grep -Fxq captain-captain <<< "$names"; then
    [[ -z "$DEPLOY_SERVICE" ]] || fail "发现两个 Deploy 控制服务，需要先确定当前实例"
    DEPLOY_SERVICE=captain-captain
  fi
  if [[ -z "$DEPLOY_SERVICE" ]] && grep -Eq '^captain-(nginx|certbot)$' <<< "$names"; then
    fail "存在 CapRover 系统服务但缺少控制服务，请先恢复原实例"
  fi
}

verify_existing_deploy() {
  local spec override data_config="$CAPTAIN_PATH/data/config-captain.json"
  spec="$(docker service inspect "$DEPLOY_SERVICE")" || return 1
  jq -e --arg path "$CAPTAIN_PATH" --argjson admin "$DEPLOY_OPC_ADMIN_PORT" '
    .[0].Spec as $s |
    $s.Mode.Replicated.Replicas == 1 and
    any($s.TaskTemplate.ContainerSpec.Env[]?; . == "IS_CAPTAIN_INSTANCE=1") and
    any($s.TaskTemplate.ContainerSpec.Mounts[]?; .Type == "bind" and .Source == $path and .Target == $path) and
    any($s.TaskTemplate.ContainerSpec.Mounts[]?; .Type == "bind" and
        .Source == "/var/run/docker.sock" and .Target == "/var/run/docker.sock") and
    any($s.EndpointSpec.Ports[]?; .Protocol == "tcp" and .PublishMode == "host" and
        .PublishedPort == $admin and .TargetPort == 3000) and
    ($s.EndpointSpec.Ports | length) == 1
  ' >/dev/null <<< "$spec" || fail "已有 $DEPLOY_SERVICE 的安装标记、挂载或管理端口与 04 不匹配，请先按 README 迁移"
  override="$CAPTAIN_PATH/data/config-override.json"
  if [[ "$DEPLOY_SERVICE" == "$DEPLOY_SERVICE_NAME" && ! -f "$override" ]]; then
    fail "已有 $DEPLOY_SERVICE 缺少 $override，无法确认控制服务名称"
  fi
  if [[ -e "$override" ]]; then
    jq -e --arg name "$DEPLOY_SERVICE" --argjson admin "$DEPLOY_OPC_ADMIN_PORT" \
      --argjson http "$DEPLOY_OPC_PROXY_PORT" --argjson https "$DEPLOY_OPC_HTTPS_PORT" '
        (.captainServiceName // "captain-captain") == $name and
        (.captainSubDomain // "captain") == "captain" and
        (.adminPortNumber3000 // $admin) == $admin and
        (.nginxPortNumber80 // $http) == $http and
        (.nginxPortNumber443 // $https) == $https
      ' "$override" >/dev/null || fail "现有 Deploy override 与 04 端口或服务名不一致"
  fi
  if [[ -e "$data_config" ]]; then
    jq -e 'type == "object" and (.forceRootSsl != true)' "$data_config" >/dev/null ||
      fail "Deploy 数据配置无效或控制台开启 Force HTTPS，请先按 README 检查并由统一入口终止 TLS"
    jq -e --arg domain "$APP_ROOT_DOMAIN" '(.customDomain // "") as $root | $root == "" or $root == $domain' \
      "$data_config" >/dev/null || fail "现有 Deploy 根域与 APP_ROOT_DOMAIN 不一致，请先核对 04 配置"
  fi
  if docker service inspect captain-nginx >/dev/null 2>&1; then
    verify_nginx_ports || fail "现有 captain-nginx 端口与 04 不一致，请先迁移"
  fi
}

verify_nginx_ports() {
  local spec
  spec="$(docker service inspect --format '{{json .Endpoint.Spec.Ports}}' captain-nginx 2>/dev/null)" || return 1
  jq -e --argjson http "$DEPLOY_OPC_PROXY_PORT" --argjson https "$DEPLOY_OPC_HTTPS_PORT" '
    any(.[]?; .Protocol == "tcp" and .PublishMode == "host" and .PublishedPort == $http and .TargetPort == 80) and
    any(.[]?; .Protocol == "tcp" and .PublishMode == "host" and .PublishedPort == $https and .TargetPort == 443)
  ' >/dev/null <<< "$spec"
}

create_deploy() (
  local bootstrap_file bootstrap status node_ip pending_override bootstrap_password
  local override="$CAPTAIN_PATH/data/config-override.json"
  [[ ! -L "$CAPTAIN_PATH" ]] || fail "请配置 /captain 软链接指向的实际数据目录"
  umask 077
  mkdir -p -- "$CAPTAIN_PATH/data"
  if [[ ! -e "$override" ]]; then
    pending_override="$(mktemp "$CAPTAIN_PATH/data/.config-override.XXXXXX")"
    jq -n --arg name "$DEPLOY_SERVICE_NAME" --argjson admin "$DEPLOY_OPC_ADMIN_PORT" --argjson http "$DEPLOY_OPC_PROXY_PORT" \
      --argjson https "$DEPLOY_OPC_HTTPS_PORT" '{
        captainServiceName:$name, useExistingSwarm:true, skipVerifyingDomains:true,
        adminPortNumber3000:$admin, nginxPortNumber80:$http, nginxPortNumber443:$https
      }' > "$pending_override"
    mv -- "$pending_override" "$override"
  fi
  jq -e --arg name "$DEPLOY_SERVICE_NAME" --argjson admin "$DEPLOY_OPC_ADMIN_PORT" --argjson http "$DEPLOY_OPC_PROXY_PORT" \
    --argjson https "$DEPLOY_OPC_HTTPS_PORT" '
      .captainServiceName == $name and
      (.captainSubDomain // "captain") == "captain" and
      .adminPortNumber3000 == $admin and .nginxPortNumber80 == $http and .nginxPortNumber443 == $https and
      .useExistingSwarm == true
  ' "$override" >/dev/null || fail "已有 Deploy 数据目录的 override 与新装参数不一致，请先检查 $override"

  # 版本覆盖仅挂载给引导容器。正式服务保留自身 release.conf 中的引擎版本。
  bootstrap=""
  bootstrap_file="$(mktemp "$STATE_DIR/.bootstrap.XXXXXX")"
  trap 'if [[ -n "$bootstrap" ]]; then docker rm -f "$bootstrap" >/dev/null 2>&1 || true; fi; rm -f -- "$bootstrap_file"' EXIT
  jq --arg version "${IMAGE_DEPLOY_OPC##*:}" \
    '. + {publishedNameOnDockerHub:"deploy-opc", version:$version}' "$override" > "$bootstrap_file"
  node_ip="$(docker node inspect self --format '{{.Status.Addr}}')"
  bootstrap_password="aiw04-$(openssl rand -hex 10)"
  [[ "$bootstrap_password" != "$CAPROVER_PASSWORD" ]] || fail "引导口令与正式口令相同，请重试"
  # 留下摘要以便中断后继续，并确认只轮换由 04 创建的引导口令。
  printf '%s' "$bootstrap_password" | openssl dgst -sha256 > "$STATE_DIR/deploy-bootstrap.sha256"
  bootstrap="$(
    DEFAULT_PASSWORD="$bootstrap_password" docker create --pull never \
      --env DEFAULT_PASSWORD --env ACCEPTED_TERMS=true --env BY_PASS_PROXY_CHECK=true \
      --env "MAIN_NODE_IP_ADDRESS=$node_ip" --env "CAPTAIN_BASE_DIRECTORY=$CAPTAIN_PATH" \
      --mount "type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock" \
      --mount "type=bind,source=$CAPTAIN_PATH,target=$CAPTAIN_PATH" \
      --mount "type=bind,source=$bootstrap_file,target=$override,readonly" \
      "$IMAGE_DEPLOY_OPC"
  )"
  docker start "$bootstrap" >/dev/null
  if ! status="$(timeout "$READY_TIMEOUT" docker wait "$bootstrap")" || [[ "$status" != 0 ]]; then
    docker logs --tail 30 "$bootstrap" >&2
    fail "Deploy 引导超时或异常退出，请检查是否已生成 Swarm 服务"
  fi
  # 安装器捕获部分异常后仍以 0 退出，另外确认正式服务已创建。
  if ! docker service inspect "$DEPLOY_SERVICE_NAME" >/dev/null 2>&1; then
    docker logs --tail 30 "$bootstrap" >&2
    fail "Deploy 引导没有创建正式服务"
  fi
)

deploy_ready() {
  local image container actual expected
  image="$(docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' "$DEPLOY_SERVICE")" || return 1
  [[ "${image%@*}" == "$IMAGE_DEPLOY_OPC" ]] || return 1
  container="$(docker ps --filter "label=com.docker.swarm.service.name=$DEPLOY_SERVICE" --format '{{.ID}}')" || return 1
  [[ -n "$container" && "$container" != *$'\n'* ]] || return 1
  actual="$(docker inspect --format '{{.Image}}' "$container")" || return 1
  expected="$(jq -er '.images["deploy-opc"].id' "$MANIFEST")" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  http_200 "$ADMIN_URL/checkhealth" 2>/dev/null | grep -Eq '^[a-f0-9-]{36}$'
}

deploy_api() {
  local path="$1" body="${2:-}"
  local -a args=(--header @-)
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary "$body")
  fi
  # curl 从 stdin 读令牌 header，避免进入命令行参数和日志。
  printf 'x-captain-auth: %s\n' "$DEPLOY_TOKEN" |
    http_200 "${args[@]}" "$ADMIN_URL/api/v2/user/$path" |
    jq -ec 'select(.status == 100)'
}

verify_deploy_auth() {
  local password="${1:-$CAPROVER_PASSWORD}" response
  DEPLOY_AUTH_STATUS=""
  DEPLOY_TOKEN=""
  response="$(printf '%s' "$password" | jq -Rs '{password:.}' |
    http_200 -H 'Content-Type: application/json' --data-binary @- "$ADMIN_URL/api/v2/login/" 2>/dev/null)" || return 1
  DEPLOY_AUTH_STATUS="$(jq -er '.status | numbers' <<< "$response")" || return 1
  case "$DEPLOY_AUTH_STATUS" in
    1001|1105|1113) return 1 ;;
  esac
  DEPLOY_TOKEN="$(jq -er 'select(.status == 100) | .data.token | select(type == "string" and length > 0)' <<< "$response")" ||
    fail "Deploy 管理认证失败（状态 ${DEPLOY_AUTH_STATUS}），请检查现有实例认证配置"
}

deploy_auth_decided() {
  verify_deploy_auth || [[ "$DEPLOY_AUTH_STATUS" == 1105 ]]
}

finalize_deploy_password() {
  local bootstrap_password env_spec managed=false
  local marker="$STATE_DIR/deploy-bootstrap.sha256"
  env_spec="$(docker service inspect --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}' "$DEPLOY_SERVICE")"
  bootstrap_password="$(jq -r '.[]? | select(startswith("DEFAULT_PASSWORD=aiw04-")) | sub("^DEFAULT_PASSWORD=";"")' <<< "$env_spec")"
  if [[ -f "$marker" && "$bootstrap_password" =~ ^aiw04-[a-f0-9]{20}$ ]] &&
    [[ "$(printf '%s' "$bootstrap_password" | openssl dgst -sha256)" == "$(cat "$marker")" ]]; then
    managed=true
  fi
  wait_for "Deploy 管理 API 认证" deploy_auth_decided
  if [[ "$DEPLOY_AUTH_STATUS" == 1105 ]]; then
    "$managed" || fail "Deploy 管理认证失败，请核对 CAPROVER_PASSWORD"
    verify_deploy_auth "$bootstrap_password" ||
      fail "Deploy 引导口令认证失败，请核对已有实例的正式口令"
    # JSON 正文和认证头分别用 stdin 与 fd 3，口令和令牌都不进入命令行。
    printf '%s\n%s' "$bootstrap_password" "$CAPROVER_PASSWORD" |
      jq -Rs 'split("\n") | {oldPassword:.[0],newPassword:.[1]}' |
      http_200 -H @/dev/fd/3 -H 'Content-Type: application/json' --data-binary @- \
        "$ADMIN_URL/api/v2/user/changepassword/" 3< <(printf 'x-captain-auth: %s\n' "$DEPLOY_TOKEN") |
      jq -e '.status == 100' >/dev/null ||
      fail "Deploy 首装口令未能持久化"
  fi
  if "$managed"; then
    [[ "$bootstrap_password" != "$CAPROVER_PASSWORD" ]] ||
      fail "请使用不同于临时引导口令的正式口令"
    wait_for "Deploy 正式口令认证" verify_deploy_auth
    timeout "$READY_TIMEOUT" docker service update --no-resolve-image --update-order stop-first \
      --env-rm DEFAULT_PASSWORD "$DEPLOY_SERVICE" >/dev/null
    wait_for "移除临时口令后的 Deploy 认证" verify_deploy_auth
  fi
  if [[ -f "$marker" && ( "$managed" == true || -z "$bootstrap_password" ) ]]; then
    rm -f -- "$marker"
  fi
}

initialize_domain() {
  local info current body
  info="$(deploy_api system/info/)" || fail "无法读取 Deploy 域名"
  current="$(jq -er '.data.rootDomain | strings' <<< "$info")" || fail "无法识别 Deploy 域名响应"
  if [[ -n "$current" ]]; then
    [[ "$current" == "$APP_ROOT_DOMAIN" ]] || fail "Deploy 已配置其他域名，请保留现有域名或先迁移"
    return
  fi
  body="$(jq -n --arg rootDomain "$APP_ROOT_DOMAIN" '{rootDomain:$rootDomain}')"
  deploy_api system/changerootdomain/ "$body" >/dev/null ||
    fail "Deploy 域名初始化失败，请检查域名与 nginx"
  info="$(deploy_api system/info/)" || fail "无法重新读取 Deploy 域名"
  jq -e --arg domain "$APP_ROOT_DOMAIN" '.data.rootDomain == $domain' <<< "$info" >/dev/null ||
    fail "Deploy 域名未生效"
}

verify_nginx_route() {
  local direct proxied
  verify_nginx_ports || return 1
  direct="$(http_200 "$ADMIN_URL/checkhealth" 2>/dev/null)" || return 1
  proxied="$(http_200 -H "Host: captain.$APP_ROOT_DOMAIN" \
    "http://127.0.0.1:$DEPLOY_OPC_PROXY_PORT/checkhealth" 2>/dev/null)" || return 1
  [[ -n "$direct" && "$direct" == "$proxied" ]]
}

ensure_volume_roots() {
  local roots current_env update_args=() root
  roots="$(setting OPC_APP_VOLUME_ROOTS)"
  [[ -n "${roots//[[:space:]]/}" ]] || return 0
  current_env="$(docker service inspect --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' "$DEPLOY_SERVICE" | awk -F= '$1=="OPC_APP_VOLUME_ROOTS"{print substr($0, index($0,"=")+1); exit}')"
  if [[ "$current_env" != "$roots" ]]; then
    update_args+=(--env-add "OPC_APP_VOLUME_ROOTS=$roots")
  fi
  IFS=',' read -r -a root_list <<< "$roots"
  for root in "${root_list[@]}"; do
    [[ -n "$root" ]] || continue
    [[ -d "$root" ]] || fail "OPC_APP_VOLUME_ROOTS 中的目录不存在: $root"
    if ! docker service inspect --format '{{json .Spec.TaskTemplate.ContainerSpec.Mounts}}' "$DEPLOY_SERVICE" |
        jq -e --arg p "$root" 'any(.[]; .Type == "bind" and .Source == $p and .Target == $p and (.ReadOnly // false | not))' >/dev/null; then
      update_args+=(--mount-add "type=bind,source=$root,target=$root")
    fi
  done
  if (( ${#update_args[@]} > 0 )); then
    timeout "$READY_TIMEOUT" docker service update --update-order stop-first "${update_args[@]}" "$DEPLOY_SERVICE" >/dev/null
  fi
}

start_deploy_swarm() {
  local previous
  ADMIN_URL="http://127.0.0.1:$DEPLOY_OPC_ADMIN_PORT"
  swarm_preflight
  if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}')" == inactive ]]; then
    docker swarm init --advertise-addr "$(setting SWARM_ADVERTISE_ADDR)" >/dev/null
  fi
  find_deploy_service
  if [[ -z "$DEPLOY_SERVICE" ]]; then
    create_deploy
    find_deploy_service
  else
    previous="$(docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' "$DEPLOY_SERVICE")"
    if [[ "${previous%@*}" != "$IMAGE_DEPLOY_OPC" ]]; then
      # 回到上一已验收镜像时，故障版本的 API 可能已不可用。
      if ! jq -e --arg image "$IMAGE_DEPLOY_OPC" '
        .images["deploy-opc"].image == $image
      ' "$STATE_DIR/active-release.json" >/dev/null 2>&1; then
        verify_deploy_auth || fail "更新前无法使用 CAPROVER_PASSWORD 登录现有 Deploy，请先恢复或核对口令"
      fi
      # 本机已校验制品，禁止请求远端解析同名镜像。
      timeout "$READY_TIMEOUT" docker service update --no-resolve-image --update-order stop-first --update-failure-action rollback \
        --image "$IMAGE_DEPLOY_OPC" "$DEPLOY_SERVICE" >/dev/null
    fi
  fi
  ensure_volume_roots
  verify_existing_deploy
  wait_for "$DEPLOY_SERVICE 管理 API" deploy_ready
  finalize_deploy_password
  initialize_domain
  wait_for "captain-nginx Host 路由" verify_nginx_route
  printf '[OK] %s 已运行指定镜像，管理认证与 captain-nginx Host 路由通过\n' "$DEPLOY_SERVICE"
}

console_ready() {
  local console_url="http://127.0.0.1:$DEPLOY_OPC_CONSOLE_PORT" host="captain.$APP_ROOT_DOMAIN"
  local container actual expected page direct proxied
  container="$(docker ps --filter "label=com.docker.swarm.service.name=$CONSOLE_SERVICE_NAME" --format '{{.ID}}')" || return 1
  [[ -n "$container" && "$container" != *$'\n'* ]] || return 1
  actual="$(docker inspect --format '{{.Image}}' "$container")" || return 1
  expected="$(jq -er '.images["deploy-opc-console"].id' "$MANIFEST")" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  page="$(http_200 -H "Host: $host" "$console_url/" 2>/dev/null)" || return 1
  [[ "$page" == *'<html'* || "$page" == *'<HTML'* ]] || return 1
  direct="$(http_200 "$ADMIN_URL/checkhealth" 2>/dev/null)" || return 1
  proxied="$(http_200 -H "Host: $host" "$console_url/checkhealth" 2>/dev/null)" || return 1
  [[ -n "$direct" && "$proxied" == "$direct" ]] || return 1
  printf 'x-captain-auth: %s\n' "$DEPLOY_TOKEN" |
    http_200 -H "Host: $host" --header @- "$console_url/api/v2/user/apps/appDefinitions/" 2>/dev/null |
    jq -e '.status == 100 and (.data.appDefinitions | type == "array")' >/dev/null
}

start_deploy_console() {
  local network_id spec current_image current_port backend
  local publish="mode=host,published=$DEPLOY_OPC_CONSOLE_PORT,target=80"
  local -a update=()
  network_id="$(docker network inspect --format '{{if and (eq .Driver "overlay") (eq .Scope "swarm")}}{{.Id}}{{end}}' "$CONSOLE_NETWORK")" ||
    fail "找不到 Deploy 的 $CONSOLE_NETWORK 网络"
  [[ -n "$network_id" ]] || fail "$CONSOLE_NETWORK 不是 Swarm overlay 网络"

  if spec="$(docker service inspect "$CONSOLE_SERVICE_NAME" 2>/dev/null)"; then
    jq -e --arg network "$network_id" '
      .[0].Spec as $s |
      $s.Labels["com.aiwork.service"] == "deploy-opc-console" and
      $s.Mode.Replicated.Replicas == 1 and
      any($s.TaskTemplate.Networks[]?; .Target == $network) and
      ($s.EndpointSpec.Ports | length) == 1 and
      any($s.EndpointSpec.Ports[]?; .Protocol == "tcp" and .PublishMode == "host" and .TargetPort == 80)
    ' >/dev/null <<< "$spec" || fail "已有 $CONSOLE_SERVICE_NAME 的归属、网络或端口配置不匹配"
    current_image="$(jq -er '.[0].Spec.TaskTemplate.ContainerSpec.Image' <<< "$spec")"
    current_port="$(jq -er '.[0].Spec.EndpointSpec.Ports[0].PublishedPort' <<< "$spec")"
    backend="$(jq -r '.[0].Spec.TaskTemplate.ContainerSpec.Env[]? | select(startswith("DEPLOY_OPC_API_HOST="))' <<< "$spec")"
    if [[ "${current_image%@*}" != "$IMAGE_DEPLOY_OPC_CONSOLE" ]]; then
      update+=(--image "$IMAGE_DEPLOY_OPC_CONSOLE")
    fi
    if [[ "$backend" != "DEPLOY_OPC_API_HOST=$DEPLOY_SERVICE" ]]; then
      update+=(--env-add "DEPLOY_OPC_API_HOST=$DEPLOY_SERVICE")
    fi
    if [[ "$current_port" != "$DEPLOY_OPC_CONSOLE_PORT" ]]; then
      update+=(--publish-rm mode=host,target=80 --publish-add "$publish")
    fi
    if (( ${#update[@]} )); then
      timeout "$READY_TIMEOUT" docker service update --no-resolve-image --update-order stop-first \
        --update-failure-action rollback "${update[@]}" "$CONSOLE_SERVICE_NAME" >/dev/null
    fi
  else
    timeout "$READY_TIMEOUT" docker service create --no-resolve-image --name "$CONSOLE_SERVICE_NAME" \
      --label com.aiwork.service=deploy-opc-console --network "$CONSOLE_NETWORK" --replicas 1 \
      --env "DEPLOY_OPC_API_HOST=$DEPLOY_SERVICE" --publish "$publish" "$IMAGE_DEPLOY_OPC_CONSOLE" >/dev/null
  fi
  wait_for "$CONSOLE_SERVICE_NAME 页面和同源 Deploy API" console_ready
  printf '[OK] %s 已就绪，控制台端口 %s，同源 API 通过\n' "$CONSOLE_SERVICE_NAME" "$DEPLOY_OPC_CONSOLE_PORT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help|-h) printf '用法: bash 04-start-deploy-opc-swarm.sh [--skip-build]\n'; exit 0 ;;
    ''|--skip-build) ;;
    *) fail "用法: bash 04-start-deploy-opc-swarm.sh [--skip-build]" ;;
  esac
  [[ $# -le 1 ]] || fail "只接受一个参数"
  require_commands docker jq curl flock timeout openssl
  load_swarm_settings
  check_engine
  lock_deployment
  swarm_preflight
  if [[ "${1:-}" != --skip-build ]]; then build_images; fi
  load_manifest
  start_deploy_swarm
  start_deploy_console
  unset DEPLOY_TOKEN
  jq --arg verifiedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg service "$DEPLOY_SERVICE" --arg consoleService "$CONSOLE_SERVICE_NAME" \
    '. + {verified_at:$verifiedAt, service:$service, console_service:$consoleService}' "$MANIFEST" > "$STATE_DIR/.active-release.new"
  mv -f -- "$STATE_DIR/.active-release.new" "$STATE_DIR/active-release.json"
fi
