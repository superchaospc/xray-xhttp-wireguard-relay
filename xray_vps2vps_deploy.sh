#!/usr/bin/env bash
# =====================================================
#  Xray VPS-to-VPS relay one-click deploy script
#
#  Topology:
#    Client -> Relay VPS (VLESS + REALITY)
#           -> Exit VPS  (VLESS + REALITY)
#           -> Internet direct egress from Exit VPS
#
#  Usage:
#    1. Run this script on the Exit VPS, choose guided install -> Exit.
#    2. Copy the generated one-line Relay install command.
#    3. Paste it on the Relay VPS.
#    4. Import the Relay client VLESS link or QR code into your client.
# =====================================================

set -euo pipefail
umask 077

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
INFO_FILE="/root/xray_vps2vps_info.json"
ROUTES_FILE="/root/xray_vps2vps_routes.json"
SYSCTL_FILE="/etc/sysctl.d/99-xray-vps2vps.conf"
IP_CACHE_FILE="/root/.xray_vps2vps_ip"
SCRIPT_PATH="/root/xray_vps2vps_deploy.sh"
SCRIPT_URL="https://raw.githubusercontent.com/superchaospc/xray-vps2vps-relay/main/xray_vps2vps_deploy.sh"
BACKUP_KEEP="${BACKUP_KEEP:-5}"
IP_CACHE_TTL="${IP_CACHE_TTL:-3600}"

CLIENT_FP="${CLIENT_FP:-chrome}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.cloudflare.com}"
REALITY_DEST="${REALITY_DEST:-${REALITY_SERVER_NAME}:443}"

XRAY_INSTALL_REF="${XRAY_INSTALL_REF:-main}"
XRAY_INSTALL_SHA256="${XRAY_INSTALL_SHA256:-}"
XRAY_REDACT="${XRAY_REDACT:-0}"
AUTO_YES="${AUTO_YES:-0}"
LAST_CONFIG_BACKUP=""

die() {
    echo -e "${RED}✗ $*${NC}" >&2
    exit 1
}

ok() {
    echo -e "${GREEN}✓ $*${NC}"
}

warn() {
    echo -e "${YELLOW}⚠ $*${NC}"
}

redact() {
    local value="$1"
    if [ "$XRAY_REDACT" != "1" ] || [ "${#value}" -lt 12 ]; then
        printf '%s\n' "$value"
        return
    fi
    printf '%s…%s\n' "${value:0:4}" "${value: -4}"
}

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════╗"
    echo "║   Xray VPS → VPS 中转部署工具                ║"
    echo "║   Client → Relay VPS → Exit VPS → Internet   ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_install_flow() {
    echo -e "${GREEN}安装顺序：一台一台来。${NC}"
    echo "  Step 1: 先登录落地 VPS，选择 Exit 安装。"
    echo "  Step 2: Exit 完成后，复制它输出的整段 Relay 安装命令。"
    echo "  Step 3: 再登录中转 VPS，粘贴那段命令安装 Relay。"
    echo "  Step 4: 扫 Relay 输出的二维码，或导入 vless:// 链接。"
    echo "  多线路: 继续新增落地 VPS 时，重复 Step 1 和 Step 3，每条线路使用不同 Relay 入口端口。"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行：sudo bash $0"
    command -v systemctl >/dev/null 2>&1 || die "需要 systemd 环境"
}

prompt() {
    local var_name="$1"
    local message="$2"
    local default_value="${3:-}"
    local value current_value
    current_value="${!var_name:-}"
    if [ "$AUTO_YES" = "1" ]; then
        if [ -n "$current_value" ]; then
            return
        fi
        if [ -n "$default_value" ]; then
            printf -v "$var_name" '%s' "$default_value"
            return
        fi
        die "AUTO_YES=1 时缺少必填参数：$message"
    fi
    if [ -n "$default_value" ]; then
        read -r -p "$message [$default_value]: " value
        value="${value:-$default_value}"
    else
        read -r -p "$message: " value
    fi
    printf -v "$var_name" '%s' "$value"
}

