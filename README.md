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
│   ├── Dockerfile             # 3proxy 镜像（ubuntu:22.04 + 官方预编译 deb）
│   ├── entrypoint.sh          # 按环境变量生成 3proxy 配置并前台启动（支持可选密码认证）
│   ├── generate-env.sh        # 扫描公网 IP，生成 .env 与 docker-compose.yml
│   ├── docker-compose.yml     # 生成物：按本机 IP 数重写为 proxy-01..proxy-N
│   ├── socks-credentials.env  # SOCKS5 访问认证凭证（可选），已 gitignore
│   └── .env                   # 生成物，已 gitignore
├── scheduler/                 # 仅在调度机使用
│   ├── generate-haproxy.sh    # 由 machines.txt 生成后端列表
│   ├── assemble-config.sh     # 组装 /etc/haproxy/haproxy.cfg 并校验
│   ├── machines.txt           # 机器清单（手工/离线模式）
│   └── haproxy-servers.cfg    # 生成物，已 gitignore
├── deploy/
│   ├── deploy.sh              # 一键多机部署（并行 rsync + 拉真实 IP）
│   └── proxy-hosts.txt        # 代理机 SSH 清单
├── .github/workflows/
│   └── release.yml            # push main 自动发版 + 推镜像到 ghcr.io
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

安全提示：3proxy 默认配置为 `auth iponly` + `allow * *`，即**无认证**。请务必通过防火墙/安全组将 1080 端口限制为调度机 IP 可访问，否则等同于开放代理。也可开启用户名/密码认证（见「访问认证（可选）」），或两者叠加。

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

# 使用 ghcr.io 预构建镜像，远端不执行 docker build
PREBUILT=1 ./deploy/deploy.sh
PREBUILT=1 IMAGE_TAG=v1.0.0 ./deploy/deploy.sh   # 锁定版本，默认 latest
```

> `PREBUILT=1` 时各代理机从 ghcr.io 拉取镜像。若镜像不是 public，需先在每台代理机执行 `docker login ghcr.io`。

脚本会输出 `Summary: N machine(s) OK, 0 failed, M backends`。若本机 `/etc/haproxy` 可写，会自动执行 `assemble-config.sh` 并 `systemctl reload haproxy`；否则打印需要手动执行的命令。

重复执行即全量重部署（代理容器会短暂重启，秒级中断）。

### 非 32 IP 机器（少卡机器）

`agent/generate-env.sh` 会自动按**本机实际检测到的公网 IP 数量**生成对应个数的 `docker-compose.yml` 服务（proxy-01..proxy-N），无需手工删改。例如 2 IP 机器会起 proxy-01/proxy-02，1 IP 机器只起 proxy-01；每容器 host 网络绑定 `IP:1080`，同机多 IP 互不冲突。

若调度机 HAProxy 与代理机**同机部署**（3proxy 已占用本机各 IP 的 1080），入口需换空闲端口：

```bash
sudo ENTRY_PORT=2080 ./assemble-config.sh && sudo systemctl reload haproxy
```

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
| `SOCKS_USER` | 否 | 空 | SOCKS5 用户名；与 `SOCKS_PASS` **同时提供**才启用密码认证 |
| `SOCKS_PASS` | 否 | 空 | SOCKS5 密码（明文写入容器内配置，勿含双引号） |
| `ALLOW_SRC` | 否 | `*` | 限定客户端来源 IP/网段（逗号分隔），启用密码后可叠加白名单 |

### 访问认证（可选）

默认 `auth iponly` + `allow * *`，即**无认证**。要开启用户名/密码认证，编辑 `agent/socks-credentials.env`：

```
SOCKS_USER=albert
SOCKS_PASS=ChangeMe_StrongPass
ALLOW_SRC=
```

两项都填即生效（`auth strong`），任一为空则自动回退为无认证模式，**不影响现有部署**。该文件已 gitignore，不会被提交。

**改密码**（一次改动，全池生效）：

```bash
# 1. 本机编辑 agent/socks-credentials.env 的 SOCKS_PASS
# 2. 一键下发到所有代理机并重建容器
./deploy/deploy.sh

