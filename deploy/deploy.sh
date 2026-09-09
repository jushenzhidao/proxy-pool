#!/bin/bash
# 一键多机部署：并行推送 agent/ 到所有代理机并启动，拉取各机器真实出口 IP，
# 直接生成 HAProxy 后端配置（不依赖 machines.txt 的"IP 连续"假设）。
#
# 用法：
#   ./deploy.sh                                        # 按 proxy-hosts.txt 全量部署
#   SSH_OPTS="-p 2222 -i ~/.ssh/deploy_key" ./deploy.sh  # 自定义 SSH 参数
#   REMOTE_DIR=/data/proxy-pool ./deploy.sh              # 自定义远程目录
#   PREBUILT=1 ./deploy.sh                               # 拉 ghcr.io 预构建镜像，不在远端 build
#   PREBUILT=1 IMAGE_TAG=v1.0.0 ./deploy.sh              # 锁定镜像版本（默认 latest）
#
# 流程：远端检查 docker -> rsync agent/ -> 生成 .env 并重启容器 -> 拉回 IP 清单
#       -> 生成 scheduler/haproxy-servers.cfg -> 本机若可写 /etc/haproxy 则自动组装+reload
#
# 幂等：重复执行即全量重部署（代理容器会短暂重启，秒级中断）
# 前提：本机可免密 SSH 到清单内所有机器；远端已安装 docker

set -uo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
AGENT_DIR="$REPO_ROOT/agent"
SCHED_DIR="$REPO_ROOT/scheduler"
HOSTS_FILE="$DEPLOY_DIR/proxy-hosts.txt"
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

fail() { echo "ERROR: $*" >&2; exit 1; }

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
    [ -n "$line" ] && TARGETS+=("$line")
done < "$HOSTS_FILE"
[ "${#TARGETS[@]}" -gt 0 ] || fail "no targets found in $HOSTS_FILE"

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
            (docker compose down --timeout 5 >/dev/null 2>&1 || true) && \
            export IMAGE_TAG='$IMAGE_TAG' && $UP_CMD" \
            || { echo "[$tag] FAIL: remote deploy failed"; return 1; }

        echo "[$tag] fetching real IP list ..."
        ips=$(ssh $SSH_OPTS "$target" "grep -E '^IP_[0-9]+=' $REMOTE_DIR/.env | cut -d= -f2") \
            || { echo "[$tag] FAIL: cannot read $REMOTE_DIR/.env"; return 1; }
        n=$(printf '%s\n' "$ips" | grep -c .)
        [ "$n" -gt 0 ] || { echo "[$tag] FAIL: no public IP found on $target"; return 1; }

        printf '%s\n' "$ips" > "$RESULTS_DIR/$tag.ips"
        echo "[$tag] OK: $n IPs exported"
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
OK=0; FAILED=0
for t in "${TARGETS[@]}"; do
    tag="$(tag_of "$t")"
    if [ "$(cat "$RESULTS_DIR/$tag.code" 2>/dev/null)" = "0" ] && [ -f "$RESULTS_DIR/$tag.ips" ]; then
        OK=$((OK + 1))
        echo "PASS  $tag"
        n=0
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            n=$((n + 1))
            echo "    server ${tag}i${n} ${ip}:1080 check inter 3s fall 3 rise 2" >> "$OUT"
        done < "$RESULTS_DIR/$tag.ips"
    else
        FAILED=$((FAILED + 1))
        echo "FAIL  $tag"
        sed 's/^/    /' "$RESULTS_DIR/$tag.log" 2>/dev/null
    fi
done

TOTAL=$(grep -c . "$OUT" 2>/dev/null || echo 0)
echo
echo "Summary: $OK machine(s) OK, $FAILED failed, $TOTAL backends -> $OUT"
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
