#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"

DEPLOY_OPC_CONSOLE_REPO_URL=https://github.com/githubsaturn/caprover-frontend.git
# 留空使用 Deploy 发布配置中的固定提交。也可填写 SHA、分支或标签的完整 ref。
DEPLOY_OPC_CONSOLE_REF=

if [[ $# -ne 2 ]]; then
  printf '用法: bash 00-prepare-source.sh <运维账号@业务机> <运维账号@Swarm机>\n' >&2
  exit 2
fi
for target in "$@"; do
  [[ "$target" =~ ^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$ ]] || {
    printf 'SSH 目标必须为 账号@主机: %s\n' "$target" >&2
    exit 2
  }
done
[[ "$1" != "$2" ]] || { printf '请分别填写业务机和 Swarm 机\n' >&2; exit 2; }
[[ ! -e src || -f src/.aiwork-managed ]] || {
  printf '现有 src 并非此脚本生成，请先备份移出\n' >&2
  exit 1
}
for target in "$@"; do
  if ! ssh "$target" 'test -w /data/aiwork-bl && command -v rsync >/dev/null && command -v flock >/dev/null'; then
    printf '无法准备 %s，请检查 SSH、/data/aiwork-bl 写权限、rsync 和 flock\n' "$target" >&2
    exit 1
  fi
done

stage=$(mktemp -d ./.source-prep.XXXXXX)
trap 'rm -rf -- "$stage"' EXIT
mkdir "$stage/src"
for repo in platform-opc knowledge-opc deploy-opc; do
  git clone --depth 1 --single-branch --branch release \
    "https://github.com/shtokendance/$repo.git" "$stage/src/$repo"
done

console_source="$stage/src/deploy-opc-console"
console_repo="$DEPLOY_OPC_CONSOLE_REPO_URL"
console_ref="$DEPLOY_OPC_CONSOLE_REF"
if [[ -z "$console_ref" ]]; then
  release_conf="$stage/src/deploy-opc/release/release.conf"
  console_ref=$(awk -F= '$1=="RELEASE_FRONTEND_COMMIT" {print $2; exit}' "$release_conf")
  [[ "$console_ref" =~ ^[a-f0-9]{40}$ ]] || {
    printf 'Deploy 发布配置缺少有效的控制台提交，请检查 00-prepare-source.sh 中的 DEPLOY_OPC_CONSOLE_REF\n' >&2
    exit 1
  }
fi
[[ "$console_repo" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$ &&
   "$console_ref" =~ ^[A-Za-z0-9][A-Za-z0-9_./-]*$ ]] || {
  printf '00-prepare-source.sh 中的控制台仓库地址或 Git ref 无效\n' >&2
  exit 1
}
git init --quiet "$console_source"
git -C "$console_source" fetch --quiet --depth 1 "$console_repo" "$console_ref"
git -C "$console_source" checkout --quiet --detach FETCH_HEAD
printf '%s\n' "$console_repo" > "$console_source/.aiwork-repository"
touch "$stage/src/.aiwork-managed"
for repo in platform-opc knowledge-opc deploy-opc deploy-opc-console; do
  git -C "$stage/src/$repo" rev-parse HEAD > "$stage/src/$repo/.aiwork-revision"
done

for repo in platform-opc knowledge-opc deploy-opc deploy-opc-console; do
  printf '%s %s\n' "$repo" "$(cat "$stage/src/$repo/.aiwork-revision")"
done

# 只同步发布文件。各阶段 env 单独按主机首次发放，现场配置和备份留在原处。
release_files=(00-network.env 00-prepare-source.sh 00-start-network.sh
  01-docker-compose.infra.yml 01-init-databases.sql 01-start-infra.sh
  02-config.litellm.yaml 02-docker-compose.platform-components.yml 02-start-platform-components.sh
  03-build-business-images.sh 03-common.sh 03-config.platform-opc.yaml
  03-docker-compose.business.yml 03-start-business.sh
  04-Dockerfile.deploy-console 04-build-deploy-image.sh 04-common.sh
  04-nginx.deploy-opc-console.conf 04-start-deploy-opc-swarm.sh
  paddleocr/server.py README.md)
mkdir "$stage/paddleocr"
for file in "${release_files[@]}"; do
  cp -p -- "$file" "$stage/$file"
done
rsync -rtp --ignore-existing --chmod=Fu=rw,Fgo-rwx \
  01-infra.env 02-platform-components.env 03-business.env "$1:/data/aiwork-bl/"
rsync -rtp --ignore-existing --chmod=Fu=rw,Fgo-rwx 04-deploy.env "$2:/data/aiwork-bl/"
for target in "$@"; do
  printf '同步到 %s:/data/aiwork-bl\n' "$target"
  ssh "$target" 'set -eu; cd /data/aiwork-bl; wrapper=$(mktemp .source-rsync.XXXXXX); trap '\''rm -f -- "$wrapper"'\'' EXIT; cat > "$wrapper"; chmod 0700 "$wrapper"; mv -f -- "$wrapper" .source-rsync' <<'REMOTE_RSYNC'
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
  (
    cd "$stage"
    rsync -rlpcR --chmod=go-w --delay-updates --delete-delay --exclude='.git' \
      --filter='protect /paddleocr/*' \
      --rsync-path=/data/aiwork-bl/.source-rsync "${release_files[@]}" src "$target:/data/aiwork-bl/"
  )
done

# 两台机器分发完成后再替换准备机的 src。
if [[ -e src ]]; then mv -- src "$stage/previous"; fi
if ! mv -- "$stage/src" src; then
  if [[ -e "$stage/previous" ]]; then mv -- "$stage/previous" src; fi
  exit 1
fi
printf '源码和部署文件已同步。首次部署请按 README 在业务机继续 00.4。\n'
