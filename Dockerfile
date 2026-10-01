# ==========================================
# Stage 1: Cloudflared Builder
# ==========================================
FROM --platform=$BUILDPLATFORM golang:1.26 AS cloudflared-builder

ARG TARGETARCH
ARG CLOUDFLARED_VERSION=2026.9.3
ENV GOARCH=$TARGETARCH \
    GO111MODULE=on \
    CGO_ENABLED=0 \
    CONTAINER_BUILD=1

WORKDIR /go/src/github.com/cloudflare/cloudflared/

# 1. Install build tools
RUN apt-get update && apt-get install -y --no-install-recommends git make ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 2. Clone Cloudflared. Pinned to a release tag so the patches below cannot
#    silently break against upstream HEAD.
RUN git clone --depth 1 --branch ${CLOUDFLARED_VERSION} \
        https://github.com/cloudflare/cloudflared.git .

# 3. Apply the two patches:
#    - cloudflared_socks.patch: route the HTTP/2 edge connection via ALL_PROXY.
#    - patch_cloudflared_dns.py: resolve via TUNNEL_DNS_ADDRESS.
COPY cloudflared_socks.patch /go/src/github.com/cloudflare/cloudflared/
COPY patch_cloudflared_dns.py /go/src/github.com/cloudflare/cloudflared/
RUN git apply -v cloudflared_socks.patch \
    && python3 patch_cloudflared_dns.py

# 4. Compile
RUN make cloudflared

# ==========================================
# Stage 2: Sing-box Builder
# ==========================================
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS singbox-builder

ARG SINGBOX_VERSION=1.14.2
ARG TARGETOS TARGETARCH

WORKDIR /go/src/github.com/sagernet/sing-box

# Install git and build tools
RUN apk add --no-cache git build-base

# Fetch source at the pinned release
RUN git clone --depth 1 --branch v${SINGBOX_VERSION} \
        https://github.com/SagerNet/sing-box.git .

# Only the tags this container actually needs:
#   with_utls       - uTLS / Reality (required by the proxy nodes in template)
#   with_quic       - QUIC, HTTP/3 DNS and Hysteria/TUIC nodes
#   with_grpc       - gRPC V2Ray transport
#   with_wireguard  - WireGuard outbound
# Deliberately omitted (see README): with_gvisor, with_clash_api, with_acme,
# with_tailscale, with_naive_outbound (pulls Chromium/cronet), with_ccm,
# with_ocm, with_cloudflared, with_usbip, with_openvpn, with_openconnect.
ENV CGO_ENABLED=0 \
    GOOS=$TARGETOS \
    GOARCH=$TARGETARCH \
    SINGBOX_TAGS="with_utls,with_quic,with_grpc,with_wireguard"

RUN export VERSION=$(go run ./cmd/internal/read_tag) \
    && go build -v -trimpath -tags "$SINGBOX_TAGS" \
        -o /go/bin/sing-box \
        -ldflags "-X \"github.com/sagernet/sing-box/constant.Version=$VERSION\" \
                  -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 \
                  -s -w -buildid=" \
        ./cmd/sing-box

# ==========================================
# Stage 3: Final (runtime)
# ==========================================
FROM debian:bookworm-slim

ARG TARGETARCH

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates jq iproute2 \
    && rm -rf /var/lib/apt/lists/*

# 1. Install sing-box
COPY --from=singbox-builder /go/bin/sing-box /usr/local/bin/sing-box

# 2. Install the patched cloudflared
COPY --from=cloudflared-builder /go/src/github.com/cloudflare/cloudflared/cloudflared /usr/local/bin/cloudflared

# 3. Entrypoint + config template
COPY entrypoint.sh /entrypoint.sh
COPY template.json /template.json
RUN chmod +x /entrypoint.sh /usr/local/bin/sing-box /usr/local/bin/cloudflared

# Force HTTP/2: the SOCKS patch only covers the HTTP/2 transport.
ENV TUNNEL_TRANSPORT_PROTOCOL=http2

# Resolve cloudflared's DNS through sing-box (nearest edge to the proxy exit).
ENV TUNNEL_DNS_ADDRESS=127.0.0.1:5533

ENTRYPOINT ["/entrypoint.sh"]
