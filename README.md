# proxy-pool

跨多机的高性能 SOCKS5 代理池。每台代理机绑定 32 个出口 IP，调度机用 HAProxy 做 TCP 层轮询与健康检查，客户端通过单一入口接入，故障节点自动剔除。

- 代理协议：SOCKS5（3proxy，`socks` 模式）
- 调度策略：轮询（roundrobin）
- 容器网络：`network_mode: host`，无 NAT 开销
- 出口 IP 总数：32 × 机器数

---

## 架构

```
                            客户端
                              |
                              v
                proxy-pool.example.com:1080
                              |
                              v
                    ┌────────────────────┐
                    │   调度机（单台）      │
                    │   HAProxy :1080     │
                    │  TCP 转发 / 轮询     │
                    │  健康检查 / 自动剔除   │
                    └─────────┬──────────┘
                              |
          ┌───────────────────┼───────────────────┐
          v                   v                   v
    ┌──────────┐        ┌──────────┐        ┌──────────┐
    │  机器1    │        │  机器2    │        │  机器N    │
    │3proxy ×32│        │3proxy ×32│        │3proxy ×32│
    │IP1~IP32  │        │IP1~IP32  │        │IP1~IP32  │
    └──────────┘        └──────────┘        └──────────┘
```

数据流：

```
客户端 --SOCKS5--> 入口:1080 --> HAProxy 轮询 --> 某机器某IP:1080 --> 目标站点
                                                     ↑
                                              出口 IP 即该地址
```

组件职责：

| 组件 | 位置 | 职责 |
|------|------|------|
| HAProxy | 调度机 | TCP 转发、轮询、健康检查、故障剔除 |
| 3proxy 容器 | 各代理机 | SOCKS5 代理，绑定单个出口 IP |
| `agent/generate-env.sh` | 各代理机 | 扫描宿主机公网 IP，生成 `.env` |
| `scheduler/*.sh` | 调度机 | 生成并组装 HAProxy 配置 |
| `deploy/deploy.sh` | 任意运维机 | 一键并行部署全部代理机 |

---

## 目录结构

```
proxy-pool/
├── agent/                     # 部署到每台代理机
│   ├── Dockerfile             # 基于 alpine:3.19 的 3proxy 镜像
│   ├── entrypoint.sh          # 按环境变量生成 3proxy 配置并前台启动
│   ├── docker-compose.yml     # proxy-01 ~ proxy-32 共 32 个服务
│   ├── generate-env.sh        # 扫描公网 IP，生成 .env（IP_1..IP_N）
│   └── .env                   # 生成物，已 gitignore
├── scheduler/                 # 仅在调度机使用
│   ├── generate-haproxy.sh    # 由 machines.txt 生成后端列表
│   ├── assemble-config.sh     # 组装 /etc/haproxy/haproxy.cfg 并校验
│   ├── machines.txt           # 机器清单（手工/离线模式）
│   └── haproxy-servers.cfg    # 生成物，已 gitignore
├── deploy/
│   ├── deploy.sh              # 一键多机部署（并行 rsync + 拉真实 IP）
│   └── proxy-hosts.txt        # 代理机 SSH 清单
└── docs/
    └── proxy-pool-solution.md # 方案设计文档（含配置逐项说明）
```

---

## 前置条件

| 角色 | 要求 |
|------|------|
| 代理机 | Docker + Docker Compose 插件；`iproute2`（提供 `ip` 命令）；32 个公网 IPv4 |
| 调度机 | HAProxy 2.x；systemd（可选，用于 reload） |
| 运维机 | `rsync`、`ssh`；到所有代理机免密 SSH；到调度机有 `/etc/haproxy` 写权限（自动 reload 时） |

安全提示：3proxy 配置为 `auth iponly` + `allow * *`，即**无认证**。请务必通过防火墙/安全组将 1080 端口限制为调度机 IP 可访问，否则等同于开放代理。

---

## 快速开始

### 路径 A：一键部署（推荐）

`deploy/deploy.sh` 会并行推送 `agent/` 到清单内所有机器、生成 `.env`、启动容器，并**拉取各机器真实出口 IP** 直接生成后端配置——不依赖"IP 连续"假设。

```bash
# 1. 填写代理机清单
cat > deploy/proxy-hosts.txt <<'EOF'
root@203.0.113.11
root@203.0.113.12
root@203.0.113.13
EOF

# 2. 执行部署（非 22 端口或指定密钥时用 SSH_OPTS）
SSH_OPTS="-p 2222 -i ~/.ssh/deploy_key" ./deploy/deploy.sh

# 自定义远程安装目录
REMOTE_DIR=/data/proxy-pool ./deploy/deploy.sh
```

脚本会输出 `Summary: N machine(s) OK, 0 failed, M backends`。若本机 `/etc/haproxy` 可写，会自动执行 `assemble-config.sh` 并 `systemctl reload haproxy`；否则打印需要手动执行的命令。

重复执行即全量重部署（代理容器会短暂重启，秒级中断）。

### 路径 B：手工部署

适用于机器 IP 段已知且连续、或无法从运维机直连全部代理机的场景。

**1. 各代理机（每台执行相同操作）**

