#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/test_helpers.sh"
assert_contains "$SCRIPT" 'xray-xhttp-wireguard-relay'
assert_contains "$SCRIPT" '-m comment --comment'
assert_contains "$SCRIPT" 'MASQUERADE'
assert_contains "$SCRIPT" 'latest handshake'
assert_contains "$SCRIPT" 'firewall_del_exit'
pass firewall-diagnostics
