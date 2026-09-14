#!/bin/bash
# 组装最终生效的 /etc/haproxy/haproxy.cfg（基础模板 + generate-haproxy.sh 生成后端�?
# 写入 /etc/haproxy 需�? root：请�? sudo 运行
#
# 入口端口：默�? 1080。若调度机与代理机同机部署（3proxy 容器 host 网络已占�?
# 本机各公�? IP �? 1080），HAProxy 无法�? bind *:1080，需改用空闲端口，例如：
#   sudo ENTRY_PORT=2080 ./assemble-config.sh
set -euo pipefail

cd "$(dirname "$0")"

[ -f haproxy-servers.cfg ] || {
    echo "haproxy-servers.cfg not found - run ./generate-haproxy.sh first" >&2
    exit 1
}

ENTRY_PORT="${ENTRY_PORT:-1080}"

cat > /etc/haproxy/haproxy.cfg <<EOF
# 状态页：仅绑定本机回环，远程查看用 SSH 隧道：ssh -L 8404:127.0.0.1:8404 <调度�?>
# 如需公网访问，改�? bind *:8404 并务必用防火墙限制来�? IP
# 注意：本节必须保持在文件最前——generate-haproxy.sh 产出�? server 行追加在文件末尾�?
#       必须保证文件末尾�? backend proxies 块，否则后端会错挂到 stats 监听�?
listen stats
    # 必须显式 mode http：defaults �? mode tcp，否�? stats 会被静默忽略
    # （表现为 "stats statement ignored ... requires HTTP mode" 警告�?8404 页面打不开�?
    mode http
    bind 127.0.0.1:8404
    stats enable
    stats uri /stats
    stats refresh 5s
    # stats 段不能继�? defaults �? tcp 超时，必须自带，否则每轮配置校验都报�?
    timeout connect 5s
    timeout client 30s
    timeout server 30s

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
    # ����ʧ��ʱ��Ͷ��������ˣ�����ǡ����ѯ���� DOWN �Ľڵ�ͱ���
    option redispatch
    option tcp-check
    tcp-check connect port 1080
EOF

# ---- 规范化后端清单：容忍 Windows 换行（CRLF）与多余缩进，统一 4 空格缩进 ----
SERVERS_TMP="$(mktemp)"
trap 'rm -f "$SERVERS_TMP"' EXIT

sed -e 's/\r$//' -e 's/^[[:space:]]*//' haproxy-servers.cfg \
    | grep -vE '^($|#)' \
    | sed 's/^/    /' > "$SERVERS_TMP"

# server 名在同一 backend 内必须唯一，重复会导致 haproxy -c 校验失败（reload �? status=1�?
DUP="$(awk '{print $2}' "$SERVERS_TMP" | sort | uniq -d)"
if [ -n "$DUP" ]; then
    echo "ERROR: haproxy-servers.cfg 中存在重复的 server 名：$DUP" >&2
    echo "       常见原因：deploy/hosts.txt 里同一台机器写了两行（tag 相同）。修掉后重跑�?" >&2
    exit 1
fi

BACKENDS="$(grep -cE '^[[:space:]]*server ' "$SERVERS_TMP" || true)"
[ "$BACKENDS" -gt 0 ] || { echo "ERROR: 后端清单为空（无有效 server 行）" >&2; exit 1; }

cat "$SERVERS_TMP" >> /etc/haproxy/haproxy.cfg

# �? haproxy 二进制时先校验语法，避免坏配置被 reload 上去（不静默，报错要能看到行号）
if command -v haproxy >/dev/null 2>&1; then
    if ! haproxy -c -f /etc/haproxy/haproxy.cfg; then
        echo "ERROR: haproxy 配置校验失败（详情见上方 error 行）；运行中的实例未被改�?" >&2
        exit 1
    fi
    echo "haproxy config check OK"
fi

echo "haproxy.cfg updated (entry :${ENTRY_PORT}, ${BACKENDS} backends)"
