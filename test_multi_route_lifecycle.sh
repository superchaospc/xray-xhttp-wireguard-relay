#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/test_helpers.sh"
assert_contains "$SCRIPT" 'route_id'
assert_contains "$SCRIPT" 'wg-quick@'
assert_contains "$SCRIPT" 'ip rule add from'
assert_contains "$SCRIPT" '已回滚'
assert_contains "$SCRIPT" 'mutate_route delete'
assert_contains "$SCRIPT" '--qr) show_qr'
assert_contains "$SCRIPT" '--stats) show_stats'
assert_contains "$SCRIPT" 'main_menu'
assert_contains "$SCRIPT" 'ensure_relay_resources_free'
assert_contains "$SCRIPT" 'ORIGINAL_CONFIG_BACKUP'
assert_contains "$SCRIPT" 'int(x["relay_port"])!=int(new)'
assert_contains "$SCRIPT" 'if ! xray run -test'
pass lifecycle