print_help() {
    cat <<'EOF'
Xray VPS -> VPS 中转部署工具

用法:
  ./xray_vps2vps_deploy.sh              进入推荐向导菜单
  ./xray_vps2vps_deploy.sh --exit       直接安装落地 Exit
  ./xray_vps2vps_deploy.sh --relay      给中转 Relay 添加/更新一条落地线路
  ./xray_vps2vps_deploy.sh --list       查看 Relay 上所有线路
  ./xray_vps2vps_deploy.sh --stats      查看线路流量统计
  ./xray_vps2vps_deploy.sh --delete     删除 Relay 上的一条线路
  ./xray_vps2vps_deploy.sh --rename     修改线路名称
  ./xray_vps2vps_deploy.sh --status     查看状态
  ./xray_vps2vps_deploy.sh --help       显示帮助

推荐流程:
  1. 第一台：在落地 VPS 上运行脚本，选择 Exit 安装。
  2. Exit 安装完成后，复制脚本输出的整段 Relay 安装命令。
  3. 第二台：在中转 VPS 上粘贴执行这段命令，添加一条线路。
  4. 扫 Relay 输出的二维码或导入 vless:// 链接。
  5. 要添加更多落地 VPS，重复 Step 1 和 Step 3，并为每条线路使用不同 Relay 入口端口。

可选变量:
  AUTO_YES=1             使用默认值/环境变量，适合复制的一键命令
  EXIT_PORT=443          Exit 监听端口
  RELAY_PORT=443         Relay 对客户端监听端口
  EXIT_BUNDLE=...        Exit 输出的一键参数包，Relay 会自动解析
  REALITY_SERVER_NAME=... REALITY SNI，默认 www.cloudflare.com
  CLIENT_FP=chrome       客户端指纹
EOF
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

valid_short_id() {
    [[ "$1" =~ ^[0-9a-fA-F]{2,16}$ ]] && [ $(( ${#1} % 2 )) -eq 0 ]
}

valid_host() {
    HOST_VALUE="$1" python3 - <<'PYEOF'
import ipaddress
import os
import re
import sys

value = os.environ["HOST_VALUE"].strip()
if not value or len(value) > 253 or any(ord(c) < 33 for c in value):
    sys.exit(1)
try:
    ipaddress.ip_address(value)
    sys.exit(0)
except ValueError:
    pass

labels = value.rstrip(".").split(".")
if len(labels) < 2:
    sys.exit(1)
pattern = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
sys.exit(0 if all(pattern.match(label) for label in labels) else 1)
PYEOF
}

route_port_exists() {
    local port="$1"
    [ -f "$ROUTES_FILE" ] || return 1
    ROUTES_FILE="$ROUTES_FILE" CHECK_RELAY_PORT="$port" python3 - <<'PYEOF'
import json
import os
import sys

try:
    data = json.load(open(os.environ["ROUTES_FILE"]))
except Exception:
    sys.exit(1)
port = os.environ["CHECK_RELAY_PORT"]
for route in data.get("routes", []):
    if str(route.get("relay_port")) == port:
        sys.exit(0)
sys.exit(1)
PYEOF
}

migrate_existing_relay_config_if_needed() {
    ROUTES_FILE="$ROUTES_FILE" CONFIG_FILE="$CONFIG_FILE" INFO_FILE="$INFO_FILE" \
    python3 - <<'PYEOF'
import json
import os
import sys
import time

routes_path = os.environ["ROUTES_FILE"]
config_path = os.environ["CONFIG_FILE"]
info_path = os.environ["INFO_FILE"]

try:
    with open(routes_path) as f:
        existing = json.load(f)
    if isinstance(existing, dict) and existing.get("routes"):
        sys.exit(0)
except Exception:
    pass

try:
    with open(config_path) as f:
        config = json.load(f)
except Exception:
    sys.exit(0)

try:
    with open(info_path) as f:
        info = json.load(f)
except Exception:
    info = {}

inbounds = config.get("inbounds", [])
outbounds = {o.get("tag"): o for o in config.get("outbounds", []) if isinstance(o, dict)}
rules = config.get("routing", {}).get("rules", [])

def first_client_public_key(client_uuid):
    if info.get("client_uuid") == client_uuid and info.get("client_public_key"):
        return info["client_public_key"]
    return info.get("client_public_key", "")

routes = []
for inbound in inbounds:
    if not isinstance(inbound, dict):
        continue
    if inbound.get("protocol") != "vless":
        continue
    stream = inbound.get("streamSettings", {})
    if stream.get("security") != "reality":
        continue
    inbound_tag = inbound.get("tag")
    relay_port = inbound.get("port")
    settings = inbound.get("settings", {})
    clients = settings.get("clients") or []
    reality = stream.get("realitySettings", {})
    if not inbound_tag or not relay_port or not clients:
        continue

    outbound_tag = None
    for rule in rules:
        inbound_tags = rule.get("inboundTag") or []
        if isinstance(inbound_tags, str):
            inbound_tags = [inbound_tags]
        if inbound_tag in inbound_tags:
            outbound_tag = rule.get("outboundTag")
            break
    if not outbound_tag and len([k for k in outbounds if str(k).startswith("to-exit")]) == 1:
        outbound_tag = [k for k in outbounds if str(k).startswith("to-exit")][0]
    outbound = outbounds.get(outbound_tag)
    if not outbound or outbound.get("protocol") != "vless":
        continue

    vnext = outbound.get("settings", {}).get("vnext") or []
    if not vnext:
        continue
    server = vnext[0]
    users = server.get("users") or []
    outbound_reality = outbound.get("streamSettings", {}).get("realitySettings", {})
    if not users:
        continue

    client_uuid = clients[0].get("id", "")
    exit_host = server.get("address", "")
    route = {
        "name": info.get("route_name") or f"Migrated-{exit_host}-{relay_port}",
        "relay_port": str(relay_port),
        "client_uuid": client_uuid,
        "client_private_key": reality.get("privateKey", ""),
        "client_public_key": first_client_public_key(client_uuid),
        "client_short_id": (reality.get("shortIds") or [""])[0],
        "client_sni": (reality.get("serverNames") or [info.get("client_sni") or "www.cloudflare.com"])[0],
        "client_fp": outbound_reality.get("fingerprint") or "chrome",
        "exit_host": exit_host,
        "exit_port": str(server.get("port", "")),
        "exit_uuid": users[0].get("id", ""),
        "exit_public_key": outbound_reality.get("publicKey", ""),
        "exit_short_id": outbound_reality.get("shortId", ""),
        "exit_sni": outbound_reality.get("serverName", ""),
        "updated_at": int(time.time()),
        "migrated": True,
    }
    required = [
        "relay_port", "client_uuid", "client_private_key", "client_short_id",
        "exit_host", "exit_port", "exit_uuid", "exit_public_key",
        "exit_short_id", "exit_sni"
    ]
    if all(str(route.get(k, "")).strip() for k in required):
        routes.append(route)

if not routes:
    sys.exit(0)

routes.sort(key=lambda r: int(r["relay_port"]))
fd = os.open(routes_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"routes": routes}, f, indent=2, ensure_ascii=False)
print(f"MIGRATED={len(routes)}")
PYEOF
}

port_in_use() {
    local port="$1"
    ss -tln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
}

get_public_ip() {
    if [ -f "$IP_CACHE_FILE" ]; then
        local age cached
        age=$(( $(date +%s) - $(stat -c %Y "$IP_CACHE_FILE" 2>/dev/null || echo 0) ))
        cached=$(cat "$IP_CACHE_FILE" 2>/dev/null || true)
        if [ "$age" -lt "$IP_CACHE_TTL" ] && HOST_VALUE="$cached" python3 - <<'PYEOF' >/dev/null 2>&1
import ipaddress
import os
ipaddress.ip_address(os.environ["HOST_VALUE"].strip())
PYEOF
        then
            echo "$cached"
            return
        fi
    fi

    local ip=""
    for provider in https://api.ipify.org https://ip.sb https://icanhazip.com https://ifconfig.me; do
        ip=$(curl -fsS4 --max-time 6 "$provider" 2>/dev/null | tr -d '[:space:]' || true)
        if HOST_VALUE="$ip" python3 - <<'PYEOF' >/dev/null 2>&1
import ipaddress
import os
ipaddress.ip_address(os.environ["HOST_VALUE"].strip())
PYEOF
        then
            printf '%s\n' "$ip" > "$IP_CACHE_FILE" || true
            chmod 600 "$IP_CACHE_FILE" 2>/dev/null || true
            echo "$ip"
            return
        fi
    done

    prompt ip "无法自动获取公网 IP，请手动输入"
    echo "$ip"
}

install_deps() {
    echo -e "${GREEN}[安装依赖]${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y --no-install-recommends curl ca-certificates python3 openssl iproute2 qrencode
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates python3 openssl iproute qrencode
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates python3 openssl iproute qrencode
    else
        die "未检测到 apt-get/dnf/yum，无法自动安装依赖"
    fi
}

install_xray() {
    if command -v xray >/dev/null 2>&1; then
        ok "Xray 已安装: $(command -v xray)"
        return
    fi

    echo -e "${GREEN}[安装 Xray]${NC}"
    local url tmp actual_sha
    url="https://raw.githubusercontent.com/XTLS/Xray-install/${XRAY_INSTALL_REF}/install-release.sh"
    tmp=$(mktemp /tmp/xray-install.XXXXXX.sh)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    curl -fsSL --max-time 30 "$url" -o "$tmp" || die "下载 Xray 安装脚本失败：$url"
    head -1 "$tmp" | grep -q '^#!' || die "下载内容不是 shell 脚本"
    grep -q 'Xray' "$tmp" || die "下载内容缺少 Xray 关键字"

    actual_sha=$(sha256sum "$tmp" | awk '{print $1}')
    if [ -n "$XRAY_INSTALL_SHA256" ]; then
        [ "$actual_sha" = "$XRAY_INSTALL_SHA256" ] || die "Xray 安装脚本 sha256 不匹配"
        ok "Xray 安装脚本 sha256 校验通过"
    else
        warn "未设置 XRAY_INSTALL_SHA256，当前 install-release.sh sha256: $actual_sha"
    fi

    bash "$tmp" install
}

enable_bbr() {
    echo -e "${GREEN}[启用 BBR / TCP 优化]${NC}"
    cat > "$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.core.somaxconn=8192
net.core.netdev_max_backlog=8192
EOF
    sysctl --system >/dev/null 2>&1 || true
    mkdir -p /etc/systemd/system/xray.service.d
    cat > /etc/systemd/system/xray.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=65535
EOF
    ok "内核参数已写入 $SYSCTL_FILE"
}

open_firewall_port() {
    local port="$1"
    echo -e "${GREEN}[放行防火墙端口 ${port}/tcp]${NC}"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null || true
        ok "ufw 已放行 ${port}/tcp"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null || true
        firewall-cmd --reload >/dev/null || true
        ok "firewalld 已放行 ${port}/tcp"
    elif command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || true
        fi
        ok "iptables 已尝试放行 ${port}/tcp"
    else
        warn "未找到可自动配置的防火墙工具"
    fi
    warn "云厂商安全组仍需手动放行 ${port}/tcp"
}

generate_reality_material() {
    local key_output
    key_output=$(xray x25519)
    PRIVATE_KEY=$(printf '%s\n' "$key_output" | awk -F':[[:space:]]*' 'tolower($1) ~ /private/ {print $2; exit}')
    PUBLIC_KEY=$(printf '%s\n' "$key_output" | awk -F':[[:space:]]*' 'tolower($1) ~ /public/ {print $2; exit}')
    [ -n "$PRIVATE_KEY" ] || die "无法从 xray x25519 输出解析 PrivateKey"
    [ -n "$PUBLIC_KEY" ] || die "无法从 xray x25519 输出解析 PublicKey"
    SHORT_ID=$(openssl rand -hex 8)
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 - <<'PYEOF'
import uuid
print(uuid.uuid4())
PYEOF
)
}

write_info() {
    local role="$1"
    shift
    ROLE="$role" INFO_FILE="$INFO_FILE" python3 - "$@" <<'PYEOF'
import json
import os
import sys

items = sys.argv[1:]
data = {"role": os.environ["ROLE"]}
for item in items:
    key, value = item.split("=", 1)
    data[key] = value
fd = os.open(os.environ["INFO_FILE"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF
}

make_exit_bundle() {
    EXIT_HOST_VALUE="$1" EXIT_PORT_VALUE="$2" EXIT_UUID_VALUE="$3" \
    EXIT_PUBLIC_KEY_VALUE="$4" EXIT_SHORT_ID_VALUE="$5" EXIT_SNI_VALUE="$6" \
    python3 - <<'PYEOF'
import base64
import json
import os

data = {
    "exit_host": os.environ["EXIT_HOST_VALUE"],
    "exit_port": os.environ["EXIT_PORT_VALUE"],
    "exit_uuid": os.environ["EXIT_UUID_VALUE"],
    "exit_public_key": os.environ["EXIT_PUBLIC_KEY_VALUE"],
    "exit_short_id": os.environ["EXIT_SHORT_ID_VALUE"],
    "exit_sni": os.environ["EXIT_SNI_VALUE"],
}
raw = json.dumps(data, separators=(",", ":"), sort_keys=True).encode()
print(base64.urlsafe_b64encode(raw).decode())
PYEOF
}

load_exit_bundle() {
    [ -n "${EXIT_BUNDLE:-}" ] || return 1

    local parsed
    parsed=$(EXIT_BUNDLE="$EXIT_BUNDLE" python3 - <<'PYEOF'
import base64
import json
import os
import shlex
import sys

required = {
    "exit_host": "EXIT_HOST",
    "exit_port": "EXIT_PORT",
    "exit_uuid": "EXIT_UUID",
    "exit_public_key": "EXIT_PUBLIC_KEY",
    "exit_short_id": "EXIT_SHORT_ID",
    "exit_sni": "EXIT_SNI",
}
try:
    raw = base64.urlsafe_b64decode(os.environ["EXIT_BUNDLE"].encode())
    data = json.loads(raw.decode())
except Exception as exc:
    print(f"ERR=无法解析 EXIT_BUNDLE: {exc}", file=sys.stderr)
    sys.exit(1)
if not isinstance(data, dict):
    print("ERR=EXIT_BUNDLE 内容不是对象", file=sys.stderr)
    sys.exit(1)
for src, dst in required.items():
    value = data.get(src)
    if not isinstance(value, str) or not value:
        print(f"ERR=EXIT_BUNDLE 缺少字段: {src}", file=sys.stderr)
        sys.exit(1)
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        print(f"ERR=EXIT_BUNDLE 字段含控制字符: {src}", file=sys.stderr)
        sys.exit(1)
    print(f"{dst}={shlex.quote(value)}")
PYEOF
)
    eval "$parsed"
    ok "已从 EXIT_BUNDLE 自动载入 Exit 参数"
}

print_relay_oneclick_command() {
    local bundle="$1"
    echo ""
    echo -e "${CYAN}━━━ 下一步：安装 Relay VPS ━━━${NC}"
    echo -e "${GREEN}现在请登录第二台服务器（中转 VPS / Relay），粘贴下面整段命令：${NC}"
    echo ""
    echo -e "${YELLOW}curl -fsSL ${SCRIPT_URL} -o ${SCRIPT_PATH}${NC}"
    echo -e "${YELLOW}chmod +x ${SCRIPT_PATH}${NC}"
    echo -e "${YELLOW}EXIT_BUNDLE='${bundle}' RELAY_PORT='443' AUTO_YES=1 ${SCRIPT_PATH} --relay${NC}"
    echo ""
    echo -e "${CYAN}这段命令只应该在 Relay VPS 上执行，不要回到当前 Exit VPS 执行。${NC}"
    echo -e "${CYAN}同一台 Relay 添加第二条及以上线路时，请把 RELAY_PORT 改成未使用端口。${NC}"
}

create_exit_config() {
    local tmp="$1"
    CONFIG_OUT="$tmp" UUID="$UUID" PRIVATE_KEY="$PRIVATE_KEY" SHORT_ID="$SHORT_ID" \
    LISTEN_PORT="$EXIT_PORT" REALITY_DEST="$REALITY_DEST" REALITY_SERVER_NAME="$REALITY_SERVER_NAME" \
    python3 - <<'PYEOF'
import json
import os

config = {
    "log": {"loglevel": "warning"},
    "stats": {},
    "api": {"tag": "api", "services": ["StatsService"]},
    "policy": {
        "system": {
            "statsInboundUplink": True,
            "statsInboundDownlink": True,
            "statsOutboundUplink": True,
            "statsOutboundDownlink": True
        }
    },
    "inbounds": [{
        "tag": "api-in",
        "listen": "127.0.0.1",
        "port": 10085,
        "protocol": "dokodemo-door",
        "settings": {"address": "127.0.0.1"}
    }, {
        "tag": "from-relay",
        "listen": "0.0.0.0",
        "port": int(os.environ["LISTEN_PORT"]),
        "protocol": "vless",
        "settings": {
            "clients": [{
                "id": os.environ["UUID"],
                "flow": "xtls-rprx-vision"
            }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": os.environ["REALITY_DEST"],
                "xver": 0,
                "serverNames": [os.environ["REALITY_SERVER_NAME"]],
                "privateKey": os.environ["PRIVATE_KEY"],
                "shortIds": [os.environ["SHORT_ID"]]
            },
            "sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}
        },
        "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
    }],
    "outbounds": [
        {"tag": "api", "protocol": "freedom"},
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"},
            {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
            {"type": "field", "inboundTag": ["from-relay"], "outboundTag": "direct"}
        ]
    }
}
with open(os.environ["CONFIG_OUT"], "w") as f:
    json.dump(config, f, indent=2)
os.chmod(os.environ["CONFIG_OUT"], 0o600)
PYEOF
}

create_relay_config() {
    local tmp="$1"
    CONFIG_OUT="$tmp" CLIENT_UUID="$CLIENT_UUID" CLIENT_PRIVATE_KEY="$CLIENT_PRIVATE_KEY" \
    CLIENT_SHORT_ID="$CLIENT_SHORT_ID" RELAY_PORT="$RELAY_PORT" REALITY_DEST="$REALITY_DEST" \
    REALITY_SERVER_NAME="$REALITY_SERVER_NAME" EXIT_HOST="$EXIT_HOST" EXIT_PORT="$EXIT_PORT" \
    EXIT_UUID="$EXIT_UUID" EXIT_PUBLIC_KEY="$EXIT_PUBLIC_KEY" EXIT_SHORT_ID="$EXIT_SHORT_ID" \
    EXIT_SNI="$EXIT_SNI" CLIENT_FP="$CLIENT_FP" \
    python3 - <<'PYEOF'
import json
import os

config = {
    "log": {"loglevel": "warning"},
    "stats": {},
    "api": {"tag": "api", "services": ["StatsService"]},
    "policy": {
        "system": {
            "statsInboundUplink": True,
            "statsInboundDownlink": True,
            "statsOutboundUplink": True,
            "statsOutboundDownlink": True
        }
    },
    "inbounds": [{
        "tag": "api-in",
        "listen": "127.0.0.1",
        "port": 10085,
        "protocol": "dokodemo-door",
        "settings": {"address": "127.0.0.1"}
    }, {
        "tag": "client-in",
        "listen": "0.0.0.0",
        "port": int(os.environ["RELAY_PORT"]),
        "protocol": "vless",
        "settings": {
            "clients": [{
                "id": os.environ["CLIENT_UUID"],
                "flow": "xtls-rprx-vision"
            }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": os.environ["REALITY_DEST"],
                "xver": 0,
                "serverNames": [os.environ["REALITY_SERVER_NAME"]],
                "privateKey": os.environ["CLIENT_PRIVATE_KEY"],
                "shortIds": [os.environ["CLIENT_SHORT_ID"]]
            },
            "sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}
        },
        "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
    }],
    "outbounds": [
        {"tag": "api", "protocol": "freedom"},
        {
            "tag": "to-exit",
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": os.environ["EXIT_HOST"],
                    "port": int(os.environ["EXIT_PORT"]),
                    "users": [{
                        "id": os.environ["EXIT_UUID"],
                        "encryption": "none",
                        "flow": "xtls-rprx-vision"
                    }]
                }]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "serverName": os.environ["EXIT_SNI"],
                    "fingerprint": os.environ["CLIENT_FP"],
                    "publicKey": os.environ["EXIT_PUBLIC_KEY"],
                    "shortId": os.environ["EXIT_SHORT_ID"],
                    "spiderX": "/"
                },
                "sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}
            }
        },
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"},
            {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
            {"type": "field", "inboundTag": ["client-in"], "outboundTag": "to-exit"}
        ]
    }
}
with open(os.environ["CONFIG_OUT"], "w") as f:
    json.dump(config, f, indent=2)
os.chmod(os.environ["CONFIG_OUT"], 0o600)
PYEOF
}

save_relay_route() {
    local route_name="$1"
    ROUTES_FILE="$ROUTES_FILE" ROUTE_NAME="$route_name" \
    RELAY_PORT="$RELAY_PORT" CLIENT_UUID="$CLIENT_UUID" CLIENT_PRIVATE_KEY="$CLIENT_PRIVATE_KEY" \
    CLIENT_PUBLIC_KEY="$CLIENT_PUBLIC_KEY" CLIENT_SHORT_ID="$CLIENT_SHORT_ID" \
    EXIT_HOST="$EXIT_HOST" EXIT_PORT="$EXIT_PORT" EXIT_UUID="$EXIT_UUID" \
    EXIT_PUBLIC_KEY="$EXIT_PUBLIC_KEY" EXIT_SHORT_ID="$EXIT_SHORT_ID" EXIT_SNI="$EXIT_SNI" \
    REALITY_SERVER_NAME="$REALITY_SERVER_NAME" CLIENT_FP="$CLIENT_FP" \
    python3 - <<'PYEOF'
import json
import os
import time

path = os.environ["ROUTES_FILE"]
relay_port = os.environ["RELAY_PORT"]
route = {
    "name": os.environ["ROUTE_NAME"],
    "relay_port": relay_port,
    "client_uuid": os.environ["CLIENT_UUID"],
    "client_private_key": os.environ["CLIENT_PRIVATE_KEY"],
    "client_public_key": os.environ["CLIENT_PUBLIC_KEY"],
    "client_short_id": os.environ["CLIENT_SHORT_ID"],
    "client_sni": os.environ["REALITY_SERVER_NAME"],
    "client_fp": os.environ["CLIENT_FP"],
    "exit_host": os.environ["EXIT_HOST"],
    "exit_port": os.environ["EXIT_PORT"],
    "exit_uuid": os.environ["EXIT_UUID"],
    "exit_public_key": os.environ["EXIT_PUBLIC_KEY"],
    "exit_short_id": os.environ["EXIT_SHORT_ID"],
    "exit_sni": os.environ["EXIT_SNI"],
    "updated_at": int(time.time()),
}
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {"routes": []}
if not isinstance(data, dict) or not isinstance(data.get("routes"), list):
    data = {"routes": []}
routes = [r for r in data["routes"] if str(r.get("relay_port")) != relay_port]
routes.append(route)
routes.sort(key=lambda r: int(r["relay_port"]))
data = {"routes": routes}
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF
}

create_relay_multi_config() {
    local tmp="$1"
    ROUTES_FILE="$ROUTES_FILE" CONFIG_OUT="$tmp" REALITY_DEST="$REALITY_DEST" \
    python3 - <<'PYEOF'
import json
import os
import sys

routes_path = os.environ["ROUTES_FILE"]
try:
    with open(routes_path) as f:
        data = json.load(f)
except FileNotFoundError:
    print(f"routes file not found: {routes_path}", file=sys.stderr)
    sys.exit(1)
routes = data.get("routes", [])
if not isinstance(routes, list) or not routes:
    print("no relay routes configured", file=sys.stderr)
    sys.exit(1)

seen_ports = set()
inbounds = [{
    "tag": "api-in",
    "listen": "127.0.0.1",
    "port": 10085,
    "protocol": "dokodemo-door",
    "settings": {"address": "127.0.0.1"}
}]
outbounds = [{"tag": "api", "protocol": "freedom"}]
rules = [
    {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"},
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
]

required = [
    "name", "relay_port", "client_uuid", "client_private_key", "client_short_id",
    "client_sni", "exit_host", "exit_port", "exit_uuid", "exit_public_key",
    "exit_short_id", "exit_sni"
]
for route in routes:
    for key in required:
        if not str(route.get(key, "")).strip():
            print(f"route missing {key}", file=sys.stderr)
            sys.exit(1)
    relay_port = int(route["relay_port"])
    if not 1 <= relay_port <= 65535:
        print(f"invalid relay_port: {relay_port}", file=sys.stderr)
        sys.exit(1)
    if relay_port in seen_ports:
        print(f"duplicate relay_port: {relay_port}", file=sys.stderr)
        sys.exit(1)
    seen_ports.add(relay_port)

    inbound_tag = f"client-in-{relay_port}"
    outbound_tag = f"to-exit-{relay_port}"
    inbounds.append({
        "tag": inbound_tag,
        "listen": "0.0.0.0",
        "port": relay_port,
        "protocol": "vless",
        "_remark": route["name"],
        "settings": {
            "clients": [{
                "id": route["client_uuid"],
                "flow": "xtls-rprx-vision"
            }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": os.environ["REALITY_DEST"],
                "xver": 0,
                "serverNames": [route["client_sni"]],
                "privateKey": route["client_private_key"],
                "shortIds": [route["client_short_id"]]
            },
            "sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}
        },
        "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
    })
    outbounds.append({
        "tag": outbound_tag,
        "protocol": "vless",
        "_remark": route["name"],
        "settings": {
            "vnext": [{
                "address": route["exit_host"],
                "port": int(route["exit_port"]),
                "users": [{
                    "id": route["exit_uuid"],
                    "encryption": "none",
                    "flow": "xtls-rprx-vision"
                }]
            }]
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "serverName": route["exit_sni"],
                "fingerprint": route.get("client_fp") or "chrome",
                "publicKey": route["exit_public_key"],
                "shortId": route["exit_short_id"],
                "spiderX": "/"
            },
            "sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}
        }
    })
    rules.append({
        "type": "field",
        "inboundTag": [inbound_tag],
        "outboundTag": outbound_tag
    })

config = {
    "log": {"loglevel": "warning"},
    "stats": {},
    "api": {"tag": "api", "services": ["StatsService"]},
    "policy": {
        "system": {
            "statsInboundUplink": True,
            "statsInboundDownlink": True,
            "statsOutboundUplink": True,
            "statsOutboundDownlink": True
        }
    },
    "inbounds": inbounds,
    "outbounds": outbounds + [
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
    ],
    "routing": {"domainStrategy": "IPIfNonMatch", "rules": rules}
}
with open(os.environ["CONFIG_OUT"], "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
os.chmod(os.environ["CONFIG_OUT"], 0o600)
PYEOF
}

install_config() {
    local tmp="$1"
    LAST_CONFIG_BACKUP=""
    mkdir -p "$(dirname "$CONFIG_FILE")"
    if ! xray run -test -config "$tmp" >/dev/null; then
        echo -e "${RED}✗ Xray 配置校验失败${NC}" >&2
        return 1
    fi

    if [ -f "$CONFIG_FILE" ]; then
        local backup
        backup="${CONFIG_FILE}.$(date +%Y%m%d%H%M%S).bak"
        cp -a "$CONFIG_FILE" "$backup"
        LAST_CONFIG_BACKUP="$backup"
        find "$(dirname "$CONFIG_FILE")" -maxdepth 1 -name 'config.json.*.bak' -type f \
            | sort -r | tail -n +"$((BACKUP_KEEP + 1))" | xargs -r rm -f
        ok "旧配置已备份：$backup"
    fi

    install -m 600 -o root "$tmp" "$CONFIG_FILE"
    local service_user service_group
    service_user=$(systemctl cat xray 2>/dev/null | awk -F= '$1 == "User" {print $2; exit}' || true)
    if [ -n "$service_user" ] && id "$service_user" >/dev/null 2>&1; then
        service_group=$(id -gn "$service_user")
        chown "root:${service_group}" "$CONFIG_FILE" || true
        chmod 640 "$CONFIG_FILE"
    elif getent group xray >/dev/null 2>&1; then
        chgrp xray "$CONFIG_FILE" || true
        chmod 640 "$CONFIG_FILE"
    else
        chmod 644 "$CONFIG_FILE"
    fi
    ok "配置已写入 $CONFIG_FILE"
}

rollback_config() {
    if [ -n "$LAST_CONFIG_BACKUP" ] && [ -f "$LAST_CONFIG_BACKUP" ]; then
        warn "正在回滚 Xray 配置到：$LAST_CONFIG_BACKUP"
        cp -a "$LAST_CONFIG_BACKUP" "$CONFIG_FILE"
        systemctl restart xray >/dev/null 2>&1 || true
        return 0
    fi
    warn "没有旧配置可回滚，正在移除新配置并停止 Xray"
    rm -f "$CONFIG_FILE"
    systemctl stop xray >/dev/null 2>&1 || true
}

backup_routes_file() {
    if [ -f "$ROUTES_FILE" ]; then
        local backup
        backup="${ROUTES_FILE}.$(date +%Y%m%d%H%M%S).bak"
        cp -a "$ROUTES_FILE" "$backup"
        printf '%s\n' "$backup"
    else
        printf '%s\n' "__none__"
    fi
}

restore_routes_file() {
    local backup="$1"
    if [ "$backup" = "__none__" ]; then
        rm -f "$ROUTES_FILE"
        return 0
    fi
    if [ -f "$backup" ]; then
        cp -a "$backup" "$ROUTES_FILE"
    fi
}

rollback_config_and_routes() {
    local routes_backup="$1"
    restore_routes_file "$routes_backup"
    rollback_config
}

restart_xray() {
    systemctl daemon-reload
    systemctl enable xray >/dev/null
    if ! systemctl restart xray; then
        echo -e "${RED}✗ Xray 重启失败${NC}" >&2
        return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}✗ Xray 启动失败，请查看：journalctl -u xray -n 80 --no-pager${NC}" >&2
        return 1
    fi
    ok "Xray 已启动"
}

url_encode() {
    VALUE="$1" python3 - <<'PYEOF'
import os
from urllib.parse import quote
print(quote(os.environ["VALUE"], safe=""))
PYEOF
}

print_client_link() {
    local relay_host="$1"
    local remark encoded_remark link
    remark="${2:-VPS2VPS-Relay}"
    encoded_remark=$(url_encode "$remark")
    link="vless://${CLIENT_UUID}@${relay_host}:${RELAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=${CLIENT_FP}&pbk=${CLIENT_PUBLIC_KEY}&sid=${CLIENT_SHORT_ID}&type=tcp#${encoded_remark}"

    echo ""
    echo -e "${CYAN}━━━ 客户端导入链接 ━━━${NC}"
    echo -e "${YELLOW}${link}${NC}"
    if command -v qrencode >/dev/null 2>&1; then
        echo ""
        qrencode -t ANSIUTF8 -m 2 "$link" || true
    fi
}

print_route_link() {
    local relay_host="$1"
    local relay_port="$2"
    local client_uuid="$3"
    local client_public_key="$4"
    local client_short_id="$5"
    local client_sni="$6"
    local route_name="$7"
    local encoded_remark link
    encoded_remark=$(url_encode "$route_name")
    link="vless://${client_uuid}@${relay_host}:${relay_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${client_sni}&fp=${CLIENT_FP}&pbk=${client_public_key}&sid=${client_short_id}&type=tcp#${encoded_remark}"
    echo -e "${YELLOW}${link}${NC}"
}

list_relay_routes() {
    if [ ! -f "$ROUTES_FILE" ]; then
        warn "未找到 Relay 线路表：$ROUTES_FILE"
        return 0
    fi

    local relay_ip
    relay_ip=$(get_public_ip)
    ROUTES_FILE="$ROUTES_FILE" RELAY_IP="$relay_ip" CLIENT_FP="$CLIENT_FP" python3 - <<'PYEOF'
import json
import os
from urllib.parse import quote

path = os.environ["ROUTES_FILE"]
with open(path) as f:
    data = json.load(f)
routes = data.get("routes", [])
if not routes:
    print("暂无 Relay 线路")
    raise SystemExit(0)

print("Relay 线路列表:")
for idx, route in enumerate(routes, 1):
    name = route["name"]
    relay_port = route["relay_port"]
    exit_host = route["exit_host"]
    exit_port = route["exit_port"]
    print(f"{idx}. {name}")
    print(f"   Relay: {os.environ['RELAY_IP']}:{relay_port}")
    print(f"   Exit:  {exit_host}:{exit_port}")
    link = (
        f"vless://{route['client_uuid']}@{os.environ['RELAY_IP']}:{relay_port}"
        f"?encryption=none&flow=xtls-rprx-vision&security=reality"
        f"&sni={route['client_sni']}&fp={route.get('client_fp') or os.environ['CLIENT_FP']}"
        f"&pbk={route['client_public_key']}&sid={route['client_short_id']}"
        f"&type=tcp#{quote(name, safe='')}"
    )
    print(f"   Link:  {link}")
PYEOF
}

show_route_status() {
    echo -e "${GREEN}[线路状态]${NC}"
    if systemctl is-active --quiet xray; then
        ok "Xray 服务运行中"
    else
        warn "Xray 服务未运行"
    fi

    if [ ! -f "$ROUTES_FILE" ]; then
        warn "未找到 Relay 线路表：$ROUTES_FILE"
        return 0
    fi

    ROUTES_FILE="$ROUTES_FILE" python3 - <<'PYEOF'
import json
import os

routes = json.load(open(os.environ["ROUTES_FILE"])).get("routes", [])
if not routes:
    print("暂无 Relay 线路")
    raise SystemExit(0)
print("线路状态:")
for route in routes:
    print(f"- {route['name']}: Relay:{route['relay_port']} -> Exit:{route['exit_host']}:{route['exit_port']}")
PYEOF

    echo ""
    echo "监听端口:"
    while IFS= read -r port; do
        [ -n "$port" ] || continue
        if ss -tln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
            echo -e "  ${GREEN}✓ ${port}/tcp 正在监听${NC}"
        else
            echo -e "  ${RED}✗ ${port}/tcp 未监听${NC}"
        fi
    done < <(ROUTES_FILE="$ROUTES_FILE" python3 - <<'PYEOF'
import json
import os
try:
    routes = json.load(open(os.environ["ROUTES_FILE"])).get("routes", [])
except Exception:
    routes = []
for route in routes:
    print(route.get("relay_port", ""))
PYEOF
)

    echo ""
    echo "落地连通性:"
    while IFS=$'\t' read -r name host port; do
        [ -n "$host" ] || continue
        if timeout 5 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓ ${name}: ${host}:${port} 可达${NC}"
        else
            echo -e "  ${RED}✗ ${name}: ${host}:${port} 不可达${NC}"
        fi
    done < <(ROUTES_FILE="$ROUTES_FILE" python3 - <<'PYEOF'
import json
import os
try:
    routes = json.load(open(os.environ["ROUTES_FILE"])).get("routes", [])
except Exception:
    routes = []
for route in routes:
    print(f"{route.get('name', '')}\t{route.get('exit_host', '')}\t{route.get('exit_port', '')}")
PYEOF
)
}

format_bytes_py='
def fmt(n):
    try:
        n = int(n)
    except Exception:
        n = 0
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    value = float(n)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.2f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
'

show_traffic_stats() {
    echo -e "${GREEN}[流量统计]${NC}"
    if [ ! -f "$ROUTES_FILE" ]; then
        warn "未找到 Relay 线路表：$ROUTES_FILE"
        return 0
    fi
    if ! systemctl is-active --quiet xray; then
        warn "Xray 未运行，无法读取实时统计"
        return 0
    fi
    if ! command -v xray >/dev/null 2>&1; then
        warn "未找到 xray 命令"
        return 0
    fi

    local stats_output
    if ! stats_output=$(xray api statsquery --server=127.0.0.1:10085 -pattern ">>>traffic>>>" 2>/dev/null); then
        warn "无法读取 Xray Stats API。请确认当前配置由新版脚本生成，并重启 Xray。"
        return 0
    fi

    ROUTES_FILE="$ROUTES_FILE" STATS_RAW="$stats_output" python3 - <<PYEOF
import json
import os
import re

${format_bytes_py}

routes = json.load(open(os.environ["ROUTES_FILE"])).get("routes", [])
try:
    payload = json.loads(os.environ["STATS_RAW"])
except Exception:
    payload = {}

stats = {}
for item in payload.get("stat", []) or payload.get("stats", []):
    name = item.get("name", "")
    value = int(item.get("value", 0))
    stats[name] = value
if not stats:
    raw = os.environ["STATS_RAW"]
    for name, value in re.findall(r'name:\\s*"([^"]+)"\\s*value:\\s*(\\d+)', raw, re.S):
        stats[name] = int(value)

def get(name):
    return stats.get(name, 0)

if not routes:
    print("暂无 Relay 线路")
    raise SystemExit(0)

print("线路流量统计（Xray 启动以来）:")
for route in routes:
    port = str(route["relay_port"])
    inbound = f"client-in-{port}"
    outbound = f"to-exit-{port}"
    in_up = get(f"inbound>>>{inbound}>>>traffic>>>uplink")
    in_down = get(f"inbound>>>{inbound}>>>traffic>>>downlink")
    out_up = get(f"outbound>>>{outbound}>>>traffic>>>uplink")
    out_down = get(f"outbound>>>{outbound}>>>traffic>>>downlink")
    print(f"- {route['name']} ({port} -> {route['exit_host']}:{route['exit_port']})")
    print(f"  客户端上行: {fmt(in_up)}")
    print(f"  客户端下行: {fmt(in_down)}")
    print(f"  Relay 出站上行: {fmt(out_up)}")
    print(f"  Relay 出站下行: {fmt(out_down)}")
PYEOF
}

rename_relay_route() {
    if [ ! -f "$ROUTES_FILE" ]; then
        warn "未找到 Relay 线路表：$ROUTES_FILE"
        return 0
    fi

    list_relay_routes
    echo ""
    prompt RENAME_RELAY_PORT "要修改名称的 Relay 入口端口"
    valid_port "$RENAME_RELAY_PORT" || die "端口必须是 1-65535"
    prompt NEW_ROUTE_NAME "新的线路名称"
    [ -n "$NEW_ROUTE_NAME" ] || die "线路名称不能为空"

    local routes_backup tmp
    routes_backup=$(backup_routes_file)
    if ! ROUTES_FILE="$ROUTES_FILE" RENAME_RELAY_PORT="$RENAME_RELAY_PORT" NEW_ROUTE_NAME="$NEW_ROUTE_NAME" python3 - <<'PYEOF'
import json
import os
import sys

path = os.environ["ROUTES_FILE"]
port = os.environ["RENAME_RELAY_PORT"]
new_name = os.environ["NEW_ROUTE_NAME"]
data = json.load(open(path))
routes = data.get("routes", [])
changed = False
for route in routes:
    if str(route.get("relay_port")) == port:
        route["name"] = new_name
        changed = True
if not changed:
    print(f"未找到端口 {port} 对应的线路", file=sys.stderr)
    sys.exit(1)
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"routes": routes}, f, indent=2, ensure_ascii=False)
PYEOF
    then
        restore_routes_file "$routes_backup"
        die "修改线路名称失败，已恢复线路表"
    fi

    tmp=$(mktemp /tmp/xray-vps2vps-relay.XXXXXX.json)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    if ! create_relay_multi_config "$tmp"; then
        restore_routes_file "$routes_backup"
        die "生成重命名后的 Relay 配置失败，已恢复线路表"
    fi
    if ! install_config "$tmp"; then
        restore_routes_file "$routes_backup"
        die "安装重命名后的 Relay 配置失败，已恢复线路表"
    fi
    if ! restart_xray; then
        rollback_config_and_routes "$routes_backup"
        die "Xray 重启失败，已回滚配置和线路表"
    fi
    ok "线路名称已修改"
}