# 若手工部署，则在每台代理机上：
docker compose up -d --force-recreate
```

> HAProxy 无需改动：它是 TCP 透传 + 纯连接探测（`tcp-check connect`），不关心 SOCKS5 认证；容器重建期间的几秒中断会被健康检查自动剔除/恢复。密码走环境变量，**不需要重新构建镜像**。

客户端连接：

```bash
curl --socks5-hostname albert:ChangeMe_StrongPass@<入口IP>:2080 http://ifconfig.me
```

Firefox 支持 SOCKS5 账号密码；Chrome/Edge 系统代理不支持，需借助本地转发工具。

> 安全提示：SOCKS5 密码为明文传输，只能挡住端口扫描；请**保留防火墙/安全组白名单**，或填 `ALLOW_SRC` 限源，形成"密码 + 白名单"双保险。

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
| 改 SOCKS5 密码 | 编辑 `agent/socks-credentials.env` → 重跑 `deploy/deploy.sh`（HAProxy 无需改动） |
| 重装 HAProxy 配置 | **调度机与代理机同机时必须带入口端口**：`sudo ENTRY_PORT=2080 ./scheduler/assemble-config.sh`。漏掉会写成 `bind *:1080`，与 3proxy 抢端口导致入口无监听（2080 上 `ss` 查不到、curl 报 Connection refused） |
| 单 IP 故障 | 无需干预，HAProxy 自动剔除并自动恢复 |
| 查看后端状态 | `ssh -L 8404:127.0.0.1:8404` 后访问状态页 |

故障影响：

| 故障 | 影响 | 处理 |
|------|------|------|
| 调度机宕机 | 全池不可用 | 快速恢复，或做主备 |
| 单机宕机 | 该机全部 IP 不可用 | HAProxy 自动剔除 |
| 单 IP 故障 | 该 IP 不可用 | HAProxy 自动剔除 |
| `up` 报 `container name "/proxy-XX" already in use` | 旧容器残留：compose 项目名=目录名，曾在别的目录（如 `/opt/proxy-pool/agent`）部署过的同名容器，当前项目的 `down` 看不见也删不掉 | `deploy.sh` 已内置自动清理（`down --remove-orphans` + 按名强删 `proxy-*`）；手工部署时先执行 `docker ps -aq --filter 'name=proxy-' \| xargs -r docker rm -f` 再 `up` |

---

## 已知约束

1. **代理机 IP 数量不限（不再硬编码 32）。** `generate-env.sh` 会按本机实际检测到的公网 IP 数量自动生成对应数量的 `docker-compose.yml` 服务（proxy-01..proxy-N）；检测到 0 个公网 IP 时直接报错退出。每容器绑定 `IP:1080`（host 网络），同机多 IP 互不冲突。
2. **路径 B 要求 IP 连续。** 手工模式下后端 IP 由起始 IP 推算，不连续的实际 IP 会导致后端地址错误；请改用路径 A。
3. **IP 扫描依赖 `ip` 命令。** 脚本会过滤 `127.`、`10.`、`192.168.`、`172.16-31.`、`169.254.` 网段，其余均视为公网 IP；若宿主机有其他非公网地址需手动调整 `.env`。
4. **`.env` 与 `haproxy-servers.cfg` 不入库。** 二者含真实出口 IP，已在 `.gitignore` 中排除。

---

## 发布与镜像（Releases / Packages）

`.github/workflows/release.yml` 在**每次 push 到 `main`** 时自动发版，产出两件东西：

| 产物 | 位置 | 内容 |
|------|------|------|
| Release | `github.com/jushenzhidao/proxy-pool/releases` | 版本号 tag + 由 commit 生成的 changelog |
| 容器镜像 | `ghcr.io/jushenzhidao/proxy-pool` | 3proxy 镜像，打上版本号与 `latest` 两个 tag |

执行顺序：`release` job 递增版本号 → 创建 tag → 创建 Release；随后 `image` job 构建镜像、推送 ghcr.io、跑启动冒烟测试。

### 版本号规则

- 只自增 **patch**：`v1.2.3` → `v1.2.4`。仓库零 tag 时从 `v0.0.0` 起算，首次发版为 `v0.0.1`。
- 需要 minor/major 时**手动打 tag**（`git tag v2.0.0 && git push origin v2.0.0`），workflow 会以该 tag 为新基线继续自增。
- `latest` 是可变 tag，每次发版强制移动。下游若固定引用 `latest` 会随之跳版本，生产环境建议锁定具体版本号。

### 跳过与手动触发

```bash
git commit -m "chore: 调文档 [skip release]"   # 提交信息含 [skip release] 则跳过发版
```

也可在 GitHub Actions 页面用 **Run workflow**（`workflow_dispatch`）手动触发。

### 使用预构建镜像

```bash
docker pull ghcr.io/jushenzhidao/proxy-pool:v0.0.1
```

一键部署时改用预构建镜像（远端不执行 `docker build`）：

```bash
PREBUILT=1 IMAGE_TAG=v0.0.1 ./deploy/deploy.sh
```

首次发版后需要注意：GitHub Packages 的镜像默认**继承仓库可见性**，私有仓库产出的镜像也是私有的，需在 package 设置中改为 public，或在各代理机执行 `docker login ghcr.io` 后使用。

---

## 相关文档

- [`docs/proxy-pool-solution.md`](docs/proxy-pool-solution.md)：方案设计文档，含各配置文件逐项说明、性能指标与故障处理矩阵。
