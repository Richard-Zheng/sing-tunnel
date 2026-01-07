# sing-tunnel

A containerized solution for running cloudflared on top of sing-box (and potentially other proxies). This tunnel-in-tunnel setup is useful for users that don't have good direct connectivity to Cloudflare's network, allowing them to leverage sing-box's capabilities to route cloudflared's traffic effectively.

## Motivation

Previously I just ran sing-box (with [auto_route](https://sing-box.sagernet.org/configuration/inbound/tun/#auto_route) and [auto_redirect](https://sing-box.sagernet.org/configuration/inbound/tun/#auto_redirect) enabled) and cloudflared outside of Docker. But apprently Docker and sing-box both want to mess with routing tables and firewall rules and it's not fun. Containerizing and using SOCKS proxy is cleaner and more robust solution.

## How It Works

It consists of two main parts:

1. **sing-box**: opens a local SOCKS5 proxy server listening on `127.0.0.1:7080`, and a DNS server on `127.0.0.1:53`. It's configured to route DNS queries and TCP traffic related to Cloudflare Tunnels through the remote proxy server, other traffic is directly forwarded.
2. **cloudflared**: modified to use the local SOCKS5 proxy provided by sing-box.

## Future Work

- non-root support: currently sing-box needs to run as root to bind to port 53 for DNS. If cloudflared can be patched to use a custom DNS server (eg. `127.0.0.1:5353`), sing-box can run as non-root user.
