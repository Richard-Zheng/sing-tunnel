#!/bin/bash
set -euo pipefail

TEMPLATE_FILE="/template.json"
NODE_FILE="${NODES_FILE:-/nodes.json}"
FINAL_CONFIG="/config.json"
TMP_CONFIG="${FINAL_CONFIG}.tmp"

# NODES_REGEX is accepted for backwards compatibility with older compose files.
REGEX="${NODE_REGEX:-${NODES_REGEX:-.*}}"

# --------------------------------------------------------
# 0. Detect the Docker embedded DNS resolver
# --------------------------------------------------------
echo "[INFO] Detecting Docker DNS..."
DOCKER_DNS_IP=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
if [ -z "$DOCKER_DNS_IP" ]; then
    echo "[WARN] Could not detect DNS from /etc/resolv.conf, falling back to 127.0.0.11"
    DOCKER_DNS_IP="127.0.0.11"
else
    echo "[INFO] Detected Docker DNS IP: $DOCKER_DNS_IP"
fi

# --------------------------------------------------------
# 1. Render the template (DNS placeholder, optional log level)
# --------------------------------------------------------
sed "s/__DOCKER_DNS__/$DOCKER_DNS_IP/g" "$TEMPLATE_FILE" > "$FINAL_CONFIG"

if [ -n "${SING_BOX_LOG_LEVEL:-}" ]; then
    echo "[INFO] Setting sing-box log level to: $SING_BOX_LOG_LEVEL"
    jq --arg level "$SING_BOX_LOG_LEVEL" '.log.level = $level' "$FINAL_CONFIG" > "$TMP_CONFIG"
    mv "$TMP_CONFIG" "$FINAL_CONFIG"
fi

# --------------------------------------------------------
# 2. Merge nodes.json into the template (when present)
# --------------------------------------------------------
if [ ! -f "$NODE_FILE" ]; then
    echo "[INFO] No $NODE_FILE found, using $TEMPLATE_FILE as-is."
else
    echo "[INFO] Found $NODE_FILE, merging with template..."

    jq --arg regex "$REGEX" --slurpfile node_data "$NODE_FILE" '
        # Outbounds fall into two groups:
        #   proxy nodes    - real protocols (trojan, vless, hysteria2, ...);
        #                    taken from nodes.json and/or the template, filtered
        #                    by tag, then collected into the ProxySel group.
        #   infrastructure - selector/urltest/direct/block/dns; taken from the
        #                    template verbatim, because route.final and the DNS
        #                    detour reference them by tag.
        ["selector", "urltest", "direct", "block", "dns"] as $infra_types |

        ($node_data[0].outbounds // []) as $node_outbounds |
        (.outbounds // []) as $template_outbounds |

        # ProxySel is regenerated below, so it is never treated as an input.
        [ ($node_outbounds + $template_outbounds)[]
          | select(
              type == "object"
              and .type != null
              and (.tag | type == "string")
              and .tag != "ProxySel"
              and (.type as $t | $infra_types | index($t) == null)
              and (.tag | test($regex))
            )
        ] as $proxies |

        [ $template_outbounds[]
          | select(
              type == "object"
              and (.tag | type == "string")
              and .tag != "ProxySel"
              and (.type as $t | $infra_types | index($t) != null)
            )
        ] as $infra |

        ($proxies | map(.tag)) as $tags |

        .outbounds = (
            $proxies + $infra +
            [ {
                "type": "urltest",
                "tag": "ProxySel",
                # ProxySel is referenced by the DNS detour and route rules, so
                # it must always exist; fall back to DirectOut with no nodes.
                "outbounds": (if ($tags | length) > 0 then $tags else ["DirectOut"] end),
                "url": "https://cp.cloudflare.com/generate_204",
                "interval": "30m",
                "tolerance": 10,
                "interrupt_exist_connections": false
              } ]
        )
    ' "$FINAL_CONFIG" > "$TMP_CONFIG"

    mv "$TMP_CONFIG" "$FINAL_CONFIG"
    echo "[INFO] Nodes merged using regex: '$REGEX'."
fi

# --------------------------------------------------------
# 3. Start sing-box
# --------------------------------------------------------
echo "[INFO] Starting sing-box..."
/usr/local/bin/sing-box run -c "$FINAL_CONFIG" &
SING_BOX_PID=$!

# Fail fast if sing-box dies during startup instead of limping on to cloudflared.
sleep 2
if ! kill -0 "$SING_BOX_PID" 2>/dev/null; then
    echo "[ERROR] sing-box exited during startup. Last log lines:"
    wait "$SING_BOX_PID" || true
    exit 1
fi

# --------------------------------------------------------
# 4. Start cloudflared through the local SOCKS5 proxy
# --------------------------------------------------------
# The patched cloudflared reads ALL_PROXY to tunnel its HTTP/2 connection
# through sing-box, and TUNNEL_DNS_ADDRESS to resolve edge hostnames via
# sing-box instead of the system resolver.
export ALL_PROXY="socks5://127.0.0.1:7080"

echo "[INFO] Starting cloudflared..."
if [ -z "${TUNNEL_TOKEN:-}" ]; then
    if [ -f "/etc/cloudflared/config.yml" ]; then
        echo "[INFO] TUNNEL_TOKEN not provided, starting cloudflared in local config mode."
        exec cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run
    fi
    echo "[WARN] Neither TUNNEL_TOKEN nor config.yml found. Starting in trycloudflare mode..."
    exec cloudflared tunnel --no-autoupdate --url "${TRY_URL:-http://host.docker.internal:8080}"
fi

exec cloudflared tunnel --no-autoupdate run
