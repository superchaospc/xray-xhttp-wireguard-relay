#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/test_helpers.sh"
assert_contains "$SCRIPT" 'route_id'
assert_contains "$SCRIPT" 'wg-quick@'
assert_contains "$SCRIPT" 'ip rule add from'
assert_contains "$SCRIPT" '已回滚'
assert_contains "$SCRIPT" 'mutate_route delete'
pass lifecycle
