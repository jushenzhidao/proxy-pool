# 多机多IP代理池解决方案

> 注：本文为方案设计稿（历史版本），其中"每机固定 32 IP""硬编码 32 个 compose 服务"等描述已迭代。
> 当前实现以 [README](../README.md) 为准：容器数量按机器实际公网 IP 数自动生成；
> 并支持可选的 SOCKS5 用户名/密码认证（配置 `agent/socks-credentials.env`）。

## 1. 方案概述

### 1.1 目标
- 跨多台物理机搭建高性能 SOCKS5 代理池
- 每台机器绑定 32 个出口 IP，自动发现、自动配置
- 客户端通过统一域名接入，轮询分配出口 IP
- 故障自动剔除，简化运维

### 1.2 核心设计
| 项目 | 方案 |
|------|------|
| 代理协议 | SOCKS5 |
| 调度策略 | 轮询（Round Robin） |
| 代理软件 | 3proxy（轻量、高性能） |
| 调度层 | HAProxy（TCP模式、健康检查） |
| 容器化 | Docker Compose + host网络 |
| IP配置 | 宿主机脚本自动生成 .env |
| 服务发现 | 静态配置 + 脚本生成 |

---

## 2. 技术架构

### 2.1 整体架构图

```
                         客户端
                            |
                            v
              proxy-pool.example.com:1080
                            |
                            v
                   ┌─────────────────┐
                   │   调度机（单台）   │
                   │  HAProxy :1080   │
                   │  轮询 + 健康检查   │
                   └────────┬────────┘
                            |
        ┌───────────────────┼───────────────────┐
        |                   |                   |
        v                   v                   v
   ┌─────────┐         ┌─────────┐         ┌─────────┐
   │  机器1   │         │  机器2   │         │  机器N   │
   │3proxy×32│         │3proxy×32│         │3proxy×32│
   │IP1~IP32 │         │IP1~IP32 │         │IP1~IP32 │
   └─────────┘         └─────────┘         └─────────┘
```

### 2.2 数据流

```
客户端 --SOCKS5--> 域名:1080 --> HAProxy轮询 --> 某机器某IP:1080 --> 目标网站
       ↑______________________________________________|
                    出口IP = 该机器该IP
```

### 2.3 组件职责

| 组件 | 位置 | 职责 |
|------|------|------|
| DNS | 域名服务商 | A记录指向调度机IP |
| HAProxy | 调度机 | TCP转发、轮询、健康检查、故障剔除 |
| 3proxy容器 | 各代理机 | SOCKS5代理、绑定出口IP |
| 生成脚本 | 各机器 | 自动发现IP、生成配置 |

---

## 3. 详细配置

### 3.1 代理机配置（每台机器相同）

#### 3.1.1 目录结构

```
/opt/proxy-pool/
├── Dockerfile              # 3proxy镜像定义
├── entrypoint.sh           # 容器启动脚本
├── docker-compose.yml      # 32个服务定义
├── generate-env.sh         # IP发现脚本
└── .env                    # 生成的IP列表
```

#### 3.1.2 Dockerfile

```dockerfile
FROM alpine:3.19

RUN apk add --no-cache 3proxy

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

#### 3.1.3 entrypoint.sh

```bash
#!/bin/sh
set -e

BIND_IP="${BIND_IP:?BIND_IP required}"
OUT_IP="${OUT_IP:-$BIND_IP}"
PORT="${PORT:-1080}"

cat > /etc/3proxy/3proxy.cfg <<EOF
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
log /dev/stdout
auth iponly
allow * *
proxy -p${PORT} -i${BIND_IP} -e${OUT_IP}
maxconn 10000
EOF

exec 3proxy /etc/3proxy/3proxy.cfg
```

#### 3.1.4 docker-compose.yml

```yaml
version: "3.8"

x-proxy-defaults: &proxy-defaults
  build: .
  network_mode: host
  restart: unless-stopped
  environment:
    PORT: 1080
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"

services:
  proxy-01:
    <<: *proxy-defaults
    container_name: proxy-01
    environment:
      BIND_IP: ${IP_1}

  proxy-02:
    <<: *proxy-defaults
    container_name: proxy-02
    environment:
      BIND_IP: ${IP_2}

  # ... 重复到 proxy-32

  proxy-32:
    <<: *proxy-defaults
    container_name: proxy-32
    environment:
      BIND_IP: ${IP_32}
```

#### 3.1.5 generate-env.sh

```bash
#!/bin/bash
# 扫描宿主机IP，生成.env

ENV_FILE=".env"
> "$ENV_FILE"

IPS=$(ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | \
      grep -v '^127\.' | grep -v '^172\.1[6-9]\.' | \
      grep -v '^172\.2[0-9]\.' | grep -v '^172\.3[01]\.' | \
      grep -v '^10\.' | grep -v '^192\.168\.' | sort)

COUNT=0
for ip in $IPS; do
    COUNT=$((COUNT + 1))
    echo "IP_${COUNT}=${ip}" >> "$ENV_FILE"
