#!/usr/bin/env bash
# =============================================================================
# provision.sh —— 代理机「纳管」：装公钥 → 装 Docker → 放行端口 → 出口 IP 自检
#
# 与 deploy.sh 共用同一份清单 deploy/hosts.txt（代理机唯一清单）。
#
# 认证方式自动探测（关键设计）：
#   · 先试免密（~/.ssh/proxy_deploy）→ 通就全程用密钥，不用 sshpass
#   · 不通才用清单里写的密码登录一次 → 装公钥 → 之后永久免密
#   · 两者都不通 → 报错，并给出 ssh 原始输出 + 按错误类型的处置建议
#
#   所以「本机」「已纳管过的机器」即使写了密码也不会走 sshpass。这一点很重要：
#   Ubuntu 默认 PermitRootLogin prohibit-password，**root 密码登录本就禁用**，
#   本机写了密码也登不进去，只能靠免密。
#
# 清单里每一行都会执行 bootstrap.sh（因为每一行都是代理机），不只是新机。
# 纳管完成后【不会】往清单里追加任何内容 —— 清单由你手工维护，天然不会重复。
#
# 用法（在运维机执行）：
#   1) cp deploy/hosts.txt.example deploy/hosts.txt
#   2) vi deploy/hosts.txt          # 每行一台：<host|user@host> [user] [password] [port]
#      chmod 600 deploy/hosts.txt
#   3) SCHED_IP=<调度机IP> ./deploy/provision.sh            # 只纳管
#      SCHED_IP=<调度机IP> ./deploy/provision.sh --deploy   # 纳管后立刻全量部署
#
# 环境变量：
#   SCHED_IP=调度机IP    # 传给 bootstrap.sh：本机 1080 仅放行调度机（HAProxy 转发/健康检查）
#   CLIENT_IP=客户端IP   # 本机兼调度机时，放行入口端口给客户端
#   ENTRY_PORT=2080      # 入口端口，默认 2080
#   UFW_ENABLE=1         # 写完规则后启用 ufw（默认只写不启用，防止把 SSH 锁死）
#   HOSTS_FILE=路径      # 自定义清单（默认 deploy/hosts.txt）
#   PUBKEY/PRIVKEY       # 部署密钥路径（默认 ~/.ssh/proxy_deploy[.pub]）
#
# 依赖：ssh、scp；sshpass 仅在「确实需要用密码登录」时才要求（缺失时自动尝试安装）
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

BOOTSTRAP="$HERE/bootstrap.sh"
PUBKEY="${PUBKEY:-$HOME/.ssh/proxy_deploy.pub}"
PRIVKEY="${PRIVKEY:-$HOME/.ssh/proxy_deploy}"

# 清单优先用统一的 hosts.txt；不存在时回退旧的 proxy-hosts.txt（兼容过渡）
HOSTS_FILE="${HOSTS_FILE:-$HERE/hosts.txt}"
if [ ! -f "$HOSTS_FILE" ] && [ -f "$HERE/proxy-hosts.txt" ]; then
    HOSTS_FILE="$HERE/proxy-hosts.txt"
    echo "[provision] WARN: 未找到 hosts.txt，回退使用旧清单 proxy-hosts.txt（建议合并为 hosts.txt）" >&2
fi

SCHED_IP="${SCHED_IP:-}"
CLIENT_IP="${CLIENT_IP:-}"
ENTRY_PORT="${ENTRY_PORT:-2080}"
DEFAULT_SSH_PORT="${SSH_PORT:-22}"
UFW_ENABLE="${UFW_ENABLE:-0}"

DO_DEPLOY=0
for arg in "$@"; do
    case "$arg" in
        --deploy) DO_DEPLOY=1 ;;
        -h|--help) sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $arg （可用：--deploy）" >&2; exit 2 ;;
    esac
done

c_log()  { printf '\033[1;36m[provision]\033[0m %s\n' "$*"; }
c_ok()   { printf '\033[1;32m[provision]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m[provision]\033[0m %s\n' "$*" >&2; }
c_err()  { printf '\033[1;31m[provision]\033[0m %s\n' "$*" >&2; }

