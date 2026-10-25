# Account-Scoped ACL: Live-Host Verification

How to prove the account-scoped ACL is actually enforcing on live hosts, plus the
evidence record from the 2026-08-21 release verification. The boundary itself is
documented in [access-control-list.md](access-control-list.md); this file is only
about confirming it holds on real hardware.

None of this is covered by `Backend/API/tests/test_bootstrap_contract.py`, which
parses `bootstrap.sh` text offline and never runs `nft`. Verdict precedence,
chain priority against the other forward-hook chains, the concatenated-set mark
comparison, and every reachability outcome are properties of a running kernel and
have no static representation.

**Re-run this when:** a region joins, a host is rebuilt, kernel/nftables changes,
or the bootstrap ruleset or policy renderer/parser changes. Inspect the live
objects and parser in Part A, then exercise the affected paths in Part B. Static
inspection alone cannot prove runtime enforcement after a version or ruleset change.

Run it after the fleet deploy from one tag and a green Sync All. Inspect each
affected host. A1-A7 are read-only; A8 adds optional temporary counters. Part B
needs live clients.

Region facts used below (`Infrastructure/OCI/terraform/subnet-registry.json`):

| Region | Tunnel v4 | Tunnel v6 | Infra (`cg_infra`) |
| --- | --- | --- | --- |
| `us-sanjose-1` | `10.0.0.0/24` | `fd42:42:42::/64` | `10.0.0.1`, `fd42:42:42::1` |
| `us-chicago-1` | `10.0.1.0/24` | `fd42:42:42:1::/64` | `10.0.1.1`, `fd42:42:42:1::1` |

Logging boundary: none of these steps may write VPN traffic, destination
metadata, or per-user connection history to disk. Counters are counts only and
are the preferred attribution tool. If you fall back to `nft monitor trace`,
keep it on-screen only, on your own test traffic, and never redirect it to a
file or paste addresses into a ticket.

## Part A - nft semantics on a real host

All commands as root on a regional host. Steps A1-A7 are read-only.

**Do not run `nft -f /etc/cloudgateway/cloudgateway.nft` on a live host.** The
file has no `flush`/`delete`, so a second load appends the whole rule list a
second time. It is safe only at `PostUp`, when `PostDown` has already deleted
the table. Use `--check` (A4) to validate it.

### A0. Command safety tiers

A1-A7 inspect live state or check syntax without committing firewall changes.
A8 deliberately changes rules to add counters and must be reverted.

Notes on the few that need a caveat:

* **`nft --check -f` (A4)** parses an add-shaped file without committing it.
  Listing the live rules in A2 is separate from validating the on-disk file.
* **`iptables -S FORWARD` / `iptables-save` (A3)** are listing operations, but
  under the `nf_tables` backend an iptables invocation can materialize an empty
  `filter` table that did not exist. On these hosts `filter/FORWARD` already
  exists because bootstrap installs rules into it, so nothing changes. To avoid
  the question entirely when `iptables --version` reports `(nf_tables)`, read
  them through nft instead: `nft list table ip filter` and
  `nft list table ip6 filter`. Use `-S` or `-L -n`, never bare `-L`, which does
  reverse DNS on every address.
* **`nft list ruleset` and the `cg_slot`/`cg_admin` listings** contain client
  tunnel addresses. Read them on-screen; do not redirect them to a file or paste
  them into a ticket.
* **`wg show wg0`** is read-only and does not print the private key, but it does
  print peer public keys, endpoints, and handshake times - per-user connection
  metadata. Same handling rule.
* **`conntrack -L`** would show live flow destinations. Do not run it as a
  general check. If you need it to confirm the `ct state established,related`
  behavior, filter it to your own test client's address and keep it on-screen.

Explicitly **not** read-only, and not to be run casually:

| Command | Effect |
| --- | --- |
| `nft -f /etc/cloudgateway/cloudgateway.nft` | Appends the whole rule list a second time; the file has no `flush`/`delete` |
| `nft replace/add/delete rule`, `nft add/delete element`, `nft flush ...` | Mutates the live boundary (A8 uses `replace` deliberately) |
| `nft reset rules` / `nft reset counters` | Zeroes counters, which is a write |
| `meta nftrace set 1` rule for `nft monitor trace` | Adds a rule; `nft monitor` alone is passive but shows nothing without it |
| `wg-quick down/up`, `systemctl restart wg-quick@wg0` | Drops every tunnel in the region |

### A0b. What read-only alone can and cannot settle

