# sing-tunnel

A containerized solution for running cloudflared on top of sing-box (and potentially other proxies). This tunnel-in-tunnel setup is useful for users that don't have good direct connectivity to Cloudflare's network, allowing them to leverage sing-box's capabilities to route cloudflared's traffic effectively.

## Motivation

Previously I just ran sing-box (with [auto_route](https://sing-box.sagernet.org/configuration/inbound/tun/#auto_route) and [auto_redirect](https://sing-box.sagernet.org/configuration/inbound/tun/#auto_redirect) enabled) and cloudflared outside of Docker. But apprently Docker and sing-box both want to mess with routing tables and firewall rules and it's not fun. Containerizing and using SOCKS proxy is cleaner and more robust solution.

## How It Works

There's two patch:

1. `patch_cloudflared_dns.py`: Use `TUNNEL_DNS_ADDRESS` environment variable to set DNS server `cloudflared` uses.
2. `cloudflared_socks_dns.patch`: Use `ALL_PROXY` environment variable to transport `http2` tunnel.
