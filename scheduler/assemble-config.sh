#!/bin/bash
# 组装最终生效的 /etc/haproxy/haproxy.cfg（基础模板 + generate-haproxy.sh 生成后端）
# 写入 /etc/haproxy 需要 root：请以 sudo 运行
#
# 入口端口：默认 1080。若调度机与代理机同机部署（3proxy 容器 host 网络已占用
# 本机各公网 IP 的 1080），HAProxy 无法再 bind *:1080，需改用空闲端口，例如：
#   sudo ENTRY_PORT=2080 ./assemble-config.sh
set -euo pipefail

cd "$(dirname "$0")"

[ -f haproxy-servers.cfg ] || {
    echo "haproxy-servers.cfg not found - run ./generate-haproxy.sh first" >&2
    exit 1
}

ENTRY_PORT="${ENTRY_PORT:-1080}"

cat > /etc/haproxy/haproxy.cfg <<EOF
# 状态页：仅绑定本机回环，远程查看用 SSH 隧道：ssh -L 8404:127.0.0.1:8404 <调度机>
# 如需公网访问，改为 bind *:8404 并务必用防火墙限制来源 IP
# 注意：本节必须保持在文件最前——generate-haproxy.sh 产出的 server 行追加在文件末尾，
#       必须保证文件末尾是 backend proxies 块，否则后端会错挂到 stats 监听上
listen stats
    bind 127.0.0.1:8404
    stats enable
    stats uri /stats
    stats refresh 5s

global
    maxconn 100000
    log /dev/null local0

defaults
    mode tcp
    retries 3
    timeout connect 5s
    timeout client 300s
    timeout server 300s
    timeout check 3s

frontend socks5
    bind *:${ENTRY_PORT}
    default_backend proxies

backend proxies
    balance roundrobin
    option tcp-check
    tcp-check connect port 1080
EOF

cat haproxy-servers.cfg >> /etc/haproxy/haproxy.cfg

# 有 haproxy 二进制时先校验语法，避免坏配置被 reload 上去
if command -v haproxy >/dev/null 2>&1; then
    haproxy -c -q -f /etc/haproxy/haproxy.cfg \
        || { echo "ERROR: haproxy config check failed - fix before reload" >&2; exit 1; }
    echo "haproxy config check OK"
fi

echo "haproxy.cfg updated (entry :${ENTRY_PORT}, $(grep -cE '^[[:space:]]+server ' /etc/haproxy/haproxy.cfg) backends)"
