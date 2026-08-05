#!/usr/bin/env bash
set -euo pipefail

# 内网 GOS 本机接口；端口变化时可用 PORT=xxxx 临时覆盖。
PORT="${PORT:-8000}"
# 默认从公网 GOS 拉取；源地址变化时可用 SOURCE_URL=http://... 临时覆盖。
SOURCE_URL="${SOURCE_URL:-http://139.217.226.70:5100}"
# overwrite 会以同步源数据覆盖本地冲突记录。
ON_CONFLICT="${ON_CONFLICT:-overwrite}"

curl -sS -X POST "http://127.0.0.1:${PORT}/api/admin/data-sync/import" \
  -H "Content-Type: application/json" \
  -d "{\"source_url\":\"${SOURCE_URL%/}\",\"on_conflict\":\"${ON_CONFLICT}\"}"
echo