delete_relay_route() {
    if [ ! -f "$ROUTES_FILE" ]; then
        warn "未找到 Relay 线路表：$ROUTES_FILE"
        return 0
    fi

    list_relay_routes
    echo ""
    prompt DELETE_RELAY_PORT "要删除的 Relay 入口端口"
    valid_port "$DELETE_RELAY_PORT" || die "端口必须是 1-65535"

    local routes_backup remaining
    routes_backup=$(backup_routes_file)
    remaining=$(ROUTES_FILE="$ROUTES_FILE" DELETE_RELAY_PORT="$DELETE_RELAY_PORT" python3 - <<'PYEOF'
import json
import os
import sys

path = os.environ["ROUTES_FILE"]
delete_port = os.environ["DELETE_RELAY_PORT"]
with open(path) as f:
    data = json.load(f)
routes = data.get("routes", [])
new_routes = [r for r in routes if str(r.get("relay_port")) != delete_port]
if len(new_routes) == len(routes):
    print(f"ERR: 未找到端口 {delete_port} 对应的线路", file=sys.stderr)
    sys.exit(2)
data = {"routes": new_routes}
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print(len(new_routes))
PYEOF
)

    if [ "$remaining" -eq 0 ]; then
        warn "已删除最后一条线路，正在停止 Xray。"
        if ! systemctl stop xray >/dev/null 2>&1; then
            restore_routes_file "$routes_backup"
            die "停止 Xray 失败，已恢复线路表"
        fi
        ok "线路已删除"
        return 0
    fi

    local tmp
    tmp=$(mktemp /tmp/xray-vps2vps-relay.XXXXXX.json)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    if ! create_relay_multi_config "$tmp"; then
        restore_routes_file "$routes_backup"
        die "生成删除后的 Relay 配置失败，已恢复线路表"
    fi
    if ! install_config "$tmp"; then
        restore_routes_file "$routes_backup"
        die "安装删除后的 Relay 配置失败，已恢复线路表"
    fi
    if ! restart_xray; then
        rollback_config_and_routes "$routes_backup"
        die "Xray 重启失败，已回滚配置和线路表"
    fi
    ok "线路已删除，其余 ${remaining} 条线路不受影响"
}

