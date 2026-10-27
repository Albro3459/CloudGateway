# Linux client

`cloudgateway` CLI and `cloudgatewayd` root daemon for Ubuntu Server 24.04 and
26.04 LTS, amd64 and arm64. The [parity contract](../../docs/linux-cli-parity.md)
defines the public behavior and the [research](../../docs/linux-cli-research.md)
explains the design. Progress lives in the [implementation plan](../../TODO/linux-cli.md).

Status: implemented and tested host-free on macOS. Nothing has run on a Linux
host yet, no release exists, and no distro support is claimed. The VM matrix
in the research doc must pass first.

## Layout

| Path | Owns |
| --- | --- |
| `cmd/cloudgateway` | CLI entry point |
| `cmd/cloudgatewayd` | Daemon entry point and `cleanup` for uninstall |
| `cmd/cloudgateway-release` | Release builds with archive hashes stamped into `install.sh` |
| `install/` | `install.sh` and the systemd unit, embedded into releases |
| `internal/cli` | Parser, help, JSON schema 1 records, rendering, session flows, login terminal, doctor runner |
| `internal/jsonout` | JSON writer that matches Swift's `JSONEncoder` bytes |
| `internal/ipc` | Length-framed CLI/daemon protocol and doctor probe catalog |
| `internal/daemon` | Controller, operation registry, request validation, peer-checked socket server |
| `internal/store` | Atomic state files, credentials, session generations, account caches, secrets, intent |
| `internal/cloud` | Device login, Firebase Auth, Firestore reads, regional API calls |
| `internal/wgconfig` | Allowlisted config parser, Mesh transform, hashes, `wg setconf` input |
| `internal/network` | Owned interface, routes, rules, nftables, resolved DNS, observation, repair |
| `internal/release` | Release asset names, code hash, installed release identity |
| `test-vm/` | Terraform for a throwaway OCI VM that installs a published release |

`internal/network` never imports HTTP or Firebase code. Its `networktest`
package simulates an Ubuntu host for tests, so the real network code runs in
daemon tests without root.

## Build and test

Go is pinned by `go.mod` (`toolchain go1.27.3`). There are no third-party
modules.

```sh
./scripts/test.sh linux
```

This runs `gofmt`, `go vet` for the host and both Linux architectures, the
race-enabled tests, the installer syntax check, and static Linux builds. Route,
DNS, and service behavior still needs real VMs.

## Runtime layout

| Path | Contents |
| --- | --- |
| `/opt/cloudgateway/releases/<version>` | Release files, previous release kept |
| `/opt/cloudgateway/current` | Atomic link to the active release |
| `/usr/local/bin/cloudgateway` | CLI link |
| `/etc/cloudgateway/daemon.json` | Enrolled operator UID, root-owned |
| `/var/lib/cloudgateway` | Daemon state, `0700`, files `0600` |
| `/run/cloudgateway/cloudgatewayd.sock` | Socket for root and the operator, checked with `SO_PEERCRED` |

Owned network identities are fixed so the daemon can remove them without its
journal: interface `cloudgateway` (created as `cloudgw-pending`) with alias
`cloudgatewayd`, table and fwmark `52820`, rule priorities `30200`-`30220`,
routing protocol `206`, and nftables table `inet cloudgateway_client`.

Docker containers skip the systemd-resolved stub. Docker hands them the servers
in `/run/systemd/resolve/resolv.conf`, without resolved's per-link routing, so
in Full their DNS can go to the physical network's servers instead of the VPN.
The [research](../../docs/linux-cli-research.md#validation-and-remaining-engineering-gates)
lists other known limits.

## Releases

1. Copy `Secrets/example.release.env` to `Secrets/release.env` and fill in the
   public Firebase web configuration.
2. Commit, then run `go run ./cmd/cloudgateway-release build -version 1.0.0 -out <dir>`.
   It builds with the `go.mod` toolchain and writes both archives and an
   `install.sh` stamped with the version, storage version, and each archive's
   size and SHA-256. It prints the `gh release` command without running it.
   Builds ignore `go env -w` settings, so set `GOPROXY` and similar as
   environment variables. `-allow-dirty` builds uncommitted changes for
   testing and prints no `gh release` command. Don't publish that build.

Tags are `linux-v<version>`. JSON `version` and `build` both carry the release
version, and `codeHash` is the SHA-256 of the daemon executable.

Each release must read the previous release's network journal and state. A
daemon that can't parse the journal removes owned resources by fixed identity,
so an update that drops support for an older journal disconnects the VPN.
Bump `storageVersion` for any state format change so the installer refuses a
downgrade across it.

For a test VM, publish a pre-release and use [test-vm](test-vm/README.md), or
copy the `linux-v<version>` folder to a machine and run
`sudo bash install.sh --from <folder> --operator <user>`. Each `install.sh`
installs only the archives it was built with, so use a release's own
`install.sh` to install it. Downloads need curl. Every installer run
enables `cloudgatewayd.service`, including on update, so it also re-enables a
service an admin disabled. `--uninstall` keeps `/var/lib/cloudgateway` unless
`--purge` is added.
