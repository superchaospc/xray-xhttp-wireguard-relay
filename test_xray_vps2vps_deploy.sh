#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/xray_vps2vps_deploy.sh"

pass() {
    printf '\033[0;32m✓ %s\033[0m\n' "$*"
}

fail() {
    printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2
    exit 1
}

run_bash_syntax_test() {
    bash -n "$DEPLOY_SCRIPT"
    pass "bash syntax"
}

run_shellcheck_test() {
    if ! command -v shellcheck >/dev/null 2>&1; then
        printf '\033[1;33m⚠ shellcheck not installed, skipped\033[0m\n'
        return
    fi
    shellcheck -S warning "$DEPLOY_SCRIPT"
    pass "shellcheck"
}

make_sourceable_copy() {
    local out="$1"
    python3 - "$DEPLOY_SCRIPT" "$out" <<'PYEOF'
import pathlib
import sys

src = pathlib.Path(sys.argv[1]).read_text()
marker = '\ncase "${1:-}" in\n    --help|-h)'
if marker in src:
    src = src.split(marker, 1)[0] + "\n"
else:
    raise SystemExit("could not find script entrypoint marker")
pathlib.Path(sys.argv[2]).write_text(src)
PYEOF
}

run_config_generation_test() {
    local sourceable tmp_exit tmp_relay tmp_routes tmp_multi tmp_migrate_routes tmp_info
    sourceable="$(mktemp /tmp/vps2vps-source.XXXXXX)"
    tmp_exit="$(mktemp /tmp/vps2vps-exit.XXXXXX)"
    tmp_relay="$(mktemp /tmp/vps2vps-relay.XXXXXX)"
    tmp_routes="$(mktemp /tmp/vps2vps-routes.XXXXXX)"
    tmp_multi="$(mktemp /tmp/vps2vps-relay-multi.XXXXXX)"
    tmp_migrate_routes="$(mktemp /tmp/vps2vps-migrate-routes.XXXXXX)"
    tmp_info="$(mktemp /tmp/vps2vps-info.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$sourceable' '$tmp_exit' '$tmp_relay' '$tmp_routes' '$tmp_multi' '$tmp_migrate_routes' '$tmp_info'" RETURN

    make_sourceable_copy "$sourceable"

    bash -c '
        source "$0"

        REALITY_SITE="microsoft"
        REALITY_SERVER_NAME=""
        REALITY_DEST=""
        REALITY_DEST_USER_SET=0
        normalize_reality_site
        [ "$REALITY_SERVER_NAME" = "www.microsoft.com" ]
        [ "$REALITY_DEST" = "www.microsoft.com:443" ]

        UUID="11111111-1111-4111-8111-111111111111"
        PRIVATE_KEY="exit_private_key_for_shape_test"
        SHORT_ID="abcd1234abcd1234"
        EXIT_PORT="443"
        REALITY_DEST="www.cloudflare.com:443"
        REALITY_SERVER_NAME="www.cloudflare.com"
        create_exit_config "$1"

        CLIENT_UUID="22222222-2222-4222-8222-222222222222"
        CLIENT_PRIVATE_KEY="relay_private_key_for_shape_test"
        CLIENT_PUBLIC_KEY="relay_public_key_for_shape_test"
        CLIENT_SHORT_ID="dcba4321dcba4321"
        RELAY_PORT="443"
        EXIT_HOST="203.0.113.10"
        EXIT_PORT="443"
        EXIT_UUID="11111111-1111-4111-8111-111111111111"
        EXIT_PUBLIC_KEY="exit_public_key_for_shape_test"
        EXIT_SHORT_ID="abcd1234abcd1234"
        EXIT_SNI="www.cloudflare.com"
        CLIENT_FP="chrome"
        REALITY_DEST="www.cloudflare.com:443"
        REALITY_SERVER_NAME="www.cloudflare.com"
        create_relay_config "$2"

        INFO_FILE="$5"
        python3 - "$INFO_FILE" <<PY
import json, sys
json.dump({
    "role": "relay",
    "client_uuid": "22222222-2222-4222-8222-222222222222",
    "client_public_key": "relay_public_key_for_shape_test",
    "client_short_id": "dcba4321dcba4321",
    "client_sni": "www.cloudflare.com"
}, open(sys.argv[1], "w"))
PY
        CONFIG_FILE="$2"
        ROUTES_FILE="$6"
        migrate_existing_relay_config_if_needed >/dev/null

        ROUTES_FILE="$3"
        ROUTE_NAME="Spain"
        save_relay_route "$ROUTE_NAME"
        RELAY_PORT="8443"
        CLIENT_UUID="33333333-3333-4333-8333-333333333333"
        CLIENT_PRIVATE_KEY="relay_private_key_for_second_route"
        CLIENT_PUBLIC_KEY="relay_public_key_for_second_route"
        CLIENT_SHORT_ID="eeee4321eeee4321"
        EXIT_HOST="198.51.100.20"
        EXIT_PORT="443"
        EXIT_UUID="44444444-4444-4444-8444-444444444444"
        EXIT_PUBLIC_KEY="second_exit_public_key"
        EXIT_SHORT_ID="ffff1234ffff1234"
        EXIT_SNI="www.cloudflare.com"
        ROUTE_NAME="Germany"
        save_relay_route "$ROUTE_NAME"
        create_relay_multi_config "$4"
    ' "$sourceable" "$tmp_exit" "$tmp_relay" "$tmp_routes" "$tmp_multi" "$tmp_info" "$tmp_migrate_routes"

    python3 - "$tmp_exit" "$tmp_relay" "$tmp_multi" "$tmp_migrate_routes" <<'PYEOF'
import json
import sys

exit_config = json.load(open(sys.argv[1]))
relay_config = json.load(open(sys.argv[2]))
multi_config = json.load(open(sys.argv[3]))
migrated_routes = json.load(open(sys.argv[4]))["routes"]

exit_in = next(i for i in exit_config["inbounds"] if i["tag"] == "from-relay")
relay_in = next(i for i in relay_config["inbounds"] if i["tag"] == "client-in")
relay_out = next(o for o in relay_config["outbounds"] if o["tag"] == "to-exit")

assert exit_config["api"]["services"] == ["StatsService"]
assert exit_in["protocol"] == "vless"
assert exit_in["streamSettings"]["security"] == "reality"
assert any(o["tag"] == "api" for o in exit_config["outbounds"])
assert exit_config["routing"]["rules"][-1]["outboundTag"] == "direct"

assert relay_config["api"]["services"] == ["StatsService"]
assert relay_in["protocol"] == "vless"
assert relay_in["streamSettings"]["security"] == "reality"
assert relay_out["streamSettings"]["security"] == "reality"
assert relay_config["routing"]["rules"][-1]["outboundTag"] == "to-exit"

route_inbounds = [i for i in multi_config["inbounds"] if i["tag"].startswith("client-in-")]
route_outbounds = [o for o in multi_config["outbounds"] if o["tag"].startswith("to-exit-")]
assert multi_config["api"]["services"] == ["StatsService"]
assert len(route_inbounds) == 2
assert {i["port"] for i in route_inbounds} == {443, 8443}
assert {i["streamSettings"]["realitySettings"]["dest"] for i in route_inbounds} == {"www.cloudflare.com:443"}
assert {o["tag"] for o in route_outbounds} == {"to-exit-443", "to-exit-8443"}
assert multi_config["routing"]["rules"][-2]["outboundTag"] == "to-exit-443"
assert multi_config["routing"]["rules"][-1]["outboundTag"] == "to-exit-8443"
assert len(migrated_routes) == 1
assert migrated_routes[0]["relay_port"] == "443"
assert migrated_routes[0]["client_public_key"] == "relay_public_key_for_shape_test"
PYEOF

    pass "config generation"
}

