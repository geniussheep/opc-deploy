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
  local name="$1" sha="$2" repo="$3" context="$4" dockerfile="$5"
  shift 5
  local image="$name:${sha:0:8}" id
  [[ -f "$dockerfile" ]] || fail "$name 缺少发布用 Dockerfile"
  if docker image inspect "$image" >/dev/null 2>&1; then
    image_id_for_revision "$image" "$sha" >/dev/null || fail "$image 已被不同制品占用"
  else
    docker buildx build --load --platform linux/amd64 \
      --label "org.opencontainers.image.revision=$sha" --label "org.opencontainers.image.source=$repo" \
      -t "$image" -f "$dockerfile" "$@" "$context"
  fi
  id="$(image_id_for_revision "$image" "$sha")" || fail "$image 构建后校验失败"
  jq -n --arg image "$image" --arg revision "$sha" --arg id "$id" --arg source "$repo" \
    '{image:$image, revision:$revision, id:$id, source:$source}' > "$BUILD_DIR/$name.json"
}

prepare_platform_dockerfile() {
  local source_dir="$1" version
  version="$(awk '
    $1 == "go" { version = $2 }
    $1 == "toolchain" && $2 ~ /^go[0-9]/ { preferred = substr($2, 3) }
    END { print (preferred != "" ? preferred : version) }
  ' "$source_dir/go.mod")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] ||
    fail "无法从 Platform go.mod 确定构建用 Go 版本"
  # 官方 Go 基础镜像关闭工具链自动下载，仅修正临时 checkout 的构建阶段。
  awk -v version="$version" '
    toupper($1) == "FROM" && $2 ~ /^golang:[0-9.]+-bookworm$/ &&
      toupper($3) == "AS" && $4 == "builder" {
        print "FROM golang:" version "-bookworm AS builder"
        found = 1
        next
    }
    { print }
    END { if (!found) exit 1 }
  ' "$source_dir/Dockerfile" > "$BUILD_DIR/Platform.Dockerfile" ||
    fail "Platform Dockerfile 的 Go 构建阶段已变更，请核对构建入口"
}

build_mirror() {
  local key="$1" fallback="$2" val
  val="$(setting "$key")"
  val="${val:-$fallback}"
  [[ "$val" != *[[:space:]]* ]] || fail "$key 不能包含空白字符"
  printf '%s' "$val"
}

knowledge_app_deps_hash() {
  local source_dir="$1" apt_mirror="$2" pip_index_url="$3" goproxy="$4"
  {
    printf 'WITH_ANYDOC=1\nAPK_MIRROR_ARG=%s\nPIP_INDEX_URL_ARG=%s\nGOPROXY_ARG=%s\n' \
      "$apt_mirror" "$pip_index_url" "$goproxy"
    (
      cd "$source_dir"
      for f in docker/Dockerfile.app go.mod go.sum scripts/build-anydoc-lib.sh scripts/docker-entrypoint.sh; do
        [[ -f "$f" ]] || return 1
        sha256sum "$f"
      done
      find third_party/anydoc-go cmd/download -type f | LC_ALL=C sort | xargs sha256sum
    )
  } | sha256sum | awk '{ print substr($1, 1, 12) }'
}

