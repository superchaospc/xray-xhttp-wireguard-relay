#!/usr/bin/env bash
set -euo pipefail
umask 077

PROJECT_ID="xray-xhttp-wireguard-relay"
SCRIPT_PATH="/root/xray_xhttp_wireguard_relay.sh"
SCRIPT_URL="https://raw.githubusercontent.com/superchaospc/xray-xhttp-wireguard-relay/main/xray_xhttp_wireguard_relay.sh"
CONFIG_FILE="${CONFIG_FILE:-/usr/local/etc/xray/config.json}"
ROUTES_FILE="${ROUTES_FILE:-/root/xray_xhttp_wireguard_routes.json}"
EXIT_ROUTES_FILE="${EXIT_ROUTES_FILE:-/root/xray_xhttp_wireguard_exit_routes.json}"
SUBSCRIPTION_FILE="${SUBSCRIPTION_FILE:-/root/xray_xhttp_wireguard_subscription.txt}"
ORIGINAL_CONFIG_BACKUP="${ORIGINAL_CONFIG_BACKUP:-/root/.xray_xhttp_wireguard_original_config.json}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
WG_SUBNET_POOL="${WG_SUBNET_POOL:-10.77.0.0/16}"
WG_PORT_START="${WG_PORT_START:-51821}"
WG_MTU="${WG_MTU:-1380}"
XHTTP_MODE="${XHTTP_MODE:-auto}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.microsoft.com}"
REALITY_DEST="${REALITY_DEST:-${REALITY_SERVER_NAME}:443}"
CLIENT_FP="${CLIENT_FP:-chrome}"
XRAY_REDACT="${XRAY_REDACT:-0}"
AUTO_YES="${AUTO_YES:-0}"
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

