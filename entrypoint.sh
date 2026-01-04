#!/bin/bash
set -e

TEMPLATE_FILE="/template.json"
NODE_FILE="/nodes.json"
FINAL_CONFIG="/config.json"

# --------------------------------------------------------
# 0. 节点缝合 (Merge Nodes)
# --------------------------------------------------------
if ! command -v jq &> /dev/null; then
    echo "[ERROR] jq is not installed. Please install jq in your Dockerfile."
    exit 1
fi

if [ -f "$NODE_FILE" ]; then
    echo "[INFO] Found $NODE_FILE, merging with template..."
    
    REGEX="${NODE_REGEX:-.*}"
    
    jq --arg regex "$REGEX" --slurpfile node_data "$NODE_FILE" '
        # 获取 nodes.json 中的 outbounds 数组
        ($node_data[0].outbounds | if type == "array" then . else [] end) as $raw_nodes |
        
        # 定义黑名单类型
        ["selector", "urltest", "direct", "block", "dns"] as $ignored_types |
        
        # 筛选有效的节点对象
        [ $raw_nodes[] | select(
            type == "object" and 
            .type != null and 
            (.type as $t | $ignored_types | index($t) == null) and 
            (.tag | type == "string" and test($regex))
        ) ] as $filtered_nodes |
        
        # 提取 tag 列表
        ($filtered_nodes | map(.tag)) as $node_tags |
        
        # 构建 Auto-Select 组
        (if ($node_tags | length) > 0 then
            {
                "type": "urltest",
                "tag": "ProxySel", 
                "outbounds": $node_tags,
                "url": "https://cp.cloudflare.com/generate_204",
                "interval": "30m",
                "tolerance": 10,
                "interrupt_exist_connections": false
            }
        else null end) as $auto_group |
        
        # 合并到 template 的 outbounds
        .outbounds = (
            (.outbounds | if type == "array" then . else [] end) + 
            $filtered_nodes + 
            (if $auto_group != null then [$auto_group] else [] end)
        )
    ' "$TEMPLATE_FILE" > "$FINAL_CONFIG"
    
    echo "[INFO] Nodes merged using regex: '$REGEX'."
else
    echo "[INFO] No nodes.json found. Using raw template."
    cp "$TEMPLATE_FILE" "$FINAL_CONFIG"
fi

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
# 注意：这里操作的是已经生成的 FINAL_CONFIG
sed -i "s/__DOCKER_DNS__/$DOCKER_DNS_IP/g" "$FINAL_CONFIG"

# --------------------------------------------------------
# 3. 系统网络配置 (劫持与启动)
# --------------------------------------------------------

echo "[INFO] Taking over System DNS..."
# 现在才覆盖 resolv.conf，让 sing-box 接管
echo "nameserver 127.0.0.1" > /etc/resolv.conf

echo "[INFO] Starting sing-box..."
# 启动时使用 FINAL_CONFIG
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
    # 如果没有提供 TUNNEL_TOKEN，使用本地配置模式
    echo "[WARN] TUNNEL_TOKEN not provided, starting cloudflared in local config mode."
    exec cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run
fi

exec cloudflared tunnel --no-autoupdate run