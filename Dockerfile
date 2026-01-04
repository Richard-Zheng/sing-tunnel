# ==========================================
# Stage 1: Builder (编译 Cloudflared)
# ==========================================
FROM golang:1.24 AS builder

ENV GO111MODULE=on \
    CGO_ENABLED=0 \
    CONTAINER_BUILD=1

WORKDIR /go/src/github.com/cloudflare/cloudflared/

# 1. 安装基础编译工具
RUN apt-get update && apt-get install -y git make curl

# 2. 克隆 Cloudflared 源码
# 这里拉取最新代码，如果 patch 冲突，可能需要回退 cloudflared 版本
RUN git clone https://gitcode.com/gh_mirrors/cl/cloudflared.git .

# 3. 【核心】下载并应用 Richard-Zheng 的补丁
COPY cloudflared_socks.patch /go/src/github.com/cloudflare/cloudflared/
RUN git apply -v cloudflared_socks.patch

# 4. 编译
RUN make cloudflared

# ==========================================
# Stage 2: Final (运行时环境)
# ==========================================
FROM debian:bookworm-slim

# 安装运行时依赖
# jq: 用于处理节点 JSON
# ca-certificates: 用于 HTTPS 验证
#RUN sed -i 's|http://deb.debian.org|http://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/debian.sources
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates jq iproute2 dnsutils \
    && rm -rf /var/lib/apt/lists/*

# 1. 安装 Sing-box
ARG SINGBOX_VERSION=1.12.12
RUN curl -L -o /tmp/sing-box.tar.gz \
    "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz" && \
    tar -xzf /tmp/sing-box.tar.gz -C /tmp && \
    mv /tmp/sing-box-*/sing-box /usr/local/bin/sing-box && \
    chmod +x /usr/local/bin/sing-box && \
    rm -rf /tmp/sing-box*

# 2. 复制编译好的 Cloudflared
COPY --from=builder /go/src/github.com/cloudflare/cloudflared/cloudflared /usr/local/bin/cloudflared
RUN chmod +x /usr/local/bin/cloudflared

# 3. 复制启动脚本
COPY entrypoint.sh entrypoint.sh
RUN chmod +x entrypoint.sh

COPY template.json template.json

# 强制使用 HTTP2 (Patch 必须配合此协议才能走代理)
ENV TUNNEL_TRANSPORT_PROTOCOL=http2

ENTRYPOINT ["entrypoint.sh"]