die(){ printf '%s✗ %s%s\n' "$RED" "$*" "$NC" >&2; exit 1; }
ok(){ printf '%s✓ %s%s\n' "$GREEN" "$*" "$NC"; }
warn(){ printf '%s⚠ %s%s\n' "$YELLOW" "$*" "$NC"; }
need(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
require_root(){ [ "$(id -u)" -eq 0 ] || die "请使用 root 运行"; need systemctl; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)); }
valid_mode(){ [[ "$1" =~ ^(auto|stream-one|stream-up|packet-up)$ ]]; }
valid_path(){ [[ "$1" =~ ^/[A-Za-z0-9._~/:-]{8,128}$ ]]; }
valid_route_id(){ [[ "$1" =~ ^[a-f0-9]{8}$ ]]; }
valid_wg_key(){ python3 - "$1" <<'PY'
import base64,sys
try: sys.exit(0 if len(base64.b64decode(sys.argv[1],validate=True))==32 else 1)
except Exception: sys.exit(1)
PY
}
json_init(){ [ -s "$1" ] || printf '{"version":1,"routes":[]}\n' >"$1"; chmod 600 "$1"; }
route_iface(){ valid_route_id "$1" || return 1; printf 'xwg-%s\n' "$1"; }
route_table(){ printf '%s\n' "$((20000 + 16#$1 % 10000))"; }
format_endpoint(){ [[ "$1" == *:* ]] && printf '[%s]:%s\n' "$1" "$2" || printf '%s:%s\n' "$1" "$2"; }
random_hex(){ od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'; }
random_path(){ printf '/%s\n' "$(random_hex 12)"; }
sha256(){ command -v sha256sum >/dev/null && sha256sum | awk '{print $1}' || shasum -a 256 | awk '{print $1}'; }
redact(){ local v="$1"; [ "$XRAY_REDACT" = 0 ] && printf '%s\n' "$v" || printf '%s…%s\n' "${v:0:4}" "${v: -4}"; }
public_ip(){ curl -4fsS --max-time 5 https://api.ipify.org || curl -6fsS --max-time 5 https://api64.ipify.org; }
egress_iface(){ ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'; }

print_banner(){
  printf '%s\n' "$CYAN"
  echo "Xray XHTTP + REALITY / WireGuard VPS Relay"
  echo "Client -> VLESS XHTTP REALITY -> Relay -> WireGuard -> Exit -> Internet"
  printf '%s\n' "$NC"
}
print_help(){ cat <<'EOF'
用法: xray_xhttp_wireguard_relay.sh [选项]
  --exit       在落地 VPS 新建 WireGuard 线路并输出秘密参数包
  --relay      在中转 VPS 导入 WG_BUNDLE 并建立 XHTTP REALITY 入口
  --list       查看线路和客户端链接
  --qr         显示线路终端二维码
  --stats      查看 Xray 当前线路流量
  --sub        刷新订阅
  --status     查看 Xray/WireGuard 状态
  --doctor     诊断监听、握手、策略路由与配置
  --rename     按 RELAY_PORT 修改 ROUTE_NAME
  --port       按 RELAY_PORT 修改 NEW_RELAY_PORT
  --delete     按 RELAY_PORT 删除线路
  --restart    重启 Xray 和项目 WireGuard 接口
  --update     更新 Xray
  --uninstall  删除本项目管理的资源

自动化变量: WG_BUNDLE RELAY_PORT ROUTE_NAME XHTTP_MODE REALITY_SERVER_NAME
安全提示: WG_BUNDLE 含 Relay 私钥；摘要只用于完整性检测，不提供加密或身份认证。
EOF
  printf '脚本更新地址: %s\n' "$SCRIPT_URL"
}

install_deps(){
  if command -v apt-get >/dev/null; then
    apt-get update -y; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl unzip python3 wireguard-tools iproute2 iptables qrencode
  elif command -v dnf >/dev/null; then dnf install -y curl unzip python3 wireguard-tools iproute iptables qrencode
  else die "仅支持 apt/dnf 系统"; fi
}
install_xray(){
  command -v xray >/dev/null && return
  local f; f=$(mktemp); curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$f"
  bash "$f" install; rm -f "$f"
}
generate_reality(){
  local out; out=$(xray x25519)
  REALITY_PRIVATE=$(awk -F':[[:space:]]*' 'tolower($1)~/private/{print $2;exit}' <<<"$out")
  REALITY_PUBLIC=$(awk -F':[[:space:]]*' 'tolower($1)~/public/{print $2;exit}' <<<"$out")
  [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || die "无法生成 REALITY 密钥"
}

make_bundle(){
  local payload digest
  payload=$(python3 - "$ROUTE_ID" "$EXIT_ENDPOINT" "$WG_PORT" "$WG_SUBNET" "$EXIT_ADDRESS" "$RELAY_ADDRESS" "$EXIT_PUBLIC_KEY" "$RELAY_PRIVATE_KEY" "$RELAY_PUBLIC_KEY" "$PRESHARED_KEY" <<'PY'
import json,sys
r,e,p,n,ea,ra,ep,rp,ru,ps=sys.argv[1:]
print(json.dumps({"version":1,"route_id":r,"exit_endpoint":e,"wg_port":int(p),"subnet":n,"exit_address":ea,"relay_address":ra,"exit_public_key":ep,"relay_private_key":rp,"relay_public_key":ru,"preshared_key":ps},sort_keys=True,separators=(",",":")))
PY
)
  digest=$(printf %s "$payload" | sha256)
  python3 - "$payload" "$digest" <<'PY'
import base64,json,sys
print(base64.urlsafe_b64encode(json.dumps({"payload":json.loads(sys.argv[1]),"sha256":sys.argv[2]},sort_keys=True,separators=(",",":")).encode()).decode().rstrip("="))
PY
}
load_bundle(){
  [ -n "${WG_BUNDLE:-}" ] || die "请设置 WG_BUNDLE"
  local decoded
  decoded=$(python3 - "$WG_BUNDLE" <<'PY'
import base64,hashlib,ipaddress,json,re,shlex,sys
try:
 b=sys.argv[1]; w=json.loads(base64.urlsafe_b64decode(b+"="*(-len(b)%4))); p=w["payload"]
 raw=json.dumps(p,sort_keys=True,separators=(",",":")).encode()
 assert hashlib.sha256(raw).hexdigest()==w["sha256"] and p["version"]==1
 assert re.fullmatch(r"[a-f0-9]{8}",p["route_id"])
 net=ipaddress.ip_network(p["subnet"]); assert net.prefixlen==30
 assert ipaddress.ip_interface(p["exit_address"]).ip in net and ipaddress.ip_interface(p["relay_address"]).ip in net
 for k in ("exit_public_key","relay_private_key","relay_public_key","preshared_key"):
  import binascii
  assert len(base64.b64decode(p[k],validate=True))==32
 assert 1<=int(p["wg_port"])<=65535
 host=str(p["exit_endpoint"])
 try: ipaddress.ip_address(host)
 except ValueError: assert re.fullmatch(r"(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?",host)
except Exception as e:
 print("die "+shlex.quote("无效或被修改的 WG_BUNDLE: "+str(e))); sys.exit()
names={"ROUTE_ID":"route_id","EXIT_ENDPOINT":"exit_endpoint","WG_PORT":"wg_port","WG_SUBNET":"subnet","EXIT_ADDRESS":"exit_address","RELAY_ADDRESS":"relay_address","EXIT_PUBLIC_KEY":"exit_public_key","RELAY_PRIVATE_KEY":"relay_private_key","RELAY_PUBLIC_KEY":"relay_public_key","PRESHARED_KEY":"preshared_key"}
for a,k in names.items(): print(a+"="+shlex.quote(str(p[k])))
PY
) || die "无法解析 WG_BUNDLE"
  eval "$decoded"
}

allocate_network(){
  json_init "$EXIT_ROUTES_FILE"
  eval "$(python3 - "$EXIT_ROUTES_FILE" "$WG_SUBNET_POOL" "$WG_PORT_START" <<'PY'
import ipaddress,json,sys
d=json.load(open(sys.argv[1])); used={r["subnet"] for r in d["routes"]}; ports={int(r["wg_port"]) for r in d["routes"]}
pool=ipaddress.ip_network(sys.argv[2]); net=next(n for n in pool.subnets(new_prefix=30) if str(n) not in used)
p=int(sys.argv[3])
while p in ports:p+=1
h=list(net.hosts())
print(f"WG_SUBNET={net}"); print(f"EXIT_ADDRESS={h[0]}/30"); print(f"RELAY_ADDRESS={h[1]}/30"); print(f"WG_PORT={p}")
PY
)"
  while ip route show table all 2>/dev/null | grep -Fq "$WG_SUBNET" || ip -o address show 2>/dev/null | grep -Fq "${EXIT_ADDRESS%/*}/"; do
    eval "$(python3 - "$WG_SUBNET" <<'PY'
import ipaddress,sys
n=ipaddress.ip_network(sys.argv[1]); n=ipaddress.ip_network((int(n.network_address)+4,30)); h=list(n.hosts())
print(f"WG_SUBNET={n}"); print(f"EXIT_ADDRESS={h[0]}/30"); print(f"RELAY_ADDRESS={h[1]}/30")
PY
)"
  done
  while ss -lunH 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$WG_PORT$"; do WG_PORT=$((WG_PORT+1)); done
}
ensure_relay_resources_free(){
  local iface table; iface=$(route_iface "$ROUTE_ID"); table=$(route_table "$ROUTE_ID")
  [ ! -e "$WG_DIR/$iface.conf" ] || die "拒绝覆盖现有 WireGuard 配置: $WG_DIR/$iface.conf"
  ! ip link show "$iface" >/dev/null 2>&1 || die "WireGuard 接口已存在: $iface"
  ! ip rule show | grep -Eq "lookup ($table|$table\\b)" || die "策略路由表已被占用: $table"
  ! ip route show table all | grep -Fq "$WG_SUBNET" || die "隧道子网已被本机路由占用: $WG_SUBNET"
}
write_exit_wg(){
  mkdir -p "$WG_DIR"; local iface out mark; iface=$(route_iface "$ROUTE_ID"); out=$(egress_iface); mark="$PROJECT_ID:$ROUTE_ID"
  cat >"$WG_DIR/$iface.conf" <<EOF
[Interface]
Address = $EXIT_ADDRESS
ListenPort = $WG_PORT
PrivateKey = $EXIT_PRIVATE_KEY
MTU = $WG_MTU
PostUp = iptables -C FORWARD -i $iface -o $out -s $WG_SUBNET -m comment --comment $mark -j ACCEPT 2>/dev/null || iptables -A FORWARD -i $iface -o $out -s $WG_SUBNET -m comment --comment $mark -j ACCEPT
PostUp = iptables -C FORWARD -i $out -o $iface -d $WG_SUBNET -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment $mark -j ACCEPT 2>/dev/null || iptables -A FORWARD -i $out -o $iface -d $WG_SUBNET -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment $mark -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -s $WG_SUBNET -o $out -m comment --comment $mark -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $WG_SUBNET -o $out -m comment --comment $mark -j MASQUERADE
PreDown = iptables -D FORWARD -i $iface -o $out -s $WG_SUBNET -m comment --comment $mark -j ACCEPT 2>/dev/null || true
PreDown = iptables -D FORWARD -i $out -o $iface -d $WG_SUBNET -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment $mark -j ACCEPT 2>/dev/null || true
PreDown = iptables -t nat -D POSTROUTING -s $WG_SUBNET -o $out -m comment --comment $mark -j MASQUERADE 2>/dev/null || true

[Peer]
PublicKey = $RELAY_PUBLIC_KEY
PresharedKey = $PRESHARED_KEY
AllowedIPs = ${RELAY_ADDRESS%/*}/32
EOF
  chmod 600 "$WG_DIR/$iface.conf"
}
write_relay_wg(){
  mkdir -p "$WG_DIR"; local iface table endpoint; iface=$(route_iface "$ROUTE_ID"); table=$(route_table "$ROUTE_ID"); endpoint=$(format_endpoint "$EXIT_ENDPOINT" "$WG_PORT")
  cat >"$WG_DIR/$iface.conf" <<EOF
[Interface]
Address = $RELAY_ADDRESS
PrivateKey = $RELAY_PRIVATE_KEY
MTU = $WG_MTU
Table = off
PostUp = ip rule add from ${RELAY_ADDRESS%/*}/32 table $table; ip route add default dev $iface table $table
PreDown = ip rule del from ${RELAY_ADDRESS%/*}/32 table $table 2>/dev/null || true; ip route flush table $table

[Peer]
PublicKey = $EXIT_PUBLIC_KEY
PresharedKey = $PRESHARED_KEY
Endpoint = $endpoint
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "$WG_DIR/$iface.conf"
}
firewall_add_exit(){
  local iface out cidr mark; iface=$(route_iface "$ROUTE_ID"); out=$(egress_iface); cidr="$WG_SUBNET"; mark="$PROJECT_ID:$ROUTE_ID"
  iptables -C FORWARD -i "$iface" -o "$out" -s "$cidr" -m comment --comment "$mark" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$iface" -o "$out" -s "$cidr" -m comment --comment "$mark" -j ACCEPT
  iptables -C FORWARD -i "$out" -o "$iface" -d "$cidr" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$mark" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$out" -o "$iface" -d "$cidr" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$mark" -j ACCEPT
  iptables -t nat -C POSTROUTING -s "$cidr" -o "$out" -m comment --comment "$mark" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$cidr" -o "$out" -m comment --comment "$mark" -j MASQUERADE
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  printf 'net.ipv4.ip_forward=1\n' >"/etc/sysctl.d/99-$PROJECT_ID.conf"
}
firewall_add_relay(){
  local mark="$PROJECT_ID:$ROUTE_ID"
  iptables -C INPUT -p tcp --dport "$RELAY_PORT" -m comment --comment "$mark" -j ACCEPT 2>/dev/null ||
    iptables -A INPUT -p tcp --dport "$RELAY_PORT" -m comment --comment "$mark" -j ACCEPT
}
firewall_del_exit(){
  local mark="$PROJECT_ID:$1"
  while read -r line; do [ -n "$line" ] && eval "iptables $line" 2>/dev/null || true; done \
    < <(iptables -S 2>/dev/null | grep -- "--comment \"$mark\"" | sed 's/^-A /-D /')
  while read -r line; do [ -n "$line" ] && eval "iptables -t nat $line" 2>/dev/null || true; done \
    < <(iptables -t nat -S 2>/dev/null | grep -- "--comment \"$mark\"" | sed 's/^-A /-D /')
}

save_exit_route(){
  python3 - "$EXIT_ROUTES_FILE" <<PY
import json
p="$EXIT_ROUTES_FILE"; d=json.load(open(p)); d["routes"].append({"route_id":"$ROUTE_ID","subnet":"$WG_SUBNET","wg_port":int("$WG_PORT"),"interface":"$(route_iface "$ROUTE_ID")"})
open(p+".tmp","w").write(json.dumps(d,indent=2)+"\n")
PY
  mv "$EXIT_ROUTES_FILE.tmp" "$EXIT_ROUTES_FILE"; chmod 600 "$EXIT_ROUTES_FILE"
}
save_relay_route(){
  local path="$1" iface table; iface=$(route_iface "$ROUTE_ID"); table=$(route_table "$ROUTE_ID")
  python3 - "$ROUTES_FILE" "$path" "$ROUTE_ID" "$ROUTE_NAME" "$RELAY_PORT" "$CLIENT_UUID" "$REALITY_PRIVATE" "$REALITY_PUBLIC" "$SHORT_ID" "$REALITY_SERVER_NAME" "$CLIENT_FP" "$XHTTP_MODE" "$iface" "$table" "$WG_SUBNET" "$RELAY_ADDRESS" "$EXIT_ADDRESS" "$EXIT_ENDPOINT" "$WG_PORT" "$EXIT_PUBLIC_KEY" "$RELAY_PRIVATE_KEY" "$RELAY_PUBLIC_KEY" "$PRESHARED_KEY" <<'PY'
import json,sys
(p,path,rid,name,port,uuid,rpriv,rpub,sid,sni,fp,mode,iface,table,subnet,raddr,eaddr,endpoint,wgport,epub,wpriv,wpub,psk)=sys.argv[1:]
d=json.load(open(p))
assert all(r["route_id"]!=rid and int(r["relay_port"])!=int(port) and r["subnet"]!=subnet and int(r["table"])!=int(table) for r in d["routes"])
d["routes"].append({"route_id":rid,"name":name,"relay_port":int(port),"uuid":uuid,"reality_private":rpriv,"reality_public":rpub,"short_id":sid,"sni":sni,"fp":fp,"xhttp_path":path,"xhttp_mode":mode,"interface":iface,"table":int(table),"subnet":subnet,"relay_address":raddr,"exit_address":eaddr,"exit_endpoint":endpoint,"wg_port":int(wgport),"exit_public_key":epub,"relay_private_key":wpriv,"relay_public_key":wpub,"preshared_key":psk})
open(p+".tmp","w").write(json.dumps(d,indent=2)+"\n")
PY
  mv "$ROUTES_FILE.tmp" "$ROUTES_FILE"; chmod 600 "$ROUTES_FILE"
}

create_xray_config(){
  python3 - "$ROUTES_FILE" "$1" "$REALITY_DEST" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); dest=sys.argv[3]
ins=[]; outs=[{"tag":"direct","protocol":"freedom"},{"tag":"blocked","protocol":"blackhole"},{"tag":"api","protocol":"freedom"}]; rules=[{"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"},{"type":"field","inboundTag":["api"],"outboundTag":"api"}]
for r in d["routes"]:
 rid=r["route_id"]; tag="client-in-"+rid
 ins.append({"tag":tag,"port":r["relay_port"],"protocol":"vless","settings":{"clients":[{"id":r["uuid"],"flow":""}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"reality","xhttpSettings":{"path":r["xhttp_path"],"mode":r["xhttp_mode"]},"realitySettings":{"show":False,"dest":dest,"xver":0,"serverNames":[r["sni"]],"privateKey":r["reality_private"],"shortIds":[r["short_id"]]}},"sniffing":{"enabled":True,"destOverride":["http","tls","quic"]}})
 out="wg-out-"+rid; outs.append({"tag":out,"protocol":"freedom","sendThrough":r["relay_address"].split("/")[0]}); rules.append({"type":"field","inboundTag":[tag],"outboundTag":out})
cfg={"log":{"loglevel":"warning"},"api":{"tag":"api","services":["StatsService"]},"stats":{},"policy":{"system":{"statsInboundUplink":True,"statsInboundDownlink":True}},"inbounds":ins+[{"tag":"api","listen":"127.0.0.1","port":10085,"protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}}],"outbounds":outs,"routing":{"domainStrategy":"AsIs","rules":rules}}
open(sys.argv[2],"w").write(json.dumps(cfg,indent=2)+"\n")
PY
}
install_xray_config(){
  local tmp backup service_user service_group; tmp=$(mktemp); backup="$CONFIG_FILE.bak.$(date +%s)"
  if ! create_xray_config "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! xray run -test -config "$tmp" >/dev/null; then rm -f "$tmp"; return 1; fi
  mkdir -p "$(dirname "$CONFIG_FILE")"
  if [ -f "$CONFIG_FILE" ]; then
    cp -a "$CONFIG_FILE" "$backup"
    [ -e "$ORIGINAL_CONFIG_BACKUP" ] || { cp -a "$CONFIG_FILE" "$ORIGINAL_CONFIG_BACKUP"; chmod 600 "$ORIGINAL_CONFIG_BACKUP"; }
  fi
  service_user=$(systemctl show xray -p User --value 2>/dev/null || true); service_user="${service_user:-root}"
  service_group=$(id -gn "$service_user" 2>/dev/null || printf root)
  if ! install -m 640 "$tmp" "$CONFIG_FILE" || ! chown "root:$service_group" "$CONFIG_FILE"; then rm -f "$tmp"; return 1; fi
  rm -f "$tmp"
  if ! systemctl restart xray; then [ ! -f "$backup" ] || mv "$backup" "$CONFIG_FILE"; systemctl restart xray || true; return 1; fi
}
client_links(){
  local host; host=$(public_ip); [[ "$host" == *:* ]] && host="[$host]"
  python3 - "$ROUTES_FILE" "$host" <<'PY'
import json,sys,urllib.parse
for r in json.load(open(sys.argv[1]))["routes"]:
 q=urllib.parse.urlencode({"security":"reality","encryption":"none","pbk":r["reality_public"],"fp":r["fp"],"type":"xhttp","path":r["xhttp_path"],"mode":r["xhttp_mode"],"sni":r["sni"],"sid":r["short_id"]})
 print(f'{r["route_id"]}\t{r["name"]}\tvless://{r["uuid"]}@{sys.argv[2]}:{r["relay_port"]}?{q}#{urllib.parse.quote(r["name"])}')
PY
}
refresh_subscription(){ local tmp; tmp=$(mktemp); client_links | cut -f3- | base64 | tr -d '\n' >"$tmp"; printf '\n' >>"$tmp"; mv "$tmp" "$SUBSCRIPTION_FILE"; chmod 600 "$SUBSCRIPTION_FILE"; }

install_exit(){
  require_root; install_deps; json_init "$EXIT_ROUTES_FILE"; allocate_network
  ROUTE_ID=$(random_hex 4); EXIT_ENDPOINT="${EXIT_ENDPOINT:-$(public_ip)}"
  EXIT_PRIVATE_KEY=$(wg genkey); EXIT_PUBLIC_KEY=$(printf %s "$EXIT_PRIVATE_KEY"|wg pubkey)
  RELAY_PRIVATE_KEY=$(wg genkey); RELAY_PUBLIC_KEY=$(printf %s "$RELAY_PRIVATE_KEY"|wg pubkey); PRESHARED_KEY=$(wg genpsk)
  write_exit_wg
  firewall_add_exit
  if ! systemctl enable --now "wg-quick@$(route_iface "$ROUTE_ID")"; then
    firewall_del_exit "$ROUTE_ID"
    rm -f "$WG_DIR/$(route_iface "$ROUTE_ID").conf"
    die "WireGuard 启动失败，已回滚"
  fi
  save_exit_route
  local bundle; bundle=$(make_bundle); printf '%s\n' "WG_BUNDLE='$bundle' RELAY_PORT='443' AUTO_YES=1 bash $SCRIPT_PATH --relay"
  warn "上面的参数包含 Relay 私钥。请通过安全渠道传输；SHA-256 摘要不提供认证。"
}
install_relay(){
  require_root; install_deps; install_xray; json_init "$ROUTES_FILE"; load_bundle
  RELAY_PORT="${RELAY_PORT:-443}"; valid_port "$RELAY_PORT" || die "无效 RELAY_PORT"
  valid_mode "$XHTTP_MODE" || die "无效 XHTTP_MODE"; ROUTE_NAME="${ROUTE_NAME:-$EXIT_ENDPOINT}"; ensure_relay_resources_free
  CLIENT_UUID=$(xray uuid); generate_reality; SHORT_ID=$(random_hex 8); local path; path=$(random_path)
  local old; old=$(mktemp); cp "$ROUTES_FILE" "$old"; save_relay_route "$path"; write_relay_wg
  if ! systemctl enable --now "wg-quick@$(route_iface "$ROUTE_ID")" || ! install_xray_config; then
    systemctl disable --now "wg-quick@$(route_iface "$ROUTE_ID")" 2>/dev/null || true; rm -f "$WG_DIR/$(route_iface "$ROUTE_ID").conf"; mv "$old" "$ROUTES_FILE"; die "安装失败，已回滚"
  fi
  firewall_add_relay
  rm -f "$old"; refresh_subscription; client_links | awk -F'\t' -v id="$ROUTE_ID" '$1==id{print $3}'; ok "线路 $ROUTE_NAME 已安装"
}
list_routes(){ json_init "$ROUTES_FILE"; client_links | awk -F'\t' '{print $1"  "$2"\n"$3"\n"}'; }
show_qr(){
  need qrencode
  while IFS=$'\t' read -r _ name link; do printf '\n%s\n' "$name"; qrencode -t ANSIUTF8 "$link"; done < <(client_links)
}
show_stats(){
  if ! xray api statsquery --server=127.0.0.1:10085 -pattern 'inbound>>>' 2>/dev/null; then
    warn "无法读取 Xray Stats API，请确认 Xray 正常运行"
    return 1
  fi
}
mutate_route(){
  local op="$1"; json_init "$ROUTES_FILE"; python3 - "$ROUTES_FILE" "$op" "${RELAY_PORT:-}" "${NEW_RELAY_PORT:-}" "${ROUTE_NAME:-}" <<'PY'
import json,sys
p,op,port,new,name=sys.argv[1:]; d=json.load(open(p)); found=False
for r in d["routes"]:
 if str(r["relay_port"])==port:
  found=True
  if op=="rename": r["name"]=name
  elif op=="port":
   assert all(x is r or int(x["relay_port"])!=int(new) for x in d["routes"])
   r["relay_port"]=int(new)
  elif op=="delete": r["_delete"]=True
assert found
d["routes"]=[r for r in d["routes"] if not r.pop("_delete",False)]
open(p+".tmp","w").write(json.dumps(d,indent=2)+"\n")
PY
  mv "$ROUTES_FILE.tmp" "$ROUTES_FILE"; chmod 600 "$ROUTES_FILE"
}
rename_route(){ [ -n "${RELAY_PORT:-}" ] && [ -n "${ROUTE_NAME:-}" ] || die "需要 RELAY_PORT 和 ROUTE_NAME"; mutate_route rename; refresh_subscription; }
change_port(){
  valid_port "${NEW_RELAY_PORT:-}" || die "需要有效 NEW_RELAY_PORT"
  local rid old="$RELAY_PORT" backup; backup=$(mktemp); cp "$ROUTES_FILE" "$backup"; rid=$(python3 - "$ROUTES_FILE" "$old" <<'PY'
import json,sys
print(next(r["route_id"] for r in json.load(open(sys.argv[1]))["routes"] if str(r["relay_port"])==sys.argv[2]))
PY
)
  mutate_route port
  if ! install_xray_config; then mv "$backup" "$ROUTES_FILE"; die "修改失败，线路状态已回滚"; fi
  rm -f "$backup"; firewall_del_exit "$rid"; ROUTE_ID="$rid"; RELAY_PORT="$NEW_RELAY_PORT"; firewall_add_relay; refresh_subscription
}
delete_route(){
  local rid iface backup; backup=$(mktemp); cp "$ROUTES_FILE" "$backup"; rid=$(python3 - "$ROUTES_FILE" "${RELAY_PORT:-}" <<'PY'
import json,sys
print(next(r["route_id"] for r in json.load(open(sys.argv[1]))["routes"] if str(r["relay_port"])==sys.argv[2]))
PY
); iface=$(route_iface "$rid"); mutate_route delete
  if ! install_xray_config; then mv "$backup" "$ROUTES_FILE"; die "删除失败，线路状态已回滚"; fi
  rm -f "$backup"; firewall_del_exit "$rid"; systemctl disable --now "wg-quick@$iface" 2>/dev/null || true; rm -f "$WG_DIR/$iface.conf"; refresh_subscription
}
status(){
  systemctl --no-pager status xray 2>/dev/null | sed -n '1,5p' || true
  json_init "$ROUTES_FILE"; python3 - "$ROUTES_FILE" <<'PY'
import json
for r in json.load(open(__import__("sys").argv[1]))["routes"]: print(r["route_id"],r["name"],r["interface"],r["exit_endpoint"],r["wg_port"])
PY
  wg show 2>/dev/null || true
}
doctor(){
  xray run -test -config "$CONFIG_FILE" || true
  ss -lntup | grep -E 'xray|xwg' || true
  ip rule show
  echo "WireGuard latest handshake / transfer:"
  wg show all latest-handshakes 2>/dev/null || true
  wg show all transfer 2>/dev/null || true
  status
}
restart_all(){ systemctl restart xray; json_init "$ROUTES_FILE"; python3 - "$ROUTES_FILE" <<'PY' | xargs -r -n1 systemctl restart
import json,sys
for r in json.load(open(sys.argv[1]))["routes"]: print("wg-quick@"+r["interface"])
PY
}
update_xray(){ require_root; local f; f=$(mktemp); curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$f"; bash "$f" install; rm -f "$f"; xray run -test -config "$CONFIG_FILE"; restart_all; }
uninstall_all(){
  require_root; [ "$AUTO_YES" = 1 ] || { read -r -p "删除本项目管理的全部资源？[y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || exit 0; }
  for f in "$ROUTES_FILE" "$EXIT_ROUTES_FILE"; do [ -s "$f" ] || continue; python3 - "$f" <<'PY' | while read -r rid iface; do
import json,sys
for r in json.load(open(sys.argv[1]))["routes"]: print(r["route_id"],r["interface"])
PY
    systemctl disable --now "wg-quick@$iface" 2>/dev/null || true; rm -f "$WG_DIR/$iface.conf"; firewall_del_exit "$rid"
  done; done
  if [ -f "$ORIGINAL_CONFIG_BACKUP" ]; then
    cp -a "$ORIGINAL_CONFIG_BACKUP" "$CONFIG_FILE"; rm -f "$ORIGINAL_CONFIG_BACKUP"; systemctl restart xray || true
  elif [ -f "$ROUTES_FILE" ]; then
    rm -f "$CONFIG_FILE"; systemctl stop xray || true
  fi
  rm -f "$ROUTES_FILE" "$EXIT_ROUTES_FILE" "$SUBSCRIPTION_FILE" "/etc/sysctl.d/99-$PROJECT_ID.conf"; ok "已删除本项目资源"
}
main_menu(){
  while true; do
    cat <<'EOF'
1) Exit 新建线路  2) Relay 导入线路  3) 查看线路  4) 二维码
5) 订阅  6) 流量  7) 状态  8) 诊断  9) 重启  10) 卸载  0) 退出
EOF
    read -r -p "请选择: " n
    case "$n" in
      1) install_exit;; 2) install_relay;; 3) list_routes;; 4) show_qr;; 5) refresh_subscription; cat "$SUBSCRIPTION_FILE";;
      6) show_stats;; 7) status;; 8) doctor;; 9) restart_all;; 10) uninstall_all;; 0) break;; *) warn "无效选择";;
    esac
  done
}

main(){
  print_banner
  case "${1:-}" in
    "") main_menu;;
    --exit) install_exit;; --relay) install_relay;; --list) list_routes;; --sub) refresh_subscription; cat "$SUBSCRIPTION_FILE";;
    --qr) show_qr;; --stats) show_stats;;
    --status) status;; --doctor) doctor;; --rename) rename_route;; --port) change_port;; --delete) delete_route;;
    --restart) restart_all;; --update) update_xray;; --uninstall) uninstall_all;; --help|-h) print_help;; *) print_help; exit 1;;
  esac
}
[ "${XRAY_WG_SOURCE_ONLY:-0}" = 1 ] || main "$@"