run_exit_bundle_test() {
    local sourceable
    sourceable="$(mktemp /tmp/vps2vps-source.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$sourceable'" RETURN
    make_sourceable_copy "$sourceable"

    bash -c '
        source "$0"
        bundle=$(make_exit_bundle "203.0.113.10" "443" "11111111-1111-4111-8111-111111111111" "pub_key_shape_test" "abcd1234abcd1234" "www.cloudflare.com")
        EXIT_BUNDLE="$bundle"
        load_exit_bundle >/dev/null
        [ "$EXIT_HOST" = "203.0.113.10" ]
        [ "$EXIT_PORT" = "443" ]
        [ "$EXIT_UUID" = "11111111-1111-4111-8111-111111111111" ]
        [ "$EXIT_PUBLIC_KEY" = "pub_key_shape_test" ]
        [ "$EXIT_SHORT_ID" = "abcd1234abcd1234" ]
        [ "$EXIT_SNI" = "www.cloudflare.com" ]
    ' "$sourceable"

    pass "exit bundle"
}

run_subscription_and_prompt_test() {
    local sourceable tmp_routes tmp_sub
    sourceable="$(mktemp /tmp/vps2vps-source.XXXXXX)"
    tmp_routes="$(mktemp /tmp/vps2vps-routes.XXXXXX)"
    tmp_sub="$(mktemp /tmp/vps2vps-sub.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$sourceable' '$tmp_routes' '$tmp_sub'" RETURN
    make_sourceable_copy "$sourceable"

    bash -c '
        source "$0"
        ROUTES_FILE="$1"
        SUBSCRIPTION_FILE="$2"
        CLIENT_FP="chrome"
        RELAY_PORT="443"
        CLIENT_UUID="22222222-2222-4222-8222-222222222222"
        CLIENT_PRIVATE_KEY="relay_private_key_for_shape_test"
        CLIENT_PUBLIC_KEY="relay_public_key_for_shape_test"
        CLIENT_SHORT_ID="dcba4321dcba4321"
        EXIT_HOST="203.0.113.10"
        EXIT_PORT="443"
        EXIT_UUID="11111111-1111-4111-8111-111111111111"
        EXIT_PUBLIC_KEY="exit_public_key_for_shape_test"
        EXIT_SHORT_ID="abcd1234abcd1234"
        EXIT_SNI="www.cloudflare.com"
        REALITY_SERVER_NAME="www.cloudflare.com"
        REALITY_DEST="www.cloudflare.com:443"
        save_relay_route "Spain Node"
        get_public_ip() { printf "%s\n" "198.51.100.1"; }
        count=$(refresh_subscription_file)
        [ "$count" = "1" ]
        python3 - "$SUBSCRIPTION_FILE" <<PY
import base64, sys
payload = base64.b64decode(open(sys.argv[1]).read().strip()).decode()
assert "vless://22222222-2222-4222-8222-222222222222@198.51.100.1:443" in payload
assert "#Spain%20Node" in payload
PY
        printf "  7  \n" | { prompt_read picked; [ "$picked" = "7" ]; }
    ' "$sourceable" "$tmp_routes" "$tmp_sub"

    pass "subscription and prompt"
}

