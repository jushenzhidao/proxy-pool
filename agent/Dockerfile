# 3proxy 官方镜像定义
#
# 为什么不是 alpine + apk add 3proxy：Alpine 官方仓库（v3.19 与 v3.22 均已确认）没有
# 3proxy 包，且 alpine:3.19 已 EOL，apk add 会直接失败。为保证长期可构建，改为安装
# 3proxy 官方预编译 deb 并锁定版本，构建过程不依赖任何发行版软件仓库。
#
# 多阶段：alpine 阶段只负责下载 deb（无需在运行镜像里留 curl/apt），
#         运行阶段 debian:bookworm-slim 仅解包即可。
#
# 切换版本：docker build --build-arg THREEPROXY_VERSION=1.0.0
FROM alpine:3.22 AS fetcher

ARG THREEPROXY_VERSION=0.9.9.0
# BuildKit 自动注入（amd64 / arm64 / arm/v7 ...），据此选择对应架构的 deb
ARG TARGETARCH=amd64

RUN set -eux; \
    apk add --no-cache curl; \
    case "${TARGETARCH}" in \
      amd64)  DEB_ARCH=x86_64 ;; \
      arm64)  DEB_ARCH=arm64 ;; \
      arm/v7) DEB_ARCH=arm ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /3proxy.deb \
      "https://github.com/3proxy/3proxy/releases/download/${THREEPROXY_VERSION}/3proxy-${THREEPROXY_VERSION}.${DEB_ARCH}.deb"; \
    test -s /3proxy.deb

# 运行阶段用 ubuntu:22.04：3proxy 官方 deb 正是基于该版本构建，且镜像自带 libssl3
# （debian:bookworm / bookworm-slim 均不含 libssl3，需额外 apt 安装）。
# 因此解包即可运行，无需 apt，构建不依赖任何发行版软件仓库。
FROM ubuntu:22.04

COPY --from=fetcher /3proxy.deb /tmp/3proxy.deb

RUN set -eux; \
    dpkg -i /tmp/3proxy.deb; \
    rm -f /tmp/3proxy.deb; \
    command -v 3proxy

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1080

ENTRYPOINT ["/entrypoint.sh"]
