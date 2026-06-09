# XHTTP WireGuard VPS Relay Design

## Goal

Create `superchaospc/xray-xhttp-wireguard-relay` from
`superchaospc/xray-vps2vps-relay` v1.4.3.

The new project deploys this topology:

```text
Client
  -> Relay VPS (VLESS + XHTTP + REALITY)
  -> WireGuard tunnel
  -> Exit VPS
  -> Internet
```

One Relay VPS can manage multiple Exit VPS routes. Each route has its own
client entry port, XHTTP path, REALITY credentials, WireGuard interface,
WireGuard UDP port, and `/30` tunnel subnet.

## Supported Systems

- Linux VPS with root access and systemd.
- Debian and Ubuntu are the primary tested distributions.
- RHEL-compatible distributions remain supported where the upstream package,
  firewall, and service helpers permit it.
- Public Relay and Exit addresses may be IPv4 or IPv6.
- Client applications must support VLESS XHTTP with REALITY.

## Installation Flow

The user installs the Exit first and the Relay second, matching the upstream
workflow.

### Exit Installation

The Exit installer:

1. Installs WireGuard and required utilities.
2. Selects an unused WireGuard UDP port and `/30` tunnel subnet.
3. Generates independent Relay and Exit WireGuard key pairs.
4. Writes the Exit interface configuration with only the Exit private key.
5. Enables IP forwarding and route-scoped forwarding and NAT rules.
6. Starts and validates the WireGuard interface.
7. Produces a versioned route bundle and a one-line Relay install command.

The generated bundle contains the Relay private key and must be treated as a
secret. It is stored only in a root-owned mode `600` file when persisted.
Normal status and diagnostic output redact private keys and bundle contents.

### Relay Installation

The Relay installer:

1. Imports and validates the versioned route bundle.
2. Refuses an occupied client TCP port, WireGuard interface, tunnel subnet, or
   local address unless explicit replacement is requested.
3. Writes the route's WireGuard interface configuration.
4. Starts WireGuard and verifies that the interface is usable.
5. Generates independent VLESS UUID, REALITY key pair, short ID, and XHTTP
   path for the client entry.
6. Adds the route to the Relay route table.
7. Generates a candidate Xray configuration, validates it with
   `xray run -test`, atomically installs it, and restarts Xray.
8. Rolls back the Xray configuration and the new WireGuard interface when any
   required step fails.

## Route Model

Each route record contains:

- Human-readable route name.
- Relay client TCP port.
- Client UUID, REALITY keys, short ID, SNI, fingerprint, XHTTP path, and mode.
- WireGuard interface name.
- Relay and Exit tunnel addresses.
- Exit public endpoint and WireGuard UDP port.
- Relay private key, Exit public key, and optional preshared key.
- Tunnel subnet and address family used for Internet egress.

Interface names are deterministic and remain within Linux's 15-character
limit. They use a short stable route identifier rather than the mutable client
port, so changing a client entry port does not rename or interrupt the
WireGuard interface.

The default allocator uses isolated `/30` IPv4 subnets from a configurable
private pool. It checks existing local interfaces, routes, and saved routes
before allocation. Users can override the subnet when it conflicts with their
network.

Each Exit route uses a distinct UDP port by default. An Exit may host multiple
routes without sharing key material or interface state.

## Xray Configuration

Every Relay route creates:

- One VLESS inbound listening on its client TCP port.
- XHTTP transport with a random path and configurable mode, default `auto`.
- REALITY security with independent credentials.
- One `freedom` outbound using `sendThrough` with the route's Relay-side
  WireGuard address.
- One routing rule from that inbound tag to that outbound tag.

The generated client URI includes `security=reality`, `type=xhttp`, `path`,
`mode`, `pbk`, `sid`, `sni`, and `fp`.

BitTorrent traffic is blocked. Xray Stats API support is retained for per-route
traffic reporting.

## WireGuard Routing