# 密码走 SSHPASS 环境变量（sshpass -e），不出现在 ps/argv 里
# -n：禁止 ssh 转发 stdin；没有它，循环里第一台机器的 ssh 会把清单剩余行当 stdin 吃掉
# 注意：-o 选项「先出现的值生效」，所以静默版必须把 LogLevel=ERROR 放在最前
#
# SSH_OPTS 与 SSH_COMMON 的区别是【有没有 -n】：
#   · 绝大多数调用要 -n（禁止 ssh 转发 stdin，否则会吃掉 while read 的清单）
#   · 但「用 ssh 传文件内容」的场景必须【不要】-n —— 那时 stdin 就是文件内容
SSH_OPTS=(-o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="$HOME/.ssh/known_hosts"
          -o ConnectTimeout=10
          -o NumberOfPasswordPrompts=1)
SSH_COMMON=(-n "${SSH_OPTS[@]}")
SSH_BASE=(-o LogLevel=ERROR "${SSH_COMMON[@]}")   # 静默版：正常调用
# 密码登录专用：关掉公钥认证，直接走 password/keyboard-interactive。
# 否则 ssh 会先把本地所有密钥试一遍（agent 里钥匙多时尤其明显）才轮到密码，
# 表现为 sshpass 密码明明对却还是失败。
SSH_PASS_EXTRA=(-o PreferredAuthentications=password,keyboard-interactive
                -o PubkeyAuthentication=no)
SCP_BASE=(-q -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="$HOME/.ssh/known_hosts"
          -o ConnectTimeout=10)

# 清理 ANSI 转义序列（很多服务器的登录横幅带颜色，会污染非交互 ssh 的输出）
strip_ansi() { sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tr -d '\r'; }

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
        c_warn "部署密钥不存在，正在生成全新的 $PRIVKEY ..."
        mkdir -p "$(dirname "$PRIVKEY")"
        ssh-keygen -t ed25519 -f "$PRIVKEY" -N "" -C "proxy-pool-deploy" >/dev/null
        c_warn "注意：这是【全新】密钥对，其公钥尚未被任何机器授权。"
        c_warn "      凡清单里没写密码的行（依赖免密）都会失败——请给它们补上密码字段，"
        c_warn "      或把 $PUBKEY 内容手工追加到各机 ~/.ssh/authorized_keys。"
    fi
    chmod 600 "$PRIVKEY" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 认证探测与统一执行入口
# ---------------------------------------------------------------------------

# 探测可用认证方式：优先密钥，其次密码。打印 key|pass，都不通返回 1
probe_auth() { # host user pass port
    local host="$1" user="$2" pass="$3" port="$4"
    if ssh "${SSH_BASE[@]}" -o BatchMode=yes -i "$PRIVKEY" -p "$port" "$user@$host" 'echo OK' \
        </dev/null >/dev/null 2>&1; then
        echo key; return 0
    fi
    [ -n "$pass" ] || return 1
    ensure_sshpass >/dev/null 2>&1 || return 1
    if SSHPASS="$pass" sshpass -e ssh "${SSH_BASE[@]}" "${SSH_PASS_EXTRA[@]}" -p "$port" \
        "$user@$host" 'echo OK' </dev/null >/dev/null 2>&1; then
        echo pass; return 0
    fi
    return 1
}

# 按已探测到的认证方式执行远端命令
run_remote() { # auth host user pass port cmd
    local auth="$1" host="$2" user="$3" pass="$4" port="$5" cmd="$6"
    if [ "$auth" = "key" ]; then
        ssh "${SSH_BASE[@]}" -o BatchMode=yes -i "$PRIVKEY" -p "$port" "$user@$host" "$cmd" </dev/null
    else
        SSHPASS="$pass" sshpass -e ssh "${SSH_BASE[@]}" "${SSH_PASS_EXTRA[@]}" -p "$port" \
            "$user@$host" "$cmd" </dev/null
    fi
}