run_traffic_history_test() {
    local sourceable tmp_routes tmp_samples output_file
    sourceable="$(mktemp /tmp/vps2vps-source.XXXXXX)"
    tmp_routes="$(mktemp /tmp/vps2vps-routes.XXXXXX)"
    tmp_samples="$(mktemp /tmp/vps2vps-traffic.XXXXXX)"
    output_file="$(mktemp /tmp/vps2vps-traffic-output.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$sourceable' '$tmp_routes' '$tmp_samples' '$output_file'" RETURN
    make_sourceable_copy "$sourceable"

    python3 - "$tmp_routes" "$tmp_samples" <<'PYEOF'
import json
import sys
import time

routes_path, samples_path = sys.argv[1], sys.argv[2]
json.dump({
    "routes": [{
        "name": "Spain Node",
        "relay_port": "443",
        "exit_host": "203.0.113.10",
        "exit_port": "443"
    }]
}, open(routes_path, "w"))

now = int(time.time())
def stats(in_up, in_down, out_up, out_down):
    return {
        "inbound>>>client-in-443>>>traffic>>>uplink": in_up,
        "inbound>>>client-in-443>>>traffic>>>downlink": in_down,
        "outbound>>>to-exit-443>>>traffic>>>uplink": out_up,
        "outbound>>>to-exit-443>>>traffic>>>downlink": out_down,
    }

samples = [
    {"ts": now - 4000, "stats": stats(1000, 2000, 3000, 4000)},
    {"ts": now - 3600, "stats": stats(1100, 2200, 3300, 4400)},
    {"ts": now - 1800, "stats": stats(2000, 4000, 6000, 8000)},
    {"ts": now - 60, "stats": stats(2500, 5000, 7500, 10000)},
]
with open(samples_path, "w") as f:
    for sample in samples:
        f.write(json.dumps(sample) + "\n")
PYEOF

    bash -c '
        source "$0"
        ROUTES_FILE="$1"
        TRAFFIC_SAMPLES_FILE="$2"
        show_traffic_stats >"$3"
        grep -q "过去1小时" "$3"
        grep -q "过去24小时" "$3"
        grep -q "过去10天" "$3"
        grep -q "当月" "$3"
        grep -q "Xray 启动以来" "$3"
        grep -q "1.37 KB" "$3"
    ' "$sourceable" "$tmp_routes" "$tmp_samples" "$output_file"

    pass "traffic history"
}

run_x25519_parser_test() {
    local private_key public_key
    private_key=$(awk -F':[[:space:]]*' 'tolower($1) ~ /private/ {print $2; exit}' <<'EOF'
PrivateKey: QHmcHCcpuu058uhpjOJ3OnNvi9_Vj_MlD2tKY_FT4U8
Password (PublicKey): fgHpeVkT25d1jJAZNVrbhLmGNgLBrpZtRcfO0osriRc
Hash32: 3k6biYPd71Rgyb1h67s2XTbzDg_wu78xGfsc_G5W-FY
EOF
)
    public_key=$(awk -F':[[:space:]]*' 'tolower($1) ~ /public/ {print $2; exit}' <<'EOF'
PrivateKey: QHmcHCcpuu058uhpjOJ3OnNvi9_Vj_MlD2tKY_FT4U8
Password (PublicKey): fgHpeVkT25d1jJAZNVrbhLmGNgLBrpZtRcfO0osriRc
Hash32: 3k6biYPd71Rgyb1h67s2XTbzDg_wu78xGfsc_G5W-FY
EOF
)
    [ "$private_key" = "QHmcHCcpuu058uhpjOJ3OnNvi9_Vj_MlD2tKY_FT4U8" ] || fail "failed to parse PrivateKey"
    [ "$public_key" = "fgHpeVkT25d1jJAZNVrbhLmGNgLBrpZtRcfO0osriRc" ] || fail "failed to parse PublicKey"
    pass "x25519 parser"
}

main() {
    [ -f "$DEPLOY_SCRIPT" ] || fail "deploy script not found: $DEPLOY_SCRIPT"
    run_bash_syntax_test
    run_shellcheck_test
    run_config_generation_test
    run_exit_bundle_test
    run_subscription_and_prompt_test
    run_traffic_history_test
    run_x25519_parser_test
    pass "all tests passed"
}

main "$@"
