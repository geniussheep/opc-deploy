#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"

DEPLOY_OPC_CONSOLE_REPO_URL=https://github.com/githubsaturn/caprover-frontend.git

usage() {
  cat >&2 <<'EOF'
用法:
  bash update-sync.sh --only <targets> [--business <账号@业务机>] [--swarm <账号@Swarm机>] [--ref <分支或SHA>]

参数说明:
  --only      要更新的项目（逗号分隔）:
              platform-opc | knowledge-opc | deploy-opc | deploy-opc-console | all
  --business  业务机 SSH 目标（更新 platform-opc / knowledge-opc 时必填）
  --swarm     Swarm 机 SSH 目标（更新 deploy-opc / deploy-opc-console 时必填）
  --ref       Git 分支/标签/SHA，默认 release（deploy-opc-console 默认按 deploy-opc release.conf）

示例:
  bash update-sync.sh --only platform-opc --business ecs-user@10.101.103.129
  bash update-sync.sh --only knowledge-opc --business ecs-user@10.101.103.129
  bash update-sync.sh --only deploy-opc --swarm root@10.101.103.131
  bash update-sync.sh --only platform-opc,deploy-opc --business ecs-user@10.101.103.129 --swarm root@10.101.103.131
EOF
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

only_arg=""
business_target=""
swarm_target=""
git_ref="release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) only_arg="${2:-}"; shift 2 ;;
    --business) business_target="${2:-}"; shift 2 ;;
    --swarm) swarm_target="${2:-}"; shift 2 ;;
    --ref) git_ref="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "未知参数: $1" ;;
  esac
done

[[ -n "$only_arg" ]] || { usage; exit 2; }
[[ "$git_ref" =~ ^[A-Za-z0-9][A-Za-z0-9_./-]*$ ]] || fail "无效的 Git ref: $git_ref"

want_platform=0
want_knowledge=0
want_deploy=0
want_console=0

IFS=',' read -r -a targets <<< "$only_arg"
for item in "${targets[@]}"; do
  case "$item" in
    platform-opc) want_platform=1 ;;
    knowledge-opc|knowledge-opc-app|knowledge-opc-ui) want_knowledge=1 ;;
    deploy-opc) want_deploy=1 ;;
    deploy-opc-console) want_console=1 ;;
    all) want_platform=1; want_knowledge=1; want_deploy=1; want_console=1 ;;
    *) fail "不支持的更新目标: $item" ;;
  esac
done

need_business=$(( want_platform | want_knowledge ))
need_swarm=$(( want_deploy | want_console ))

if (( need_business )) && [[ -z "$business_target" ]]; then
  fail "更新 platform-opc 或 knowledge-opc 时必须提供 --business <账号@业务机>"
fi
if (( need_swarm )) && [[ -z "$swarm_target" ]]; then
  fail "更新 deploy-opc 或 deploy-opc-console 时必须提供 --swarm <账号@Swarm机>"
fi

for target in ${business_target:+"$business_target"} ${swarm_target:+"$swarm_target"}; do
  [[ "$target" =~ ^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$ ]] || fail "SSH 目标必须为 账号@主机: $target"
  ssh "$target" 'test -w /data/aiwork-bl && command -v rsync >/dev/null && command -v flock >/dev/null' ||
    fail "无法准备 $target，请检查 SSH、/data/aiwork-bl 写权限、rsync 和 flock"
done

stage="$(mktemp -d ./.update-sync.XXXXXX)"
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/src"

clone_repo() {
  local repo="$1" dest="$stage/src/$repo"
  printf '[INFO] 拉取 %s (%s)...\n' "$repo" "$git_ref"
  git init --quiet "$dest"
  git -C "$dest" fetch --quiet --depth 1 "https://github.com/shtokendance/$repo.git" "$git_ref"
  git -C "$dest" checkout --quiet --detach FETCH_HEAD
  git -C "$dest" rev-parse HEAD > "$dest/.aiwork-revision"
  printf '  %s -> %s\n' "$repo" "$(cat "$dest/.aiwork-revision")"
}

(( want_platform )) && clone_repo platform-opc
(( want_knowledge )) && clone_repo knowledge-opc
(( want_deploy )) && clone_repo deploy-opc