relay_manager() {
    while true; do
        print_banner
        echo "Relay 多线路管理（每条线路使用一个独立入口端口）"
        echo ""
        echo "1) 添加/更新一条落地线路"
        echo "2) 查看线路状态"
        echo "3) 流量统计"
        echo "4) 删除一条线路"
        echo "5) 修改线路名称"
        echo "6) 查看所有线路和客户端链接"
        echo "7) 重启 Xray"
        echo "0) 返回"
        echo ""
        read -r -p "请选择: " relay_choice
        case "$relay_choice" in
            1) install_relay; break ;;
            2) show_route_status; read -r -p "按回车返回菜单..." _ ;;
            3) show_traffic_stats; read -r -p "按回车返回菜单..." _ ;;
            4) delete_relay_route; break ;;
            5) rename_relay_route; break ;;
            6) list_relay_routes; read -r -p "按回车返回菜单..." _ ;;
            7) restart_xray; read -r -p "按回车返回菜单..." _ ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
    done
}

install_exit() {
    echo -e "${GREEN}[Exit VPS 部署]${NC}"
    echo -e "${CYAN}当前步骤：Step 1 / 2，在落地 VPS 上安装 Exit。${NC}"
    echo -e "${CYAN}安装完成后再去第二台中转 VPS 安装 Relay。${NC}"
    prompt EXIT_PORT "Exit 监听端口" "${EXIT_PORT:-443}"
    valid_port "$EXIT_PORT" || die "端口必须是 1-65535"
    if port_in_use "$EXIT_PORT"; then
        warn "端口 $EXIT_PORT 看起来已被占用；如果是旧 Xray 配置，可继续覆盖后重启"
    fi

    install_deps
    install_xray
    enable_bbr
    generate_reality_material

    local tmp exit_ip exit_bundle
    tmp=$(mktemp /tmp/xray-vps2vps-exit.XXXXXX.json)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    create_exit_config "$tmp"
    install_config "$tmp" || die "安装 Exit 配置失败"
    open_firewall_port "$EXIT_PORT"
    if ! restart_xray; then
        rollback_config
        die "Xray 重启失败，已回滚 Exit 配置"
    fi

    exit_ip=$(get_public_ip)
    write_info "exit" \
        "exit_host=$exit_ip" \
        "exit_port=$EXIT_PORT" \
        "exit_uuid=$UUID" \
        "exit_public_key=$PUBLIC_KEY" \
        "exit_short_id=$SHORT_ID" \
        "exit_sni=$REALITY_SERVER_NAME"

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                Exit VPS 部署完成              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo -e "Exit Host:       ${YELLOW}${exit_ip}${NC}"
    echo -e "Exit Port:       ${YELLOW}${EXIT_PORT}${NC}"
    echo -e "Exit UUID:       ${YELLOW}$(redact "$UUID")${NC}"
    echo -e "Exit Public Key: ${YELLOW}${PUBLIC_KEY}${NC}"
    echo -e "Exit Short ID:   ${YELLOW}${SHORT_ID}${NC}"
    echo -e "Exit SNI:        ${YELLOW}${REALITY_SERVER_NAME}${NC}"
    echo ""
    exit_bundle=$(make_exit_bundle "$exit_ip" "$EXIT_PORT" "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$REALITY_SERVER_NAME")
    print_relay_oneclick_command "$exit_bundle"
    echo -e "${GREEN}也可以手动把以上 6 项填到 Relay VPS 的部署向导里。${NC}"
}

