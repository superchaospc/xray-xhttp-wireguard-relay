# XHTTP WireGuard VPS Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the upstream VPS-to-VPS VLESS relay into a multi-route deployment tool where clients use VLESS XHTTP REALITY to the Relay and each Relay-to-Exit path uses an isolated WireGuard tunnel.

**Architecture:** Keep the upstream single-file Bash deployment experience and versioned JSON route state. Exit installation generates both WireGuard peer key pairs and a secret route bundle; Relay installation imports that bundle, creates a stable per-route WireGuard interface, and binds the matching Xray `freedom` outbound to the tunnel address. Each behavior is developed test-first and route deletion removes only project-owned state.

**Tech Stack:** Bash, Python 3 JSON helpers, Xray-core, VLESS XHTTP REALITY, WireGuard, `ip rule`, systemd, iptables/nftables, ShellCheck

---

## File Structure

- `xray_xhttp_wireguard_relay.sh`: single-file installer, menu, route state, Xray generation, WireGuard generation, firewall ownership, diagnostics, rollback, and CLI entrypoint.
- `test_helpers.sh`: shared test loader, assertions, temporary-file cleanup, and fake command helpers.
- `test_identity_and_xhttp.sh`: project identity, XHTTP settings, client URI, and Xray JSON tests.
- `test_wireguard_bundle.sh`: bundle integrity, endpoint formatting, interface naming, subnet/port allocation, and WireGuard config tests.
- `test_multi_route_lifecycle.sh`: add, rename, port change, delete isolation, subscriptions, and rollback tests.
- `test_firewall_and_diagnostics.sh`: owned NAT/forwarding cleanup, status, handshake, and diagnostic tests.
- `run_all_tests.sh`: syntax, ShellCheck, and all focused test scripts.
- `README.md`: installation, multi-route operation, security, compatibility, troubleshooting, badges, and release notes.
- `LICENSE`: retained MIT license with upstream copyright preserved.

### Task 1: Establish Project Identity and Test Harness

**Files:**
- Rename: `xray_vps2vps_deploy.sh` to `xray_xhttp_wireguard_relay.sh`
- Create: `test_helpers.sh`
- Create: `test_identity_and_xhttp.sh`
- Create: `run_all_tests.sh`
- Delete: `test_xray_vps2vps_deploy.sh`

- [ ] **Step 1: Write failing identity tests**

Create assertions that the deploy script uses:

```bash
PROJECT_ID="xray-xhttp-wireguard-relay"
SCRIPT_PATH="/root/xray_xhttp_wireguard_relay.sh"
SCRIPT_URL="https://raw.githubusercontent.com/superchaospc/xray-xhttp-wireguard-relay/main/xray_xhttp_wireguard_relay.sh"
ROUTES_FILE="/root/xray_xhttp_wireguard_routes.json"
```

Also assert that help and banner text describe `Client -> VLESS XHTTP REALITY -> Relay -> WireGuard -> Exit`.

- [ ] **Step 2: Run the identity test and verify it fails**

Run: `bash test_identity_and_xhttp.sh`

Expected: FAIL because the upstream script and identifiers still use `xray-vps2vps`.

- [ ] **Step 3: Rename the script and apply the minimum project identity changes**

Preserve the upstream menu shape and helpers. Remove Exit-side Xray constants and descriptions that imply Relay-to-Exit VLESS.

- [ ] **Step 4: Add the aggregate test runner**

`run_all_tests.sh` must run `bash -n`, `shellcheck -S warning` when available, then every `test_*.sh` except `test_helpers.sh`.

- [ ] **Step 5: Run tests and commit**

Run: `bash run_all_tests.sh`

Expected: identity tests PASS.

Commit: `refactor: establish XHTTP WireGuard project`

### Task 2: Generate XHTTP REALITY Client Entries

**Files:**
- Modify: `xray_xhttp_wireguard_relay.sh`
- Modify: `test_identity_and_xhttp.sh`

- [ ] **Step 1: Write failing XHTTP tests**

For one and two saved routes, assert generated Xray JSON contains:

```json
{
  "protocol": "vless",
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "xhttpSettings": {
      "path": "/independent-random-path",
      "mode": "auto"
    }
  }
}
```

Assert each route has a distinct path and REALITY material. Assert each outbound is:

```json
{
  "protocol": "freedom",
  "sendThrough": "10.77.0.2"
}
```