# 传 bootstrap.sh：用「ssh + stdin 重定向」而不是 scp。
#
# 为什么不用 scp：scp 走的 SCP/SFTP 协议对 stdout 上的杂散字节零容忍。很多服务器
# 的 ~/.bashrc 或登录横幅在非交互 ssh 时仍会输出内容（带 ANSI 颜色），scp 就会报
# "Connection closed" / "protocol error" 而 ssh 命令本身却完全正常。
# 用 ssh 'cat > file' < file 完全走 stdin，不依赖 SCP 协议，天然免疫该问题。
copy_bootstrap() { # auth host user pass port
    local auth="$1" host="$2" user="$3" pass="$4" port="$5" remote=/tmp/proxy-bootstrap.sh
    if [ "$auth" = "key" ]; then
        ssh "${SSH_BASE[@]}" -o BatchMode=yes -i "$PRIVKEY" -p "$port" "$user@$host" \
            "cat > $remote" < "$BOOTSTRAP" || return 1
        # 校验：远端文件大小应与本地一致
        local lsize rsize
        lsize=$(wc -c < "$BOOTSTRAP" | tr -d '[:space:]')
        rsize=$(ssh "${SSH_BASE[@]}" -o BatchMode=yes -i "$PRIVKEY" -p "$port" "$user@$host" \
            "wc -c < $remote" </dev/null 2>/dev/null | strip_ansi | tail -1 | tr -d '[:space:]')
        if [ -n "$rsize" ] && [ "$rsize" != "$lsize" ]; then
            c_err "  文件校验失败：本地 $lsize 字节，远端 $rsize 字节"
            return 1
        fi
    else
        SSHPASS="$pass" sshpass -e ssh "${SSH_BASE[@]}" "${SSH_PASS_EXTRA[@]}" -p "$port" \
            "$user@$host" "cat > $remote" < "$BOOTSTRAP" || return 1
    fi
    return 0
}

# 诊断版：不带 LogLevel=ERROR，把 ssh 的真实报错吐出来
key_diag() { # host user port
    ssh "${SSH_COMMON[@]}" -o BatchMode=yes -i "$PRIVKEY" -p "$3" "$2@$1" 'echo OK' </dev/null 2>&1
}
pass_diag() { # host user pass port
    SSHPASS="$3" sshpass -e ssh "${SSH_COMMON[@]}" "${SSH_PASS_EXTRA[@]}" -p "$4" "$2@$1" 'echo OK' </dev/null 2>&1
}

explain_ssh_error() { # host port out mode
    local host="$1" port="$2" out="$3" mode="$4"
    case "$out" in
        *"Connection refused"*|*"timed out"*|*"No route to host"*|*"Connection closed"*)
            c_err "  -> 连不上 $host:$port。检查：sshd 是否监听该地址与端口"
            c_err "     ss -lntp | grep ':$port'   /   grep -E '^(Port|ListenAddress)' /etc/ssh/sshd_config"
            c_err "     本机自连(127.0.0.1)时：sshd 若只绑了公网 IP（ListenAddress），回环就连不上；可把清单里这行改成本机公网 IP" ;;
        *"Permission denied"*|*"Authentication failed"*)
            if [ "$mode" = "pass" ]; then
                c_err "  -> 密码登录被拒。最常见原因：sshd 禁用了 root 密码登录"
                c_err "     grep -E '^(PermitRootLogin|PasswordAuthentication)' /etc/ssh/sshd_config"
                c_err "     Ubuntu 默认 'PermitRootLogin prohibit-password' —— root 只能用密钥，写密码无效。"
                c_err "     修法二选一：① 给该机配好免密（推荐，本机就走这条）；"
                c_err "                ② 改 'PermitRootLogin yes' + 'PasswordAuthentication yes' 后 systemctl restart sshd"
                c_err "     另确认 root 密码本身存在：本机可用 'sudo passwd root' 设置"
            else
                c_err "  -> 密钥不被接受。检查：$PUBKEY 是否已写入该机 ~/.ssh/authorized_keys"
                c_err "     sshd 的 PubkeyAuthentication yes / PermitRootLogin prohibit-password（不能是 no）"
                c_err "     私钥 $PRIVKEY 权限须为 600；本机自连则检查 /root/.ssh/authorized_keys"
            fi ;;
        *"IDENTIFICATION HAS CHANGED"*|*"Offending"*|*"REMOTE HOST ID"*)
            c_err "  -> known_hosts 里的主机指纹与当前不符。执行：ssh-keygen -R $host  然后重跑" ;;
        *"no such identity"*|*"identity file"*)
            c_err "  -> 私钥 $PRIVKEY 不存在。脚本本应自动生成，检查 ~/.ssh 是否可写" ;;
        *)
            c_err "  -> 见上方 ssh 原始报错" ;;
    esac
}