The Relay WireGuard interface does not replace the host default route.
Xray's route-specific `freedom` outbound binds to the route's tunnel address,
and policy routing sends packets sourced from that address through its matching
WireGuard interface. SSH and unrelated host traffic retain their existing
routes.

The Exit enables forwarding only for the route's tunnel subnet and applies
source NAT only when traffic leaves through the selected public egress
interface. Rules are tagged or otherwise recorded so the script removes only
rules it owns.

`PersistentKeepalive` is enabled on the Relay peer. MTU is configurable and
defaults conservatively for nested transport.

## Management

The upstream menu model is retained and adapted for WireGuard:

- Add an Exit route from a route bundle.
- List routes and client links.
- Show terminal QR codes.
- Refresh the base64 subscription.
- Show current and historical per-route traffic.
- Rename a route.
- Change a client entry port without changing its WireGuard identity.
- Delete one route and only its owned Xray, WireGuard, firewall, and policy
  routing state.
- Show service, port, interface, handshake, endpoint, and egress diagnostics.
- Update Xray and restart managed services.
- Uninstall project-managed resources after explicit confirmation.

The Exit also provides status, diagnostic, route removal, and uninstall
operations for interfaces installed by this project.

## Persistence And Ownership

Project state is stored in versioned JSON rather than inferred only from live
configuration. Sensitive state is mode `600`.

Generated systemd units, WireGuard files, sysctl files, routing tables, and
firewall rules carry a project-specific identity. Existing WireGuard
interfaces, Xray services, routes, firewall rules, and SSH configuration are
not changed unless they are explicitly adopted by the user.

Config writes follow:

1. Generate a temporary candidate.
2. Validate syntax and required fields.
3. Back up the current managed file.
4. Atomically replace it.
5. Restart and verify.
6. Restore the backup if verification fails.

## Validation And Error Handling

Inputs are validated before use:

- Public hosts and IPv4/IPv6 endpoints.
- TCP and UDP ports.
- UUID, REALITY short ID, XHTTP mode and path.
- WireGuard keys, interface names, CIDRs, and tunnel addresses.
- Version and integrity of imported route bundles.

The installer verifies:

- Required kernel and command support.
- Xray's support for XHTTP.
- Candidate Xray JSON.
- WireGuard interface state and latest handshake.
- Tunnel reachability.
- Exit forwarding and NAT.
- End-to-end public egress when connectivity permits.

Failures identify the affected route and provide safe diagnostic commands.
Private keys, UUIDs, and full client links are redacted unless explicitly
requested.

## Testing

Automated tests cover:

- Bash syntax and ShellCheck warnings.
- Route bundle encode, decode, validation, and tamper rejection.
- Interface naming and collision detection.
- Subnet and UDP port allocation.
- XHTTP REALITY inbound generation.
- Per-route `sendThrough` and routing rules.
- WireGuard and policy-routing config generation.
- IPv4 and IPv6 endpoint formatting.
- Firewall and NAT ownership and cleanup.
- Atomic update and rollback.
- Multi-route add, rename, port change, and delete isolation.
- Subscription, QR payload, status, traffic, and diagnostic helpers.

When suitable disposable VPS hosts are available, smoke testing verifies an
actual WireGuard handshake and confirms that a client connecting through the
Relay observes the Exit VPS public IP.

## Repository And Release

The repository is public and licensed under MIT with upstream attribution.
The README includes:

- Architecture and installation walkthrough.
- Multi-route examples.
- Security warning for route bundles.
- Compatibility requirements.
- Troubleshooting and uninstall guidance.
- Badges for release, release date, downloads, tests, license, shell, Linux,
  Xray, XHTTP, REALITY, WireGuard, and supported distributions.

The first release is tagged `v1.0.0`. The release notes describe the protocol
change from Relay-to-Exit VLESS REALITY to WireGuard, supported features,
security considerations, automated validation, and any limits of live VPS
testing.