Assert routing maps `client-in-<route-id>` only to `wg-out-<route-id>`, and BitTorrent maps to `blocked`.

- [ ] **Step 2: Verify the new tests fail**

Run: `bash test_identity_and_xhttp.sh`

Expected: FAIL because upstream uses RAW/TCP REALITY and a VLESS Exit outbound.

- [ ] **Step 3: Implement XHTTP helpers and route schema**

Add validation for `XHTTP_MODE=auto|stream-one|stream-up|packet-up` and paths matching `^/[A-Za-z0-9._~/-]{8,128}$`. Generate a random path when absent. Persist stable `route_id`, VLESS credentials, XHTTP path/mode, WireGuard addresses, interface, endpoint, and keys in each route record.

- [ ] **Step 4: Implement multi-route Xray generation and client URI output**

Client URIs must include URL-encoded `path`, plus `type=xhttp`, `mode`, `security=reality`, `pbk`, `sid`, `sni`, and `fp`. Changing a client port must not change `route_id`, path, credentials, or WireGuard identity.

- [ ] **Step 5: Run tests and commit**

Run: `bash test_identity_and_xhttp.sh && bash run_all_tests.sh`

Expected: PASS.

Commit: `feat: use XHTTP REALITY client entries`

### Task 3: Add Versioned Secret WireGuard Route Bundles

**Files:**
- Modify: `xray_xhttp_wireguard_relay.sh`
- Create: `test_wireguard_bundle.sh`

- [ ] **Step 1: Write failing bundle tests**

Round-trip a bundle with this logical payload:

```json
{
  "version": 1,
  "route_id": "a1b2c3d4",
  "exit_endpoint": "203.0.113.10",
  "wg_port": 51821,
  "subnet": "10.77.0.0/30",
  "exit_address": "10.77.0.1/30",
  "relay_address": "10.77.0.2/30",
  "exit_private_key": "not-exported",
  "exit_public_key": "base64-key",
  "relay_private_key": "base64-key",
  "relay_public_key": "base64-key",
  "preshared_key": "base64-key"
}
```

Assert the exported bundle excludes `exit_private_key`, includes the Relay private key, rejects unknown versions, malformed keys, invalid CIDRs, mismatched addresses, trailing data, and a modified integrity digest.

- [ ] **Step 2: Verify bundle tests fail**

Run: `bash test_wireguard_bundle.sh`

Expected: FAIL because upstream bundles VLESS Exit credentials.

- [ ] **Step 3: Implement strict bundle encoding and decoding**

Use canonical compact JSON, SHA-256 integrity metadata, and URL-safe base64. Integrity detects accidental modification; README and output must state it is not encryption or authentication. Never print the full bundle in status or diagnostics.

- [ ] **Step 4: Add IPv4/IPv6 endpoint formatting and key validation**

Format IPv6 WireGuard endpoints as `[2001:db8::10]:51821`. Accept standard WireGuard base64 keys only after decoding to exactly 32 bytes.

- [ ] **Step 5: Run tests and commit**

Run: `bash test_wireguard_bundle.sh && bash run_all_tests.sh`

Expected: PASS.

Commit: `feat: add WireGuard route bundles`

### Task 4: Generate and Manage Isolated WireGuard Interfaces

**Files:**
- Modify: `xray_xhttp_wireguard_relay.sh`
- Modify: `test_wireguard_bundle.sh`

- [ ] **Step 1: Write failing interface and allocation tests**

Assert route `a1b2c3d4` maps to a stable interface no longer than 15 characters, for example `xwg-a1b2c3d4`. Changing client port must not rename it.

Test allocation skips:

```text
10.77.0.0/30   saved route
10.77.0.4/30   existing local route
UDP 51821      active socket
```

and selects the next free subnet and port.

- [ ] **Step 2: Write failing WireGuard config tests**

Exit config must contain its private key, listen port, Relay public key, preshared key, and Relay `/32` allowed IP. Relay config must contain its private key, Exit endpoint/public key, preshared key, `AllowedIPs = 0.0.0.0/0, ::/0`, `Table = off`, and `PersistentKeepalive = 25`.

- [ ] **Step 3: Verify tests fail**

Run: `bash test_wireguard_bundle.sh`

Expected: FAIL because no WireGuard config helpers exist.

- [ ] **Step 4: Implement allocators and config writers**

