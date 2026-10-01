# sing-tunnel

A containerized solution for running cloudflared on top of sing-box (and potentially other proxies). This tunnel-in-tunnel setup is useful for users that don't have good direct connectivity to Cloudflare's network, allowing them to leverage sing-box's capabilities to route cloudflared's traffic effectively.

## Motivation

Previously I just ran sing-box (with [auto_route](https://sing-box.sagernet.org/configuration/inbound/tun/#auto_route) and [auto_redirect](https://sing-box.sagernet.org/configuration/inbound/tun/#auto_redirect) enabled) and cloudflared outside of Docker. But apparently Docker and sing-box both want to mess with routing tables and firewall rules and it's not fun. Containerizing and using SOCKS proxy is cleaner and more robust solution.

## How It Works

The container runs two processes:

1. **sing-box** exposes a local SOCKS5 proxy on `127.0.0.1:7080` and a DNS
   server on `127.0.0.1:5533`. Cloudflare-related DNS and TCP traffic is routed
   through the proxy node; everything else goes out directly.
2. **cloudflared** is patched to send its HTTP/2 edge connection through that
   SOCKS5 proxy and to resolve edge hostnames through sing-box's DNS.

Two patches are applied to the cloudflared source at build time:

1. `cloudflared_socks.patch` — reads `ALL_PROXY` and transports the `http2`
   tunnel through it.
2. `patch_cloudflared_dns.py` — reads `TUNNEL_DNS_ADDRESS` and uses it as
   cloudflared's resolver (also disabling the direct-DoT fallback so DNS can
   never leak outside the tunnel).

Because DNS no longer needs `/etc/resolv.conf` to be rewritten, sing-box does
not have to bind port 53 and the container no longer needs to run as root for
that purpose.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `NODE_REGEX` | `.*` | Regex matched against node `tag`s in `nodes.json`. Only matching proxy nodes are kept. (`NODES_REGEX` is still accepted as a fallback.) |
| `SING_BOX_LOG_LEVEL` | *(template value)* | Overrides `log.level` in the generated config, e.g. `debug`. |
| `TUNNEL_TOKEN` | *(unset)* | Cloudflare tunnel token. If unset, falls back to `/etc/cloudflared/config.yml`, then to trycloudflare. |
| `TRY_URL` | `http://host.docker.internal:8080` | Local service to expose in trycloudflare mode. |
| `NODES_FILE` | `/nodes.json` | Path to the node list to merge. |

The generated config is written to `/config.json` inside the container.

## Node merging

If `nodes.json` exists (typically your existing sing-box `outbounds`), the
entrypoint merges it into `template.json` with an inline `jq` filter. Outbounds
are split into:

* **proxy nodes** — real protocols (`trojan`, `vless`, `hysteria2`, ...).
  These are filtered by `NODE_REGEX` and collected into an `urltest` group
  named `ProxySel`.
* **infrastructure** — `selector`, `urltest`, `direct`, `block` and `dns`
  outbounds. These are preserved from `template.json` verbatim, because
  `route.final` and the DNS detour reference them by tag.

If no `nodes.json` is present, `template.json` is used as-is; it already
contains a `ProxySel` that falls back to `DirectOut`.

## Build tags

The image builds sing-box from source with a deliberately small tag set:

```
with_utls,with_quic,with_grpc,with_wireguard
```

`with_utls` is required for uTLS/Reality nodes, `with_quic` for QUIC, HTTP/3
DNS and Hysteria/TUIC nodes, `with_grpc` for gRPC transports, and
`with_wireguard` for WireGuard outbounds. This is enough for the protocols used
here while cutting the binary from ~58 MB to ~41 MB.

Notable tags that are **not** enabled:

* `with_naive_outbound` — pulls in Chromium/cronet (`cronet-go`), which is why
  the official default build is much larger.
* `with_gvisor` — only needed by the deprecated gVisor Tun stack; also a
  prerequisite of `with_tailscale` in recent sing-box versions.
* `with_clash_api`, `with_acme`, `with_ccm`, `with_ocm`, `with_cloudflared`,
  `with_usbip`, `with_openvpn`, `with_openconnect` — unused by this container.

If you need one of these, add it to `SINGBOX_TAGS` in the `Dockerfile`.

## Usage

```yaml
services:
  cf-tunnel:
    build: .
    container_name: cf-tunnel
    restart: always
    environment:
      - NODE_REGEX=香港
    volumes:
      - /etc/sing-box/config.json:/nodes.json:ro
      - /etc/cloudflared:/etc/cloudflared:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

## Version pinning

Both upstream projects are pinned to release tags so that the patches and the
`nodes.json` schema cannot silently break against upstream HEAD:

* `CLOUDFLARED_VERSION` (default `2026.9.3`)
* `SINGBOX_VERSION` (default `1.14.2`)

Note that cloudflared's `go.mod` requires Go 1.26, and that recent sing-box
releases add node fields (e.g. `tcp_keep_alive`) that older sing-box builds
reject. Bump these together with your `nodes.json` when upgrading.
