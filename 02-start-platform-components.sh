#!/usr/bin/env bash
# ==============================================================================
# 02 平台支撑组件一键启动
#   1) 检查 root_default 网桥，不存在直接退出（需先执行 00-start-network.sh）
#   2) 在 /data/aiwork 下创建 ClickHouse / LiteLLM / MCP Gateway / docreader / paddleocr 数据目录
#   3) 首次启动时生成 LiteLLM 配置与 PaddleOCR server.py
#   4) 启动 ClickHouse / LiteLLM / MCP Gateway / docreader / paddleocr / Langfuse
# 前置: 需先执行 00 建网桥、01 起基础设施；docreader/paddleocr 镜像需已构建或导入
# 用法: sudo bash 02-start-platform-components.sh
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE="02-platform-components.env"
NETWORK_ENV_FILE="00-network.env"

if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] 需要 root 权限（创建 /data/aiwork 目录）" >&2
  echo "        请使用: sudo bash $0" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] 未找到 docker 命令" >&2
  exit 1
fi

docker compose version >/dev/null 2>&1 || {
  echo "[ERROR] 需要 Docker Compose v2（docker compose 插件）" >&2
  exit 1
}

env_get() {
  local value
  value="$(awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit }' "./$1" || true)"
  [ -n "${value}" ] || {
    echo "[ERROR] $1 缺少配置项: $2" >&2
    exit 1
  }
  printf '%s' "${value}"
}

COMPOSE_FILE="$(env_get "${ENV_FILE}" COMPOSE_FILE)"
NETWORK_NAME="$(env_get "${NETWORK_ENV_FILE}" NETWORK_NAME)"
DATA_DIR="$(env_get "${ENV_FILE}" AIWORK_DATA_DIR)"
DB_USER="$(env_get "${ENV_FILE}" POSTGRES_USER)"
REDIS_PASS="$(env_get "${ENV_FILE}" REDIS_PASSWORD)"
DOCREADER_IMAGE="$(env_get "${ENV_FILE}" IMAGE_DOCREADER)"
PADDLEOCR_IMAGE="$(env_get "${ENV_FILE}" IMAGE_PADDLEOCR)"

echo "[1/4] 检查网桥 ${NETWORK_NAME}"
docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1 || {
  echo "[ERROR] 网桥 ${NETWORK_NAME} 不存在，请先执行: bash 00-start-network.sh" >&2
  exit 1
}

echo "[2/4] 检查基础设施层与本地镜像"
docker exec infra-postgres pg_isready -U "${DB_USER}" -d postgres >/dev/null 2>&1 || {
  echo "[ERROR] infra-postgres 未就绪，请先执行: sudo bash 01-start-infra.sh" >&2
  exit 1
}
REDIS_PING="$(docker exec -e REDISCLI_AUTH="${REDIS_PASS}" infra-redis redis-cli ping 2>/dev/null || true)"
[ "${REDIS_PING}" = "PONG" ] || {
  echo "[ERROR] infra-redis 未就绪，请检查: docker logs infra-redis" >&2
  exit 1
}
docker exec infra-minio curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1 || {
  echo "[ERROR] infra-minio 未就绪，请检查: docker logs infra-minio" >&2
  exit 1
}
for img in "${DOCREADER_IMAGE}" "${PADDLEOCR_IMAGE}"; do
  docker image inspect "${img}" >/dev/null 2>&1 || {
    echo "      本地缺少 ${img}，尝试拉取..."
    docker pull "${img}" || {
      echo "[ERROR] 拉取 ${img} 失败，请确认已 docker login SWR 或导入离线镜像" >&2
      exit 1
    }
  }
done

echo "[3/4] 创建数据目录 ${DATA_DIR}"
mkdir -p "${DATA_DIR}/clickhouse" "${DATA_DIR}/litellm" "${DATA_DIR}/mcp-gateway" "${DATA_DIR}/docreader/tmp" "${DATA_DIR}/paddleocr"
[ ! -d "${DATA_DIR}/litellm/config.yaml" ] || {
  echo "[ERROR] ${DATA_DIR}/litellm/config.yaml 是目录，请删除后重试" >&2
  exit 1
}
[ ! -d "${DATA_DIR}/paddleocr/server.py" ] || {
  echo "[ERROR] ${DATA_DIR}/paddleocr/server.py 是目录，请删除后重试" >&2
  exit 1
}
if [ ! -f "${DATA_DIR}/litellm/config.yaml" ]; then
  cp "./02-config.litellm.yaml" "${DATA_DIR}/litellm/config.yaml"
  echo "      已生成 ${DATA_DIR}/litellm/config.yaml"
fi
if [ ! -f "${DATA_DIR}/paddleocr/server.py" ]; then
  cp "./paddleocr/server.py" "${DATA_DIR}/paddleocr/server.py"
  echo "      已生成 ${DATA_DIR}/paddleocr/server.py"
fi

echo "[4/4] 启动平台支撑组件"
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d --remove-orphans

docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" ps
echo "平台支撑组件启动完成"
