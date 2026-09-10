#!/bin/sh
# 3proxy 容器入口：按环境变量生成配置并前台启动
#   BIND_IP     必填，SOCKS5 监听地址（host 网络下即宿主机出口 IP）
#   OUT_IP      可选，出口绑定地址，默认同 BIND_IP
#   PORT        可选，监听端口，默认 1080
#   SOCKS_USER  可选，SOCKS5 用户名；与 SOCKS_PASS 同时提供才启用密码认证
#   SOCKS_PASS  可选，SOCKS5 密码（写入容器内配置，勿含双引号）
#   ALLOW_SRC   可选，限定允许的客户端来源 IP/网段（逗号分隔），默认 *（不限）
#
# 认证策略：
#   - 同时设置 SOCKS_USER / SOCKS_PASS → auth strong（用户名密码认证）
#   - 否则                              → auth iponly（无认证，仅靠来源 IP / 防火墙）
set -e

BIND_IP="${BIND_IP:?BIND_IP required}"
OUT_IP="${OUT_IP:-$BIND_IP}"
PORT="${PORT:-1080}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASS="${SOCKS_PASS:-}"
ALLOW_SRC="${ALLOW_SRC:-*}"

if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    # 启用用户名/密码认证；ALLOW_SRC 为 * 时不限来源，否则按来源 IP 白名单
    AUTH_CFG="auth strong
users \"${SOCKS_USER}:CL:${SOCKS_PASS}\"
allow ${SOCKS_USER} ${ALLOW_SRC}"
else
    # 未配置账号密码：保持原有的无认证模式（向后兼容）
    AUTH_CFG="auth iponly
allow * *"
fi

mkdir -p /etc/3proxy

cat > /etc/3proxy/3proxy.cfg <<EOF
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
log /dev/stdout
${AUTH_CFG}
maxconn 10000
socks -p${PORT} -i${BIND_IP} -e${OUT_IP}
EOF

exec 3proxy /etc/3proxy/3proxy.cfg
