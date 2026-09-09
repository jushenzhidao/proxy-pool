#!/bin/bash
# 从 machines.txt 生成 HAProxy 后端列表 haproxy-servers.cfg
# 约定：每台机器的 32 个出口 IP 从起始 IP 开始连续递增，且不得跨第四个 octet 边界
set -euo pipefail

cd "$(dirname "$0")"

INPUT="machines.txt"
OUTPUT="haproxy-servers.cfg"
: > "$OUTPUT"

while read -r name start_ip || [ -n "${name:-}" ]; do
    # 跳过空行与注释行
    [ -z "${name:-}" ] && continue
    case "$name" in \#*) continue ;; esac

    base=$(echo "$start_ip" | cut -d. -f1-3)
    last=$(echo "$start_ip" | cut -d. -f4)

    for i in $(seq 0 31); do
        oct=$((last + i))
        if [ "$oct" -gt 255 ]; then
            echo "ERROR: ${name} ${start_ip}: IP x.x.x.${last} + $i exceeds 255" >&2
            echo "ERROR: start IP must not be later than x.x.x.224 (32 consecutive IPs)" >&2
            exit 1
        fi
        ip="${base}.${oct}"
        echo "    server ${name}i$((i+1)) ${ip}:1080 check inter 3s fall 3 rise 2" >> "$OUTPUT"
    done
done < "$INPUT"

echo "Generated $(wc -l < "$OUTPUT") backends -> ${OUTPUT}"
