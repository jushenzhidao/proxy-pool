#!/usr/bin/env bash
# =============================================================================
# provision.sh —— 用「IP + 用户名 + 密码」一键纳管新代理机（首次免密自动化）
#
# 解决的问题：新机器还没有免密 SSH，deploy.sh 跑不了。本脚本用密码只登录一次，
#             自动完成：
#               ① 登录连通性检查（兼采集系统信息）
#               ② 安装部署公钥 → 之后永久免密
#               ③ 执行 bootstrap.sh → 装 Docker/compose + 写防火墙规则 + 出口 IP 自检
#               ④ 把机器追加进 deploy/proxy-hosts.txt（自动去重）
#               ⑤ 可选：立刻跑 deploy.sh 完成应用层部署（--deploy）
#
# 用法（在运维机执行，推荐就用现有那台 Linux 调度机）：
#   1) cp deploy/new-hosts.txt.example deploy/new-hosts.txt
#   2) vi deploy/new-hosts.txt        # 每行一台：<host> <user> <password> [port]
#      chmod 600 deploy/new-hosts.txt
#   3) ./deploy/provision.sh          # 只做系统层纳管
#      ./deploy/provision.sh --deploy # 纳管完立刻全量部署（含老机器）
#
# 环境变量：
#   SCHED_IP=调度机IP    # 传给 bootstrap.sh：本机 1080 仅放行调度机（HAProxy 转发/健康检查）
#   CLIENT_IP=客户端IP   # 本机兼调度机时，放行入口端口给客户端
#   ENTRY_PORT=2080      # 入口端口，默认 2080
#   UFW_ENABLE=1         # 写完规则后启用 ufw（默认只写不启用，防止把 SSH 锁死）
#   HOSTS_FILE=路径      # 自定义新机清单（默认 deploy/new-hosts.txt）
#   PUBKEY/PRIVKEY       # 部署密钥路径（默认 ~/.ssh/proxy_deploy[.pub]）
#
# 依赖：sshpass（缺失时脚本会尝试自动安装）、ssh、scp
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

HOSTS_FILE="${HOSTS_FILE:-$HERE/new-hosts.txt}"
PUBKEY="${PUBKEY:-$HOME/.ssh/proxy_deploy.pub}"
PRIVKEY="${PRIVKEY:-$HOME/.ssh/proxy_deploy}"
BOOTSTRAP="$HERE/bootstrap.sh"
PROXY_HOSTS="$HERE/proxy-hosts.txt"

SCHED_IP="${SCHED_IP:-}"
CLIENT_IP="${CLIENT_IP:-}"
ENTRY_PORT="${ENTRY_PORT:-2080}"
DEFAULT_SSH_PORT="${SSH_PORT:-22}"
UFW_ENABLE="${UFW_ENABLE:-0}"

DO_DEPLOY=0
for arg in "$@"; do
    case "$arg" in
        --deploy) DO_DEPLOY=1 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $arg （可用：--deploy）" >&2; exit 2 ;;
    esac
done

c_log()  { printf '\033[1;36m[provision]\033[0m %s\n' "$*"; }
c_ok()   { printf '\033[1;32m[provision]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m[provision]\033[0m %s\n' "$*" >&2; }
c_err()  { printf '\033[1;31m[provision]\033[0m %s\n' "$*" >&2; }

# 密码走 SSHPASS 环境变量（sshpass -e），不出现在 ps/argv 里
SSH_BASE=(-o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="$HOME/.ssh/known_hosts"
          -o ConnectTimeout=10
          -o NumberOfPasswordPrompts=1
          -o LogLevel=ERROR)
SCP_BASE=(-q -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="$HOME/.ssh/known_hosts"
          -o ConnectTimeout=10)

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
[ -f "$BOOTSTRAP" ] || { c_err "找不到 $BOOTSTRAP（请在本仓库的运维机副本上运行）"; exit 1; }

ensure_sshpass() {
    command -v sshpass >/dev/null 2>&1 && return 0
    c_log "sshpass 未安装，尝试自动安装 ..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq sshpass
    elif command -v dnf >/dev/null 2>&1; then dnf install -y sshpass
    elif command -v yum >/dev/null 2>&1; then yum install -y sshpass
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache sshpass
    else
        c_err "无法自动安装 sshpass，请手动安装后重跑（Debian/Ubuntu: apt install -y sshpass）"
        return 1
    fi
    command -v sshpass >/dev/null 2>&1
}

