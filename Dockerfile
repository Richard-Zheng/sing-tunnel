# ==========================================
# Stage 1: Cloudflared Builder
# ==========================================
FROM --platform=$BUILDPLATFORM golang:1.24 AS cloudflared-builder

ARG TARGETARCH
ENV GOARCH=$TARGETARCH \
    GO111MODULE=on \
    CGO_ENABLED=0 \
    CONTAINER_BUILD=1

WORKDIR /go/src/github.com/cloudflare/cloudflared/

# 1. 安装基础编译工具
RUN apt-get update && apt-get install -y git make curl

# 2. 克隆 Cloudflared 源码
# 这里拉取最新代码，如果 patch 冲突，可能需要回退 cloudflared 版本
RUN git clone https://github.com/cloudflare/cloudflared.git .

# 3. 【核心】下载并应用 socks 代理补丁
COPY cloudflared_socks.patch /go/src/github.com/cloudflare/cloudflared/
RUN git apply -v cloudflared_socks.patch

# 4. 编译
RUN make cloudflared

# ==========================================
# Stage 2: Sing-box Builder
# ==========================================
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS singbox-builder

ARG SINGBOX_VERSION=1.12.15
ARG TARGETOS TARGETARCH

WORKDIR /go/src/github.com/sagernet/sing-box

# 安装 git 和编译工具
RUN apk add --no-cache git build-base

# 拉取源码并切换到指定版本
RUN git clone https://github.com/SagerNet/sing-box.git . && \
    git checkout v${SINGBOX_VERSION}

ENV CGO_ENABLED=0 \
    GOOS=$TARGETOS \
    GOARCH=$TARGETARCH

# 编译 sing-box
RUN export COMMIT=$(git rev-parse --short HEAD) \
    && export VERSION=$(go run ./cmd/internal/read_tag) \
    && go build -v -trimpath -tags \
        "with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale" \
        -o /go/bin/sing-box \
        -ldflags "-X \"github.com/sagernet/sing-box/constant.Version=$VERSION\" -s -w -buildid=" \
        ./cmd/sing-box

# ==========================================
# Stage 3: Final (运行时环境)
# ==========================================
FROM debian:bookworm-slim

ARG TARGETARCH

# 安装运行时依赖
# jq: 用于处理节点 JSON
# ca-certificates: 用于 HTTPS 验证
#RUN sed -i 's|http://deb.debian.org|http://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/debian.sources
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates jq iproute2 dnsutils \
    && rm -rf /var/lib/apt/lists/*

# 1. 安装 Sing-box
COPY --from=singbox-builder /go/bin/sing-box /usr/local/bin/sing-box
RUN chmod +x /usr/local/bin/sing-box

# 2. 复制编译好的 Cloudflared
COPY --from=cloudflared-builder /go/src/github.com/cloudflare/cloudflared/cloudflared /usr/local/bin/cloudflared
RUN chmod +x /usr/local/bin/cloudflared

# 3. 复制启动脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY template.json /template.json

# 强制使用 HTTP2 (Patch 必须配合此协议才能走代理)
ENV TUNNEL_TRANSPORT_PROTOCOL=http2

ENTRYPOINT ["/entrypoint.sh"]