# root 前缀：root 用户为空；非 root 且 NOPASSWD sudo 可用则 "sudo -n"；否则失败
#   uid 用带标记的输出（PPUID=）而不是裸 `id -u`：远端 shell 若输出横幅，裸输出
#   取最后一行仍可能是横幅；带标记则只认 PPUID= 那一行。
detect_sudo() { # auth host user pass port
    local auth="$1" host="$2" user="$3" pass="$4" port="$5" uid
    uid=$(run_remote "$auth" "$host" "$user" "$pass" "$port" 'printf "PPUID=%s\n" "$(id -u)"' 2>/dev/null \
          | strip_ansi | sed -n 's/^PPUID=//p' | tail -1 | tr -d '[:space:]')
    if [ "$uid" = "0" ]; then echo ""; return 0; fi
    if run_remote "$auth" "$host" "$user" "$pass" "$port" 'sudo -n true' >/dev/null 2>&1; then
        echo "sudo -n"; return 0
    fi
    [ -z "$uid" ] && c_err "  另：未能识别远端 uid（输出被污染？检查远端 ~/.bashrc 非交互时是否直接 return）"
    return 1
}

# ---------------------------------------------------------------------------
# 单台纳管：先探测认证方式，再走完全相同的后续流程
# ---------------------------------------------------------------------------
provision_one() { # host user pass port
    local host="$1" user="$2" pass="$3" port="$4"
    local tag="$user@$host:$port"
    local auth info uid os arch docker compose_ver sudo_prefix key

    LAST_AUTH=""          # 由主循环读取，用于统计口径
    c_log "======== $tag ========"

    # ① 探测认证方式：能用密钥就绝不用密码
    auth=$(probe_auth "$host" "$user" "$pass" "$port")
    if [ -z "$auth" ]; then
        c_err "[$tag] 免密与密码两条路都不通。诊断信息："
        local kout pout
        kout=$(key_diag "$host" "$user" "$port")
        c_err "  [密钥] $(printf '%s' "$kout" | head -3 | tr '\n' ' ')"
        explain_ssh_error "$host" "$port" "$kout" key
        if [ -n "$pass" ]; then
            if ensure_sshpass >/dev/null 2>&1; then
                pout=$(pass_diag "$host" "$user" "$pass" "$port")
                c_err "  [密码] $(printf '%s' "$pout" | head -3 | tr '\n' ' ')"
                explain_ssh_error "$host" "$port" "$pout" pass
            else
                c_err "  [密码] sshpass 不可用，无法尝试密码登录"
            fi
        else
            c_err "  [密码] 清单该行未写密码，未尝试。"
            c_err "     处置：补上密码字段后重跑，或先把 $PUBKEY 装到该机 ~/.ssh/authorized_keys"
        fi
        return 1
    fi
    LAST_AUTH="$auth"
    [ "$auth" = "key" ] && c_ok "[$tag] 免密可用，全程走密钥（清单里的密码字段不再需要）" \
                        || c_ok "[$tag] 免密不可用，已用密码登录，接下来装公钥"

    # ② 采集信息
    info=$(run_remote "$auth" "$host" "$user" "$pass" "$port" \
        'echo "UID=$(id -u)"; ( . /etc/os-release 2>/dev/null && echo "OS=$PRETTY_NAME" ) || echo "OS=unknown"; \
         echo "ARCH=$(uname -m)"; echo "HOST=$(hostname)"; \
         echo "DOCKER=$(command -v docker >/dev/null 2>&1 && docker --version || echo none)"; \
         echo "COMPOSE=$(docker compose version --short 2>/dev/null || echo none)"' 2>&1) \
        || { c_err "[$tag] 执行远端命令失败：$info"; return 1; }
    info=$(printf '%s\n' "$info" | strip_ansi)

    uid=$(printf '%s\n' "$info" | sed -n 's/^UID=//p'     | tail -1 | tr -d '[:space:]')
    os=$(printf '%s\n' "$info"  | sed -n 's/^OS=//p'      | tail -1)
    arch=$(printf '%s\n' "$info" | sed -n 's/^ARCH=//p'   | tail -1 | tr -d '[:space:]')
    docker=$(printf '%s\n' "$info" | sed -n 's/^DOCKER=//p' | tail -1)
    compose_ver=$(printf '%s\n' "$info" | sed -n 's/^COMPOSE=//p' | tail -1 | tr -d '[:space:]')

    # 远端非交互 shell 若输出了额外内容（登录横幅、.bashrc 的 echo 等），
    # 会污染输出解析，还会让 scp 断连。检测到就提示，避免用户一头雾水。
    case "$uid" in
        ''|*[!0-9]*)
            c_warn "[$tag] 未能识别远端 uid（得到 '${uid:-<空>}'）。多半是该机非交互 shell 输出了额外内容："
            printf '%s\n' "$info" | head -5 | sed 's/^/       | /'
            c_warn "     检查远端 ~/.bashrc 是否有 echo/横幅，并确保非交互时直接 return；本脚本已改用 stdin 传文件，不受影响" ;;
    esac

    c_ok "[$tag] 登录成功：$os / $arch / uid=$uid / docker=${docker:-none} / compose=${compose_ver:-none}"

    # ③ root 权限判定
    sudo_prefix=$(detect_sudo "$auth" "$host" "$user" "$pass" "$port")
    if [ $? -ne 0 ]; then
        c_err "[$tag] 该用户不是 root 且 sudo 需要密码。请改用 root 账号，或先配置 NOPASSWD sudo"
        return 1
    fi
    [ -n "$sudo_prefix" ] && c_warn "[$tag] 非 root 用户，后续用 '$sudo_prefix' 提权（需保证 /opt/proxy-pool 可写）"
    if [ "$port" != "22" ]; then
        c_warn "[$tag] 非 22 端口：deploy.sh 按清单里的主机直连 22 端口。请在运维机 ~/.ssh/config 里为该主机写 Port $port，否则部署阶段连不上"
    fi

    # ④ 安装部署公钥（幂等：已存在则不重复追加）
    key=$(cat "$PUBKEY")
    run_remote "$auth" "$host" "$user" "$pass" "$port" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
         { grep -qF '$key' ~/.ssh/authorized_keys || printf '%s\n' '$key' >> ~/.ssh/authorized_keys; }" \
        || { c_err "[$tag] 写入 authorized_keys 失败"; return 1; }

    # ⑤ 确认免密可用（走密码进来的，装完公钥后必须能免密）
    if [ "$auth" != "key" ]; then
        if ! ssh "${SSH_BASE[@]}" -o BatchMode=yes -i "$PRIVKEY" -p "$port" "$user@$host" 'echo OK' \
            </dev/null >/dev/null 2>&1; then
            local kout2
            kout2=$(key_diag "$host" "$user" "$port")
            c_err "[$tag] 公钥已写入，但免密验证仍不通过。ssh 原始报错："
            printf '%s\n' "$kout2" | sed 's/^/       | /'
            explain_ssh_error "$host" "$port" "$kout2" key
            c_err "     免密不通则 deploy.sh 后续连不上该机，请修好再重跑"
            return 1
        fi
        c_ok "[$tag] 免密已生效（后续可把该行密码字段删掉）"
        auth=key   # 公钥既已生效，后续步骤改用密钥，不再依赖 sshpass
    fi

    # ⑥ 传输并执行 bootstrap.sh（Docker + compose + 防火墙 + 出口 IP 自检）
    c_log "[$tag] 传输 bootstrap.sh 并执行系统层初始化 ..."
    copy_bootstrap "$auth" "$host" "$user" "$pass" "$port" \
        || { c_err "[$tag] scp 失败"; return 1; }

    if ! run_remote "$auth" "$host" "$user" "$pass" "$port" \
        "$sudo_prefix env SCHED_IP='$SCHED_IP' CLIENT_IP='$CLIENT_IP' ENTRY_PORT='$ENTRY_PORT' SSH_PORT='$port' UFW_ENABLE='$UFW_ENABLE' bash /tmp/proxy-bootstrap.sh"; then
        c_err "[$tag] bootstrap.sh 执行失败（详情见上方输出）"
        return 1
    fi
    c_ok "[$tag] 系统层初始化完成"
    return 0
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
[ -f "$HOSTS_FILE" ] || {
    c_err "找不到代理机清单 $HOSTS_FILE"
    echo "  先复制模板再填：cp $HERE/hosts.txt.example $HOSTS_FILE"
    exit 1
}

