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
    local sourceable tmp_exit tmp_relay tmp_routes tmp_multi
    sourceable="$(mktemp /tmp/vps2vps-source.XXXXXX)"
    tmp_exit="$(mktemp /tmp/vps2vps-exit.XXXXXX)"
    tmp_relay="$(mktemp /tmp/vps2vps-relay.XXXXXX)"
    tmp_routes="$(mktemp /tmp/vps2vps-routes.XXXXXX)"
    tmp_multi="$(mktemp /tmp/vps2vps-relay-multi.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$sourceable' '$tmp_exit' '$tmp_relay' '$tmp_routes' '$tmp_multi'" RETURN

    make_sourceable_copy "$sourceable"

    bash -c '
        source "$0"

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
    ' "$sourceable" "$tmp_exit" "$tmp_relay" "$tmp_routes" "$tmp_multi"

    python3 - "$tmp_exit" "$tmp_relay" "$tmp_multi" <<'PYEOF'
import json
import sys

exit_config = json.load(open(sys.argv[1]))
relay_config = json.load(open(sys.argv[2]))
multi_config = json.load(open(sys.argv[3]))

assert exit_config["inbounds"][0]["protocol"] == "vless"
assert exit_config["inbounds"][0]["streamSettings"]["security"] == "reality"
assert exit_config["outbounds"][0]["protocol"] == "freedom"
assert exit_config["routing"]["rules"][-1]["outboundTag"] == "direct"

assert relay_config["inbounds"][0]["protocol"] == "vless"
assert relay_config["inbounds"][0]["streamSettings"]["security"] == "reality"
assert relay_config["outbounds"][0]["tag"] == "to-exit"
assert relay_config["outbounds"][0]["streamSettings"]["security"] == "reality"
assert relay_config["routing"]["rules"][-1]["outboundTag"] == "to-exit"

assert len(multi_config["inbounds"]) == 2
assert {i["port"] for i in multi_config["inbounds"]} == {443, 8443}
assert {o["tag"] for o in multi_config["outbounds"][:2]} == {"to-exit-443", "to-exit-8443"}
assert multi_config["routing"]["rules"][-2]["outboundTag"] == "to-exit-443"
assert multi_config["routing"]["rules"][-1]["outboundTag"] == "to-exit-8443"
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
    run_x25519_parser_test
    pass "all tests passed"
}

main "$@"