install_relay() {
    echo -e "${GREEN}[Relay VPS 添加/更新线路]${NC}"
    echo -e "${CYAN}当前步骤：在中转 VPS 上添加一条落地线路。${NC}"
    if load_exit_bundle; then
        :
    elif [ "$AUTO_YES" != "1" ]; then
        warn "没有检测到 EXIT_BUNDLE。正常流程是先在落地 VPS 安装 Exit，再复制 Exit 输出的 Relay 安装命令。"
        read -r -p "仍然手动输入 Exit 的 6 个参数继续安装 Relay? (y/n): " manual_continue
        case "$manual_continue" in
            y|Y) ;;
            *) echo "已取消。请先去落地 VPS 安装 Exit。"; exit 0 ;;
        esac
    fi
    local migrated_output
    migrated_output=$(migrate_existing_relay_config_if_needed || true)
    if [ -n "$migrated_output" ]; then
        ok "已迁移旧版单线路配置到 Relay 线路表：${migrated_output#MIGRATED=}"
    fi
    prompt RELAY_PORT "这条线路的 Relay 入口端口" "${RELAY_PORT:-443}"
    valid_port "$RELAY_PORT" || die "端口必须是 1-65535"
    if route_port_exists "$RELAY_PORT" && [ "${ALLOW_OVERWRITE:-0}" != "1" ]; then
        if [ "$AUTO_YES" = "1" ]; then
            die "Relay 端口 ${RELAY_PORT} 已有线路。新增其他落地 VPS 时，请把命令里的 RELAY_PORT 改成未使用端口，例如 8443。若要覆盖旧线路，请设置 ALLOW_OVERWRITE=1"
        fi
        warn "Relay 端口 ${RELAY_PORT} 已有线路。"
        read -r -p "覆盖这条线路? (y/n): " overwrite_choice
        case "$overwrite_choice" in
            y|Y) ;;
            *) echo "已取消。请换一个 RELAY_PORT 后重试。"; exit 0 ;;
        esac
    fi
    if port_in_use "$RELAY_PORT"; then
        warn "端口 $RELAY_PORT 看起来已被占用；如果是旧 Xray 配置，可继续覆盖后重启"
    fi
    prompt EXIT_HOST "Exit Host/IP" "${EXIT_HOST:-}"
    valid_host "$EXIT_HOST" || die "Exit Host/IP 格式不合法"
    prompt EXIT_PORT "Exit Port" "${EXIT_PORT:-443}"
    valid_port "$EXIT_PORT" || die "Exit Port 必须是 1-65535"
    prompt EXIT_UUID "Exit UUID" "${EXIT_UUID:-}"
    valid_uuid "$EXIT_UUID" || die "Exit UUID 格式不合法"
    prompt EXIT_PUBLIC_KEY "Exit Public Key" "${EXIT_PUBLIC_KEY:-}"
    [ -n "$EXIT_PUBLIC_KEY" ] || die "Exit Public Key 不能为空"
    prompt EXIT_SHORT_ID "Exit Short ID" "${EXIT_SHORT_ID:-}"
    valid_short_id "$EXIT_SHORT_ID" || die "Exit Short ID 必须是偶数长度十六进制，长度 2-16"
    prompt EXIT_SNI "Exit SNI" "${EXIT_SNI:-$REALITY_SERVER_NAME}"
    [ -n "$EXIT_SNI" ] || die "Exit SNI 不能为空"
    ROUTE_NAME_DEFAULT="Exit-${EXIT_HOST}-${RELAY_PORT}"
    prompt ROUTE_NAME "线路名称" "${ROUTE_NAME:-$ROUTE_NAME_DEFAULT}"
    [ -n "$ROUTE_NAME" ] || die "线路名称不能为空"

    install_deps
    install_xray
    enable_bbr
    generate_reality_material
    CLIENT_UUID="$UUID"
    CLIENT_PRIVATE_KEY="$PRIVATE_KEY"
    CLIENT_PUBLIC_KEY="$PUBLIC_KEY"
    CLIENT_SHORT_ID="$SHORT_ID"
    local routes_backup
    routes_backup=$(backup_routes_file)
    save_relay_route "$ROUTE_NAME"

    local tmp relay_ip
    tmp=$(mktemp /tmp/xray-vps2vps-relay.XXXXXX.json)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    if ! create_relay_multi_config "$tmp"; then
        restore_routes_file "$routes_backup"
        die "生成 Relay 多线路配置失败，已恢复线路表"
    fi
    if ! install_config "$tmp"; then
        restore_routes_file "$routes_backup"
        die "安装 Relay 配置失败，已恢复线路表"
    fi
    open_firewall_port "$RELAY_PORT"
    if ! restart_xray; then
        rollback_config_and_routes "$routes_backup"
        die "Xray 重启失败，已回滚配置和线路表"
    fi

    relay_ip=$(get_public_ip)
    write_info "relay" \
        "relay_host=$relay_ip" \
        "relay_port=$RELAY_PORT" \
        "client_uuid=$CLIENT_UUID" \
        "client_public_key=$CLIENT_PUBLIC_KEY" \
        "client_short_id=$CLIENT_SHORT_ID" \
        "client_sni=$REALITY_SERVER_NAME" \
        "routes_file=$ROUTES_FILE"

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              Relay 线路添加完成               ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo -e "线路名称:          ${YELLOW}${ROUTE_NAME}${NC}"
    echo -e "Relay Host:        ${YELLOW}${relay_ip}${NC}"
    echo -e "Relay Port:        ${YELLOW}${RELAY_PORT}${NC}"
    echo -e "Exit:              ${YELLOW}${EXIT_HOST}:${EXIT_PORT}${NC}"
    echo -e "Client UUID:       ${YELLOW}$(redact "$CLIENT_UUID")${NC}"
    echo -e "Client Public Key: ${YELLOW}${CLIENT_PUBLIC_KEY}${NC}"
    echo -e "Client Short ID:   ${YELLOW}${CLIENT_SHORT_ID}${NC}"
    echo -e "Client SNI:        ${YELLOW}${REALITY_SERVER_NAME}${NC}"
    print_client_link "$relay_ip" "$ROUTE_NAME"
}

