# Shorter CLI lists and easier VPN selection

Status: planned, implementation has not started

## Goal

Make configs easy to find and select without copying an account/region/client
identifier. Keep region grouping, show the client UUID, and number rows from 1
inside each region. Add a detailed list matching the iOS details card.
Also preserve tunnel details during operation lookup, reject unknown region
filters, and support the usual version command aliases.

This plan follows the latest requested syntax. A bare number is insufficient
because each region starts at 1.

## Commands

```text
cloudgateway list
cloudgateway ls
cloudgateway list --long
cloudgateway list -l
cloudgateway ls -l
cloudgateway ls --long
cloudgateway ls -l --json
cloudgateway list --region sanjose

cloudgateway up
cloudgateway up <client-uuid>
cloudgateway up <region> <index>
cloudgateway down
cloudgateway down <client-uuid>
cloudgateway down <region> <index>

cloudgateway status --operation <operation-id>
cloudgateway version
cloudgateway --version
cloudgateway -v
```

- `ls` is an alias of `list`, including help, errors, filtering, refresh, timeout,
  and JSON support. Structured records use the canonical command name `list`
- `-l` and `--long` mean the same thing and apply only to `list`/`ls`
- Keep `--region` and `--refresh`, including their combinations with long and JSON
- Bare `up` keeps using the signed-in account's last selection
- Bare `down` keeps stopping CloudGateway while signed out or offline
- A supplied selector always identifies one config. Never fall back to the last
  selection or an unscoped stop when resolution fails
- Replace the compound-ID positional syntax in public CLI help and parsing.
  Compound identifiers remain internal and in existing JSON fields
- `version`, `--version`, and `-v` print the same app version/build, support
  `--json`, and complete locally without starting or connecting to the controller

## List output

Normal output keeps owner email beside the name for admin inventories. It shows
only the client UUID in the ID column. Move the tunnel IP into long output.
Keep connection, selection, and unavailable-state labels. Installation labels
stay removed.

Example layout, using illustrative metadata:

```text
California (us-sanjose-1)
  1  Desktop (desktop@example.com)  78ab8633-ae25-4287-885f-57bbbf6e7f63
  2  Laptop (laptop@example.com)    4830b738-2823-4888-bf37-2918ae356ad5

Chicago (us-chicago-1)
  1  Mac (owner@example.com)        d1482e58-5202-4771-82ae-bb34a313c537  connected, selected
  2  Phone (owner@example.com)      c3553af9-7c1b-49a9-a791-dcaa14288080

Tunnel observation: current at 2026-10-23T15:29:16Z
Inventory: current
```

Long output uses the same region groups, row order, indices, and state labels,
with one details block per config:

```text
Chicago (us-chicago-1)
  1  Mac  connected, selected
     VPN id:         d1482e58-5202-4771-82ae-bb34a313c537
     Tunnel IP:      10.0.0.2
     Connection URL: wg.us-chicago-1.example.com
     Owner email:    owner@example.com
```

Match the iOS details semantics: VPN id is the client UUID, Tunnel IP removes
the CIDR suffix, Connection URL prefers the server hostname and falls back to
server IPv4, and missing values display `Unavailable` or `Unknown` for email.
Do not repeat region inside every details block. Retain the existing observation
and inventory/offline footer in both layouts.

## Region and index resolution

- Accept exact region IDs, case-insensitive display names, and a city alias from
  the region ID: `us-sanjose-1` → `sanjose`, `us-chicago-1` → `chicago`
- Display names containing spaces require shell quotes. The San Jose display
  name currently shown is `California`, so support both `California` and `sanjose`
- Match a full region ID first. Otherwise collect exact normalized display-name
  and city-alias matches. Reject zero or multiple matches with useful candidates
- Do not introduce substring or fuzzy matching. Alias collisions require the
  full region ID
- Reuse this resolver for `list --region` and positional `up`/`down` regions
- An unmatched region filter is an error, with exit code 2 and structured error
  code `usage` in JSON. Include the supplied value and available region IDs/names
  in the message or suggestion. Never report success with an empty list for an
  unmatched filter, including `ls`, `--long`, `--json`, and `--refresh` combinations
- Resolve against the full account-filtered inventory before applying the region
  or eligibility filter. The current IPC snapshot has no independent region
  catalog, so the error should say the region is unavailable in this account's
  current inventory, rather than claiming it does not exist globally. Offline,
  candidates come from the authorized saved inventory
- An unfiltered empty inventory still succeeds. If a future snapshot includes
  known regions with no clients, a recognized empty region may also succeed.
  This change does not add a region-catalog fetch