Inspection confirms object kinds, concatenation types, priority, mark ownership,
slot-0 reservation, and parser compatibility. Only a packet can prove that the
early drop defeats later iptables accepts.

Part B needs no firewall mutation. A8 counters attribute a result to a rule.
Without counters, use differential probes: prove the same destination and
protocol respond over an allowed path immediately before the denied path, ideally
using the same device and changing only its account/config. A reply from a
different target proves the initiator's path works but cannot establish that the
denied target is awake or listening. Record both control and deny results.

### A1. Environment

```sh
nft --version
uname -a
iptables --version      # note whether it says (nf_tables) or (legacy)
ip6tables --version
ip -br link show wg0
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
systemctl status cloudgateway-api.service --no-pager
journalctl -u cloudgateway-sync-peers.service -n 50 --no-pager
```

Record the nft version: the JSON element wrappers `src/policy.py`
`_unwrap_element_value` tolerates (`elem`/`val`) are version-dependent, and A5
is what proves this host's shape parses.

### A2. Table, object kinds, and rule text

```sh
nft list table inet cloudgateway
nft describe "ip daddr"
nft describe mark
```

Confirm, against `Infrastructure/OCI/host/bootstrap.sh`:

* `cg_tunnel4` = `10.0.0.0/16`, `cg_tunnel6` = `fd42:42:42::/48`, both `flags interval`.
* `cg_infra4/6`, `cg_admin4/6` are **sets**; `cg_slot4/6` are **maps** of address to `mark`.
* `cg_pairs4/6` declared `typeof ip daddr . meta mark` list back as a concatenated
  type (`ipv4_addr . mark` / `ipv6_addr . mark`). This is the mark-comparison
  syntax check: the kernel accepted and stored the concatenation.
* Chain header lists `type filter hook forward priority -10; policy accept;`
  (some versions print `priority filter - 10`; same value).
* Rule order is exactly: `ct state established,related accept`, the four
  infra/admin accepts, the two `meta mark set ... map @cg_slot`, then the two
  `ip daddr @cg_tunnelN ip daddr . meta mark != @cg_pairsN drop`.
* The `!= @cg_pairsN` comparison survives the round trip as written. If this
  host's nft rewrote it into another form, note the exact printed form - the
  contract test asserts the bootstrap source, not the printed form.

### A3. Chain priority, and every other forward-hook chain

```sh
nft list ruleset | grep -n "hook forward"
iptables -S FORWARD
ip6tables -S FORWARD
```

`cg_forward` runs at `-10`, before the expected iptables `filter/FORWARD`
priority `0`. Investigate other negative-priority forward chains and any change
to the expected order.

### A4. The on-disk ruleset still parses

```sh
nft --check -f /etc/cloudgateway/cloudgateway.nft
```

Syntax-only. `--check` does not commit, so it will not duplicate rules.

### A5. JSON read-back shape (what the API actually parses)

```sh
nft -j list table inet cloudgateway | python3 -m json.tool | head -60
nft -j list set inet cloudgateway cg_pairs4 | python3 -m json.tool | head -30
nft -j list set inet cloudgateway cg_pairs6 | python3 -m json.tool | head -30
```

`cg_pairs4/6` elements must appear as `{"concat": [<addr>, <mark>]}` (optionally
wrapped in `elem`/`val`). That is exactly what `_parse_pairs_set` requires; a
different shape can break policy read-back. Run the installed parser on each
host too, printing only counts and hashes:

```sh
/opt/cloudgateway/api/.venv/bin/python - <<'PYTHON'
from src.policy import LocalPolicyManager

live = LocalPolicyManager().read_map()
print("row_count:", live.row_count)
print("mapHashV4:", live.hash_v4)
print("mapHashV6:", live.hash_v6)
PYTHON
```

This reads nftables only and needs no Firebase credentials. Compare both hashes
across hosts and with `Policy/*` after a quiet, successful Sync All. Do not print
the full `live` object, which contains client addresses.

### A6. Mark exclusivity

The chain assumes nothing else uses the packet mark, and that no `ip rule fwmark`
exists (see "Filter design" in [access-control-list.md](access-control-list.md)).

```sh
nft list ruleset | grep -in mark
ip rule show
ip -6 rule show
iptables-save | grep -i -- '-j MARK\|--mark'
ip6tables-save | grep -i -- '-j MARK\|--mark'
```

Only the `cloudgateway` table may reference marks. The map rules do not clear an
existing mark, so unknown sources rely on mark 0. Another mark user or `fwmark`
policy rule requires a deliberate ownership/masking change before relying on the ACL.