show_info() {
    if [ ! -f "$INFO_FILE" ]; then
        warn "未找到 $INFO_FILE"
    else
        python3 -m json.tool "$INFO_FILE" || cat "$INFO_FILE"
    fi
    echo ""
    list_relay_routes || true
    echo ""
    systemctl status xray --no-pager -l | sed -n '1,12p' || true
}

guided_install() {
    print_banner
    print_install_flow
    echo ""
    echo "请选择当前这台服务器要安装/管理的角色："
    echo "1) Step 1: 安装 Exit 落地 VPS（第一台，最终出口 IP）"
    echo "2) Step 2: 在 Relay 中转 VPS 添加一条线路（第二台，客户端入口）"
    echo "3) 管理 Relay 已有线路（状态/统计/删除/改名/重启）"
    echo "0) 返回"
    echo ""
    read -r -p "请选择: " role_choice
    case "$role_choice" in
        1)
            echo ""
            echo -e "${CYAN}正在安装 Exit。完成后会生成给第二台 Relay VPS 使用的完整命令。${NC}"
            install_exit
            ;;
        2)
            echo ""
            if [ -z "${EXIT_BUNDLE:-}" ]; then
                warn "如果你还没有先安装 Exit，请先退出，到落地 VPS 上选择 Step 1。"
                echo -e "${CYAN}如果你已经在 Exit 上拿到完整命令，更推荐直接粘贴那段命令，而不是走菜单。${NC}"
            fi
            install_relay
            ;;
        3) relay_manager ;;
        0) return ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
}