perm=$(stat -c '%a' "$HOSTS_FILE" 2>/dev/null || stat -f '%A' "$HOSTS_FILE" 2>/dev/null || echo '')
if [ -n "$perm" ] && [ "$perm" != "600" ]; then
    c_warn "清单含明文密码，权限 $perm 过宽，已自动收紧为 600"
    chmod 600 "$HOSTS_FILE"
fi

ensure_keypair
mkdir -p "$(dirname "$HOME/.ssh/known_hosts")"

c_log "代理机清单：$HOSTS_FILE"
c_log "调度机 IP：${SCHED_IP:-<未设置，1080 将不写来源限制>}    入口端口：$ENTRY_PORT"

total=0; key_cnt=0; pass_cnt=0; failed_list=()
LAST_AUTH=""
# 清单从 fd 3 读：循环体内的 ssh/sshpass 即使抢 stdin 也影响不到 read
while IFS= read -r -u 3 line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2086
    set -- $line
    h_field="$1"
    if [ "${h_field#*@}" != "$h_field" ]; then
        # 写法：user@host [password] [port]
        local_user="${h_field%@*}"; local_host="${h_field#*@}"
        local_pass="${2:-}"; local_port="${3:-}"
    else
        # 写法：host [user] [password] [port]
        local_host="$1"; local_user="${2:-root}"
        local_pass="${3:-}"; local_port="${4:-}"
    fi

    if [ -z "$local_host" ]; then
        c_warn "跳过格式不完整的行：$line"
        continue
    fi

    # 清单没写端口时，从 ssh_config 解析实际端口再连。
    # 否则命令行上的 -p 22 会覆盖 ~/.ssh/config 里的 Port —— 这正是
    # "改过 SSH 端口的机器 / 本机" 在 deploy.sh 里能连、在 provision.sh 里失败的原因。
    if [ -z "$local_port" ]; then
        local_port=$(ssh -G "$local_user@$local_host" 2>/dev/null | sed -n 's/^port //p' | head -1)
    fi
    [ -n "$local_port" ] || local_port="$DEFAULT_SSH_PORT"

    total=$((total + 1))
    if provision_one "$local_host" "$local_user" "$local_pass" "$local_port"; then
        if [ "$LAST_AUTH" = "key" ]; then
            key_cnt=$((key_cnt + 1))
        else
            pass_cnt=$((pass_cnt + 1))
        fi
    else
        failed_list+=("$local_user@$local_host:$local_port")
    fi
