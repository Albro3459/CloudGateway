# Linux CLI parity contract

Baseline: implemented macOS CLI at `32dae6c`, inspected 2026-10-26.
This specifies Linux implementation requirements, not currently available Linux
commands. [Research and platform decisions](linux-cli-research.md) explain the
runtime, version, update, and diagnostic substitutions.

## Commands and parsing

```text
cloudgateway
cloudgateway help [command...]
cloudgateway -h|--help
cloudgateway version
cloudgateway -v|--version
cloudgateway auth login [--no-qr]
cloudgateway auth status
cloudgateway auth logout
cloudgateway mode
cloudgateway mode status
cloudgateway mode full
cloudgateway mode mesh
cloudgateway list|ls [--region <region>] [--refresh] [-l|--long]
cloudgateway status [--operation <operation-uuid>]
cloudgateway up [<client-uuid> | <region> <index>]
cloudgateway down [<client-uuid> | <region> <index>]
cloudgateway add <region> <name>
cloudgateway remove <client-uuid>|<region> <index> --yes
cloudgateway update [--allow-disconnect]
cloudgateway refresh
cloudgateway doctor
```

Every topic accepts `-h`/`--help`, `--json`, `--non-interactive`, and
`--timeout <seconds>`. There is no public `login` alias, `regions` command,
`--mode`, `--name`, `--config`, `--autostart`, or daemon-management command.

* Root without a command shows help. Help/version finish without initializing
  auth, services, or networking. Help still validates operands/options, but
  `remove --help` requires neither consent nor a selector.
* Commands/modes are case-sensitive. `ls` canonicalizes to `list`; bare `mode`
  canonicalizes to `mode status`. Version flags work only without a command.
  Help takes precedence over a valid version flag.
* Options can precede, interrupt, or follow command words. Value options accept
  `--option=value`. Repeated boolean flags work; repeated value options fail.
  Boolean values such as `--yes=false` fail. No `--` terminator, combined short
  flags, abbreviations, or additional aliases are accepted.
* Timeout is finite, positive, at most 86400 seconds, and may be fractional.
  A value beginning with `-` fails as missing. Default is 30 seconds, or 300 for
  update. Login startup is capped separately at 30 seconds, then follows the
  server challenge expiry. An explicit timeout bounds the entire invocation
  and can only shorten approval waiting.
* Add requires both positional operands. Trim the name, accept 1–80 Unicode
  scalars and at most 320 UTF-8 bytes, and reject control/format characters.
  Region input must be nonblank, at most 512 UTF-8 bytes, contain no `/`, and
  survive the existing sanitizer unchanged.

Normative source: [arguments and topics](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIArguments.swift),
[execution](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLI.swift),
and [parser cases](../Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCLITests/CloudGatewayMacCLIParserTests.swift).

## Selectors and inventory

Accept a client UUID or a region plus positive ASCII-decimal index. Leading
zeroes work. Reject compound config IDs as public selectors, signed numbers,
fractions, Unicode digits, and overflow. Exact case-sensitive region IDs win;
otherwise match trimmed lowercase display names or city aliases formed by
removing the ID's first/last hyphen-separated components. Quote names with spaces.

Unknown/ambiguous regions or out-of-range indices produce `usage` (2).
Missing/ambiguous UUIDs produce `config_unavailable` (5). Resolve once from
settled inventory and retain the exact target through account/inventory changes.
Targeted down never falls back to global down.

Sort regions by display order, name, then ID, and clients by owner label, name,
then compound identifier. Indices restart at 1 per region. Ineligible rows retain
their index, including when a choices response contains only eligible rows.
Indices can change after refresh or offline fallback. Use UUIDs in scripts.
Do not implement the older last-displayed-number mapping.

`clientId` is the cloud UUID. `configId` is `signedInUID/regionId/clientId`,
including when an admin can see another owner's client. Online inventory lists
authorized cloud records, including configless/inactive rows. Offline inventory
contains only the current account's authorized saved configurations. Owner
metadata may be absent offline. Cached `installed:true` describes retained
installation metadata, not a fresh operating-system observation.