uninstall_all() {
    warn "这会卸载 Xray 并删除 $CONFIG_FILE / $INFO_FILE"
    read -r -p "确认卸载？(yes/no): " answer
    [ "$answer" = "yes" ] || { echo "已取消"; return; }
    if command -v xray >/dev/null 2>&1; then
        local url tmp
        url="https://raw.githubusercontent.com/XTLS/Xray-install/${XRAY_INSTALL_REF}/install-release.sh"
        tmp=$(mktemp /tmp/xray-remove.XXXXXX.sh)
        # shellcheck disable=SC2064
        trap "rm -f '$tmp'" RETURN
        curl -fsSL --max-time 30 "$url" -o "$tmp" && bash "$tmp" remove || true
    fi
    rm -f "$CONFIG_FILE" "$INFO_FILE" "$ROUTES_FILE" "$IP_CACHE_FILE"
    ok "卸载流程已完成"
}

main_menu() {
    while true; do
        print_banner
        print_install_flow
        echo ""
        echo "1) 推荐向导安装（按 Step 1/Step 2 引导）"
        echo "2) Step 1: Install Exit VPS（落地 VPS，最终直连出站）"
        echo "3) Step 2: Add Relay Route（中转 VPS 添加/更新一条线路）"
        echo "4) Route status（查看线路状态）"
        echo "5) Traffic stats（流量统计）"
        echo "6) Relay route manager（查看/删除/改名多条线路）"
        echo "7) Restart Xray"
        echo "8) Uninstall"
        echo "0) Exit"
        echo ""
        read -r -p "请选择: " choice
        case "$choice" in
            1) guided_install; break ;;
            2) install_exit; break ;;
            3) install_relay; break ;;
            4) show_route_status; read -r -p "按回车返回菜单..." _ ;;
            5) show_traffic_stats; read -r -p "按回车返回菜单..." _ ;;
            6) relay_manager; break ;;
            7) restart_xray; read -r -p "按回车返回菜单..." _ ;;
            8) uninstall_all; break ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
    done
}

case "${1:-}" in
    --help|-h) print_help; exit 0 ;;
esac

require_root
case "${1:-}" in
    --exit) install_exit ;;
    --relay) install_relay ;;
    --list) list_relay_routes ;;
    --stats) show_traffic_stats ;;
    --delete) delete_relay_route ;;
    --rename) rename_relay_route ;;
    --guided|"") main_menu ;;
    --status) show_route_status ;;
    --restart) restart_xray ;;
    *) print_help; die "未知参数：$1" ;;
esac
