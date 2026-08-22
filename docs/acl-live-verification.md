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

**Re-run this when:** a new region joins the fleet, a host is rebuilt or its
kernel/nftables version changes, the base ruleset in `bootstrap.sh` is edited, or
the policy renderer/parser in `Backend/API/src/policy.py` changes. Part A alone
is enough for a version or ruleset change; Part B matters when the fleet's shape
changes.

Run it after the fleet deploy from one tag and a green Sync All. Part A is
read-only inspection on one host. Part B is the reachability matrix and needs
live clients.

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

Everything in A1-A7 is strictly read-only: `nft list`, `nft describe`, `ip ...
show`, `wg show`, `systemctl status`, and `journalctl` read kernel or unit state
and write nothing. A8 is the only step in this document that modifies the host.

The strictly read-only set, copy-pasteable as one block:

```sh
nft --version
uname -a
nft list tables
nft list table inet cloudgateway
nft -a list chain inet cloudgateway cg_forward
nft -j list table inet cloudgateway
nft -j list set inet cloudgateway cg_pairs4
nft -j list set inet cloudgateway cg_pairs6
nft list map inet cloudgateway cg_slot4
nft list map inet cloudgateway cg_slot6
nft list set inet cloudgateway cg_admin4
nft list set inet cloudgateway cg_infra4
nft list set inet cloudgateway cg_tunnel4
nft list ruleset | grep -n "hook forward"
nft list ruleset | grep -in mark
nft describe "ip daddr"
nft describe mark
ip rule show
ip -6 rule show
ip -br link show wg0
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
cat /etc/cloudgateway/cloudgateway.nft
systemctl status cloudgateway-api.service --no-pager
journalctl -u cloudgateway-sync-peers.service -n 50 --no-pager
```

Notes on the few that need a caveat:

* **`nft --check -f` (A4)** is documented as "check commands validity without
  actually applying the changes" - it does not commit. It is still the only
  command here that parses an add-shaped file rather than listing, so if you want
  zero doubt, skip it: A2 already round-trips the rules that are live.
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

Read-only inspection closes most of blocker 1: object kinds and types, the stored
form of the concatenated `cg_pairs` type, chain priority ordering, mark
exclusivity, slot-0 reservation, and the JSON shape the API parses. It cannot
settle verdict precedence, because "a `drop` at priority -10 beats an `accept` at
priority 0" is a runtime behavior with no static representation - only a packet
proves it.

Part B needs no server-side mutation either. Pings from client devices do not
change host state; the only mutating piece is the A8 counters, and they buy
attribution, not the result. Without them you can still run the full matrix, as
long as you substitute **differential testing** for rule attribution: from the
same device, within the same minute, probe a known-allowed peer and the denied
peer back to back. If the allowed probe replies and the cross-account probe does
not, the difference is the policy map, not client routing, a sleeping responder,
or a dead tunnel. Run that pairing for every deny case, and record both halves.

Counters remain the stronger evidence, and they are cheap to revert. Read-only
plus differential testing is the fallback if you would rather not touch the
live chain at all.

### A1. Environment

```sh
nft --version
uname -a
iptables --version      # note whether it says (nf_tables) or (legacy)
ip6tables --version
```

Record the nft version: the JSON element wrappers `src/policy.py`
`_unwrap_element_value` tolerates (`elem`/`val`) are version-dependent, and A5
is what proves this host's shape parses.

### A2. Table, object kinds, and rule text