done

echo "IP_COUNT=${COUNT}" >> "$ENV_FILE"
echo "Generated ${COUNT} IPs"
```

#### 3.1.6 启动命令

```bash
cd /opt/proxy-pool
./generate-env.sh
docker compose build
docker compose up -d
```

---

### 3.2 调度机配置

#### 3.2.1 目录结构

```
/etc/haproxy/
└── haproxy.cfg              # 最终生效配置

/opt/proxy-pool/
├── generate-haproxy.sh      # 后端生成脚本
├── assemble-config.sh       # 配置组装脚本
└── machines.txt             # 机器IP列表
```

#### 3.2.2 machines.txt 格式

```
机器名 起始IP
machine1 203.0.113.1
machine2 203.0.114.1
machine3 203.0.115.1
```

#### 3.2.3 generate-haproxy.sh

```bash
#!/bin/bash
# 生成HAProxy后端配置

OUTPUT="haproxy-servers.cfg"
> "$OUTPUT"

while read -r name start_ip; do
    [ -z "$name" ] && continue
    
    base=$(echo "$start_ip" | cut -d. -f1-3)
    last=$(echo "$start_ip" | cut -d. -f4)
    
    for i in {0..31}; do
        ip="${base}.$((last + i))"
        echo "    server ${name}i$((i+1)) ${ip}:1080 check inter 3s fall 3 rise 2" >> "$OUTPUT"
    done
done < machines.txt

echo "Generated $(wc -l < "$OUTPUT") backends"
```

#### 3.2.4 assemble-config.sh

```bash
#!/bin/bash
# 生成完整haproxy.cfg

cat > /etc/haproxy/haproxy.cfg <<'EOF'
global
    maxconn 100000
    log /dev/null local0

defaults
    mode tcp
    retries 3
    timeout connect 5s
    timeout client 300s
    timeout server 300s

frontend socks5
    bind *:1080
    default_backend proxies

backend proxies
    balance roundrobin
    option tcp-check
    tcp-check connect port 1080
EOF

cat haproxy-servers.cfg >> /etc/haproxy/haproxy.cfg
echo "haproxy.cfg updated"
```

#### 3.2.5 更新命令

```bash
cd /opt/proxy-pool
./generate-haproxy.sh
./assemble-config.sh
systemctl reload haproxy
```

---

### 3.3 域名配置

| 项目 | 值 |
|------|-----|
| 记录类型 | A记录 |
| 主机记录 | proxy-pool |
| 记录值 | 调度机公网IP |
| TTL | 300 |

---

## 4. 客户端使用

### 4.1 无认证

```bash
curl --socks5 proxy-pool.example.com:1080 http://target.com
```

### 4.2 指定IP测试

```bash
curl --socks5 203.0.113.5:1080 http://ifconfig.me
```

---

## 5. 运维操作

### 5.1 日常维护

| 场景 | 操作 |
|------|------|
| 加机器 | machines.txt加行 → 重新生成HAProxy配置 → reload |
| 减机器 | machines.txt删行 → 重新生成 → reload |
| 机器加IP | 该机器重新运行generate-env.sh → docker compose up -d |
| 机器减IP | 该机器重新运行generate-env.sh → docker compose up -d |
| 某IP故障 | HAProxy自动剔除，修复后自动恢复 |

### 5.2 验证命令

| 验证项 | 命令 | 预期结果 |
|--------|------|----------|
| 单IP出口 | curl --socks5 IP:1080 ifconfig.me | 返回该IP |
| 轮询效果 | 多次curl --socks5 域名:1080 ifconfig.me | 返回不同IP |
| 健康检查 | 停某容器，看HAProxy状态页 | 该后端DOWN |

---

## 6. 性能指标

| 指标 | 数值 | 说明 |
|------|------|------|
| HAProxy并发 | 100,000+ | 单调度机支撑能力 |
| 3proxy单实例 | 10,000连接 | maxconn配置 |
| 跨公网延迟 | +1~5ms | 可接受 |
| 出口IP数量 | 32×N | N为机器数 |

---

## 7. 故障处理

| 故障 | 影响 | 处理 |
|------|------|------|
| 调度机宕机 | 全池不可用 | 快速重启或主备部署 |
| 某机器宕机 | 该机器32个IP不可用 | HAProxy自动剔除 |
| 某IP故障 | 该IP不可用 | HAProxy自动剔除 |
| 网络分区 | 部分机器不可用 | HAProxy健康检查自动处理 |

---

## 8. 方案优势

| 优势 | 说明 |
|------|------|
| 简单 | 每台机器相同操作，一条命令启动 |
| 高性能 | host网络无NAT，TCP内核级转发 |
| 可扩展 | 加机器只需改machines.txt |
| 自动剔除 | HAProxy健康检查，故障自动下线 |
| 无依赖 | 仅Docker+HAProxy，无复杂组件 |
