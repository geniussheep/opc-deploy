#!/usr/bin/env bash
# ==============================================================================
# 00 共享网桥一键创建
#   Compose v2 无法只凭 networks 段创建网络（必须挂服务，挂服务就要拉镜像），
#   因此这里直接调用 docker network create，零镜像依赖。
#   网桥参数从 00-network.env 读取。
# 用法: bash 00-start-network.sh
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE="00-network.env"

env_get() {
  local value
  value="$(awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit }' "./$1" || true)"
  [ -n "${value}" ] || {
    echo "[ERROR] $1 缺少配置项: $2" >&2
    exit 1
  }
  printf '%s' "${value}"
}

NETWORK_NAME="$(env_get "${ENV_FILE}" NETWORK_NAME)"
NETWORK_DRIVER="$(env_get "${ENV_FILE}" NETWORK_DRIVER)"

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] 未找到 docker 命令" >&2
  exit 1
fi

echo "[1/2] 检查网桥 ${NETWORK_NAME}"
if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  echo "      已存在，跳过创建"
else
  echo "[2/2] 创建网桥"
  docker network create "${NETWORK_NAME}" --driver "${NETWORK_DRIVER}"
fi

ACTUAL_DRIVER="$(docker network inspect -f '{{.Driver}}' "${NETWORK_NAME}" 2>/dev/null || true)"
[ "${ACTUAL_DRIVER}" = "${NETWORK_DRIVER}" ] || {
  echo "[ERROR] 网桥 ${NETWORK_NAME} 已存在，驱动为 ${ACTUAL_DRIVER}，期望 ${NETWORK_DRIVER}" >&2
  exit 1
}

docker network inspect "${NETWORK_NAME}" --format '      网桥: {{.Name}} | 驱动: {{.Driver}}'
