#!/bin/bash
# 新代理机一键初始化：公网 IP 自检 → Docker/compose → 防火墙规则 → 打印后续步骤
# 在【新机器上】以 root 执行；运维机上的后续动作见脚本末尾提示
#
# 环境变量（均可选）：
#   SCHED_IP=调度机IP     # ufw 规则：1080 仅放行调度机（HAProxy 转发 + 健康检查）
#   CLIENT_IP=客户端IP    # 本机兼调度机时：入口端口放行客户端
#   ENTRY_PORT=2080       # 入口端口，默认 2080
#   SSH_PORT=22           # sshd 端口（启用 ufw 前必须放行；改过端口务必指定，防自锁）
#   UFW_ENABLE=1          # 写完规则后启用 ufw（默认只写规则不启用，防止把 SSH 锁死）
#
# 示例：
#   SCHED_IP=103.207.68.201 ./bootstrap.sh
#   SCHED_IP=103.207.68.201 CLIENT_IP=1.2.3.4 UFW_ENABLE=1 SSH_PORT=22 ./bootstrap.sh
set -uo pipefail

SCHED_IP="${SCHED_IP:-}"
CLIENT_IP="${CLIENT_IP:-}"
ENTRY_PORT="${ENTRY_PORT:-2080}"
SSH_PORT="${SSH_PORT:-22}"
UFW_ENABLE="${UFW_ENABLE:-0}"

say() { echo "[bootstrap] $*"; }
die() { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请以 root 运行"
command -v ip >/dev/null 2>&1 || die "缺少 ip 命令（iproute2）"
command -v systemctl >/dev/null 2>&1 || die "仅支持 systemd 系统（Ubuntu 20.04/22.04 等）"

# ---- 1. 公网 IP 自检（云控制台“绑定”不等于写入网卡！）----
say "检查公网 IP ..."
IPS=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 \
    | grep -vE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.)' || true)
[ -n "$IPS" ] || die "未检测到公网 IP。多 IP 机器请先在云控制台绑定辅助 IP 并写入网卡（netplan），再重跑本脚本"
echo "$IPS" | sed 's/^/  出口 IP: /'

# ---- 2. Docker + compose 插件 ----
if ! command -v docker >/dev/null 2>&1; then
    say "安装 Docker ..."
    command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl; }
    curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker compose version >/dev/null 2>&1 \
    || die "docker compose 插件缺失：重跑 curl -fsSL https://get.docker.com | sh 可一并装上"
say "Docker 就绪：$(docker --version)"

# ---- 3. 防火墙规则 ----
if command -v ufw >/dev/null 2>&1; then
    say "写入 ufw 规则 ..."
    ufw allow "${SSH_PORT}"/tcp >/dev/null 2>&1 || true
    [ -n "$SCHED_IP" ] && ufw allow from "$SCHED_IP" to any port 1080 proto tcp >/dev/null 2>&1
    [ -n "$CLIENT_IP" ] && ufw allow from "$CLIENT_IP" to any port "$ENTRY_PORT" proto tcp >/dev/null 2>&1
    if [ "$UFW_ENABLE" = "1" ]; then
        ufw --force enable && say "ufw 已启用"
    else
        say "规则已写入、ufw 保持关闭（要启用请加 UFW_ENABLE=1 重跑）"
    fi
elif command -v bt >/dev/null 2>&1 || [ -d /www/server/panel ]; then
    say "检测到宝塔面板：请在 面板-安全 页面放行 TCP 1080（来源限 ${SCHED_IP:-调度机IP}）"
else
    say "未检测到 ufw / 宝塔：请在云安全组放行端口（见末尾提醒）"
fi

# ---- 4. 后续步骤提示 ----
cat <<'EOF'

[bootstrap] 初始化完成。剩余步骤在【运维机】上执行：
  1) 清单：  把本机加进 deploy/hosts.txt（唯一清单，与 deploy.sh 共用）
             root@<本机IP> <密码>      # 有密码：provision.sh 会先纳管再部署
             root@<本机IP>             # 已免密：只参与部署
             注意：手工追加，不要写第二行（同一台机器只一行）
  2) 纳管+部署： SCHED_IP=<调度机IP> ./deploy/provision.sh --deploy
                 # 已免密的机器可跳过纳管，直接：ENTRY_PORT=2080 ./deploy/deploy.sh
  3) 验证：   grep -c . deploy/hosts.txt
               curl --socks5-hostname user:pass@<调度机IP>:2080 http://ifconfig.me

[bootstrap] 云安全组提醒（云控制台手工配置，脚本管不到）：
  - 本机 TCP 1080：来源限调度机 IP（HAProxy 转发 + 健康检查）
  - 本机 TCP 2080：仅当本机兼调度机时放行，来源限你的客户端 IP
  - 1080 绝不对 0.0.0.0/0 放行（3proxy 有认证也不建议裸奔公网）
EOF
