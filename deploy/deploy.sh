#!/bin/bash
# 一键多机部署：并行推送 agent/ 到所有代理机并启动，拉取各机器真实出口 IP，
# 直接生成 HAProxy 后端配置（不依赖 machines.txt 的"IP 连续"假设）。
#
# 用法：
#   ./deploy.sh                                        # 按 deploy/hosts.txt 全量部署
#   SSH_OPTS="-p 2222 -i ~/.ssh/deploy_key" ./deploy.sh  # 自定义 SSH 参数
#   REMOTE_DIR=/data/proxy-pool ./deploy.sh              # 自定义远程目录
#   PREBUILT=1 ./deploy.sh                               # 拉 ghcr.io 预构建镜像，不在远端 build
#   PREBUILT=1 IMAGE_TAG=v1.0.0 ./deploy.sh              # 锁定镜像版本（默认 latest）
#
# 流程：远端检查 docker -> rsync agent/ -> 生成 .env 并清理旧容器后重启 -> 拉回 IP 清单
#       （down --remove-orphans 清同项目孤儿；再按 proxy-* 名字强删，
#        覆盖"曾在别的目录/项目部署过"留下的跨项目同名容器，避免 name 冲突）
#       -> 生成 scheduler/haproxy-servers.cfg -> 本机若可写 /etc/haproxy 则自动组装+reload
#
# 幂等：重复执行即全量重部署（代理容器会短暂重启，秒级中断）
# 前提：本机可免密 SSH 到清单内所有机器；远端已安装 docker

set -uo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
AGENT_DIR="$REPO_ROOT/agent"
SCHED_DIR="$REPO_ROOT/scheduler"
# 清单：统一用 hosts.txt（与 provision.sh 共用）；不存在时回退旧名 proxy-hosts.txt
HOSTS_FILE="${HOSTS_FILE:-$DEPLOY_DIR/hosts.txt}"
if [ ! -f "$HOSTS_FILE" ] && [ -f "$DEPLOY_DIR/proxy-hosts.txt" ]; then
    echo "WARN: 未找到 $HOSTS_FILE，回退使用旧清单 $DEPLOY_DIR/proxy-hosts.txt（建议合并为 hosts.txt）" >&2
    HOSTS_FILE="$DEPLOY_DIR/proxy-hosts.txt"
fi
REMOTE_DIR="${REMOTE_DIR:-/opt/proxy-pool}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
case "$IMAGE_TAG" in
    *[!A-Za-z0-9._-]*) fail "IMAGE_TAG contains unsafe characters: $IMAGE_TAG" ;;
esac

# 预构建镜像模式：拉 ghcr.io 镜像；否则在远端本地构建
if [ "${PREBUILT:-0}" = "1" ]; then
    UP_CMD='docker compose pull && docker compose up -d'
else
    UP_CMD='docker compose up -d --build'
fi
SSH_OPTS="-o ConnectTimeout=10 ${SSH_OPTS:-}"   # shellcheck disable=SC2086

# ---- 可选：排除某些 IP，不进后端池 ----
# 场景：机器上确实扫到了、但不想作为出口的 IP（管理口、回程未通的辅助 IP、临时网卡等）。
# 两种写法任选其一（可同时用）：
#   环境变量  EXCLUDE_IPS="1.2.3.4,5.6.7.8" ./deploy.sh
#   文件      deploy/exclude-ips.txt         # 一行一个，# 开头为注释
EXCLUDE_FILE="${EXCLUDE_FILE:-$DEPLOY_DIR/exclude-ips.txt}"
if [ -f "$EXCLUDE_FILE" ]; then
    while IFS= read -r _xl || [ -n "$_xl" ]; do
        _xl="${_xl%%#*}"; _xl="${_xl%$'\r'}"
        _xl="$(printf '%s' "$_xl" | tr -d '[:space:]')"
        [ -n "$_xl" ] && EXCLUDE_IPS="${EXCLUDE_IPS:-},${_xl}"
    done < "$EXCLUDE_FILE"
fi
is_excluded() {
    local ip="$1" e
    local -a arr=()
    IFS=',' read -r -a arr <<< "${EXCLUDE_IPS:-}" || true
    for e in "${arr[@]}"; do
        e="${e// /}"
        [ -n "$e" ] && [ "$e" = "$ip" ] && return 0
    done
    return 1
}

[ -d "$AGENT_DIR" ] || fail "agent/ not found under $REPO_ROOT"
[ -f "$HOSTS_FILE" ] || fail "hosts file not found: $HOSTS_FILE"
command -v rsync >/dev/null 2>&1 || fail "rsync is required locally"
command -v ssh >/dev/null 2>&1 || fail "ssh is required locally"

# ---- 读取目标机器清单（支持 # 注释与空行）----
TARGETS=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="${line%$'\r'}"
    line="$(echo "$line" | xargs 2>/dev/null || true)"
    [ -n "$line" ] && TARGETS+=("${line%% *}")   # 只取第一个字段：其后是 user/password/port
