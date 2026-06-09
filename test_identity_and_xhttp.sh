#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/test_helpers.sh"
assert_contains "$SCRIPT" 'PROJECT_ID="xray-xhttp-wireguard-relay"'
assert_contains "$SCRIPT" 'network":"xhttp"'
assert_contains "$SCRIPT" '"sendThrough":r["relay_address"]'
assert_contains "$SCRIPT" '"protocol":["bittorrent"]'
assert_contains "$SCRIPT" 'type":"xhttp"'
assert_contains README.md 'superchaospc/xray-xhttp-wireguard-relay'
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/routes.json" <<'JSON'
{"version":1,"routes":[{"route_id":"a1b2c3d4","name":"Test","relay_port":443,"uuid":"11111111-1111-4111-8111-111111111111","reality_private":"private","reality_public":"public","short_id":"aabbccddeeff0011","sni":"www.microsoft.com","fp":"chrome","xhttp_path":"/1234567890abcdef","xhttp_mode":"auto","relay_address":"10.77.0.2/30"}]}
JSON
ROUTES_FILE="$tmp/routes.json"
XRAY_WG_SOURCE_ONLY=1
export ROUTES_FILE XRAY_WG_SOURCE_ONLY
# shellcheck disable=SC1090
source "$SCRIPT"
create_xray_config "$tmp/config.json"
python3 - "$tmp/config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
i=c["inbounds"][0]; o=next(x for x in c["outbounds"] if x["tag"]=="wg-out-a1b2c3d4")
assert i["streamSettings"]["network"]=="xhttp"
assert i["streamSettings"]["xhttpSettings"]=={"path":"/1234567890abcdef","mode":"auto"}
assert o["sendThrough"]=="10.77.0.2"
assert c["routing"]["rules"][-1]["inboundTag"]==["client-in-a1b2c3d4"]
PY
pass identity-xhttp
