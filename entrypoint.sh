#!/bin/bash
set -e

TEMPLATE_FILE="template.json"
FINAL_CONFIG="/etc/sing-box/config.json"
# 这是你在 docker-compose 中挂载进去的路径
LOCAL_NODES_FILE="/etc/sing-box/nodes.json"
TEMP_NODES="/tmp/all_nodes.json"

# --------------------------------------------------------
# 1. 动态探测 Docker DNS IP
# --------------------------------------------------------
echo "[INFO] Detecting Docker DNS..."
# 读取 /etc/resolv.conf 中的 nameserver
DOCKER_DNS_IP=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | head -n 1)

if [ -z "$DOCKER_DNS_IP" ]; then
    echo "[WARN] Could not detect DNS from /etc/resolv.conf, falling back to 127.0.0.11"
    DOCKER_DNS_IP="127.0.0.11"
else
    echo "[INFO] Detected Docker DNS IP: $DOCKER_DNS_IP"
fi

# 使用 sed 将模板中的 __DOCKER_DNS__ 替换为真实 IP
sed "s/__DOCKER_DNS__/$DOCKER_DNS_IP/g" "$TEMPLATE_FILE" > "$FINAL_CONFIG"

# --------------------------------------------------------
# 2. 系统网络配置 (劫持与启动)
# --------------------------------------------------------

echo "[INFO] Taking over System DNS..."
# 现在才覆盖 resolv.conf，让 sing-box 接管
echo "nameserver 127.0.0.1" > /etc/resolv.conf

echo "[INFO] Starting sing-box..."
/usr/local/bin/sing-box run -c "$FINAL_CONFIG" &
sleep 2

# dns lookup test
echo "[INFO] Testing DNS resolution..."
dig +noedns google.com
dig +noedns host.docker.internal

echo "[INFO] Configuring Proxy Environment..."
# 这里的关键是：打过补丁的 cloudflared 能够识别 ALL_PROXY 并正确走 SOCKS5 远程解析 DNS
export ALL_PROXY="socks5://127.0.0.1:7080"

echo "[INFO] Starting Cloudflared..."
if [ -z "$TUNNEL_TOKEN" ]; then
    echo "[ERROR] TUNNEL_TOKEN is missing!"
    exit 1
fi

# use strace to debug cannot execute: required file not found
exec cloudflared tunnel --no-autoupdate run