ensure_keypair() {
    if [ ! -f "$PRIVKEY" ] || [ ! -f "$PUBKEY" ]; then
        c_log "部署密钥不存在，生成 $PRIVKEY ..."
        mkdir -p "$(dirname "$PRIVKEY")"
        ssh-keygen -t ed25519 -f "$PRIVKEY" -N "" -C "proxy-pool-deploy" >/dev/null
    fi
    chmod 600 "$PRIVKEY" 2>/dev/null || true
    c_ok "部署公钥：$(cat "$PUBKEY")"
}

# 用密码执行远端命令
run_pass() { # host user pass port cmd
    SSHPASS="$3" sshpass -e ssh "${SSH_BASE[@]}" -p "$4" "$2@$1" "$5"
}

# 用密钥执行远端命令（BatchMode：还要密码就直接失败，不卡住）
run_key() { # host user port cmd
    ssh "${SSH_BASE[@]}" -o BatchMode=yes -i "$PRIVKEY" -p "$3" "$2@$1" "$4"
}

# root 前缀：root 用户为空；非 root 且 NOPASSWD sudo 可用则 "sudo -n"；否则失败
detect_sudo() { # host user pass port
    local uid
    uid=$(run_pass "$1" "$2" "$3" "$4" 'id -u' 2>/dev/null | tr -d '\r')
    if [ "$uid" = "0" ]; then echo ""; return 0; fi
    if run_pass "$1" "$2" "$3" "$4" 'sudo -n true' >/dev/null 2>&1; then echo "sudo -n"; return 0; fi
    return 1
}