done 3< "$HOSTS_FILE"

echo
c_log "============ 纳管结果 ============"
c_log "清单 $total 台：免密纳管 $key_cnt 台，密码纳管 $pass_cnt 台"
if [ "${#failed_list[@]}" -gt 0 ]; then
    c_err "失败 ${#failed_list[@]} 台：${failed_list[*]}"
fi

if [ "$pass_cnt" -gt 0 ] || [ "$key_cnt" -gt 0 ]; then
    echo
    c_log "提示：密码纳管成功的那行，密码字段可以删掉（后续全走密钥），但【行本身要保留】—— deploy.sh 靠它识别机器"
    c_warn "安全提醒：$HOSTS_FILE 含明文密码，建议 chmod 600 且勿入库（.gitignore 已排除）"
fi

if [ "$DO_DEPLOY" = "1" ]; then
    if [ "${#failed_list[@]}" -eq 0 ]; then
        echo
        c_log "开始全量部署（deploy.sh）..."
        ( cd "$ROOT" && ENTRY_PORT="$ENTRY_PORT" HOSTS_FILE="$HOSTS_FILE" SSH_OPTS="-i $PRIVKEY" "$HERE/deploy.sh" )
    else
        c_warn "有机器纳管失败，跳过部署。修复后重跑（脚本可重入，已纳管的会跳过）"
    fi
fi

[ "${#failed_list[@]}" -eq 0 ] && exit 0 || exit 1