Use configurable defaults `WG_SUBNET_POOL=10.77.0.0/16`, `WG_PORT_START=51821`, and `WG_MTU=1380`. Detect collisions from saved state, `ip route`, `ip address`, `wg show interfaces`, and listening UDP sockets.

- [ ] **Step 5: Implement policy routing lifecycle**

Create one deterministic routing table number per route. Add rules equivalent to:

```bash
ip rule add from 10.77.0.2/32 table 20101
ip route add default dev xwg-a1b2c3d4 table 20101
```

Persist lifecycle commands through `wg-quick` hooks or a project-owned systemd unit. Removal must be idempotent.

- [ ] **Step 6: Run tests and commit**

Run: `bash test_wireguard_bundle.sh && bash run_all_tests.sh`

Expected: PASS.

Commit: `feat: manage isolated WireGuard routes`

### Task 5: Implement Exit Forwarding and Owned Firewall Rules

**Files:**
- Modify: `xray_xhttp_wireguard_relay.sh`
- Create: `test_firewall_and_diagnostics.sh`

- [ ] **Step 1: Write failing firewall ownership tests**

Test generated rule identity includes route ID, such as:

```text
xray-xhttp-wg:a1b2c3d4
```

Assert forwarding accepts only the route tunnel subnet/interface pair and NAT applies only from that subnet to the selected egress interface. Deleting the route must remove matching owned rules and preserve unrelated rules on the same port or subnet.

- [ ] **Step 2: Verify tests fail**

Run: `bash test_firewall_and_diagnostics.sh`

Expected: FAIL because upstream only opens Xray TCP ports.

- [ ] **Step 3: Implement forwarding and NAT backends**

Support existing host firewall tools conservatively. Prefer tagged nftables or iptables comments. Record the selected backend and exact owned rule identity in route state. Enable forwarding through a project sysctl file without replacing unrelated settings.

- [ ] **Step 4: Implement Exit install and removal**

Exit install generates keys, writes mode `600` config/state, opens only the selected UDP port, starts `wg-quick@<interface>`, verifies interface state, then emits the secret Relay bundle. Removal stops only that route's interface and removes only owned files/rules.

- [ ] **Step 5: Run tests and commit**

Run: `bash test_firewall_and_diagnostics.sh && bash run_all_tests.sh`

Expected: PASS.

Commit: `feat: configure WireGuard exit forwarding`

### Task 6: Integrate Relay Install, Rollback, and Multi-Route Lifecycle

**Files:**
- Modify: `xray_xhttp_wireguard_relay.sh`
- Create: `test_multi_route_lifecycle.sh`

- [ ] **Step 1: Write failing lifecycle tests**

Cover:

- Import first and second bundles without overwriting the first route.
- Reject duplicate `route_id`, TCP port, interface, subnet, tunnel address, or routing table.
- Rename changes only `name`.
- Port change changes only `relay_port`, inbound port, firewall TCP rule, link, and subscription.
- Delete removes only the selected Xray inbound/outbound/rule, WireGuard interface, policy rule, and owned firewall rules.
- Failed `xray run -test`, Xray restart, or WireGuard start restores previous route JSON and Xray config and removes newly created route resources.

- [ ] **Step 2: Verify tests fail**

Run: `bash test_multi_route_lifecycle.sh`

Expected: FAIL before lifecycle integration.

- [ ] **Step 3: Implement transactional Relay install**

Order operations as: validate bundle and collisions, write temporary route state, generate/validate Xray, write WireGuard config, start interface, atomically install route/Xray state, restart Xray, verify both services. On failure, restore all previous managed state.

- [ ] **Step 4: Adapt menus and CLI**

Support:

```text
--exit
--relay
--list
--stats
--qr
--sub
--delete
--rename
--port
--doctor
--update
--restart
--status
--uninstall
```

Exit and Relay management views must clearly identify the local role and never expose private keys by default.

- [ ] **Step 5: Preserve subscriptions and traffic history**

Use stable route IDs in Xray tags so port changes do not split traffic identity. Subscription generation must remain atomic and contain one current URI per route.

- [ ] **Step 6: Run tests and commit**

Run: `bash test_multi_route_lifecycle.sh && bash run_all_tests.sh`

Expected: PASS.

Commit: `feat: add transactional multi-route lifecycle`

### Task 7: Add Diagnostics, Security Checks, and Update Behavior