# ---------------------------------------------------------------------------
# 单台纳管
# ---------------------------------------------------------------------------
provision_one() {
    local host="$1" user="$2" pass="$3" port="$4"
    local tag="$user@$host:$port"
    local sudo_cmd info uid os arch docker compose_ver sudo_prefix

    c_log "======== $tag ========"

    # ① 连通性 + 采集信息
    info=$(run_pass "$host" "$user" "$pass" "$port" \
        'echo "UID=$(id -u)"; ( . /etc/os-release 2>/dev/null && echo "OS=$PRETTY_NAME" ) || echo "OS=unknown"; \
         echo "ARCH=$(uname -m)"; echo "HOST=$(hostname)"; \
         echo "DOCKER=$(command -v docker >/dev/null 2>&1 && docker --version || echo none)"; \
         echo "COMPOSE=$(docker compose version --short 2>/dev/null || echo none)"' 2>&1) \
        || { c_err "[$tag] 登录失败：检查 IP/用户名/密码/端口是否正确，或 sshd 是否放行你的 IP"; return 1; }

    uid=$(echo "$info"   | sed -n 's/^UID=//p'    | tr -d '\r')
    os=$(echo "$info"    | sed -n 's/^OS=//p'     | tr -d '\r')
    arch=$(echo "$info"  | sed -n 's/^ARCH=//p'   | tr -d '\r')
    docker=$(echo "$info" | sed -n 's/^DOCKER=//p' | tr -d '\r')
    compose_ver=$(echo "$info" | sed -n 's/^COMPOSE=//p' | tr -d '\r')

    c_ok "[$tag] 登录成功：$os / $arch / uid=$uid / docker=${docker:-none} / compose=${compose_ver:-none}"

    # ② root 权限判定
    sudo_prefix=$(detect_sudo "$host" "$user" "$pass" "$port")
    if [ $? -ne 0 ]; then
        c_err "[$tag] 该用户不是 root 且 sudo 需要密码。请改用 root 账号，或先配置 NOPASSWD sudo"
        return 1
    fi
    [ -n "$sudo_prefix" ] && c_warn "[$tag] 非 root 用户，后续用 '$sudo_prefix' 提权（需保证 /opt/proxy-pool 可写）"
    if [ "$port" != "22" ]; then
        c_warn "[$tag] 非 22 端口：deploy.sh 按清单里的 user@host 直连 22 端口。请在运维机 ~/.ssh/config 里为该主机写 Port $port，否则部署阶段连不上"
    fi

    # ③ 安装部署公钥（幂等：已存在则不重复追加）
    local key
    key=$(cat "$PUBKEY")
    run_pass "$host" "$user" "$pass" "$port" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
         { grep -qF '$key' ~/.ssh/authorized_keys || printf '%s\n' '$key' >> ~/.ssh/authorized_keys; }" \
        || { c_err "[$tag] 写入 authorized_keys 失败"; return 1; }

    # ④ 验证免密（BatchMode，还要密码就算失败）
    if ! run_key "$host" "$user" "$port" 'echo OK' >/dev/null 2>&1; then
        c_err "[$tag] 免密验证失败：公钥已写入但 key 认证不通过，检查远端 sshd 的 PubkeyAuthentication / PermitRootLogin"
        return 1
    fi
    c_ok "[$tag] 免密已生效（后续无需密码）"

    # ⑤ 传输并执行 bootstrap.sh（Docker + compose + 防火墙 + IP 自检）
    c_log "[$tag] 传输 bootstrap.sh 并执行系统层初始化 ..."
    scp "${SCP_BASE[@]}" -i "$PRIVKEY" -P "$port" "$BOOTSTRAP" "$user@$host:/tmp/proxy-bootstrap.sh" \
        || { c_err "[$tag] scp 失败"; return 1; }

    if ! run_key "$host" "$user" "$port" \
        "$sudo_prefix env SCHED_IP='$SCHED_IP' CLIENT_IP='$CLIENT_IP' ENTRY_PORT='$ENTRY_PORT' SSH_PORT='$port' UFW_ENABLE='$UFW_ENABLE' bash /tmp/proxy-bootstrap.sh"; then
        c_err "[$tag] bootstrap.sh 执行失败（详情见上方输出）"
        return 1
    fi
    c_ok "[$tag] 系统层初始化完成"

    # ⑥ 加入 proxy-hosts.txt（去重、保留原有所有行）
    local entry="$user@$host"
    if [ -f "$PROXY_HOSTS" ] && grep -qxF "$entry" "$PROXY_HOSTS"; then
        c_log "[$tag] 已在 proxy-hosts.txt 中，跳过追加"
    else
        echo "$entry" >> "$PROXY_HOSTS"
        c_ok "[$tag] 已追加到 proxy-hosts.txt：$entry"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
[ -f "$HOSTS_FILE" ] || {
    c_err "找不到新机清单 $HOSTS_FILE"
    echo "  先复制模板再填：cp $HERE/new-hosts.txt.example $HOSTS_FILE"
    exit 1
}

perm=$(stat -c '%a' "$HOSTS_FILE" 2>/dev/null || stat -f '%A' "$HOSTS_FILE" 2>/dev/null || echo '')
if [ -n "$perm" ] && [ "$perm" != "600" ]; then
    c_warn "清单含明文密码，权限 $perm 过宽，已自动收紧为 600"
    chmod 600 "$HOSTS_FILE"
fi

ensure_sshpass || exit 1
ensure_keypair
mkdir -p "$(dirname "$HOME/.ssh/known_hosts")"

c_log "新机清单：$HOSTS_FILE"
c_log "调度机 IP：${SCHED_IP:-<未设置，1080 将不写来源限制>}    入口端口：$ENTRY_PORT"

total=0; ok=0; failed_list=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2086
    set -- $line
    h_field="$1"
    if [ "${h_field#*@}" != "$h_field" ]; then
        # 写法：user@host pass [port]
        local_user="${h_field%@*}"; local_host="${h_field#*@}"
        local_pass="${2:-}"; local_port="${3:-$DEFAULT_SSH_PORT}"
    else
        # 写法：host [user] pass [port]
        local_host="$1"; local_user="${2:-root}"
        local_pass="${3:-}"; local_port="${4:-$DEFAULT_SSH_PORT}"
    fi

    if [ -z "$local_host" ] || [ -z "$local_pass" ]; then
        c_warn "跳过格式不完整的行：$line"
        continue
    fi

    total=$((total + 1))
    if provision_one "$local_host" "$local_user" "$local_pass" "$local_port"; then
        ok=$((ok + 1))
    else
        failed_list+=("$local_user@$local_host:$local_port")
    fi
done < "$HOSTS_FILE"

echo
c_log "============ 纳管结果 ============"
c_log "共 $total 台，成功 $ok 台"
if [ "${#failed_list[@]}" -gt 0 ]; then
    c_err "失败 ${#failed_list[@]} 台：${failed_list[*]}"
fi

if [ "$ok" -gt 0 ]; then
    echo
    c_warn "安全提醒：$HOSTS_FILE 含明文密码，纳管完成后建议删除（免密已生效，不再需要）"
    echo "  shred -u $HOSTS_FILE    # 或 rm -f"
fi

if [ "$DO_DEPLOY" = "1" ] && [ "$ok" -gt 0 ]; then
    echo
    c_log "开始全量部署（deploy.sh）..."
    ( cd "$ROOT" && ENTRY_PORT="$ENTRY_PORT" SSH_OPTS="-i $PRIVKEY" "$HERE/deploy.sh" )
fi

[ "$ok" -eq "$total" ] && [ "$total" -gt 0 ] && exit 0 || exit 1