### A7. Slot 0 and populated state

```sh
nft list map inet cloudgateway cg_slot4 | grep -c 0x00000000   # expect 0
nft list map inet cloudgateway cg_slot6 | grep -c 0x00000000   # expect 0
nft list set inet cloudgateway cg_admin4
nft list set inet cloudgateway cg_infra4
nft list set inet cloudgateway cg_admin6
nft list set inet cloudgateway cg_infra6
```

`cg_infra4` must hold `10.0.0.1` and `10.0.1.1` (both regions, fleet-wide),
`cg_admin4` your admin account's client addresses, and no slot may be
`0x00000000`. An unknown source relies on an initially zero mark, and no
`cg_pairs` entry may pair a destination with slot 0. Check the equivalent IPv6
state. Use A5's parsed `row_count`, rather than `wc -l` on nft output, to compare
with `policyRowCount` / Server Health.

### A8. Temporary counters for Part B attribution (mutating, revert after)

Without counters, "ping got no reply" and "ACL dropped it" look identical. Add
counters to the two drop rules and the four infra/admin accepts, run Part B, then
revert. Counters do not change `mapHashV4/V6`: the hash covers the named
sets/maps only, never chain rules.

```sh
nft -a list chain inet cloudgateway cg_forward     # capture handles
nft list chain inet cloudgateway cg_forward > /root/cg_forward.before.txt
```

For each rule, replace it with the identical text plus `counter`, one at a time,
re-listing after each:

```sh
nft replace rule inet cloudgateway cg_forward handle <H> \
  iifname "wg0" oifname "wg0" ip daddr @cg_tunnel4 ip daddr . meta mark != @cg_pairs4 counter drop
```

Then `nft list counters` is not used here (these are anonymous, inline counters);
read them with `nft list chain inet cloudgateway cg_forward` and record deltas
between cases. Counter resets are another mutation and are unnecessary.

Revert by replacing each rule back to its original text from
`/root/cg_forward.before.txt`, then diff:

```sh
nft list chain inet cloudgateway cg_forward | diff /root/cg_forward.before.txt -
```

The diff must be empty before finishing. Do not restart WireGuard just to
remove counters: it drops every regional tunnel and empties runtime peers/routes.
A deliberate interface restart also needs an immediate `cloudgateway-sync-peers`
to restore state.

## Part B - the four reachability cases

### Prerequisites

* Two accounts: **Account A** (admin role) and **Account B** (non-admin). They
  must hold different `accountSlot` values.
* Configs for both accounts in both regions: `A-sj`, `A-chi`, `B-sj`, `B-chi`.
  Same-region allow tests also need `A-sj2` and `B-sj2`. Configs can be swapped
  between cases, with only each pair online for its check.
* At least two devices online at once; run each case with both endpoints
  connected. Cases are pairwise, so a phone plus a laptop is enough if you swap
  configs between cases.
* `meshEnabled` on for both regions, and Sync All green with matching v4/v6
  hashes on both.
* Client `AllowedIPs` must cover the fleet aggregate (`10.0.0.0/16`,
  `fd42:42:42::/48`) or be full-tunnel; otherwise a failure is client routing,
  not policy.
* **Positive control first.** Confirm the target responds to the chosen protocol
  over an allowed tunnel path in the same session. A Mac with SSH enabled or a
  verified ICMP responder is a useful target. The release-test iPhones had no
  inbound SSH and answered ICMP inconsistently, so their silence proved nothing.

Note each client's tunnel addresses from the dashboard before starting.

### Matrix

Run every case in **both directions** - initiate from each side. One direction is
not sufficient: `ct state established,related accept` means the return path of an
allowed flow is free, so testing only the reverse of an already-open flow proves
nothing. Use a fresh connection/probe for each direction, especially after
changing account roles or map contents. Existing conntrack flows are accepted
before the policy lookup.

| # | Case | From -> To | Expect | Host evidence |
| --- | --- | --- | --- | --- |
| 1 | Same account, same region | `A-sj` <-> `A-sj2`, then `B-sj` <-> `B-sj2` | reply, v4 and v6 | no drop-counter increment |
| 2 | Same account, cross region | `A-sj` <-> `A-chi`, then `B-sj` <-> `B-chi` | reply, v4 and v6 | no drop-counter increment on either host |
| 3 | Cross account, both directions | `A-sj` <-> `B-sj`, and `A-sj` <-> `B-chi` | 100% loss both ways | drop counter increments on the host the packet enters |
| 4 | Admin proxy jump, cross region | `A-chi` (admin) <-> `10.0.0.1` / `fd42:42:42::1`, and `A-sj` <-> `10.0.1.1` / `fd42:42:42:1::1` | reply both ways | infra/admin accept counter increments |
| 5 | Non-admin and remote infra (control) | `B-sj` <-> `10.0.1.1` / `fd42:42:42:1::1` | 100% loss, both families | drop counter increments |

