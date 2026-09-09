#!/bin/sh
# 3proxy 容器入口：按环境变量生成配置并前台启动
#   BIND_IP  必填，SOCKS5 监听地址（host 网络下即宿主机出口 IP）
#   OUT_IP   可选，出口绑定地址，默认同 BIND_IP
#   PORT     可选，监听端口，默认 1080
set -e

BIND_IP="${BIND_IP:?BIND_IP required}"
OUT_IP="${OUT_IP:-$BIND_IP}"
PORT="${PORT:-1080}"

mkdir -p /etc/3proxy

cat > /etc/3proxy/3proxy.cfg <<EOF
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
log /dev/stdout
auth iponly
allow * *
maxconn 10000
socks -p${PORT} -i${BIND_IP} -e${OUT_IP}
EOF

exec 3proxy /etc/3proxy/3proxy.cfg
