#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
source "$(dirname "$0")/test_helpers.sh"; source_script
[ "$(route_iface a1b2c3d4)" = xwg-a1b2c3d4 ] || fail iface
[ "${#PROJECT_ID}" -gt 0 ] || fail identity
[ "$(format_endpoint 2001:db8::1 51821)" = '[2001:db8::1]:51821' ] || fail ipv6
assert_contains "$SCRIPT" 'ListenPort = $WG_PORT'
valid_mode auto && ! valid_mode grpc || fail mode
valid_path /12345678 && ! valid_path /short || fail path
key=$(python3 - <<'PY'
import base64
print(base64.b64encode(bytes(range(32))).decode())
PY
)
ROUTE_ID=a1b2c3d4 EXIT_ENDPOINT=2001:db8::1 WG_PORT=51821 WG_SUBNET=10.77.0.0/30
EXIT_ADDRESS=10.77.0.1/30 RELAY_ADDRESS=10.77.0.2/30 EXIT_PUBLIC_KEY=$key
RELAY_PRIVATE_KEY=$key RELAY_PUBLIC_KEY=$key PRESHARED_KEY=$key
WG_BUNDLE=$(make_bundle)
unset ROUTE_ID EXIT_ENDPOINT WG_PORT WG_SUBNET EXIT_ADDRESS RELAY_ADDRESS EXIT_PUBLIC_KEY RELAY_PRIVATE_KEY RELAY_PUBLIC_KEY PRESHARED_KEY
load_bundle
[ "$ROUTE_ID" = a1b2c3d4 ] && [ "$EXIT_ENDPOINT" = 2001:db8::1 ] && [ "$WG_PORT" = 51821 ] || fail bundle
pass wireguard-helpers