Case 5 controls the admin exemption in case 4. Run a fresh server-originated
probe toward the remote client too, rather than relying on return traffic from
an already-established flow. Both directions must reject non-admin clients.

Commands, from the client device:

```sh
ping -c 4 10.0.1.5
ping6 -c 4 fd42:42:42:1::5         # macOS; Linux: ping -6
nc -vz -w 3 10.0.1.5 22           # optional TCP probe
```

### What case 3 proves beyond reachability

A counter-attributed cross-account drop proves that the concatenated lookup
rejects the packet and that the earlier nft drop prevents the later iptables
`FORWARD` accept from allowing it. Record the relevant drop-counter delta.
Without counters, record the differential control and retain that attribution
limitation.

### Recording results

Record the deploy ref, host/kernel/nft versions, printed drop-rule form, parsed
hash agreement, each flow/control result, and counter deltas when used. If A8
was used, confirm its revert diff was empty. Keep client identity, live addresses,
keys, and connection metadata out of tickets and persisted logs.

## Results: 2026-08-21 read-only pass

This is historical release evidence, not a claim about the current live fleet.
Both hosts were inspected over their tunnel addresses without nft writes,
package installs, service restarts, or temporary counters.

| Check | Recorded result |
| --- | --- |
| Environment | nftables `1.0.9`, kernel `6.17.0-1007-oracle` aarch64, iptables/ip6tables `1.8.10 (nf_tables)` |
| Priority/order | Nine rules, no duplicates; `cg_forward` at `filter - 10`, iptables forward at `filter` (0) |
| Objects | Correct sets/maps, aggregates, family types, and concatenated pair types |
| JSON | Pairs used `{"concat": [address, mark]}` and slots `[address, mark]`, with no `elem`/`val` wrapper; installed parser succeeded |
| Live map agreement | Both hosts returned 9 rows and identical IPv4/IPv6 hashes; each family had 1 tunnel, 2 infra, 4 admin, 9 slot, and 9 pair elements |
| Mark ownership | No mark references outside the ACL; no iptables MARK target or fwmark route rule; no slot 0 |
| Syntax check | `nft --check -f` passed on both hosts |
| Service observation | 16 refresh starts/completions, no failures in the inspected 24 hours; sync unit last exited 0 |

The hosts had no `ping` binary. Operator probes and an on-screen Python raw-socket
probe under `sudo` supplied reachability evidence without installing packages.
`/etc/cloudgateway` was mode 700, so reading its mode-644 nft file still required root.

## Open test matrix

Final recorded status from the same release session. Earlier intermediate results
are consolidated here. Closed rows are historical observations. Open, partial,
weak, and inconclusive rows remain unverified in the stated shape.

### Client capability constraints

The test Mac accepted SSH and answered ICMP over both tunnel families. The phones
could initiate SSH but had no inbound SSH listener, and sometimes failed ICMP
even over the local server's unfiltered output path. Prefer a verified Mac as the
deny target. Recheck target capability each session, because switching configs
can leave the old address assigned to a different device.

### Client-to-client, allow paths

| ID | Flow | Family | Final recorded status |
| --- | --- | --- | --- |
| C1 / C2 | Admin, same region | v4 / v6 | Open: no second responsive admin client |
| C3 | Admin, cross region | v4 | Closed: ICMP 4/4 and reverse operator SSH |
| C4 | Admin, cross region | v6 | Partial: ICMP 4/4, independently initiated reverse not run |
| C5 | Non-admin, same account and region | v4/v6 | Operator SSH success recorded; the original entry grouped both families without separate results |
| C6 | Non-admin, same account, cross region | v4 / v6 | Closed in both families by the controlled phone-to-Mac check below |

C5 proves non-admin same-account access, but its retained evidence does not
separately establish each family's result. C6 directly proves both families
across the mesh.

### Client-to-client, deny paths