prepare_knowledge_app_dockerfiles() {
  local source_dir="$1" builder_base="$2" runtime_base="$3"
  local src_df="$source_dir/docker/Dockerfile.app"
  [[ -f "$src_df" ]] || return 1

  awk -v builder_out="$BUILD_DIR/KnowledgeAppBuilderBase.Dockerfile" \
      -v runtime_out="$BUILD_DIR/KnowledgeAppRuntimeBase.Dockerfile" \
      -v inc_out="$BUILD_DIR/KnowledgeAppIncremental.Dockerfile" \
      -v builder_base="$builder_base" \
      -v runtime_base="$runtime_base" '
    BEGIN { section = "head" }
    /^FROM .* AS browserskill$/ { browserskill_line = $0 }
    /^FROM .* AS builder$/ { section = "builder_pre"; print $0 > builder_out; next }
    section == "builder_pre" && /^COPY \. \.$/ {
      print "COPY third_party/anydoc-go ./third_party/anydoc-go" > builder_out
      print "COPY scripts/build-anydoc-lib.sh ./scripts/build-anydoc-lib.sh" > builder_out
      section = "builder_skip_src"
      next
    }
    section == "builder_skip_src" && /^ARG WITH_ANYDOC=1$/ { section = "builder_anydoc" }
    section == "builder_anydoc" && /^# Build the application/ { section = "builder_post"; next }
    section == "builder_post" && /^RUN --mount=type=cache,target=\/go\/pkg\/mod cp -r \/go\/pkg\/mod\/github\.com\/yanyiwu\// {
      print "RUN mkdir -p /opt/anydoc-lib && cp -a /app/third_party/anydoc-go/lib /opt/anydoc-lib/" > builder_out
      print $0 > builder_out
      has_builder_end = 1
      section = "wait_final"
      next
    }
    section == "wait_final" && /^FROM debian:/ {
      if (browserskill_line == "") exit 1
      print browserskill_line > runtime_out
      print "FROM " builder_base " AS builder" > runtime_out
      print $0 > runtime_out
      section = "runtime_base"
      next
    }
    section == "runtime_base" && /^COPY --from=builder \/app\/yanyiwu\// {
      print $0 > runtime_out
      print "COPY --from=builder /root/.duckdb /home/appuser/.duckdb" > runtime_out
      has_runtime_end = 1
      section = "runtime_app"
      next
    }
    section == "builder_pre" || section == "builder_anydoc" { print $0 > builder_out }
    section == "runtime_base" { print $0 > runtime_out }
    END {
      if (!has_builder_end || !has_runtime_end) exit 1
      print "FROM " builder_base " AS builder" > inc_out
      print "COPY . ." > inc_out
      print "RUN rm -rf /app/third_party/anydoc-go/lib && cp -a /opt/anydoc-lib/lib /app/third_party/anydoc-go/lib" > inc_out
      print "ARG VERSION_ARG" > inc_out
      print "ARG COMMIT_ID_ARG" > inc_out
      print "ARG BUILD_TIME_ARG" > inc_out
      print "ENV VERSION=${VERSION_ARG} COMMIT_ID=${COMMIT_ID_ARG} BUILD_TIME=${BUILD_TIME_ARG}" > inc_out
      print "RUN --mount=type=cache,target=/go/pkg/mod \\" > inc_out
      print "    --mount=type=cache,target=/root/.cache/go-build \\" > inc_out
      print "    export GO_VERSION=\"$(go version)\"; \\" > inc_out
      print "    make build-prod GO_BUILD_TAGS=anydoc" > inc_out
      print "RUN --mount=type=cache,target=/go/pkg/mod bash ./scripts/copy-licenses.sh /license-bundle" > inc_out
      print "" > inc_out
      print "FROM " runtime_base > inc_out
      print "COPY --from=builder /app/config ./config" > inc_out
      print "COPY --from=builder /app/scripts ./scripts" > inc_out
      print "COPY --from=builder /app/migrations ./migrations" > inc_out
      print "COPY --from=builder /app/dataset/samples ./dataset/samples" > inc_out
      print "COPY --from=builder /app/WeKnora ." > inc_out
      print "COPY --from=builder /license-bundle/ ./" > inc_out
      print "COPY --from=builder /app/scripts/docker-entrypoint.sh ./scripts/docker-entrypoint.sh" > inc_out
      print "RUN chmod +x ./scripts/*.sh" > inc_out
      print "EXPOSE 8080" > inc_out
      print "ENTRYPOINT [\"./scripts/docker-entrypoint.sh\"]" > inc_out
      print "CMD [\"./WeKnora\"]" > inc_out
    }
  ' "$src_df"
}

build_knowledge_app_image() {
  local sha="$1" repo="$2" source_dir="$3" apt_mirror="$4" pip_index_url="$5" goproxy="$6"
  local image="knowledge-opc-app:${sha:0:8}" id deps_hash builder_base runtime_base
  local full_build="${AIWORK_FULL_BUILD:-0}"

  if docker image inspect "$image" >/dev/null 2>&1; then
    image_id_for_revision "$image" "$sha" >/dev/null || fail "$image 已被不同制品占用"
    id="$(image_id_for_revision "$image" "$sha")" || fail "$image 校验失败"
    jq -n --arg image "$image" --arg revision "$sha" --arg id "$id" --arg source "$repo" \
      '{image:$image, revision:$revision, id:$id, source:$source}' > "$BUILD_DIR/knowledge-opc-app.json"
    return
  fi

  if deps_hash="$(knowledge_app_deps_hash "$source_dir" "$apt_mirror" "$pip_index_url" "$goproxy" 2>/dev/null)"; then
    builder_base="knowledge-opc-app-builder-base:$deps_hash"
    runtime_base="knowledge-opc-app-runtime-base:$deps_hash"
    if prepare_knowledge_app_dockerfiles "$source_dir" "$builder_base" "$runtime_base"; then
      if [[ "$full_build" == "1" ]] || ! docker image inspect "$builder_base" >/dev/null 2>&1; then
        printf '[INFO] 构建 knowledge-opc-app 构建底座 %s\n' "$builder_base"
        docker buildx build --load --platform linux/amd64 \
          --label "aiwork.deps_hash=$deps_hash" \
          -t "$builder_base" -f "$BUILD_DIR/KnowledgeAppBuilderBase.Dockerfile" \
          --build-arg WITH_ANYDOC=1 --build-arg "APK_MIRROR_ARG=$apt_mirror" --build-arg "GOPROXY_ARG=$goproxy" \
          "$source_dir"
      else
        printf '[INFO] 复用构建底座 %s\n' "$builder_base"
      fi

      if [[ "$full_build" == "1" ]] || ! docker image inspect "$runtime_base" >/dev/null 2>&1; then
        printf '[INFO] 构建 knowledge-opc-app 运行底座 %s\n' "$runtime_base"
        docker buildx build --load --platform linux/amd64 \
          --label "aiwork.deps_hash=$deps_hash" \
          -t "$runtime_base" -f "$BUILD_DIR/KnowledgeAppRuntimeBase.Dockerfile" \
          --build-arg "APK_MIRROR_ARG=$apt_mirror" --build-arg "PIP_INDEX_URL_ARG=$pip_index_url" \
          "$source_dir"
      else
        printf '[INFO] 复用运行底座 %s\n' "$runtime_base"
      fi

      printf '[INFO] 增量构建 %s（仅更新编译产物与配置）\n' "$image"
      docker buildx build --load --platform linux/amd64 \
        --label "org.opencontainers.image.revision=$sha" \
        --label "org.opencontainers.image.source=$repo" \
        --label "aiwork.deps_hash=$deps_hash" \
        -t "$image" -f "$BUILD_DIR/KnowledgeAppIncremental.Dockerfile" \
        --build-arg "VERSION_ARG=${sha:0:8}" --build-arg "COMMIT_ID_ARG=$sha" \
        "$source_dir"

      id="$(image_id_for_revision "$image" "$sha")" || fail "$image 构建后校验失败"
      jq -n --arg image "$image" --arg revision "$sha" --arg id "$id" --arg source "$repo" \
        '{image:$image, revision:$revision, id:$id, source:$source}' > "$BUILD_DIR/knowledge-opc-app.json"
      return
    fi
  fi

  printf '[WARN] knowledge-opc-app Dockerfile 结构已变化，回退到全量构建\n' >&2
  build_image knowledge-opc-app "$sha" "$repo" "$source_dir" \
    "$source_dir/docker/Dockerfile.app" \
    --build-arg WITH_ANYDOC=1 --build-arg "VERSION_ARG=${sha:0:8}" --build-arg "COMMIT_ID_ARG=$sha" \
    --build-arg "APK_MIRROR_ARG=$apt_mirror" --build-arg "PIP_INDEX_URL_ARG=$pip_index_url" \
    --build-arg "GOPROXY_ARG=$goproxy"
}