- Accept positive decimal indices starting at 1. Reject zero, negative values,
  non-integers, overflow, extra operands, and out-of-range indices
- Share one ordering implementation between list rendering and selector
  resolution. Preserve the current region order and owner/name/identifier row
  order. Use explicit deterministic comparisons, independent of terminal locale
- Assign indices before filtering eligible choices. An unavailable row still
  occupies its index, and selection-error choices retain the full list's indices
- Indices describe the current authorized inventory, not permanent identities.
  Refresh, renaming, adding/removing clients, and offline fallback can change
  them. Document that users should rerun `ls` after inventory changes and use a
  UUID in scripts
- Resolve a selector once from a settled account-filtered controller snapshot,
  then reserve the exact compound identifier. Never reinterpret its number after
  refresh, retry, or operation acceptance. Account changes invalidate the target
- Match UUIDs case-insensitively and require exactly one authorized match. The
  backend generates UUIDs, but a duplicate must produce an ambiguity error

## Controller metadata and stop behavior

The controller remains the source of authorized inventory and tunnel state.
The CLI owns formatting, region aliases, indices, and resolving those selectors.
The controller continues using account/region/client identifiers for profiles,
secrets, selections, and mutation validation. The account prefix represents the
signed-in account's namespace, including admin access, and is not an owner ID.

Existing metadata already provides name, owner email, tunnel IP, region, and the
compound identifier. Add explicit client UUID and optional connection endpoint
metadata to the domain snapshot and IPC state. Populate them from cloud client
fields and saved snapshot fields, with the same hostname/IP fallback as iOS.
Keep text bounds, control-character handling, account filtering, and reply-size
limits enforced. Check the maximum inventory payload after adding metadata.

Saved snapshots already contain endpoint and IP fields. They do not contain
owner email. For this change, show `Unknown` offline rather than expanding the
persistent cache or substituting the signed-in admin's email. No secret/config
fetch, DNS lookup, or new network request is needed for details.

Targeted `down` needs controller support. The existing `turnOff` rejects an
identifier and stops all CloudGateway profiles. Add a current-build scoped-stop
request and pass the exact target through reservation, confirmation, and command
execution. Keep the compatible, unscoped stop contract intact for bare `down`,
the menu, and older frontends.

- Scoped stop requires an authorized account snapshot to resolve the target,
  including existing authorized offline access
- Check the target again in the controller at execution, across any asynchronous
  observation. A different running config must remain running
- An already disconnected target succeeds without stopping another config
- Unknown or ambiguous targets fail before mutation acceptance
- Preserve confirmed-stop semantics, operation lookup, cancellation, deadlines,
  account fencing, and existing command/drain/update admission rules
- Signed-out users retain bare `down`; targeted selectors require sign-in

## Operation status keeps tunnel details

Reported behavior: ordinary `status` includes tunnel `configId` and `observedAt`,
but `status --operation <id>` reports `connected` with both fields null.

The current operation lookup uses `controlReply`, which includes only the coarse
`CloudGatewayMacControllerStatus`. The CLI constructs the tunnel from that
reduced status instead of the account-filtered snapshot used by ordinary
`status`. The missing fields are lost before rendering.

- For a matching current build, include account-filtered observation details in
  the operation reply and construct the tunnel through the same mapping as
  ordinary `status`. Prefer one snapshot for its state, ID, timestamp, and
  freshness, avoiding a mixture of observations from separate reads
- Retain the requested operation ID and its own result. Looking up an older or
  unknown operation must never substitute the latest operation
- The top-level tunnel describes the currently observed VPN. The operation's
  `configId` describes that operation's target, which may be a different config
- Preserve meaningful nulls when disconnected, when no observation exists, or
  when an account is not entitled to see the active config. Keep stale timestamps
  and stale observation labels consistent with ordinary status
- Retain account filtering for profiles and operation outcomes after logout or
  account changes. Do not expose account metadata through older/different-build
  compatible control replies. Their coarse status fallback remains supported
- Apply the fix to JSON and human output, including failure data for unknown,
  expired, or failed operations. Keep existing operation exit codes
- Check reply validation and compatible decoding when extending the reply. Do
  not relax the compatible control protocol's build or account boundaries

## Version aliases

The parser currently recognizes only the root `--version` flag. Add `-v` as its
short alias and `version` as a command that reaches the same local version action.