| ID | Flow | Family | Final recorded status |
| --- | --- | --- | --- |
| D1 | Non-admin -> admin, same region | v4 | Closed: operator SSH failed while the same Mac accepted the allowed control |
| D2 | Non-admin -> admin, cross region | v4 | Closed on the original responsive-Mac control; later probes after its config changed were discarded |
| D3 / D4 | Non-admin -> admin, same/cross region | v6 | Inconclusive: target listener/responder unverified |
| D5 | Admin -> non-admin, same region | v4/v6 | Open |
| D6 / D6b | Admin -> non-admin, cross region | v4 / v6 | Closed in both families by the controlled check below |
| D7 | Non-admin account A -> non-admin account B | v4/v6 | Inconclusive: responder unverified |
| D8 | Client -> unallocated aggregate address | v4 | Weak: silence without counter attribution |
| D9 | Client -> unallocated aggregate address | v6 | Open |

### Client-to-infrastructure

Local server access uses `INPUT`; remote infrastructure access passes through
`FORWARD` on the source region.

| ID | Flow | Family | Final recorded status |
| --- | --- | --- | --- |
| I1 | Admin -> own region server | v4 | Closed: ICMP and SSH succeeded |
| I2 / I3 | Admin -> remote server | v4 / v6 | Closed: ICMP 3/3; IPv4 SSH also succeeded |
| I4 / I5 | Remote server -> admin client | v4 / v6 | Closed: newly initiated ICMP 3/3, exercising the infra-to-admin exemption |
| I6 | Non-admin -> own server | v4/v6 | Closed: IPv4 SSH and IPv6 ICMP succeeded |
| I7 | Non-admin -> remote server | v4/v6 | Closed: IPv4 SSH/ICMP and IPv6 ICMP failed against the I2/I3 responsive target |
| I8 | Remote server -> non-admin client | v4/v6 | Closed: ICMP 0/3 in each family; same Mac had answered 3/3 as admin, and the same-session mesh control answered 3/3 |
| I9 | Own server -> non-admin local client | v4 | Closed: ICMP 3/3 over `OUTPUT` |

I6/I7 confirm the intended difference: every client needs its local server/DNS
address, while forwarded access to another region's server is admin-only. I7 also
exercised the IPv6 pair-miss drop against a known-responsive target.

### Attribution gap on D1/D2

No temporary counters were used. D1/D2 used differential reachability, not direct
rule attribution. The tested non-admin client reached its own tunnel server
(I6), and later same-account cross-region success (C6) proved a working mesh path.
The strongest control is the same-device, same-target check below. A future pass
can add A8 counters to attribute each denial directly.

### Server-originated traffic is not ACL-governed

The chain hooks `forward` only. A server can reach any of its own clients through
`OUTPUT`, regardless of account. An SSH proxy jump through that client's own
region therefore succeeds by design, subject to SSH access and the client
listener. Server access/key custody controls this path.

A jump through another region crosses the target host's forward chain. There,
`cg_admin` tests the **destination client's account**, not the operator. Packets
from root on a regional host carry its infra source address. The remote jump is
allowed for an admin-owned target (I4/I5), denied for a non-admin target (I8).

### The ACL governs the tunnel path only

A public-hostname connection arrives on the target server's public `INPUT` path,
where OCI and host ingress rules apply. It does not test this forward-chain ACL.
Use the remote **tunnel address** for I2/I3/I7. The connection to a local server's
tunnel address is also `INPUT`, and remains outside the ACL.

### The decisive A/B, 2026-08-21

The operator used one phone, one responsive Mac target, and the same protocol,
changing only the phone's account/config:

| Phone account | Mac account | IPv4 | IPv6 |
| --- | --- | --- | --- |
| Non-admin, same account as Mac | Non-admin | Reached | Reached |
| Admin, different account from Mac | Non-admin | Denied | Denied |

The allowed probe immediately preceded the denied probe to the same target in
both families. This controlled for routing, `AllowedIPs`, app IPv6 support,
responder capability, and mesh health. It closed C6 and D6/D6b without claiming
counter attribution.

### Release checklist status

The release record marked the nft semantics and core reachability blockers
closed. Inspection confirmed the stored contract; controlled packets supported
runtime enforcement, including direct cross-account IPv6 denial. Both hosts'
parsed live hashes agreed independently of the dashboard.

This did not complete every matrix row. Same-region admin allow, same-region
admin-to-non-admin deny, non-admin-to-admin IPv6 deny, and denial between two
non-admin accounts remained open or inconclusive. The reverse IPv6 initiation in C4
also remained untested: conntrack return traffic is not an independent initiation.
The release record accepted the missing rows as confirmatory because the same
slot/pair lookup had been exercised in each family. Preserve those limitations
when using this record, and rerun the matrix for the current fleet.