```bash
mkdir -p /opt/proxy-pool
# 拷贝 agent/ 下 4 个文件到该目录
cd /opt/proxy-pool
./generate-env.sh          # 生成 .env；不足 32 个 IP 会告警
docker compose build
docker compose up -d
```

**2. 调度机**

```bash
# 填写机器清单：机器名 + 起始 IP
cat > /opt/proxy-pool/machines.txt <<'EOF'
machine1 203.0.113.1
machine2 203.0.114.1
EOF

cd /opt/proxy-pool
./generate-haproxy.sh
sudo ./assemble-config.sh   # 写入 /etc/haproxy/haproxy.cfg 并做语法校验
sudo systemctl reload haproxy
```

**3. DNS**

| 项目 | 值 |
|------|-----|
| 记录类型 | A |
| 主机记录 | `proxy-pool` |
| 记录值 | 调度机公网 IP |
| TTL | 300 |

---

## 配置说明

### `scheduler/machines.txt`

```
# 格式：机器名 起始IP
machine1 203.0.113.1
```

约定每台机器的 32 个出口 IP 从起始 IP 起连续递增，**起始 IP 的第四段不得大于 224**（否则跨 255 边界，脚本会报错退出）。走路径 A 时无需维护此文件。

### `deploy/proxy-hosts.txt`

```
# 一行一台，格式 [user@]host；# 开头为注释
root@203.0.113.11
```

端口与密钥用 `SSH_OPTS` 传入，不写在文件里。

### 容器环境变量

| 变量 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `BIND_IP` | 是 | — | SOCKS5 监听地址，host 网络下即宿主机出口 IP |
| `OUT_IP` | 否 | 同 `BIND_IP` | 出口绑定地址 |
| `PORT` | 否 | 1080 | 监听端口 |

### HAProxy 关键参数

- `balance roundrobin`：轮询分发
- `tcp-check connect port 1080` + `check inter 3s fall 3 rise 2`：3 秒探测、连续 3 次失败剔除、连续 2 次成功恢复
- `maxconn 100000`，`timeout client/server 300s`
- 状态页监听 `127.0.0.1:8404`（`listen stats` 段必须保持在配置最前，后端 server 行追加在文件末尾）。远程查看：

```bash
ssh -L 8404:127.0.0.1:8404 <调度机>   # 然后访问 http://127.0.0.1:8404/stats
```

---

## 验证

```bash
# 单 IP 出口是否正确
curl --socks5 203.0.113.5:1080 http://ifconfig.me

# 轮询是否生效（多次执行应返回不同 IP）
for i in $(seq 1 8); do curl -s --socks5 proxy-pool.example.com:1080 http://ifconfig.me; echo; done
```

| 验证项 | 命令 | 预期 |
|--------|------|------|
| 单 IP 出口 | `curl --socks5 IP:1080 ifconfig.me` | 返回该 IP |
| 轮询效果 | 多次请求统一入口 | 返回不同 IP |
| 健康检查 | 停掉某容器后看状态页 | 对应后端 DOWN |

---

## 日常运维

| 场景 | 操作 |
|------|------|
| 加机器 | `proxy-hosts.txt` 加行 → 重跑 `deploy/deploy.sh` |
| 减机器 | `proxy-hosts.txt` 删行 → 重跑 `deploy/deploy.sh` |
| 某台机器 IP 变更 | 该机器重跑 `generate-env.sh` + `docker compose up -d`，再重跑 `deploy.sh` 刷新后端 |
| 单 IP 故障 | 无需干预，HAProxy 自动剔除并自动恢复 |
| 查看后端状态 | `ssh -L 8404:127.0.0.1:8404` 后访问状态页 |

故障影响：

| 故障 | 影响 | 处理 |
|------|------|------|
| 调度机宕机 | 全池不可用 | 快速恢复，或做主备 |
| 单机宕机 | 该机 32 个 IP 不可用 | HAProxy 自动剔除 |
| 单 IP 故障 | 该 IP 不可用 | HAProxy 自动剔除 |

---

## 已知约束

1. **代理机必须恰好 32 个公网 IP。** `docker-compose.yml` 硬编码 32 个服务，且用 `${IP_N:?...}` 强制校验。IP 不足时 `generate-env.sh` 会告警、`docker compose up` 会直接失败；IP 多于 32 时多余的会被忽略。非 32 卡的机器需自行增删 compose 中的服务定义。
2. **路径 B 要求 IP 连续。** 手工模式下后端 IP 由起始 IP 推算，不连续的实际 IP 会导致后端地址错误；请改用路径 A。
3. **IP 扫描依赖 `ip` 命令。** 脚本会过滤 `127.`、`10.`、`192.168.`、`172.16-31.`、`169.254.` 网段，其余均视为公网 IP；若宿主机有其他非公网地址需手动调整 `.env`。
4. **`.env` 与 `haproxy-servers.cfg` 不入库。** 二者含真实出口 IP，已在 `.gitignore` 中排除。

---

## 相关文档

- [`docs/proxy-pool-solution.md`](docs/proxy-pool-solution.md)：方案设计文档，含各配置文件逐项说明、性能指标与故障处理矩阵。