```sh
nft list table inet cloudgateway
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

`cg_forward` at `-10` must be the lowest (earliest) priority of any forward-hook
chain on the box. iptables `filter/FORWARD` sits at priority 0 under either
backend, so `-10` evaluates first. Flag anything else negative at this hook.

### A4. The on-disk ruleset still parses

```sh
nft --check -f /etc/cloudgateway/cloudgateway.nft
```

Syntax-only. `--check` does not commit, so it will not duplicate rules.

### A5. JSON read-back shape (what the API actually parses)

```sh
nft -j list table inet cloudgateway | python3 -m json.tool | head -60
nft -j list set inet cloudgateway cg_pairs4 | python3 -m json.tool | head -30
```

`cg_pairs4` elements must appear as `{"concat": [<addr>, <mark>]}` (optionally
wrapped in `elem`/`val`). That is exactly what `_parse_pairs_set` requires; a
different shape on this nft version is a real defect, not a cosmetic one.

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

Only the `cloudgateway` table may reference marks. Any `fwmark` policy rule means
switching to a masked mark before release.

### A7. Slot 0 and populated state

```sh
nft list map inet cloudgateway cg_slot4 | grep -c 0x00000000   # expect 0
nft list map inet cloudgateway cg_slot4 | wc -l
nft list set inet cloudgateway cg_admin4
nft list set inet cloudgateway cg_infra4
```

`cg_infra4` must hold `10.0.0.1` and `10.0.1.1` (both regions, fleet-wide),
`cg_admin4` your admin account's client addresses, and no slot may be
`0x00000000` - an unknown source leaves the mark cleared, and 0 is never in
`cg_pairs`. Slot-map row count should match `policyRowCount` / Server Health.

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
read them with `nft list chain inet cloudgateway cg_forward`. Reset between cases
with a `nft reset rules inet cloudgateway cg_forward` if your nft supports it,
otherwise record deltas.

Revert by replacing each rule back to its original text from
`/root/cg_forward.before.txt`, then diff:

```sh
nft list chain inet cloudgateway cg_forward | diff /root/cg_forward.before.txt -
```

The diff must be empty before you call the boundary verified. A `wg-quick down
wg0 && wg-quick up wg0` also restores the chain from file, at the cost of every
tunnel on that region.

## Part B - the four reachability cases

### Prerequisites

* Two accounts: **Account A** (admin role) and **Account B** (non-admin). They
  must hold different `accountSlot` values.
* Four client configs: `A-sj`, `A-chi`, `B-sj`, `B-chi`.
* At least two devices online at once; run each case with both endpoints
  connected. Cases are pairwise, so a phone plus a laptop is enough if you swap
  configs between cases.
* `meshEnabled` on for both regions, and Sync All green with matching v4/v6
  hashes on both.
* Client `AllowedIPs` must cover the fleet aggregate (`10.0.0.0/16`,
  `fd42:42:42::/48`) or be full-tunnel; otherwise a failure is client routing,
  not policy.
* **Positive control first.** Confirm each responder actually answers ICMP over
  the tunnel (macOS: firewall stealth mode off; iOS answers by default) using a
  known-allowed pair before you interpret any silence as a deny.

Note each client's tunnel addresses from the dashboard before starting.

### Matrix

Run every case in **both directions** - initiate from each side. One direction is
not sufficient: `ct state established,related accept` means the return path of an
allowed flow is free, so testing only the reverse of an already-open flow proves
nothing.

| # | Case | From -> To | Expect | Host evidence |
| --- | --- | --- | --- | --- |
| 1 | Same account, same region | `A-sj` <-> `A-sj2` | reply, v4 and v6 | no drop-counter increment |
| 2 | Same account, cross region | `A-sj` <-> `A-chi` | reply, v4 and v6 | no drop-counter increment on either host |
| 3 | Cross account, both directions | `A-sj` <-> `B-sj`, and `A-sj` <-> `B-chi` | 100% loss both ways | drop counter increments on the host the packet enters |
| 4 | Admin proxy jump, cross region | `A-chi` (admin) <-> `10.0.0.1` / `fd42:42:42::1`, and `A-sj` <-> `10.0.1.1` / `fd42:42:42:1::1` | reply both ways | infra/admin accept counter increments |
| 5 | Non-admin to remote infra (control) | `B-sj` -> `10.0.1.1` | 100% loss | drop counter increments |

Case 5 is not in the checklist but is the control that proves `cg_admin` is
actually gating case 4 rather than the infra address being reachable for
everyone. It is the intentional behavior documented in "Filter design".

Commands, from the client device:

```sh
ping -c 4 10.0.1.5
ping6 -c 4 fd42:42:42:1::5        # macOS: ping -6
nc -vz -w 3 10.0.1.5 22           # optional TCP probe
```

### What case 3 proves beyond reachability

The cross-account drop is the live proof for the Part A claims that cannot be
tested by inspection: the packet is accepted by the iptables `FORWARD` rules at
priority 0 and still dies, which demonstrates (a) `cg_forward` at `-10` runs
first, (b) a `drop` verdict is terminal across tables, and (c) the
`ip daddr . meta mark != @cg_pairs` comparison evaluates the way the design
assumed. Record the drop-counter delta for this case specifically.

### Recording results

Record here: nft version,
the exact printed form of the two drop rules, the case-3 counter delta, and
confirmation that the A8 revert diff was empty.

## Results: 2026-08-21 read-only pass

Run against both regional hosts over the WireGuard tunnel (`ubuntu@10.0.0.1`,
`ubuntu@10.0.1.1`) from an admin client at `10.0.0.7`/`fd42:42:42::7`. No host
was modified: no `nft` write, no package install, no service restart.

Environment, identical on both hosts: nftables v1.0.9, kernel 6.17.0-1007-oracle
aarch64, iptables/ip6tables v1.8.10 `(nf_tables)` backend.

Blocker 1 - nft semantics: **passed**, with one item that inspection cannot
reach.

* Chain header prints `type filter hook forward priority filter - 10; policy
  accept;` on both hosts. The two `iptables-nft` forward chains (`ip filter`,
  `ip6 filter`) print `priority filter` (0), so `cg_forward` is the earliest
  forward-hook chain in the ruleset.
* All nine rules present, in the designed order, with handles 12-20 and no
  duplicates - confirming the additive `nft -f` hazard has not been triggered on
  either host.
* The mark comparison round-trips verbatim as
  `ip daddr @cg_tunnel4 ip daddr . meta mark != @cg_pairs4 drop`. `cg_pairs4/6`
  declared `typeof ip daddr . meta mark` resolve to type `["ipv4_addr","mark"]` /
  `["ipv6_addr","mark"]`.
* Object kinds and types match `bootstrap.sh`: `cg_infra*`/`cg_admin*`/`cg_tunnel*`
  sets, `cg_slot4/6` maps of `ipv4_addr : mark` / `ipv6_addr : mark`.
  `cg_tunnel4` = `10.0.0.0/16`, `cg_tunnel6` = `fd42:42:42::/48`, both
  `flags interval`.
* `cg_infra4` holds both regions' interface addresses on both hosts, confirming
  the fleet-wide pull rather than a region-local view.
* nft 1.0.9 JSON emits pairs elements as `{"concat": [<addr>, <mark>]}` and slot
  elements as `[<addr>, <mark>]`, with no `elem`/`val` wrapper - exactly the
  shapes `_parse_pairs_set` and `_parse_slot_map_elements` accept.
* `LocalPolicyManager().read_map()` run in-place against the live ruleset on both
  hosts (read-only; it only shells out to `nft -j list table`) parses cleanly and
  yields **identical hashes on both regions**, v4
  `3b0ec456...5250a91` and v6 `9382d47f...ff8d8eb`, `row_count` 9, with
  `tunnel=1 infra=2 admin=4 slots=9 pairs=9` per family. Fleet hash agreement is
  therefore confirmed at the source, not only through Server Health.
* Mark exclusivity holds: the only mark references anywhere in the ruleset are
  the four `cloudgateway` declarations and the four `cloudgateway` rules. No
  iptables `MARK` target, and `ip rule`/`ip -6 rule` show only the default
  local/main/default lookups on both hosts. The masked-mark fallback is not
  needed.
* No `cg_slot4/6` element carries mark `0x00000000` on either host; slot 0 stays
  reserved.
* `nft --check -f /etc/cloudgateway/cloudgateway.nft` passes on both hosts
  (no-commit).
* `cg_admin4` is exactly the four slot-3 addresses in `cg_slot4`, so the admin
  derivation matches the slot map.
* Not reachable by inspection: verdict precedence. `iptables -S FORWARD` shows
  `-A FORWARD -i wg0 -j ACCEPT` at priority 0 on both hosts, which is precisely
  the accept the ACL drop at -10 must beat. Only a cross-account packet proves
  it.

Blocker 2 - reachability: **3 of 4 cases at least partly closed**. Superseded in
detail by the open test matrix below, which is the authoritative status.

| Case | Result |
| --- | --- |
| 1. Same account, same region | **Not run** - no second slot-3 client online in `us-sanjose-1` |
| 2. Same account, cross region | **Passed both directions.** ICMP v4/v6 `10.0.0.7` -> `10.0.1.2`, 0% loss; SSH `10.0.1.2` -> `10.0.0.7` (operator-run). IPv6 reverse still owed |
| 3. Cross account, both directions | **One direction passed** (operator-run): SSH to `10.0.0.7` refused from a non-admin account's San Jose client and from its Chicago client - same region and through the mesh. Admin -> non-admin direction and all IPv6 coverage still owed |
| 4. Admin proxy jump, cross region | **Passed both directions.** Outbound: SSH plus ICMP v4/v6 from admin `10.0.0.7` to `10.0.1.1`/`fd42:42:42:1::1`. Inbound: ICMP v4/v6 issued from the Chicago host to `10.0.0.7`/`fd42:42:42::7`, 3/3 replies each - a new flow, not `ct` return traffic, so it exercises the `saddr @cg_infra` -> `daddr @cg_admin` accept on the San Jose host |
| 5. Non-admin to remote infra (control) | **Not run** - needs a non-admin client online |

Supporting observation, not a substitute for case 3: from the admin client,
probes to in-aggregate addresses with no `cg_pairs` entry (`10.0.0.200`,
`10.0.5.5`) returned silence with no ICMP unreachable, consistent with the
drop rule firing rather than a routing failure. Without counters this is
suggestive only.

API health on both hosts over the last 24 hours: 16 `policy_refresh_started`
and 16 `policy_refresh_completed`, no failures; `cloudgateway-sync-peers.service`
last exited 0.

Note for a future pass: the hosts have no `ping` binary. An inline Python raw
socket probe run under `sudo python3 -` works and avoids installing anything.
`/etc/cloudgateway` is mode 700, so the nft file must be read through `sudo`
even though the file itself is 644.

## Open test matrix

Authoritative status of every ACL-relevant flow. Supersedes the per-case tables
above. "Agent" = run from the tooling session over the tunnel; "operator" = run
by hand from a real client device.

Accounts referenced: **admin** (slot 3, owns `10.0.0.2`, `10.0.0.7`,
`10.0.1.2`, `10.0.1.3`), **other** = any non-admin account (slots 1, 5, 6).
San Jose is `10.0.0.0/24`, Chicago is `10.0.1.0/24`.

### Client capability constraints

These are properties of the test devices, not of the ACL, and they decide which
probe is valid for a given pair:

* **iOS cannot be an SSH target.** The OS accepts no inbound SSH at all, so a
  failed SSH *into* the phone proves nothing about policy. The phone is
  initiator-only for SSH; as a target it can only be probed with ICMP.
* **iOS answers ICMP only some of the time.** It replied 4/4 as `10.0.1.2` while
  in use and 0/3 as `10.0.0.10` later, including on the unfiltered `OUTPUT` path
  from its own region's server. Treat phone-as-ICMP-target silence as
  inconclusive unless a same-session unfiltered control also answers.
* **macOS is a reliable target** for both SSH and ICMP over the tunnel, and is
  therefore the preferred target for every deny case.

Rule of thumb: make the Mac the target and the phone the initiator.

### Client-to-client, allow paths

| ID | Flow | Family | Expected | Status | Evidence |
| --- | --- | --- | --- | --- | --- |
| C1 | admin -> admin, same region (SJ) | v4 | allow | **OPEN** | needs `10.0.0.2` online |
| C2 | admin -> admin, same region (SJ) | v6 | allow | **OPEN** | needs `10.0.0.2` online |
| C3 | admin -> admin, cross region | v4 | allow | **CLOSED** | agent ICMP `10.0.0.7`->`10.0.1.2` 4/4; operator SSH `10.0.1.2`->`10.0.0.7` |
| C4 | admin -> admin, cross region | v6 | allow | **PARTIAL** | agent ICMP `10.0.0.7`->`fd42:42:42:1::2` 4/4; reverse (phone-initiated v6) not run |
| C5 | other -> same-account other, same region | v4/v6 | allow | **CLOSED** | operator SSH `10.0.0.10` (phone) -> `10.0.0.9` (Mac) succeeds. The earlier agent ICMP 0/4 in this direction was an iOS responder artifact, confirmed by the unfiltered OUTPUT path also returning 0/3 |
| C6 | other -> same-account other, cross region (mesh) | v4/v6 | allow | **CLOSED both families** | operator from phone on `10.0.1.6` (Chicago, slot 8) reaches the Mac at `10.0.0.9` **and** `fd42:42:42::9` |

C5 and C6 matter because every allow result so far is from the admin account.
Nothing yet proves a non-admin account can reach *itself* - only that it cannot
reach someone else. A bug that denied all client-to-client traffic for
non-admins would currently look identical to a pass.

### Client-to-client, deny paths

| ID | Flow | Family | Expected | Status | Evidence |
| --- | --- | --- | --- | --- | --- |
| D1 | other -> admin, same region (SJ->SJ) | v4 | deny | **CLOSED** | operator SSH to `10.0.0.7` from a non-admin SJ client: no connection |
| D2 | other -> admin, cross region (CHI->SJ) | v4 | deny | **CLOSED** | operator SSH to `10.0.0.7` from a non-admin CHI client: no connection |
| D3 | other -> admin, same region | v6 | deny | **INCONCLUSIVE** | agent SSH `10.0.0.9` -> `fd42:42:42::7` times out and ICMP is 0/3, but nothing establishes that the device currently on `10.0.0.7` accepts SSH or answers ICMP at all. Needs a confirmed-responsive admin target |
| D4 | other -> admin, cross region | v6 | deny | **INCONCLUSIVE** | agent ICMP `10.0.0.9` -> `fd42:42:42:1::2` 0/3, but that target is an iOS device with an unreliable ICMP responder and no inbound SSH |
| D5 | admin -> other, same region | v4/v6 | deny | **OPEN** | admin client `10.0.0.7` and non-admin `10.0.0.9` are both online; needs one SSH attempt from the former to the latter, in each family |
| D6 | admin -> other, cross region | v4 | deny | **CLOSED** | operator: admin phone on `10.0.1.2` could not reach the Mac on `10.0.0.9`. Conclusive - that Mac is a proven-reachable target, accepting both SSH (C5/C6) and ICMP (3/3 from its own host) | 
| D6b | admin -> other, cross region | v6 | deny | **CLOSED** | same phone, same target, switched to the admin client `10.0.1.2`: both `10.0.0.9` and `fd42:42:42::9` fail. See the A/B note below |
| D7 | other account A -> other account B | v4/v6 | deny | **INCONCLUSIVE** | agent ICMP `10.0.0.9` (slot 8) -> `10.0.0.3`/`fd42:42:42::3` (slot 6) 0/3 both families; responder unverified |
| D8 | any client -> unallocated in-aggregate address | v4 | deny | **WEAK** | agent probes to `10.0.0.200`, `10.0.5.5`: silence, no ICMP unreachable. No counter attribution |
| D9 | any client -> unallocated in-aggregate address | v6 | deny | **OPEN** | - |

**The IPv6 drop rule has now fired.** Handle 20
(`ip6 daddr @cg_tunnel6 ip6 daddr . meta mark != @cg_pairs6 drop`) was exercised
by I7 v6: a non-admin client's ICMPv6 to the remote region's infra address was
dropped, against a target that answered 3/3 for an admin client in I3. Same rule,
same pair-miss mechanism as a client-to-client deny, so D3/D4 now confirm the
exact client-to-client shape rather than the rule's basic function.

### Client-to-infrastructure

Local server access is `INPUT`, not `FORWARD`, so it is not ACL-governed; remote
server access is `FORWARD` and is.

| ID | Flow | Family | Expected | Status | Evidence |
| --- | --- | --- | --- | --- | --- |
| I1 | admin -> own region infra (`10.0.0.1`) | v4 | allow (INPUT) | **CLOSED** | agent ICMP 3/3, plus SSH |
| I2 | admin -> remote infra (`10.0.1.1`) | v4 | allow (rule 14) | **CLOSED** | agent ICMP 3/3, plus SSH |
| I3 | admin -> remote infra | v6 | allow (rule 16) | **CLOSED** | agent ICMP 3/3 |
| I4 | remote infra -> admin client | v4 | allow (rule 13) | **CLOSED** | agent ICMP from CHI host -> `10.0.0.7` 3/3, new flow not ct return |
| I5 | remote infra -> admin client | v6 | allow (rule 15) | **CLOSED** | agent ICMP from CHI host -> `fd42:42:42::7` 3/3 |
| I6 | other -> own region infra | v4/v6 | allow (INPUT) | **CLOSED** | agent from `10.0.0.9`: SSH to `10.0.0.1` succeeds, ICMP v6 to `fd42:42:42::1` 3/3 |
| I7 | other -> remote infra | v4/v6 | deny (rule 5) | **CLOSED** | agent from `10.0.0.9`: SSH+ICMP to `10.0.1.1` and ICMP v6 to `fd42:42:42:1::1` all 100% loss, against a target proven alive by I2/I3 |

I6 and I7 together are the intended asymmetry, not a bug: a client must reach its
**own** region's server because that address is also the region's DNS resolver
(`wg_dns_address_v4/v6` equal the interface address, and `bootstrap.sh` opens
`INPUT` for port 53 on it), while no product path requires a client to reach a
**different** region's server. Cross-region server access is an operations
affordance, so it is restricted to admin-owned clients via `cg_admin`, and every
other account is dropped by rule 5 on the way out of its own region.
| I8 | remote infra -> other client | v4/v6 | deny | **CLOSED** | agent ICMP from the Chicago host -> `10.0.0.9`/`fd42:42:42::9` 0/3 both families, with a same-session mesh control (Chicago host -> `10.0.0.1`) at 3/3. Clean A/B against I4: the same physical Mac answered 3/3 from the same source as admin `10.0.0.7` and 0/3 as non-admin `10.0.0.9` - only the account changed |

### Attribution gap on D1/D2

D1 and D2 are differential results, not counter-attributed: the same target on
the same port over the same tunnel accepts the admin account (C3) and refuses the
non-admin account. That is strong, and it is the pairing this document
prescribes when counters are not in use. One alternative explanation survives:
if the non-admin clients' configs lacked `AllowedIPs` covering the fleet
aggregate, their packets would never leave the device and the result would look
identical.

**Retired 2026-08-21 by I6.** The non-admin client at `10.0.0.9` reaches its own
region's server over the tunnel (SSH and ICMPv6 both succeed), so its tunnel
demonstrably carries in-aggregate traffic, while the remote region's server is
dropped (I7) from that same client in the same session. The routing explanation
for D1/D2 is eliminated; the denials were policy.

### What D1/D2 already settled in blocker 1

D1 is a same-region flow, so it crossed the San Jose host's forward hook, where
`iptables -S FORWARD` contains `-A FORWARD -i wg0 -j ACCEPT` at priority 0. The
packet was accepted there and still never arrived. That is the live evidence
inspection could not produce:

* `cg_forward` at priority -10 evaluates before the iptables filter chain.
* A `drop` verdict is terminal across tables - the priority-0 accept cannot
  rescue the packet.
* The concatenated-set comparison `ip daddr . meta mark != @cg_pairs4`
  evaluates as designed against a real packet.

Blocker 1 has no remaining open item for IPv4. The same three properties on the
IPv6 path rest on D3/D4, which are untested.

### Server-originated traffic is not ACL-governed

| ID | Flow | Expected | Status | Evidence |
| --- | --- | --- | --- | --- |
| I9 | own region infra -> any client on that host | allow (OUTPUT) | **CLOSED** | SJ host ICMP -> `10.0.0.9` 3/3 |

`cg_forward` hooks `forward` only. A packet the regional server itself originates
toward one of its own peers is `OUTPUT`, and a packet a client sends to its own
region's server is `INPUT`; neither traverses the chain. Consequences:

* An SSH **ProxyJump through a region's own server into a client of that same
  region succeeds, by design**, for any account. It is not an ACL bypass: root on
  the WireGuard server terminates the tunnel and can reach any peer regardless of
  nftables. Treat server key custody, not the ACL, as the control there.
* A ProxyJump through the **other** region's server into a client is a different
  flow - it re-enters the target region over the mesh and is `FORWARD` - so it is
  governed, and for a non-admin target it must fail. That is I8.

Two points that are easy to invert:

* **`cg_admin` tests the destination, not the operator.** Rule 13 is
  `saddr @cg_infra -> daddr @cg_admin accept`. Once anyone is root on a regional
  host, their packets carry that host's infra address no matter who they are, so
  whether the cross-region jump lands depends entirely on whether the *target
  client's* account is admin-owned. I4 and I8 are the same probe from the same
  source into the same physical Mac: 3/3 while it held the admin address
  `10.0.0.7`, 0/3 while it held the non-admin address `10.0.0.9`.
* **DNS explains `INPUT`, not `OUTPUT`.** The region's own address doubles as its
  DNS resolver, which is why a client must be able to reach it (I6). That is the
  client-to-server direction. The server-to-client direction succeeds for a
  separate reason - it is `OUTPUT` and never enters the chain - and it succeeds
  for *any* account, not only admin ones: the San Jose host reached the non-admin
  `10.0.0.9` at 3/3.

### The ACL governs the tunnel path only

Reaching a regional host by its **public hostname** and reaching it at its
**tunnel address** are different flows, and only the second is ACL-governed.

| Path | Hook on the target host | Governed by |
| --- | --- | --- |
| Public hostname, over the internet | `INPUT` on the public interface | OCI security list |
| Tunnel address, over the mesh | `FORWARD` | `cg_forward` |

`cg_forward` hooks `forward` only, so a connection that arrives on the host's
public interface never enters the chain and no nftables policy applies to it.
When interpreting an I7 result, confirm the probe used the tunnel address
(`10.0.1.1`, `fd42:42:42:1::1`) and not a public hostname - a success over the
public path is not a policy failure and does not contradict a tunnel-path denial.

### Target capability audit, 2026-08-21

Probed from the San Jose host over the unfiltered `OUTPUT` path, so the result
reflects the device only and not policy:

| Address | Port 22 | Usable as a deny target |
| --- | --- | --- |
| `10.0.0.9` / `fd42:42:42::9` (Mac, non-admin) | **OPEN**, `SSH-2.0-OpenSSH_10.2`, both families | yes - the only one |
| `10.0.0.7` / `fd42:42:42::7` (admin) | timeout | no |
| `10.0.0.3` (slot 6) | timeout | no |

Consequences:

* A failed SSH *into* `10.0.0.7` or `10.0.0.3` is not evidence of anything - there
  is no listener to refuse it. Two probes have to be discarded on this basis: the
  operator's Chicago-client-to-`10.0.0.7` attempt, and the agent's D3 probe.
* D1 and D2 remain closed on their original evidence, which was taken while the
  Mac itself held `10.0.0.7` and was demonstrably accepting SSH.
* Every remaining deny case must **target the Mac** and be initiated from an
  admin client, in whichever family is being tested.

### Failed positive control, 2026-08-21

A batch of v6 deny probes from `10.0.0.9` was run alongside a C6 v6 positive
control to `fd42:42:42:1::6` - same account, slot 8, cross region, therefore an
allow path. **The control returned 0/3.** Every deny result in that batch is
consequently inconclusive, not a pass: the shared explanation "these targets do
not answer ICMP" fits all of them.

The agent's own v6 path was verified healthy in the same session
(`fd42:42:42::1`, own region infra, 2/2), so the failure is target-side. Most of
these endpoints are iOS devices, which refuse inbound SSH outright and answer
ICMP only intermittently.

This is the rule the document opens with, and it held: never read silence as a
denial without a same-session control proving the target answers. Prefer a macOS
target for every deny case.

### The decisive A/B, 2026-08-21

One device, one target, one protocol, both address families, with the account as
the only variable. Handshake times on the Chicago host confirm the sequence:
`10.0.1.6` at T-101s, then `10.0.1.2` at T-71s.

| Phone's client | Account | -> `10.0.0.9` (v4) | -> `fd42:42:42::9` (v6) |
| --- | --- | --- | --- |
| `10.0.1.6` | non-admin, slot 8 (same as target) | **reaches** | **reaches** |
| `10.0.1.2` | admin, slot 3 | **denied** | **denied** |

This is the strongest evidence in the document. The allow leg immediately
preceding the deny leg eliminates every non-policy explanation at once - client
routing, `AllowedIPs`, IPv6 support in the SSH app, the target's responder, mesh
health - because all of them were demonstrably working seconds earlier against
the same address. The only thing that changed was which account's slot the source
address maps to in `cg_slot`.

It closes C6 and D6b in both families, and it independently re-confirms D6 on v4.

### IPv6 coverage by composition

**Superseded 2026-08-21 by the A/B above, which tested the client-to-client v6
shape directly.** Retained because it documents why the v6 rule path was already
sound, and because D3/D4 (the non-admin -> admin direction on v6) are still not
directly tested and rest on this reasoning plus direction symmetry.

D3/D4/D6b are the only untested *shape* on IPv6 (client source and client
destination holding different slots). Every mechanical element that shape depends
on is already proven conclusively on IPv6, by flows that differ from it only in
what the destination address happens to be:

| Element of the v6 path | Proven by |
| --- | --- |
| Handle 18 assigns a nonzero mark from `cg_slot6` | I7 v6 - source `fd42:42:42::9` is a slot-8 member |
| Pair **hit** with a nonzero mark -> allow | C4 - admin to admin cross region, 4/4 |
| Pair **miss** with a nonzero mark -> drop | I7 v6 - slot-8 source, non-paired destination, 100% loss against a target proven alive by I3 |
| Pair **miss** with mark 0 -> drop | I8 v6 - infra source into `fd42:42:42::9`, 0/3, mesh control 3/3 |

The drop rule reads `ip6 daddr @cg_tunnel6 ip6 daddr . meta mark != @cg_pairs6`.
It does not care whether the destination is a client or an infra address - both
sit inside `cg_tunnel6`, and neither is in `cg_pairs6` under a foreign mark. I7
v6 is therefore the same evaluation as a cross-account client-to-client deny,
with the destination being the one detail that differs and the one detail the
rule does not test.

Remaining risk if D3/D4/D6b are never run: a defect that distinguishes a client
destination from an infra destination on IPv6 only, while IPv4 behaves correctly
in both. No such distinction exists in the ruleset. Treat these rows as
confirmatory, not load-bearing.

### Remaining rows, and why none of them block release

Both release blockers are closed. Every remaining row is a duplicate of a
mechanism already proven conclusively, in the same family, by a flow that differs
only in which endpoint plays which part.

| Row | Why it is not load-bearing |
| --- | --- |
| D3 / D4 (non-admin -> admin, v6) | The reverse direction, D6b, is closed on v6. The drop rule keys on destination-and-mark and has no notion of direction; both directions are also closed on v4 (D1/D2 one way, D6 the other). Blocked in practice because no admin-held address currently answers SSH or ICMP |
| D5 (admin -> other, same region) | Same-region deny is closed in the other direction by D1, and this direction is closed cross-region by D6/D6b. Same rule, same evaluation |
| D7 (non-admin A -> non-admin B) | The mechanism is slot inequality, which D1/D2/D6/D6b all exercise. Nothing about the rule reads the admin flag on a client-to-client path |
| C1 / C2 (admin account, same region allow) | The same-region allow path is closed by C5 for a different account. The rule does not read the admin flag here either |
| C4 reverse (v6 admin -> admin, phone-initiated) | The forward direction is closed 4/4, and `ct state established,related` makes the reverse of an allowed flow free by construction |

To close them anyway, the fleet needs one more machine that both accepts SSH and
answers ICMP while holding an admin client. Today only the Mac qualifies, and it
can hold one account at a time.

### Release checklist status

* Blocker 1, nft semantics: **closed**. Inspection covered priority, rule order,
  object kinds, the concatenated-set type, mark exclusivity, slot-0 reservation
  and the JSON shape the API parses; D1 supplied the live proof of verdict
  precedence that inspection could not.
* Blocker 2, the four reachability cases: **closed**, both address families.
  Same-account same-region (C5), same-account cross-region (C3, C6), cross-account
  both directions (D1/D2 one way, D6/D6b the other), and the admin proxy jump
  both directions cross-region (I2-I5), each with a same-session control.
* Fleet hash agreement confirmed at the source on both hosts, not only through
  Server Health.
