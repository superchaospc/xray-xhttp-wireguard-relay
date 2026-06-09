#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$ROOT/xray_xhttp_wireguard_relay.sh"
pass(){ printf 'PASS %s\n' "$*"; }
fail(){ printf 'FAIL %s\n' "$*" >&2; exit 1; }
assert_contains(){ grep -Fq -- "$2" "$1" || fail "$1 missing $2"; }
source_script(){
  # shellcheck disable=SC1090
  XRAY_WG_SOURCE_ONLY=1 source "$SCRIPT"
}
