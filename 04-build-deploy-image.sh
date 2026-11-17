#!/usr/bin/env bash
set -euo pipefail

source_revision() {
  local dir="$1" sha
  [[ -r "$dir/.aiwork-revision" ]] || fail "缺少 $dir 的交付源码，请先运行 00-prepare-source.sh"
  sha="$(cat "$dir/.aiwork-revision")"
  [[ "$sha" =~ ^[a-f0-9]{40}$ ]] || fail "$dir 的源码版本无效"
  printf '%s\n' "$sha"
}

build_image() {
  local name="$1" sha="$2" repo="$3" context="$4" dockerfile="$5" tag="$6"
  shift 6
  local image="$name:$tag" id
  [[ -f "$dockerfile" ]] || fail "$name 缺少发布用 Dockerfile"
  if docker image inspect "$image" >/dev/null 2>&1; then
    image_id_for_revision "$image" "$sha" >/dev/null || fail "$image 已被不同制品占用"
    if [[ "$name" == deploy-opc-console ]]; then
      # 同一个 Git 提交在不同仓库中内容一致，保留已有镜像的实际来源。
      repo="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.source"}}' "$image")"
    fi
  else
    docker buildx build --load --platform linux/amd64 \
      --label "org.opencontainers.image.revision=$sha" --label "org.opencontainers.image.source=$repo" \
      -t "$image" -f "$dockerfile" "$@" "$context"
  fi
  id="$(image_id_for_revision "$image" "$sha")" || fail "$image 构建后校验失败"
  jq -n --arg image "$image" --arg revision "$sha" --arg id "$id" --arg source "$repo" \
    '{image:$image, revision:$revision, id:$id, source:$source}' > "$BUILD_DIR/$name.json"
}

build_images() (
  set -euo pipefail
  local pending deploy_sha console_sha console_repo console_config_sha npm_registry
  local deploy_source="$SCRIPT_DIR/src/deploy-opc"
  local console_source="$SCRIPT_DIR/src/deploy-opc-console"
  local console_dockerfile="$SCRIPT_DIR/04-Dockerfile.deploy-console"
  require_commands sha256sum
  exec 8<"$SCRIPT_DIR/.source.lock" || fail "缺少源码同步记录，请先运行 00-prepare-source.sh"
  flock -sn 8 || fail "00 正在同步源码，请同步完成后重试"
  [[ -f "$SCRIPT_DIR/.source-ready" ]] || fail "源码分发未完成，请重新执行 00-prepare-source.sh"
  BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiwork-build.XXXXXX")"
  trap 'rm -rf -- "$BUILD_DIR"; if [[ -n "${pending:-}" ]]; then rm -f -- "$pending"; fi' EXIT
  pending="$(mktemp "$STATE_DIR/.images.XXXXXX")"

  npm_registry="$(setting BUILD_NPM_REGISTRY)"
  npm_registry="${npm_registry:-https://registry.npmmirror.com}"
  [[ "$npm_registry" != *[[:space:]]* ]] || fail "BUILD_NPM_REGISTRY 不能包含空白字符"

  deploy_sha="$(source_revision "$deploy_source")"
  console_sha="$(source_revision "$console_source")"
  console_repo="$(cat "$console_source/.aiwork-repository")" ||
    fail "缺少控制台仓库记录，请重新执行 00"
  [[ "$console_repo" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$ ]] ||
    fail "控制台仓库记录无效，请重新执行 00"
  cp -R -- "$console_source" "$BUILD_DIR/console"
  cp -- "$SCRIPT_DIR/04-nginx.deploy-opc-console.conf" "$BUILD_DIR/console/.aiwork-nginx.conf"
  # 使用固定文件顺序及各自的内容摘要，避免路径影响标签。
  console_config_sha="$(
    { sha256sum < "$console_dockerfile" && sha256sum < "$BUILD_DIR/console/.aiwork-nginx.conf"; } |
      sha256sum | awk '{print $1}'
  )" || fail "无法校验控制台的 Dockerfile 和 Nginx 配置"

  build_image deploy-opc "$deploy_sha" https://github.com/shtokendance/deploy-opc.git "$deploy_source" \
    "$deploy_source/release/dockerfile.release" "${deploy_sha:0:8}"
  build_image deploy-opc-console "$console_sha" "$console_repo" "$BUILD_DIR/console" \
    "$console_dockerfile" "${console_sha:0:8}-${console_config_sha:0:8}" \
    --build-arg "NPM_REGISTRY=$npm_registry"

  jq -s '{images: (map({(.image | split(":")[0]): .}) | add)}' "$BUILD_DIR/"*.json > "$pending"
  mv -f -- "$pending" "$MANIFEST"
  jq -r '.images[].image' "$MANIFEST"
  printf '制品清单已写入 %s\n' "$MANIFEST"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(dirname -- "$0")/04-common.sh"
  [[ $# == 0 ]] || fail "用法: bash 04-build-deploy-image.sh"
  require_commands docker flock jq
  load_settings
  check_engine
  lock_deployment
  build_images
fi