**Files:**
- Modify: `xray_xhttp_wireguard_relay.sh`
- Modify: `test_firewall_and_diagnostics.sh`

- [ ] **Step 1: Write failing diagnostic tests**

Assert diagnostics report per route:

```text
Xray config validity
client TCP listener
WireGuard service/interface
endpoint
latest handshake age
RX/TX counters
tunnel peer reachability
policy rule and route table
Exit forwarding/NAT state
```

Mock stale/no handshake and verify it is a warning with an actionable command, not a false success.

- [ ] **Step 2: Verify tests fail**

Run: `bash test_firewall_and_diagnostics.sh`

Expected: FAIL before WireGuard-aware diagnostics.

- [ ] **Step 3: Implement redacted diagnostics and status**

Redact UUIDs, REALITY private keys, WireGuard private/preshared keys, and bundles. Public keys and endpoints may be shown. `XRAY_REDACT=0` may show full client links but must still never print WireGuard private keys.

- [ ] **Step 4: Implement update and uninstall safeguards**

Updating Xray must verify XHTTP support before restart. Uninstall requires explicit confirmation, enumerates project-owned routes, and removes only project-owned Xray files, interfaces, systemd units, sysctl files, policy rules, and firewall entries.

- [ ] **Step 5: Run tests and commit**

Run: `bash test_firewall_and_diagnostics.sh && bash run_all_tests.sh`

Expected: PASS.

Commit: `feat: add WireGuard diagnostics and safeguards`

### Task 8: Rewrite README and Prepare v1.0.0

**Files:**
- Modify: `README.md`
- Modify: `LICENSE` only if attribution formatting requires it

- [ ] **Step 1: Add documentation assertions**

Extend `test_identity_and_xhttp.sh` to require repository-correct badge URLs and the terms `XHTTP`, `REALITY`, `WireGuard`, `route bundle`, `v1.0.0`, and upstream attribution.

- [ ] **Step 2: Verify documentation tests fail**

Run: `bash test_identity_and_xhttp.sh`

Expected: FAIL while README still documents VLESS between VPS hosts.

- [ ] **Step 3: Rewrite README**

Document:

- Architecture diagram and why WireGuard is used.
- Exit-first, Relay-second installation.
- Secret bundle warning and mode `600` handling.
- Multi-route examples with independent TCP/UDP ports and `/30` subnets.
- XHTTP-compatible clients and Xray version requirement.
- Status, links, QR, subscription, rename, port change, delete, diagnostics, update, restart, and uninstall.
- IPv4/IPv6 endpoints, firewall/security-group requirements, MTU guidance, and troubleshooting.
- MIT/upstream attribution and legal disclaimer.

Add badges pointing to `superchaospc/xray-xhttp-wireguard-relay` for release, date, downloads, last commit, issues, stars, forks, repo/code size, license, tests, Bash, Linux, Xray, XHTTP, REALITY, WireGuard, Debian, Ubuntu, and RHEL-compatible systems.

- [ ] **Step 4: Run full static verification**

Run:

```bash
bash run_all_tests.sh
git diff --check
```

Expected: all tests PASS and no whitespace errors.

- [ ] **Step 5: Commit**

Commit: `docs: prepare v1.0.0 release`

### Task 9: Final Review and Release Readiness

**Files:**
- Review all tracked files

- [ ] **Step 1: Run clean-checkout verification**

Clone the local repository to a temporary directory and run:

```bash
bash run_all_tests.sh
bash -n xray_xhttp_wireguard_relay.sh
shellcheck -S warning xray_xhttp_wireguard_relay.sh test_*.sh run_all_tests.sh
```

Expected: PASS. If ShellCheck is unavailable, install it or clearly record the skipped check.

- [ ] **Step 2: Perform security review**

Search tracked files for sample private keys, real UUIDs, VPS credentials, generated bundles, `output/` artifacts, and old repository URLs. Confirm executable bits and mode-sensitive runtime writes.

- [ ] **Step 3: Confirm release contents**

The release commit must contain only source, tests, README, LICENSE, and design/plan docs. Do not include real VPS output, QR codes, client links, or secrets.

- [ ] **Step 4: Record verification result**

Prepare concise release notes for `v1.0.0` listing architecture, multi-route support, tests, security model, and whether live disposable-VPS testing was performed.

- [ ] **Step 5: Commit any final review fixes**

Commit only if needed: `chore: finalize v1.0.0`