done < "$HOSTS_FILE"
[ "${#TARGETS[@]}" -gt 0 ] || fail "no targets found in $HOSTS_FILE"

# ---- 同行去重：同一台机器只写一行（root@IP 与 IP 视为同一台）----
# 不去重会导致后端出现重复 server 名（如 64-83-38-16i1 出现两次），
# haproxy 语法校验直接失败、assemble-config.sh 拒绝写入。
host_only() { local t="$1"; echo "${t##*@}"; }
UNIQ_TARGETS=(); SEEN_HOSTS=""
for t in "${TARGETS[@]}"; do
    h="$(host_only "$t")"
    case " $SEEN_HOSTS " in
        *" $h "*)
            echo "WARN: $HOSTS_FILE 中 $h 重复出现（写法不同也算重复，如 root@IP 与 IP），已跳过" >&2
            continue ;;
    esac
    SEEN_HOSTS="$SEEN_HOSTS $h"
    UNIQ_TARGETS+=("$t")
done
TARGETS=("${UNIQ_TARGETS[@]}")

tag_of() { local t="$1"; t="${t##*@}"; echo "$t" | tr '.' '-'; }

RESULTS_DIR="$(mktemp -d)"
trap 'rm -rf "$RESULTS_DIR"' EXIT

# ---- 单机部署（在后台子进程中执行，日志落入 $RESULTS_DIR）----
deploy_one() {
    local target="$1" tag log ips n
    tag="$(tag_of "$target")"
    log="$RESULTS_DIR/$tag.log"

    {
        echo "[$tag] checking docker on remote ..."
        ssh $SSH_OPTS "$target" 'command -v docker >/dev/null 2>&1' \
            || { echo "[$tag] FAIL: docker not found on $target (install docker first)"; return 1; }

        echo "[$tag] rsync $AGENT_DIR/ -> $target:$REMOTE_DIR/"
        rsync -az -e "ssh $SSH_OPTS" "$AGENT_DIR/" "$target:$REMOTE_DIR/" \
            || { echo "[$tag] FAIL: rsync failed"; return 1; }

        echo "[$tag] generating env and restarting containers ..."
        ssh $SSH_OPTS "$target" "cd $REMOTE_DIR && ./generate-env.sh && \
            (docker compose down --timeout 5 --remove-orphans >/dev/null 2>&1 || true) && \
            (docker ps -aq --filter 'name=proxy-' | xargs -r docker rm -f >/dev/null 2>&1 || true) && \
            export IMAGE_TAG='$IMAGE_TAG' && $UP_CMD" \
            || { echo "[$tag] FAIL: remote deploy failed"; return 1; }

        echo "[$tag] fetching real IP list ..."
        ips=$(ssh $SSH_OPTS "$target" "grep -E '^IP_[0-9]+=' $REMOTE_DIR/.env | cut -d= -f2") \
            || { echo "[$tag] FAIL: cannot read $REMOTE_DIR/.env"; return 1; }
        n=$(printf '%s\n' "$ips" | grep -c .)
        [ "$n" -gt 0 ] || { echo "[$tag] FAIL: no public IP found on $target"; return 1; }

        # ---- 出口自检：逐 IP 验证「以该 IP 真的能出网」 ----
        # 背景：generate-env.sh 只是 ip -4 -o addr 扫网卡，扫到不等于能出网。
        #       辅助 IP 无回程路由、3proxy bind 失败、IP 已回收但仍在网卡上等场景下，
        #       这些 IP 会被写进 HAProxy 后端，导致客户端轮询到它们时拿到
        #       BAD REQUEST / 连接失败——而 deploy 却显示 PASS。
        # 做法：远端用 curl --interface <ip> 直连检测站，回显 IP 与本 IP 一致才算通过。
        # 关闭：VERIFY_EGRESS=0 ./deploy.sh（跳过自检，保留全部 IP）
        : > "$RESULTS_DIR/$tag.bad"
        if [ "${VERIFY_EGRESS:-1}" = "1" ]; then
            echo "[$tag] verifying egress per IP ..."
            ssh $SSH_OPTS "$target" \
                "REMOTE_DIR='$REMOTE_DIR' CHECK_URL='${CHECK_URL:-http://ifconfig.me}' bash -s" \
                > "$RESULTS_DIR/$tag.egress" 2>>"$log" <<'REMOTE_EGRESS' || true
command -v curl >/dev/null 2>&1 || exit 0
grep -E '^IP_[0-9]+=' "$REMOTE_DIR/.env" | cut -d= -f2 | while read -r ip; do
    [ -n "$ip" ] || continue
    got=$(curl -s --max-time 8 --interface "$ip" "$CHECK_URL" 2>/dev/null | tr -d '[:space:]')
    if [ "$got" = "$ip" ]; then
        printf '%s\tOK\n' "$ip"
    else
        printf '%s\tBAD:%s\n' "$ip" "${got:-no-response}"
    fi
done
REMOTE_EGRESS
            # 检出结果非空才据此过滤（远端没装 curl 时不误伤）
            if [ -s "$RESULTS_DIR/$tag.egress" ]; then
                : > "$RESULTS_DIR/$tag.ips"
                while IFS=$'\t' read -r ip st; do
                    [ -n "$ip" ] || continue
                    if [ "$st" = "OK" ]; then
                        printf '%s\n' "$ip" >> "$RESULTS_DIR/$tag.ips"
                    else
                        printf '%s(%s)\n' "$ip" "${st#BAD:}" >> "$RESULTS_DIR/$tag.bad"
                    fi
                done < "$RESULTS_DIR/$tag.egress"
                # 整台机器所有出口都不通 -> 视为部署失败，避免把坏节点塞进后端池
                if [ ! -s "$RESULTS_DIR/$tag.ips" ]; then
                    echo "[$tag] FAIL: 所有出口 IP 自检未通过"
                    return 1
                fi
            else
                printf '%s\n' "$ips" > "$RESULTS_DIR/$tag.ips"
            fi
        else
            printf '%s\n' "$ips" > "$RESULTS_DIR/$tag.ips"
        fi
        return 0
    } > "$log" 2>&1
}