build_images() (
  set -euo pipefail
  local pending platform_sha knowledge_sha apt_mirror pip_index_url npm_registry goproxy
  local platform_source="$SCRIPT_DIR/src/platform-opc"
  local knowledge_source="$SCRIPT_DIR/src/knowledge-opc"
  exec 8<"$SCRIPT_DIR/.source.lock" || fail "缺少源码同步记录，请先运行 00-prepare-source.sh"
  flock -sn 8 || fail "00 正在同步源码，请同步完成后重试"
  [[ -f "$SCRIPT_DIR/.source-ready" ]] || fail "源码分发未完成，请重新执行 00-prepare-source.sh"
  BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiwork-build.XXXXXX")"
  trap 'rm -rf -- "$BUILD_DIR"; if [[ -n "${pending:-}" ]]; then rm -f -- "$pending"; fi' EXIT
  pending="$(mktemp "$STATE_DIR/.images.XXXXXX")"

  apt_mirror="$(build_mirror BUILD_APT_MIRROR mirrors.aliyun.com)"
  pip_index_url="$(build_mirror BUILD_PIP_INDEX_URL https://mirrors.aliyun.com/pypi/simple/)"
  npm_registry="$(build_mirror BUILD_NPM_REGISTRY https://registry.npmmirror.com)"
  goproxy="$(build_mirror BUILD_GOPROXY https://goproxy.cn,direct)"

  platform_sha="$(source_revision "$platform_source")"
  knowledge_sha="$(source_revision "$knowledge_source")"
  prepare_platform_dockerfile "$platform_source"
  build_image platform-opc "$platform_sha" https://github.com/shtokendance/platform-opc.git "$platform_source" \
    "$BUILD_DIR/Platform.Dockerfile" \
    --build-arg "GOPROXY_ARG=$goproxy" --build-arg "APK_MIRROR_ARG=$apt_mirror"
  build_knowledge_app_image "$knowledge_sha" https://github.com/shtokendance/knowledge-opc.git \
    "$knowledge_source" "$apt_mirror" "$pip_index_url" "$goproxy"
  build_image knowledge-opc-ui "$knowledge_sha" https://github.com/shtokendance/knowledge-opc.git "$knowledge_source/frontend" \
    "$knowledge_source/frontend/Dockerfile" \
    --build-arg "VITE_FRONTEND_COMMIT=$knowledge_sha" --build-arg "NPM_REGISTRY=$npm_registry"

  jq -s '{images: (map({(.image | split(":")[0]): .}) | add)}' "$BUILD_DIR/"*.json > "$pending"
  mv -f -- "$pending" "$MANIFEST"
  jq -r '.images[].image' "$MANIFEST"
  printf '制品清单已写入 %s\n' "$MANIFEST"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(dirname -- "$0")/03-common.sh"
  [[ $# == 0 ]] || fail "用法: bash 03-build-business-images.sh"
  require_commands docker flock jq
  load_settings
  check_engine
  lock_deployment
  build_images
fi
