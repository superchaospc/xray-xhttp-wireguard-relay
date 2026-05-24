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
  ./xray_vps2vps_deploy.sh --relay      直接安装中转 Relay
  ./xray_vps2vps_deploy.sh --status     查看状态
  ./xray_vps2vps_deploy.sh --help       显示帮助

推荐流程:
  1. 第一台：在落地 VPS 上运行脚本，选择 Exit 安装。
  2. Exit 安装完成后，复制脚本输出的整段 Relay 安装命令。
  3. 第二台：在中转 VPS 上粘贴执行这段命令。
  4. 扫 Relay 输出的二维码或导入 vless:// 链接。

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
    "inbounds": [{
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
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
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
    "inbounds": [{
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

install_config() {
    local tmp="$1"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    xray run -test -config "$tmp" >/dev/null || die "Xray 配置校验失败"

    if [ -f "$CONFIG_FILE" ]; then
        local backup
        backup="${CONFIG_FILE}.$(date +%Y%m%d%H%M%S).bak"
        cp -a "$CONFIG_FILE" "$backup"
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

restart_xray() {
    systemctl daemon-reload
    systemctl enable xray >/dev/null
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray || die "Xray 启动失败，请查看：journalctl -u xray -n 80 --no-pager"
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
    install_config "$tmp"
    open_firewall_port "$EXIT_PORT"
    restart_xray

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
    echo -e "${GREEN}[Relay VPS 部署]${NC}"
    echo -e "${CYAN}当前步骤：Step 2 / 2，在中转 VPS 上安装 Relay。${NC}"
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
    prompt RELAY_PORT "Relay 对客户端监听端口" "${RELAY_PORT:-443}"
    valid_port "$RELAY_PORT" || die "端口必须是 1-65535"
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

    install_deps
    install_xray
    enable_bbr
    generate_reality_material
    CLIENT_UUID="$UUID"
    CLIENT_PRIVATE_KEY="$PRIVATE_KEY"
    CLIENT_PUBLIC_KEY="$PUBLIC_KEY"
    CLIENT_SHORT_ID="$SHORT_ID"

    local tmp relay_ip
    tmp=$(mktemp /tmp/xray-vps2vps-relay.XXXXXX.json)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    create_relay_config "$tmp"
    install_config "$tmp"
    open_firewall_port "$RELAY_PORT"
    restart_xray

    relay_ip=$(get_public_ip)
    write_info "relay" \
        "relay_host=$relay_ip" \
        "relay_port=$RELAY_PORT" \
        "client_uuid=$CLIENT_UUID" \
        "client_public_key=$CLIENT_PUBLIC_KEY" \
        "client_short_id=$CLIENT_SHORT_ID" \
        "client_sni=$REALITY_SERVER_NAME" \
        "exit_host=$EXIT_HOST" \
        "exit_port=$EXIT_PORT"

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║               Relay VPS 部署完成              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo -e "Relay Host:        ${YELLOW}${relay_ip}${NC}"
    echo -e "Relay Port:        ${YELLOW}${RELAY_PORT}${NC}"
    echo -e "Client UUID:       ${YELLOW}$(redact "$CLIENT_UUID")${NC}"
    echo -e "Client Public Key: ${YELLOW}${CLIENT_PUBLIC_KEY}${NC}"
    echo -e "Client Short ID:   ${YELLOW}${CLIENT_SHORT_ID}${NC}"
    echo -e "Client SNI:        ${YELLOW}${REALITY_SERVER_NAME}${NC}"
    print_client_link "$relay_ip" "VPS2VPS-Relay"
}

show_info() {
    if [ ! -f "$INFO_FILE" ]; then
        warn "未找到 $INFO_FILE"
        return
    fi
    python3 -m json.tool "$INFO_FILE" || cat "$INFO_FILE"
    echo ""
    systemctl status xray --no-pager -l | sed -n '1,12p' || true
}

guided_install() {
    print_banner
    print_install_flow
    echo ""
    echo "请选择当前这台服务器要安装的角色："
    echo "1) Step 1: 安装 Exit 落地 VPS（第一台，最终出口 IP）"
    echo "2) Step 2: 安装 Relay 中转 VPS（第二台，客户端入口）"
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
    rm -f "$CONFIG_FILE" "$INFO_FILE" "$IP_CACHE_FILE"
    ok "卸载流程已完成"
}

main_menu() {
    while true; do
        print_banner
        print_install_flow
        echo ""
        echo "1) 推荐向导安装（按 Step 1/Step 2 引导）"
        echo "2) Step 1: Install Exit VPS（落地 VPS，最终直连出站）"
        echo "3) Step 2: Install Relay VPS（中转 VPS，客户端入口）"
        echo "4) Show status / info"
        echo "5) Restart Xray"
        echo "6) Uninstall"
        echo "0) Exit"
        echo ""
        read -r -p "请选择: " choice
        case "$choice" in
            1) guided_install; break ;;
            2) install_exit; break ;;
            3) install_relay; break ;;
            4) show_info; read -r -p "按回车返回菜单..." _ ;;
            5) restart_xray; read -r -p "按回车返回菜单..." _ ;;
            6) uninstall_all; break ;;
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
    --guided|"") main_menu ;;
    --status) show_info ;;
    --restart) restart_xray ;;
    *) print_help; die "未知参数：$1" ;;
esac