echo "Deploying agent/ to ${#TARGETS[@]} machine(s) in parallel ..."
for t in "${TARGETS[@]}"; do
    tag="$(tag_of "$t")"
    ( trap - EXIT; deploy_one "$t"; echo $? > "$RESULTS_DIR/$tag.code" ) &
done
wait

# ---- 汇总结果，用真实 IP 生成后端配置 ----
OUT="$SCHED_DIR/haproxy-servers.cfg"
: > "$OUT"
OK=0; FAILED=0; EXC=0
for t in "${TARGETS[@]}"; do
    tag="$(tag_of "$t")"
    if [ "$(cat "$RESULTS_DIR/$tag.code" 2>/dev/null)" = "0" ] && [ -f "$RESULTS_DIR/$tag.ips" ]; then
        OK=$((OK + 1))
        n=0; kept=""; skipped=""
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            if is_excluded "$ip"; then
                EXC=$((EXC + 1))
                skipped="${skipped:+$skipped,}$ip"
                continue
            fi
            n=$((n + 1))
            kept="${kept:+$kept,}$ip"
            echo "    server ${tag}i${n} ${ip}:1080 check inter 3s fall 3 rise 2" >> "$OUT"
        done < "$RESULTS_DIR/$tag.ips"
        # 打印「机器 -> 出口 IP」映射，便于核对某个后端 IP 到底来自哪台机器
        printf 'PASS  %-22s -> %s%s\n' "$tag" "${kept:-（无可用出口）}" \
            "${skipped:+   已排除: $skipped}"
    else
        FAILED=$((FAILED + 1))
        echo "FAIL  $tag"
        sed 's/^/    /' "$RESULTS_DIR/$tag.log" 2>/dev/null
    fi
done

TOTAL=$(grep -c . "$OUT" 2>/dev/null || echo 0)
echo
echo "Summary: $OK machine(s) OK, $FAILED failed, $TOTAL backends -> $OUT"
[ "$EXC" -gt 0 ] && echo "         ($EXC 个 IP 被 EXCLUDE_IPS / exclude-ips.txt 排除，未写入后端)"
[ "$BAD_N" -eq 0 ] || echo "         ($BAD_N 台机器有出口 IP 自检不通，已自动剔除，见上方「自检不通已剔除」)"
[ "$FAILED" -eq 0 ] || { echo "Fix the failures above, then re-run."; exit 1; }
[ "$TOTAL" -gt 0 ] || fail "no backends generated"

# ---- 调度机侧：本机可写 /etc/haproxy 则自动组装并 reload ----
if [ -d /etc/haproxy ] && [ -w /etc/haproxy ]; then
    "$SCHED_DIR/assemble-config.sh"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reload haproxy || fail "systemctl reload haproxy failed"
        echo "haproxy reloaded. Done."
    else
        echo "systemd not detected - reload haproxy manually."
    fi
elif [ -d /etc/haproxy ]; then
    echo "NOTE: /etc/haproxy exists but not writable (need root). Run manually:"
    echo "  sudo $SCHED_DIR/assemble-config.sh && sudo systemctl reload haproxy"
else
    echo "NOTE: no /etc/haproxy on this machine (not the scheduler?)."
    echo "On the scheduler run:"
    echo "  sudo $SCHED_DIR/assemble-config.sh && sudo systemctl reload haproxy"
    echo "(or copy $SCHED_DIR/{assemble-config.sh,haproxy-servers.cfg} there first)"
fi
