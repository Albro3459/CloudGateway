# WireGuard Apple Fork Plan

Goal: carry the smallest possible CloudGateway patch on top of upstream `wireguard-apple` so Xcode 26 can build `WireGuardKit` without turning `CloudGatewayKit` into a fork.

## Repositories

Local upstream reference clone:

```text
/Users/alexbrodsky/GitHub/wireguard-apple
```

CloudGateway fork:

```text
https://github.com/Albro3459/wireguard-apple
```

CloudGateway app dependency target:

```text
Frontend/Apple/iOS/CloudGateway.xcodeproj
```

## Remote Layout

In the local `wireguard-apple` clone:

* `upstream` should point to the official source: `https://git.zx2c4.com/wireguard-apple`
* `origin` should point to Alex's fork: `https://github.com/Albro3459/wireguard-apple`
* pushing to `upstream` should be disabled
* the CloudGateway patch branch should be `cloudgateway/xcode-26`

Planned commands:

```sh
git -C /Users/alexbrodsky/GitHub/wireguard-apple remote rename origin upstream
git -C /Users/alexbrodsky/GitHub/wireguard-apple remote add origin https://github.com/Albro3459/wireguard-apple
git -C /Users/alexbrodsky/GitHub/wireguard-apple remote set-url --push upstream DISABLED
git -C /Users/alexbrodsky/GitHub/wireguard-apple fetch upstream
git -C /Users/alexbrodsky/GitHub/wireguard-apple fetch origin
```

Codex should not push. Alex can push `cloudgateway/xcode-26` to `origin` after reviewing the patch.

## Branch Point

Start from the same official revision CloudGateway currently pins:

```text
ccc7472fd7d1c7c19584e6a30c45a56b8ba57790
```

Planned commands:

```sh
git -C /Users/alexbrodsky/GitHub/wireguard-apple switch --detach ccc7472fd7d1c7c19584e6a30c45a56b8ba57790
git -C /Users/alexbrodsky/GitHub/wireguard-apple switch -c cloudgateway/xcode-26
```

After Alex pushes the branch, set branch tracking to the fork:

```sh
git -C /Users/alexbrodsky/GitHub/wireguard-apple branch --set-upstream-to=origin/cloudgateway/xcode-26 cloudgateway/xcode-26
```

## Patch

Keep the patch tiny. The current Xcode 26 blocker is in:

```text
Sources/WireGuardKitC/WireGuardKitC.h
```

The header uses Darwin typedefs such as `u_int32_t`, `u_int16_t`, and `u_char` before importing the system header that defines them. The intended patch is to add the missing system include before the WireGuard headers and copied `ctl_info` / `sockaddr_ctl` declarations:

```c
#include <sys/types.h>
```

Do not refactor WireGuardKit, rename package products, or move CloudGateway code into the fork.

Current local fork patch commit:

```text
2cc1e15d40e7b99f2b84ba6617393a1c76da11ee
```

This commit has been pushed to Alex's fork and is now the CloudGateway SwiftPM pin.

## CloudGateway Update

The iOS Xcode project package reference was updated from:

```text
https://git.zx2c4.com/wireguard-apple
```

to:

```text
https://github.com/Albro3459/wireguard-apple
```

It is pinned to the patched commit on `cloudgateway/xcode-26`.

Pending patched revision:

```text
2cc1e15d40e7b99f2b84ba6617393a1c76da11ee
```

## Verification

From the CloudGateway repo:

```sh
xcodebuild -list -project Frontend/Apple/iOS/CloudGateway.xcodeproj
xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj -scheme CloudGateway -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
```

Expected result before Apple signing is fully fixed:

* package resolution uses `https://github.com/Albro3459/wireguard-apple`
* `WireGuardKitC` builds under Xcode 26
* `WireGuardGoBridgeiOS` builds `libwg-go.a`
* unsigned build proceeds past the previous WireGuardKit failure

The final signed real-device build may still require Xcode-managed provisioning profiles for App Groups, Data Protection, and Network Extension.