Source: [selectors/order](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLISelectors.swift),
[account cache](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacAccountCache.swift),
and [controller mapping](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift).

## Behavioral requirements

* Auth uses browser device approval. Print URL/code promptly, without
  automatically opening a browser. Suitable terminals offer copy/open/cancel.
  JSON/redirected/noninteractive output suppress shortcuts and decoration.
  `NO_COLOR` disables style/QR but retains interactive shortcuts. Cancellation
  targets that attempt; frontend disappearance leaves polling bounded by expiry.
  `auth status` can succeed while signed out, denied, or restoring.
* Logout ends the local session and hides account data, retaining the running
  VPN, saved profiles/secrets/cache. It does not request cloud deletion.
* Full is the account-local default. A missing legacy preference defaults to
  Full; a malformed explicit preference remains unavailable. Mesh clears VPN
  DNS/search domains and applies exactly `10.0.0.0/16` and `fd42:42:42::/48`.
  Changing mode while disconnected saves the preference. While connected it
  restarts the same client. Selected and applied modes can differ during failure
  or transition. Unknown pending applied mode makes repeated up busy.
* Bare up uses only this account's last saved selection. It can restore/install
  an eligible retained config. Success is start submission or already active,
  not a connectivity test. Bare down works signed out and succeeds only after
  confirmed stop or an already-stopped observation. Targeted down needs current
  account authorization, including permitted offline authorization.
* Normal list waits for settled access/inventory. Unavailable inventory takes
  precedence over resolving the region filter. `list --refresh` and refresh
  await their own online result without reconnecting. Failed refresh may return
  stale inventory. `--long` changes human output only.
* Add uses enabled creation regions and verified capacity, including empty
  regions. It leaves the VPN and selection unchanged. Result creation data
  carries requested name/region, not a new UUID. Inventory failure after verified
  success produces a warning. Ordinary uncertain creation failures map to
  `operation_unknown`; actual 401/403 invalidates account access.
* Remove always requires an explicit selector and `--yes`, checked before IPC.
  There is no deletion prompt or inferred last selection. Fresh authorization
  is required. Disabled/configless/uninstalled cloud clients are valid targets.
  Active/connecting/reasserting/disconnecting or unobservable targets are not
  safe to remove. `client_active` is exit 4. Consent never authorizes a stop.
  Verified cloud deletion with cleanup/refresh warning still exits 0. Retain
  secrets under the existing policy. Recover uncertain removal by operation ID,
  online refresh, and the original UUID, never by replaying a changed index.
* Status can succeed with stale/unavailable observation and a failed latest
  operation. Explicit operation lookup returns the operation's mapped failure
  together with current observed state, which can differ from its original target.
  The observation read is bounded at five seconds within the caller deadline.
* Update activates the already-installed runtime. Matching runtime is a no-op;
  active replacement needs `--allow-disconnect`. Capture the same config/mode,
  stop, activate, check readiness, and request authorized reconnect. Initially
  off stays off. Use Linux platform wording and the activation design in research.
* Doctor reads supported setup/permission/auth/network evidence without login,
  refresh, install, repair, or tunnel changes. Optional unknown/warning succeeds.
  Cancellation/deadline takes precedence, then first required setup failure,
  then required online failure. Setup probes can supply a specific mapped code.

Sources: [session reads](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLISession.swift),
[mutations](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIMutations.swift),
[login](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLILogin.swift),
[mode transform](../Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/CloudGatewayRoutingMode.swift),
[update](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIUpdate.swift),
and [doctor](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIDoctor.swift).

## JSON schema 1

Stdout is compact NDJSON with recursively sorted object keys, unescaped `/`,
UTC ISO-8601 timestamps, lowercase operation UUIDs, and a newline per record.
Data objects have no enum-case wrapper. Preserve arrays as `[]`, not null.
In the field inventory below, `?` means omitted when absent. `|null` means the
field is present even without a value. Other fields are required.

