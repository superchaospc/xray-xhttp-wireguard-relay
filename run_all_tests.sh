#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
bash -n xray_xhttp_wireguard_relay.sh test_*.sh run_all_tests.sh
if command -v shellcheck >/dev/null; then shellcheck -S warning xray_xhttp_wireguard_relay.sh test_*.sh run_all_tests.sh; fi
for t in test_identity_and_xhttp.sh test_wireguard_bundle.sh test_multi_route_lifecycle.sh test_firewall_and_diagnostics.sh; do
  out=$(bash "$t")
  printf '%s\n' "$out"
  grep -q '^PASS ' <<<"$out"
done
echo "PASS all"
