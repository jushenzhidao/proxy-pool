#!/bin/bash
# 扫描宿主机公网 IPv4，生成 .env（IP_1..IP_N），供 docker-compose.yml 变量替换使用
# 需以 root 运行（部署机器需安装 iproute2：ip 命令）
set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=".env"
: > "$ENV_FILE"

IPS=$(ip -4 -o addr show \
    | awk '{print $4}' | cut -d/ -f1 \
    | grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.)' \
    | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n)

COUNT=0
for ip in $IPS; do
    COUNT=$((COUNT + 1))
    echo "IP_${COUNT}=${ip}" >> "$ENV_FILE"
done

echo "IP_COUNT=${COUNT}" >> "$ENV_FILE"
echo "Generated ${COUNT} IPs -> ${ENV_FILE}"

if [ "$COUNT" -ne 32 ]; then
    echo "WARNING: expected 32 public IPs, found ${COUNT}." >&2
    echo "WARNING: docker compose up will fail on the missing IP_\$N entries." >&2
fi