```text
Envelope:
  schemaVersion:integer = 1
  type:"accepted"|"result"|"error"|"login_required"
  command:string|null, operationId:string|null
  data:object|null, error:Failure|null
Failure:
  code:string, message:string, suggestion:string|null

Version:
  version:string, build:string
Auth:
  state:"signed_out"|"retained"|"restoring"|"online"|"offline"|"denied"
  accountId:string|null, retainedSession:boolean
  access:"unverified"|"checking"|"online"|"offline"|"denied"|"unreachable"
  credentials:"available"|"unknown", loginPending:boolean
Mode:
  selectedMode:"full"|"mesh"|null, activeMode:"full"|"mesh"|null
  tunnelState:TunnelState, observation:Observation, observedAt:timestamp|null
Tunnel:
  state:TunnelState, observation:Observation
  observedAt:timestamp|null, configId:string|null
TunnelState = "disconnected"|"connecting"|"connected"|"disconnecting"|"unknown"
Observation = "current"|"stale"|"unavailable"
Operation:
  id:string, state:"accepted"|"running"|"completed"|"failed"|"unknown"
  result:"start_requested"|"already_active"|"completed"|"failed"|"unknown"|"expired"|null
  configId:string|null
  warning:"selection_not_saved"|"inventory_not_refreshed"|
          "local_cleanup_incomplete"|"reconnect_suppression_not_persisted"|null
  error:Failure|null
Status:
  tunnel:Tunnel, operation:Operation|null, mode:Mode|null, auth:Auth|null
  update?:Update

Inventory:
  accountId:string, scope:"authorized"|"installed"
  freshness:"current"|"cached"|"stale", profileObservation:Observation
  profilesObservedAt:timestamp|null, regionId:string|null
  regions:[{regionId:string, name:string, configs:[Config]}]
Config:
  configId:string, clientId:string, index:integer
  connectionUrl:string|null, name:string, owner:string|null, internalIp:string|null
  cloudState:"creating"|"active"|"failed"|"removed"
  eligibility:"eligible"|"inactive"|"config_missing"|"region_unavailable"
  installed:boolean, source:"cloud"|"cache", selected:boolean
  tunnel:"invalid"|"disconnected"|"connecting"|"connected"|"reasserting"|"disconnecting"|null
  readAt:timestamp, updatedAt:timestamp|null
Mutation:
  command:"up"|"down"|"logout"|"update"|"add"|"remove"|"mode"
  operation:Operation, tunnel:Tunnel, choices:Inventory|null
  update?:Update, creation?:{regionId:string,name:string}
  requestedMode?:"full"|"mesh", mode?:Mode
Refresh:
  result:"refreshed"|"unavailable"|"denied"|"skipped"|"superseded"|"sign_in_required"|"timed_out"
  inventory:Inventory|null
Update:
  id:string
  phase:"prepared"|"stopping"|"activating"|"approval_required"|"restart_required"|
        "checking_readiness"|"reconnecting"|"completed"|"failed"|"superseded"
  target:{version:string,build:string,codeHash:string}
  configId:string|null, reconnect:boolean, error:Failure|null, warning:Failure|null

Doctor:
  checks:[{name:string,status:"pass"|"warning"|"fail"|"unknown",
           evidence:string,suggestion:string|null,failureCode?:string}]
  timedOut:boolean
Help:
  topic:string|null, usage:string, summary:string
  commands:[{name:string,arguments:string|null,summary:string}]
  options:[{flags:[string],value:string|null,summary:string}]
  commonOptions:[same option shape], notes:[string], examples:[string]
Login challenge:
  verificationURL:string, userCode:string, expiresIn:integer
```

Reads usually emit one record. Mutations usually emit `accepted` then a final
record. Login can emit `login_required` before its auth result. Accepted records
have null `data` and `error`. Ordinary status leaves envelope `operationId:null`
even with a retained `data.operation`. Explicit lookup uses the requested ID.
Error records can carry typed data, including stale refresh inventory. Account
redaction retains coarse operation state but nulls account-bound result,
configId, warning, and error. Internal `isLong` and operation `failure` never
serialize. Do not blanket-apply Go `omitempty` to optional fields.

