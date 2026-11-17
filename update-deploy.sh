#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/04-common.sh"
source "$SCRIPT_DIR/04-build-deploy-image.sh"

usage() {
  cat >&2 <<'EOF'
用法:
  bash update-deploy.sh [--only <targets>]

参数说明:
  --only  要更新的 Swarm 服务（逗号分隔）:
          auto（默认，自动检测版本有变化的项目）
          deploy-opc | deploy-opc-console | all
EOF
}

only_arg="auto"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) only_arg="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "未知参数: $1" ;;
  esac
done

require_commands docker jq curl flock sha256sum awk
load_settings
check_engine
lock_deployment

[[ -r "$MANIFEST" ]] || fail "缺少 $MANIFEST，请先完成首次部署（04-build-deploy-image.sh + 04-start-deploy-opc-swarm.sh）"
exec 8<"$SCRIPT_DIR/.source.lock" || fail "缺少源码同步记录，请先运行 00-prepare-source.sh 或 update-sync.sh"
flock -sn 8 || fail "源码正在同步中，请稍后重试"
[[ -f "$SCRIPT_DIR/.source-ready" ]] || fail "源码分发未完成，请重新同步源码"

deploy_source="$SCRIPT_DIR/src/deploy-opc"
console_source="$SCRIPT_DIR/src/deploy-opc-console"
console_dockerfile="$SCRIPT_DIR/04-Dockerfile.deploy-console"

deploy_sha="$(source_revision "$deploy_source")"
console_sha="$(source_revision "$console_source")"

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiwork-update-deploy.XXXXXX")"
pending="$(mktemp "$STATE_DIR/.images.XXXXXX")"
trap 'rm -rf -- "$BUILD_DIR" "$pending"' EXIT

cp -R -- "$console_source" "$BUILD_DIR/console"
cp -- "$SCRIPT_DIR/04-nginx.deploy-opc-console.conf" "$BUILD_DIR/console/.aiwork-nginx.conf"
console_config_sha="$(
  { sha256sum < "$console_dockerfile" && sha256sum < "$BUILD_DIR/console/.aiwork-nginx.conf"; } |
    sha256sum | awk '{print $1}'
)" || fail "无法校验控制台的 Dockerfile 和 Nginx 配置"
expected_console_tag="${console_sha:0:8}-${console_config_sha:0:8}"

want_deploy=0
want_console=0
if [[ "$only_arg" == "auto" ]]; then
  cur_deploy="$(jq -r '.images["deploy-opc"].revision // ""' "$MANIFEST")"
  cur_console_image="$(jq -r '.images["deploy-opc-console"].image // ""' "$MANIFEST")"
  [[ "$deploy_sha" != "$cur_deploy" ]] && want_deploy=1
  [[ "deploy-opc-console:$expected_console_tag" != "$cur_console_image" ]] && want_console=1
else
  IFS=',' read -r -a targets <<< "$only_arg"
  for item in "${targets[@]}"; do
    case "$item" in
      deploy-opc) want_deploy=1 ;;
      deploy-opc-console) want_console=1 ;;
      all) want_deploy=1; want_console=1 ;;
      *) fail "不支持的更新目标: $item" ;;
    esac
  done
fi

if (( want_deploy == 0 && want_console == 0 )); then
  printf '[OK] Swarm 镜像均已是最新源码版本（deploy-opc=%s, console=%s），无需更新。\n' \
    "${deploy_sha:0:8}" "$expected_console_tag"
  exit 0
fi

for existing in deploy-opc deploy-opc-console; do
  jq -e --arg k "$existing" '.images[$k]' "$MANIFEST" > "$BUILD_DIR/$existing.json" ||
    fail "$MANIFEST 缺少 $existing 记录，请先执行一次全量 04 构建"
done

npm_registry="$(setting BUILD_NPM_REGISTRY)"
npm_registry="${npm_registry:-https://registry.npmmirror.com}"
[[ "$npm_registry" != *[[:space:]]* ]] || fail "BUILD_NPM_REGISTRY 不能包含空白字符"

if (( want_deploy )); then
  build_image deploy-opc "$deploy_sha" https://github.com/shtokendance/deploy-opc.git "$deploy_source" \
    "$deploy_source/release/dockerfile.release" "${deploy_sha:0:8}"
fi

if (( want_console )); then
  console_repo="$(cat "$console_source/.aiwork-repository")" ||
    fail "缺少控制台仓库记录，请重新执行 00 或 update-sync.sh"
  build_image deploy-opc-console "$console_sha" "$console_repo" "$BUILD_DIR/console" \
    "$console_dockerfile" "$expected_console_tag" \
    --build-arg "NPM_REGISTRY=$npm_registry"
fi

jq -s '{images: (map({(.image | split(":")[0]): .}) | add)}' "$BUILD_DIR/"*.json > "$pending"
mv -f -- "$pending" "$MANIFEST"

load_manifest

if (( want_deploy )); then
  deploy_service="$(docker service ls --filter label=aiwork.role=deploy-opc --format '{{.Name}}' | head -n1)"
  [[ -n "$deploy_service" ]] || deploy_service="captain-captain"
  printf '[INFO] 更新 Swarm 服务 %s -> %s ...\n' "$deploy_service" "$IMAGE_DEPLOY_OPC"
  docker service update --force --image "$IMAGE_DEPLOY_OPC" "$deploy_service"
fi

if (( want_console )); then
  console_service="$(jq -r '.console_service // "deploy-opc-console"' "$STATE_DIR/active-release.json" 2>/dev/null || echo deploy-opc-console)"
  printf '[INFO] 更新 Swarm 服务 %s -> %s ...\n' "$console_service" "$IMAGE_DEPLOY_OPC_CONSOLE"
  docker service update --force --image "$IMAGE_DEPLOY_OPC_CONSOLE" "$console_service"
fi

if [[ -f "$STATE_DIR/active-release.json" ]]; then
  cp -- "$STATE_DIR/active-release.json" "$STATE_DIR/previous-release.json"
fi
jq --arg verifiedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '. + {verified_at:$verifiedAt}' "$MANIFEST" > "$STATE_DIR/.active-release.new"
mv -f -- "$STATE_DIR/.active-release.new" "$STATE_DIR/active-release.json"
printf '[OK] Swarm 增量更新完成。当前清单: %s\n' "$STATE_DIR/active-release.json"
