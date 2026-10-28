# CloudGateway for Linux

`cloudgateway` is the CLI and `cloudgatewayd` is its root systemd daemon.
The 1.0.0 release targets **Ubuntu 24.04 LTS on ARM64 and AMD64**. Both
architectures passed sign-in and Chicago/San Jose connectivity checks in Mesh
and Full modes. The [VM results](../../docs/linux-cli-vm-results.md) record the
exact prerelease versions and test scope.

Linux defaults to **Mesh**, which leaves ordinary internet traffic and DNS on
the host's network. **Full is experimental on cloud VMs** and may require
DHCP/DNS configuration. Read [Mesh vs Full and cloud VM setup](../../docs/linux-cli-routing.md)
before enabling it. Explicit saved mode choices are retained during upgrades.

Other distributions with systemd and kernel WireGuard will likely need small
installer or network-integration changes. They are unverified; hosts with a
different init system or resolver may need more work. Containers, WSL, and
user-space WireGuard are outside the supported scope.

## Install

Download `install.sh` from the [Linux release](https://github.com/Albro3459/CloudGateway/releases/tag/linux-v1.0.0),
inspect it, then run it as root. Choose the local user who will control the VPN:

```sh
curl --proto '=https' --tlsv1.2 -fSLO https://github.com/Albro3459/CloudGateway/releases/download/linux-v1.0.0/install.sh
less install.sh
sudo bash install.sh --operator "$USER"
```

The installer selects the ARM64 or AMD64 archive and verifies its embedded size
and SHA-256 before installation. It requires systemd, kernel WireGuard, `ip`,
`wg`, and `nft`. It asks before installing missing network tools; `--yes` grants
that consent for unattended installation. Full also requires systemd-resolved
as the system resolver. The installer does not switch DNS managers.

The daemon starts immediately and is enabled at boot. Run the CLI as the
enrolled user, without sudo. Root can also control it; other users are denied.
No desktop app or Firebase service-account credentials are required.

## Sign in and connect

```sh
cloudgateway auth login
cloudgateway list
cloudgateway up '<client-uuid>'
cloudgateway status
cloudgateway doctor
cloudgateway down
```

Approve the displayed device code in a browser on any device. To create a new
client, use `cloudgateway add chicago 'Ubuntu VM'`, then list the clients to get
its UUID. Region aliases such as `chicago` and `sanjose` are accepted.

`up` reports that the start was accepted; use `status` to confirm the observed
tunnel state. The daemon continues accepted operations after the CLI or SSH
session disconnects. Use `--json` for scripts, and UUIDs rather than row indices
when retaining a selector across inventory changes.

Useful commands:

* `cloudgateway help` or `cloudgateway help <command>`: command reference.
* `cloudgateway mode status`: selected and active routing modes.
* `cloudgateway mode mesh` / `cloudgateway mode full`: save a mode, or switch
  the connected client to that mode.
* `cloudgateway refresh`: refresh inventory and the active server endpoint.
* `cloudgateway auth status`: session and access state.
* `cloudgateway auth logout`: sign out while retaining the running tunnel and
  saved configs. Run `down` first when you also want to disconnect.
* `cloudgateway remove '<client-uuid>' --yes`: permanently remove an inactive
  cloud client and free its peer slot.

The daemon resumes the last connected client and mode after reboot unless
reconnect was suppressed by an explicit stop, logout, or a failed transition.
A sign-in session is not needed for bare `cloudgateway down`.

## Update and uninstall

Run the **new release's** installer to install its exact archives. Each
installer is stamped for one version. To install from a downloaded release
folder instead, use `sudo bash install.sh --from <folder> --operator <user>`.

The installer switches `/opt/cloudgateway/current` to the new release and
restarts the daemon. `cloudgateway update` only activates an already installed
release; it does not download an update. A matching version is a no-op. Every
installer run enables the daemon service, including if an administrator had
previously disabled it.

Before decommissioning a machine, disconnect and remove its cloud clients
while signed in. Uninstalling alone does not remove cloud clients:

```sh
cloudgateway down
cloudgateway remove '<client-uuid>' --yes
sudo bash install.sh --uninstall
```

Uninstall removes CloudGateway's networking, service, and program files. It
keeps account data unless `--purge` is also passed. Shared distro tools are kept.

## Layout and development

| Path | Owns |
| --- | --- |
| `cmd/cloudgateway` | CLI entry point |
| `cmd/cloudgatewayd` | Root daemon and uninstall cleanup |
| `cmd/cloudgateway-release` | Reproducible archives and stamped installer |
| `install/` | Installer and systemd unit |
| `internal/cli`, `internal/jsonout` | Commands, terminal UI, diagnostics, and JSON schema 1 |
| `internal/ipc` | Framed CLI/daemon protocol and peer authority |
| `internal/daemon`, `internal/store` | Auth, inventory, operations, persisted intent, and private state |
| `internal/cloud` | Existing device auth, Firebase, and regional API contracts |
| `internal/network`, `internal/wgconfig` | Kernel WireGuard, owned routes/firewall/DNS, and config parsing |
| `internal/release`, `internal/buildinfo` | Version, installed identity, and public build configuration |
| `test-vm/` | Isolated Terraform state for a disposable OCI test VM |

Swift and platform UI code stay in the Apple projects. Linux's network package
has no HTTP or Firebase imports. Its simulated Ubuntu host exercises the real
network code without root.

Go is pinned by `go.mod` (`toolchain go1.27.3`), with no third-party modules.
From the repository root:

```sh
./scripts/test.sh linux
```

This runs formatting checks, host and Linux architecture vetting, race-enabled
tests, installer checks, and static AMD64/ARM64 builds. For privileged network
checks, use the [disposable VM setup](test-vm/README.md).

See the [parity contract](../../docs/linux-cli-parity.md) for command/JSON
behavior and the [design](../../docs/linux-cli-research.md) for architecture and
remaining validation scenarios.

## Runtime paths

| Path | Contents |
| --- | --- |
| `/opt/cloudgateway/releases/<version>` | Release files; the previous release is retained |
| `/opt/cloudgateway/current` | Atomic link to the active release |
| `/usr/local/bin/cloudgateway` | CLI link |
| `/etc/cloudgateway/daemon.json` | Root-owned enrolled operator UID |
| `/var/lib/cloudgateway` | Private state, directory `0700` and files `0600` |
| `/run/cloudgateway/cloudgatewayd.sock` | Root/operator socket checked with `SO_PEERCRED` |

Owned network identities are fixed for recovery: interface `cloudgateway`
(created as `cloudgw-pending`) with alias `cloudgatewayd`, table and fwmark
`52820`, rule priorities `30200`–`30220`, routing protocol `206`, and nftables
table `inet cloudgateway_client`.

## Releases

1. Copy `Secrets/example.release.env` to `Secrets/release.env` and fill in the
   public Firebase client configuration. Use a native-compatible API key that
   permits headless Firebase Auth REST calls. HTTP-referrer restrictions block
   CLI login. Keep this local file out of git; do not use service-account keys.
2. Run `./scripts/test.sh linux` from the repository root, then commit the
   release changes before building official assets.
3. From `Frontend/Linux`, run:

   ```sh
   go run ./cmd/cloudgateway-release build -version 1.0.0 -out <dir>
   ```

The builder writes `linux-v1.0.0/` containing the AMD64 and ARM64 archives and
an installer stamped with their sizes, SHA-256 hashes, and storage version. It
prints publication steps but uploads nothing. `-allow-dirty` is for local
validation builds only; those artifacts must not be published. Builds ignore
`go env -w` settings, so set `GOPROXY` and similar as environment variables.

Tags use `linux-v<version>`. JSON `version` and `build` both carry the release
version; `codeHash` is the daemon executable's SHA-256. Leave GitHub's global
Latest selection on the Mac release when publishing Linux.

Each release must read the previous network journal and state. If it cannot
parse the journal, the daemon removes owned resources by fixed identity and
reports disconnected. Bump `storageVersion` for state-format changes so the
installer refuses an incompatible downgrade. Connected upgrades between
releases have not had VM acceptance testing; see the [recorded scope](../../docs/linux-cli-vm-results.md).
