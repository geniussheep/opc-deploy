#!/usr/bin/env bash
# ==============================================================================
# 01 基础设施层一键启动
#   1) 检查 root_default 网桥，不存在直接退出（需先执行 00-start-network.sh）
#   2) 在 /data/aiwork 下创建各组件持久化目录
#   3) 检查 Milvus 目录权限与内核参数
#   4) 启动全部基础设施容器，初始化数据库与 MinIO 存储桶
# 用法: sudo bash 01-start-infra.sh
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE="01-infra.env"
NETWORK_ENV_FILE="00-network.env"

if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] 需要 root 权限（创建 /data/aiwork 目录、chown Milvus 目录）" >&2
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
SQL_FILE="$(env_get "${ENV_FILE}" SQL_FILE)"
DATA_DIR="$(env_get "${ENV_FILE}" AIWORK_DATA_DIR)"
DB_USER="$(env_get "${ENV_FILE}" POSTGRES_USER)"
MINIO_USER="$(env_get "${ENV_FILE}" MINIO_ROOT_USER)"
MINIO_PASS="$(env_get "${ENV_FILE}" MINIO_ROOT_PASSWORD)"
MINIO_BUCKETS="$(env_get "${ENV_FILE}" MINIO_BUCKETS)"

echo "[1/6] 检查网桥 ${NETWORK_NAME}"
docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1 || {
  echo "[ERROR] 网桥 ${NETWORK_NAME} 不存在，请先执行: bash 00-start-network.sh" >&2
  exit 1
}

echo "[2/6] 创建数据目录 ${DATA_DIR}"
mkdir -p \
  "${DATA_DIR}/postgres" \
  "${DATA_DIR}/redis" \
  "${DATA_DIR}/minio" \
  "${DATA_DIR}/etcd" \
  "${DATA_DIR}/milvus/logs" \
  "${DATA_DIR}/neo4j/data" \
  "${DATA_DIR}/neo4j/logs" \
  "${DATA_DIR}/neo4j/import" \
  "${DATA_DIR}/neo4j/plugins"

echo "[3/6] 检查 Milvus 目录权限与内核参数"
chown -R 999:999 "${DATA_DIR}/milvus"
MAX_MAP_COUNT="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
if [ "${MAX_MAP_COUNT}" -lt 2000000 ]; then
  echo "[ERROR] vm.max_map_count=${MAX_MAP_COUNT} < 2000000，Milvus 无法启动" >&2
  echo "        临时生效: sysctl -w vm.max_map_count=2000000" >&2
  echo "        持久化:   echo 'vm.max_map_count=2000000' > /etc/sysctl.d/99-milvus.conf && sysctl --system" >&2
  exit 1
fi

echo "[4/6] 启动基础设施容器"
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d --remove-orphans

echo "      等待 PostgreSQL 就绪..."
for i in $(seq 1 60); do
  if docker exec infra-postgres pg_isready -U "${DB_USER}" -d postgres >/dev/null 2>&1; then
    break
  fi
  if [ "${i}" -eq 60 ]; then
    echo "[ERROR] PostgreSQL 120s 未就绪，请查看: docker logs infra-postgres" >&2
    exit 1
  fi
  sleep 2
done

echo "[5/6] 初始化数据库与基座表"
docker exec -i infra-postgres psql -U "${DB_USER}" -d postgres -v ON_ERROR_STOP=1 < "${SQL_FILE}"

echo "[6/6] 初始化 MinIO 存储桶"
for i in $(seq 1 60); do
  if docker exec infra-minio curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1; then
    break
  fi
  if [ "${i}" -eq 60 ]; then
    echo "[ERROR] MinIO 120s 未就绪，请查看: docker logs infra-minio" >&2
    exit 1
  fi
  sleep 2
done

MC=(docker exec infra-minio mc --config-dir /tmp/.mc)
"${MC[@]}" alias set local http://127.0.0.1:9000 "${MINIO_USER}" "${MINIO_PASS}" >/dev/null
for bucket in ${MINIO_BUCKETS}; do
  "${MC[@]}" mb --ignore-existing "local/${bucket}" >/dev/null
  echo "      ${bucket}"
done
"${MC[@]}" ls local

docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" ps
echo "基础设施层启动完成"
