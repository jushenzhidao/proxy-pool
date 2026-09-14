#!/bin/bash
# 逐个直连后端出口，验证「登记在 haproxy-servers.cfg 里的 IP」是否真的
# 能以该 IP 出网。用于回答"后端清单和实际不符"这类问题。
#
# 原理：对每个后端分别 curl --socks5-hostname <ip>:1080，把返回的公网 IP
#       与该行登记的 IP 比对。不一致 = 这个 IP 绑了但出不去（或出网走了别的地址）。
#
# 用法（在调度机或任意能直连所有 1080 端口的机器上跑）：
#   ./deploy/verify-egress.sh
#   CHECK_URL=https://api.ipify.org ./deploy/verify-egress.sh     # 换检测站点
#   ENTRY_HOST=154.40.45.34 ENTRY_PORT=2080 ./deploy/verify-egress.sh   # 顺带抽查入口轮询
#
# 前置：能直连各代理机的 1080（若 1080 只对调度机放行，就在调度机上跑）。
#       若开了 SOCKS5 认证，自动从 agent/socks-credentials.env 读取账号密码。

set -uo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
CFG="${CFG:-$REPO_ROOT/scheduler/haproxy-servers.cfg}"
CRED="${CRED:-$REPO_ROOT/agent/socks-credentials.env}"
CHECK_URL="${CHECK_URL:-http://ifconfig.me}"
TIMEOUT="${TIMEOUT:-8}"
ENTRY_HOST="${ENTRY_HOST:-}"
ENTRY_PORT="${ENTRY_PORT:-2080}"

[ -f "$CFG" ] || { echo "ERROR: 找不到 $CFG" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: 需要 curl" >&2; exit 1; }

# ---- 读取 SOCKS5 认证（如启用）----
SOCKS_USER=""; SOCKS_PASS=""
if [ -f "$CRED" ]; then
    while IFS= read -r l || [ -n "$l" ]; do
        l="${l%$'\r'}"
        case "$l" in
            SOCKS_USER=*) SOCKS_USER="${l#SOCKS_USER=}" ;;
            SOCKS_PASS=*) SOCKS_PASS="${l#SOCKS_PASS=}" ;;
        esac
    done < "$CRED"
fi
AUTH=""
if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    AUTH="${SOCKS_USER}:${SOCKS_PASS}@"
    echo "已启用 SOCKS5 认证：user=${SOCKS_USER}"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check_one() {
    local ip="$1" name="$2" out
    out=$(curl -s --max-time "$TIMEOUT" --socks5-hostname "${AUTH}${ip}:1080" \
          "$CHECK_URL" 2>/dev/null | tr -d '[:space:]')
    if [ "$out" = "$ip" ]; then
        printf 'OK       %-22s %-16s -> %s\n' "$name" "$ip" "$out"
    elif [ -z "$out" ]; then
        printf 'FAIL     %-22s %-16s -> 无响应（连不上 / 超时 / 认证失败）\n' "$name" "$ip"
    else
        printf 'MISMATCH %-22s %-16s -> 实际出网 %s\n' "$name" "$ip" "$out"
    fi
}

echo "检测站点: $CHECK_URL   超时: ${TIMEOUT}s"
echo "=================================================================="
printf '%-8s %-22s %-16s %s\n' 状态 后端名 登记IP 实测出网
echo "------------------------------------------------------------------"

n=0
while IFS= read -r -u 3 line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
        ''|'#'*) continue ;;
        *server*) ;;
        *) continue ;;
    esac
    # 形如：    server <name> <ip>:1080 check ...
    # shellcheck disable=SC2086
    set -- $line
    [ "$1" = "server" ] || continue
    name="$2"; addr="$3"
    ip="${addr%%:*}"
    [ -n "$ip" ] || continue
    n=$((n + 1))
    check_one "$ip" "$name" >> "$TMP/out" &
done 3< "$CFG"

[ "$n" -gt 0 ] || { echo "ERROR: $CFG 里没有解析到 server 行" >&2; exit 1; }
wait
sort "$TMP/out" 2>/dev/null

OK_N=$(grep -c '^OK' "$TMP/out" 2>/dev/null || true)
BAD_N=$(grep -cE '^(FAIL|MISMATCH)' "$TMP/out" 2>/dev/null || true)
OK_N="${OK_N:-0}"; BAD_N="${BAD_N:-0}"
echo "------------------------------------------------------------------"
echo "直连后端：$n 个，正常 $OK_N，异常 $BAD_N"

# ---- 可选：抽查入口轮询 ----
if [ -n "$ENTRY_HOST" ]; then
    echo
    echo "=================================================================="
    echo "入口轮询抽查：$ENTRY_HOST:$ENTRY_PORT（$n 次）"
    echo "------------------------------------------------------------------"
    for i in $(seq 1 "$n"); do
        curl -s --max-time "$TIMEOUT" --socks5-hostname "${AUTH}${ENTRY_HOST}:${ENTRY_PORT}" \
             "$CHECK_URL" 2>/dev/null | tr -d '[:space:]'
        echo
    done | sort | uniq -c | sort -rn
    echo "（左侧数字=出现次数；若只有 1~2 个 IP，说明其余后端被健康检查和掉了）"
fi

[ "$BAD_N" -eq 0 ] || exit 1
exit 0