Normative source: [public records](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIRecords.swift),
plus the login/update/doctor types linked above. Version fields remain strings;
Linux sets both to its release version, without a separate build number.
Platform-specific messages/checks differ meaningfully, while shapes, shared
enum values, command names, and exit mappings remain compatible.

## Operation ownership and exits

Reserve an operation, flush acceptance successfully, then confirm effects.
An output failure leaves work unconfirmed. After confirmation, timeout,
interruption, broken pipe, or SSH loss detaches observation and must not resend
the operation. Suppress SIGPIPE termination and return exit 1 on output failure.

Unconfirmed reservations last 30 seconds. Non-stop receipts last 600 seconds
from acceptance and are capped at 64. Ordinary terminal results last 600 seconds
from completion in memory, unless replaced or the controller exits. Creation
has a separate result slot. Managed update has durable recovery. These clocks
are independent. A receipt can survive restart without its result and yield
unknown without redispatch. Expiry does not prove whether a cloud effect occurred.
Down remains usable during pending add, with independent result/operation IDs.

```text
0   success
1   internal_error, not_implemented, invalid_response
2   usage
3   sign_in_required, access_denied
4   setup_required, credentials_unavailable, incompatible_version,
    untrusted_build, installation_required, controller_unavailable,
    controller_rejected, extension_mismatch, extension_replacement_blocked,
    initial_setup_required, approval_required, restart_required,
    invalid_bundle, checking_readiness, disconnect_required, client_active
5   config_unavailable, selection_unavailable
6   network_unavailable, refresh_skipped, storage_unavailable, observation_unavailable
7   busy, refresh_superseded
8   timeout, stop_timed_out
9   vpn_failed, command_failed, activation_failed, readiness_failed
10  operation_unknown, operation_expired, update_superseded, reconnect_suppressed
130 interrupted
```

Keep the existing taxonomy, including Apple-specific values that Linux normally
does not emit. Adapt setup/recovery wording to Linux. Do not expose raw process,
HTTP, or resolver errors. Human `network_unavailable` is exactly
`Waiting for network… Try again soon.` JSON retains its structured details.

Source: [error lookup](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIError.swift),
[renderer](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIRenderer.swift),
and [request receipts](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerRequests.swift).

## Compatibility verification

Create language-neutral fixtures from existing literal macOS expectations,
using synthetic state, fixed timestamps, and fixed UUIDs. Each case supplies
argv/terminal environment, controller replies, expected stdout/stderr/exit,
and reserve/flush/confirm/detach actions. Preserve JSON semantics and exact
stable bytes, including Unicode sanitization/counting/order, nulls versus
omissions, empty arrays, HTML escaping, date precision, and newline behavior.
Go's default JSON encoding does not automatically match Swift's serializer.

Cover every command/flag/alias, malformed argv, account states, offline/denied
reads, region collisions, numbering, redaction, add/remove unknown outcomes,
acceptance write failure, update consent, and selected versus observed mode.
Allow only the explicit Linux text/check/version substitutions described here.
Do not serialize macOS-only approval events to simulate a Linux update.

Starting fixtures:

* [JSON output](../Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCLITests/CloudGatewayMacCLIOutputTests.swift)
* [Command records](../Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCLITests/CloudGatewayMacCLICommandTests.swift)
* [Selection and list layout](../Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCLITests/CloudGatewayMacCLISelectorTests.swift)
* [Mode behavior](../Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCLITests/CloudGatewayMacCLIModeTests.swift)
* [Removal and redaction](../Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCLITests/CloudGatewayMacCLIRemoveTests.swift)

Two source/document discrepancies are explicit: code uses a 60-second stale
threshold, and generic macOS commands lack login's dedicated signal handler,
so a final interrupted JSON record is not guaranteed there. Linux should
install a consistent signal-to-detach handler and emit a safe interrupted result
when stdout remains available. That is an intentional lifecycle improvement,
with command, schema, and exit compatibility retained.