- All three forms print `CloudGateway <version> (<build>)` and exit 0
- Their `--json` forms return the existing version record/data shape unchanged
- Add `version` to root help and support `help version` and `version --help`
- Reject extra positional arguments and unrelated options with normal usage
  errors. Root version flags remain invalid on unrelated commands, such as
  `list --version` and `status -v`
- Verify these paths without installed-controller readiness, sign-in, or network
  access. They should behave like the existing local `--version` path

## JSON contract

Support `--json` for all aliases and selector forms. Keep the existing versioned
record envelope, error codes, accepted/result sequence, explicit nulls, and
canonical command names.

Add `clientId`, region-local `index`, and nullable `connectionUrl` to inventory
config records. Keep existing `configId` as the compound machine identifier, and
retain existing `owner`, `internalIp`, state, freshness, and cache fields without
renaming or changing their meaning. Add the same new fields wherever inventory
appears, including refresh results and selection-error choices.

JSON always returns the complete inventory metadata. `--long` affects human
formatting, so `ls --json` and `ls -l --json` have the same data shape. Document
the additive fields in schema version 1 and update exact JSON fixtures. Do not
change mutation/status `configId` fields as part of this display change.

## Implementation sequence

1. Extend domain/IPC metadata for UUID and endpoint. Update construction,
   sanitization, validation, offline mapping, and relevant fixtures. Confirm
   compatibility rules and payload bounds
2. Extract shared CLI inventory ordering and selector resolution. Implement
   region IDs, names, city aliases, UUID lookup, and indices with clear errors
3. Add the scoped controller stop path. Preserve unscoped compatible stop and
   verify that targeting a disconnected/different config cannot stop the active
   one
4. Add `ls`, `-l`/`--long`, selector operands for `up`/`down`, canonical help/error
   behavior, and session dispatch. Reject unmatched region filters across all
   list paths. Resolve only settled snapshots within the existing single caller
   deadline
5. Render numbered short/long lists and additive JSON metadata. Update CLI help,
   examples, the macOS README, and the original CLI plan's command contract
6. Preserve account-filtered tunnel details in current-build operation status,
   keeping compatible coarse replies and operation lookup semantics intact
7. Add local `version` and `-v` aliases, help, and unchanged JSON version output
8. Complete unsigned validation and inspect the final diff against this plan

## Validation

Use focused coverage for parser aliases/options/help, UUID and region matching,
ambiguous aliases/UUIDs, per-region numbering, filters, unavailable rows, index
bounds, and identical ordering in short/long/JSON/selection paths. Cover offline
missing metadata, CIDR removal, endpoint fallback, terminal-text sanitization,
and unchanged JSON fields.

Replace the existing test that expects success for `list --region eu-west-1`
when it is absent from the fixture inventory. Verify unmatched-region failures
in text/JSON, both command aliases, refresh paths, and empty/offline inventories.
Ensure valid region IDs, names, and aliases still resolve, and filtering never
silently drops an unmatched value.

For operation lookup, compare tunnel details with ordinary status against the
same fixed observation. Cover connected/stale/unavailable observations, a
different active config from the operation target, unknown/failed operations,
signed-out/account changes, and compatible different-build fallback. Assert
actual `configId` and `observedAt` values, not just the tunnel phase.

Verify `version`, `--version`, and `-v` produce identical text and JSON and make
zero controller connection calls. Cover version help, extra operands, and invalid
flag placement. Add all three forms to packaged CLI smoke checks.

Exercise account changes, inventory changes after resolution, targeted stop
against another active config, already stopped targets, signed-out bare stop,
compatible older-client stop, accepted-operation tracking, and snapshot deadlines.
Keep the stable UUID target through asynchronous work.

Run `./scripts/test.sh macos` with unsigned builds only. Update packaged CLI
smoke checks for aliases/help/parser behavior. For this planning change, manual
review and `git diff --check` are sufficient. No implementation or test run is
included in this checkpoint.

## Code references

- [iOS details card](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/iOS/CloudGateway/ContentView.swift:1494)
- [Domain client metadata](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacControllerContracts.swift:90)
- [Online and offline metadata mapping](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:621)
- [Saved config metadata](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/CloudGatewayConfigModels.swift:145)
- [IPC state mapping and validation](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerState.swift)
- [IPC request validation and compatible control](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerContracts.swift)
- [CLI parser and help](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIArguments.swift)
- [Inventory ordering and JSON records](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIRecords.swift)
- [Human output](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIRenderer.swift)
- [CLI snapshot reads](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLISession.swift)
- [CLI mutation flow](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIMutations.swift)
- [Profile stop sequencing](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacConfigCoordinator.swift:247)