if (( want_console )); then
  console_ref=""
  if [[ -f "$stage/src/deploy-opc/release/release.conf" ]]; then
    console_ref="$(awk -F= '$1=="RELEASE_FRONTEND_COMMIT" {print $2; exit}' "$stage/src/deploy-opc/release/release.conf")"
  elif [[ -f "src/deploy-opc/release/release.conf" ]]; then
    console_ref="$(awk -F= '$1=="RELEASE_FRONTEND_COMMIT" {print $2; exit}' "src/deploy-opc/release/release.conf")"
  fi
  if [[ "$git_ref" != "release" ]]; then
    console_ref="$git_ref"
  fi
  [[ -n "$console_ref" ]] || fail "无法确定 deploy-opc-console 提交，请同时更新 deploy-opc 或使用 --ref"
  printf '[INFO] 拉取 deploy-opc-console (%s)...\n' "$console_ref"
  console_dest="$stage/src/deploy-opc-console"
  git init --quiet "$console_dest"
  git -C "$console_dest" fetch --quiet --depth 1 "$DEPLOY_OPC_CONSOLE_REPO_URL" "$console_ref"
  git -C "$console_dest" checkout --quiet --detach FETCH_HEAD
  printf '%s\n' "$DEPLOY_OPC_CONSOLE_REPO_URL" > "$console_dest/.aiwork-repository"
  git -C "$console_dest" rev-parse HEAD > "$console_dest/.aiwork-revision"
  printf '  deploy-opc-console -> %s\n' "$(cat "$console_dest/.aiwork-revision")"
fi

sync_to_host() {
  local target="$1"
  shift
  local items=("$@")
  printf '[INFO] 增量同步到 %s:/data/aiwork-bl ...\n' "$target"
  ssh "$target" 'set -eu; cd /data/aiwork-bl; mkdir -p src; wrapper=$(mktemp .source-rsync.XXXXXX); trap '\''rm -f -- "$wrapper"'\'' EXIT; cat > "$wrapper"; chmod 0700 "$wrapper"; mv -f -- "$wrapper" .source-rsync' <<'REMOTE_RSYNC'
#!/bin/sh
set -eu
umask 022
cd -- "$(dirname -- "$0")"
exec 9>.source.lock
flock -x 9
rm -f .source-ready
rsync "$@"
touch .source-ready
REMOTE_RSYNC

  local f
  for f in "${items[@]}"; do
    if [[ "$f" == src/* ]]; then
      local repo_name="${f#src/}"
      ssh "$target" "mkdir -p /data/aiwork-bl/src/$repo_name"
      rsync -rlpc --chmod=go-w --delay-updates --delete-delay --exclude='.git' \
        --rsync-path=/data/aiwork-bl/.source-rsync \
        "$stage/src/$repo_name/" "$target:/data/aiwork-bl/src/$repo_name/"
    else
      rsync -rlpc --chmod=go-w --delay-updates \
        --rsync-path=/data/aiwork-bl/.source-rsync \
        "$f" "$target:/data/aiwork-bl/$f"
    fi
  done
}

if (( need_business )); then
  biz_items=(03-build-business-images.sh 03-common.sh 03-config.platform-opc.yaml 03-docker-compose.business.yml 03-start-business.sh update-business.sh)
  (( want_platform )) && biz_items+=(src/platform-opc)
  (( want_knowledge )) && biz_items+=(src/knowledge-opc)
  sync_to_host "$business_target" "${biz_items[@]}"
fi

if (( need_swarm )); then
  swarm_items=(04-Dockerfile.deploy-console 04-build-deploy-image.sh 04-common.sh 04-nginx.deploy-opc-console.conf 04-start-deploy-opc-swarm.sh update-deploy.sh)
  (( want_deploy )) && swarm_items+=(src/deploy-opc)
  (( want_console )) && swarm_items+=(src/deploy-opc-console)
  sync_to_host "$swarm_target" "${swarm_items[@]}"
fi

mkdir -p src
touch src/.aiwork-managed
for repo in platform-opc knowledge-opc deploy-opc deploy-opc-console; do
  if [[ -d "$stage/src/$repo" ]]; then
    rm -rf -- "src/$repo"
    mv -- "$stage/src/$repo" "src/$repo"
  fi
done

printf '[OK] 定向源码与更新脚本同步完成。\n'
if (( need_business )); then
  printf '  在业务机执行: cd /data/aiwork-bl && sudo bash update-business.sh\n'
fi
if (( need_swarm )); then
  printf '  在 Swarm 机执行: cd /data/aiwork-bl && bash update-deploy.sh\n'
fi
