#!/usr/bin/env bash
# Installs, updates, or uninstalls CloudGateway for Linux. Read it, then run it
# as root:
#   curl --proto '=https' --tlsv1.2 -fsSLO https://github.com/Albro3459/CloudGateway/releases/download/linux-v<version>/install.sh
#   sudo bash install.sh
#
# It verifies the release manifest signature against the pinned key below,
# then every archive and file hash, before installing anything
set -euo pipefail
# Byte order for manifest sorting and plain tool output
export LC_ALL=C

# Stamped by cloudgateway-release build
RELEASE_VERSION=""
PINNED_PUBLIC_KEY=""

REPOSITORY="Albro3459/CloudGateway"
SERVICE="cloudgatewayd.service"
# Matches release.ValidVersion and its 18-digit bound
NUMBER='(0|[1-9][0-9]{0,17})'
VERSION_RE="^$NUMBER[.]$NUMBER[.]$NUMBER\$"
MAX_MANIFEST_BYTES=65536

# Test only: prefixes every system path so tests run unprivileged with stub
# commands on PATH. Never set it for a real install
ROOT="${CLOUDGATEWAY_INSTALL_TEST_ROOT:-}"
if [[ -n $ROOT && $EUID -eq 0 ]]; then
  echo "install.sh: CLOUDGATEWAY_INSTALL_TEST_ROOT is only for tests. Unset it and rerun" >&2
  exit 1
fi

INSTALL_DIR="$ROOT/opt/cloudgateway"
RELEASES_DIR="$INSTALL_DIR/releases"
CURRENT_LINK="$INSTALL_DIR/current"
CONFIG_DIR="$ROOT/etc/cloudgateway"
DAEMON_CONFIG="$CONFIG_DIR/daemon.json"
STATE_DIR="$ROOT/var/lib/cloudgateway"
UNIT_PATH="$ROOT/etc/systemd/system/$SERVICE"
BIN_LINK="$ROOT/usr/local/bin/cloudgateway"

usage() {
  cat <<'EOF'
Usage:
  install.sh [--operator <user>] [--version <x.y.z>] [--from <dir>] [--yes]
  install.sh --uninstall [--purge]

Options:
  --operator <user>  Local user allowed to control CloudGateway, besides root.
                     Defaults to $SUDO_USER on first install, then keeps the
                     enrolled user. Use --operator root to allow only root
  --version <x.y.z>  Release to install. Defaults to this installer's release
  --from <dir>       Use manifest.json, manifest.json.sig, and the archive in
                     <dir> instead of downloading them
  --yes              Answer yes to prompts, such as installing missing packages
  --uninstall        Stop CloudGateway, remove its network changes, and remove
                     its files. Keeps account data in /var/lib/cloudgateway
  --purge            With --uninstall, also delete /var/lib/cloudgateway
EOF
}

say() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
die() {
  echo "install.sh: $*" >&2
  exit 1
}

# Reads the terminal since stdin may be the script itself
confirm() {
  if [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  if ! (: </dev/tty) 2>/dev/null; then
    return 1
  fi
  local answer=""
  printf '%s [y/N] ' "$1" >&2
  read -r answer </dev/tty || true
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

OPERATOR=""
ASSUME_YES=0
VERSION=""
FROM=""
UNINSTALL=0
PURGE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --operator | --version | --from)
      [[ $# -ge 2 && -n $2 ]] || die "$1 needs a value"
      case "$1" in
        --operator) OPERATOR="$2" ;;
        --version) VERSION="$2" ;;
        --from) FROM="$2" ;;
      esac
      shift 2
      ;;
    --yes | -y) ASSUME_YES=1 && shift ;;
    --uninstall) UNINSTALL=1 && shift ;;
    --purge) PURGE=1 && shift ;;
    -h | --help) usage && exit 0 ;;
    *) usage >&2 && exit 2 ;;
  esac
done
if [[ $UNINSTALL -eq 1 && -n $OPERATOR$VERSION$FROM ]]; then
  die "--uninstall takes only --purge and --yes"
fi
if [[ $PURGE -eq 1 && $UNINSTALL -eq 0 ]]; then
  die "--purge needs --uninstall"
fi
if [[ -n $VERSION && ! $VERSION =~ $VERSION_RE ]]; then
  die "--version must look like 1.0.0"
fi
if [[ $OPERATOR == -* ]]; then
  die "invalid operator name $OPERATOR"
fi

umask 022
if [[ $(id -u) -ne 0 ]]; then
  die "run as root, for example: sudo bash install.sh"
fi

# Serializes every step that changes the system
take_lock() {
  command -v flock >/dev/null 2>&1 || die "flock is missing. Install util-linux and rerun"
  mkdir -p "$INSTALL_DIR"
  chown root:root "$INSTALL_DIR"
  chmod 0755 "$INSTALL_DIR"
  exec 9>"$INSTALL_DIR/.lock"
  flock -n 9 || die "another install.sh is running"
}

# Puts back a release a killed same-version reinstall moved aside, then drops the rest
restore_replaced() {
  local dir
  for dir in "$RELEASES_DIR"/.replaced.*/*; do
    if [[ -d $dir && ! -e $RELEASES_DIR/${dir##*/} ]]; then
      mv "$dir" "$RELEASES_DIR/${dir##*/}"
    fi
  done
  rm -rf "$RELEASES_DIR"/.replaced.*
}

# owned_network reports whether the daemon's link or nftables table remains:
# the link by its alias, or under the temporary name only the daemon uses
owned_network() {
  local alias="" dir
  [[ -e $ROOT/sys/class/net/cloudgw-pending ]] && return 0
  alias="$(cat "$ROOT/sys/class/net/cloudgateway/ifalias" 2>/dev/null || true)"
  [[ $alias == cloudgatewayd ]] && return 0
  for dir in /usr/sbin /usr/bin /sbin /bin; do
    if [[ -x $ROOT$dir/nft ]]; then
      [[ -n $("$ROOT$dir/nft" list table inet cloudgateway_client 2>/dev/null || true) ]]
      return
    fi
  done
  return 1
}

uninstall() {
  # An interrupted repair can leave current pointing at a moved release
  restore_replaced
  say "Stopping $SERVICE"
  systemctl stop "$SERVICE" 2>/dev/null || true
  local daemon="" candidate
  if [[ -x $CURRENT_LINK/bin/cloudgatewayd ]]; then
    daemon="$CURRENT_LINK/bin/cloudgatewayd"
  else
    # The highest installed version reads every older state format
    while IFS= read -r candidate; do
      if [[ -x $candidate ]]; then
        daemon="$candidate"
      fi
    done < <(printf '%s\n' "$RELEASES_DIR"/*/bin/cloudgatewayd | sort -V)
    if [[ -z $daemon ]] && compgen -G "$RELEASES_DIR/*/bin/cloudgatewayd" >/dev/null; then
      die "could not pick an installed cloudgatewayd to remove network changes. Check that sort supports -V, then rerun install.sh --uninstall"
    fi
  fi
  if [[ -n $daemon ]]; then
    say "Removing CloudGateway network changes"
    "$daemon" cleanup ||
      die "cloudgatewayd cleanup failed, so owned network changes may remain. The service is stopped and its files are kept. Fix the error above and rerun install.sh --uninstall"
  elif owned_network; then
    die "no cloudgatewayd is left to remove the VPN's network changes. Reboot to clear them, then rerun install.sh --uninstall"
  fi
  systemctl disable "$SERVICE" 2>/dev/null || true
  rm -f "$UNIT_PATH"
  systemctl daemon-reload
  if [[ -L $BIN_LINK && $(readlink "$BIN_LINK") == "$CURRENT_LINK/bin/cloudgateway" ]]; then
    rm -f "$BIN_LINK"
  fi
  rm -f "$DAEMON_CONFIG"
  rmdir "$CONFIG_DIR" 2>/dev/null || true
  if [[ $PURGE -eq 1 ]]; then
    rm -rf "$STATE_DIR"
  fi
  # Last, since it holds the lock that keeps an install from starting meanwhile
  rm -rf "$INSTALL_DIR"
  if [[ $PURGE -eq 1 ]]; then
    say "Uninstalled CloudGateway and deleted its account data"
  else
    say "Uninstalled CloudGateway. Kept account data in $STATE_DIR. Rerun with --uninstall --purge to delete it"
  fi
  echo "Cloud clients and distro packages were not changed"
}

if [[ $UNINSTALL -eq 1 ]]; then
  take_lock
  uninstall
  exit 0
fi

case "$(uname -m)" in
  x86_64 | amd64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) die "unsupported architecture $(uname -m). CloudGateway ships amd64 and arm64" ;;
esac

# os-release is parsed as data and never sourced
OS_ID=""
OS_VERSION_ID=""
OS_NAME="this distro"
os_release="$ROOT/etc/os-release"
[[ -f $os_release ]] || os_release="$ROOT/usr/lib/os-release"
if [[ -f $os_release ]]; then
  while IFS='=' read -r key value || [[ -n $key ]]; do
    value="${value#[\"\']}"
    value="${value%[\"\']}"
    case "$key" in
      ID) OS_ID="$value" ;;
      VERSION_ID) OS_VERSION_ID="$value" ;;
      PRETTY_NAME) OS_NAME="$value" ;;
    esac
  done <"$os_release"
fi
if [[ $OS_ID != ubuntu || ($OS_VERSION_ID != 24.04 && $OS_VERSION_ID != 26.04) ]]; then
  warn "CloudGateway is tested on Ubuntu 24.04 and 26.04. Continuing on $OS_NAME"
fi

[[ -d $ROOT/run/systemd/system ]] || die "CloudGateway needs systemd as the init system"

if [[ ! -d $ROOT/sys/module/wireguard ]] && ! modprobe -n wireguard >/dev/null 2>&1; then
  die "kernel WireGuard is unavailable. CloudGateway needs a kernel with the wireguard module (Linux 5.6 or later)"
fi

# cloudgatewayd runs these from the same fixed directories, ignoring PATH
system_tool() {
  local dir
  for dir in /usr/sbin /usr/bin /sbin /bin; do
    if [[ -f $ROOT$dir/$1 && -x $ROOT$dir/$1 ]]; then
      return 0
    fi
  done
  return 1
}

missing=""
for tool in ip wg nft; do
  if ! system_tool "$tool"; then
    missing="$missing $tool"
  fi
done
if [[ -n $missing ]]; then
  manager=""
  for candidate in apt-get dnf pacman; do
    if command -v "$candidate" >/dev/null 2>&1; then
      manager="$candidate"
      break
    fi
  done
  packages=""
  for tool in $missing; do
    case "$tool" in
      ip) [[ $manager == dnf ]] && packages="$packages iproute" || packages="$packages iproute2" ;;
      wg) packages="$packages wireguard-tools" ;;
      nft) packages="$packages nftables" ;;
    esac
  done
  case "$manager" in
    apt-get) install_command="apt-get update && apt-get install -y$packages" ;;
    dnf) install_command="dnf install -y$packages" ;;
    pacman) install_command="pacman -S --needed --noconfirm$packages" ;;
    *) die "missing commands:$missing. Install the packages that provide them ($packages ) and rerun" ;;
  esac
  confirm "Missing commands:$missing. Install$packages with $manager?" ||
    die "missing commands:$missing. Install them with: $install_command"
  # Package names are fixed words, so word splitting is intended
  case "$manager" in
    apt-get)
      apt-get update || die "apt-get update failed. Fix the package sources and rerun"
      apt-get install -y $packages || die "apt-get install$packages failed"
      ;;
    dnf) dnf install -y $packages || die "dnf install$packages failed" ;;
    pacman) pacman -S --needed --noconfirm $packages || die "pacman -S$packages failed" ;;
  esac
  for tool in $missing; do
    system_tool "$tool" || die "$tool is still missing from /usr/sbin, /usr/bin, /sbin, and /bin after installing$packages"
  done
fi

# Mesh works without systemd-resolved. Full refuses later and doctor shows the
# fix. The installer never switches resolvers since a wrong switch breaks DNS
# for the whole machine, and Ubuntu already uses resolved by default
resolver=""
if ! systemctl is-active --quiet systemd-resolved.service; then
  resolver="systemd-resolved is not running"
elif [[ $(readlink "$ROOT/etc/resolv.conf" 2>/dev/null) != */run/systemd/resolve/stub-resolv.conf ]]; then
  resolver="/etc/resolv.conf does not point at the systemd-resolved stub"
else
  # Captured first, since grep -q exiting early would fail the pipeline under pipefail
  resolver_dns="$(resolvectl dns 2>/dev/null || true)"
  if ! grep -Eq '^Link [0-9]+ \([^)]*\): *[0-9A-Fa-f:.]+' <<<"$resolver_dns"; then
    resolver="no network link has upstream DNS servers in systemd-resolved"
  fi
fi
if [[ -n $resolver ]]; then
  warn "$resolver. Mesh mode works without it, but Full mode needs systemd-resolved as the system resolver"
  if [[ $OS_ID == ubuntu ]]; then
    echo "  Ubuntu uses it by default. To restore it:" >&2
    echo "    systemctl enable --now systemd-resolved" >&2
    echo "    ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf" >&2
  else
    echo "  Configure your network manager to use systemd-resolved before using Full mode" >&2
  fi
fi

OPERATOR_UID=""
if [[ -z $OPERATOR && ! -f $DAEMON_CONFIG ]]; then
  OPERATOR="${SUDO_USER:-}"
  if [[ -z $OPERATOR || $OPERATOR == root ]]; then
    die "pass --operator <user> to choose the local user allowed to control CloudGateway, or --operator root to allow only root"
  fi
fi
if [[ -n $OPERATOR ]]; then
  OPERATOR_UID="$(id -u -- "$OPERATOR" 2>/dev/null)" || die "no local user named $OPERATOR"
  if [[ ! $OPERATOR_UID =~ ^[0-9]+$ || $OPERATOR_UID == 4294967295 ]]; then
    die "cannot enroll $OPERATOR with uid $OPERATOR_UID"
  fi
fi

if [[ -e $BIN_LINK || -L $BIN_LINK ]] && [[ $(readlink "$BIN_LINK" 2>/dev/null) != "$CURRENT_LINK/bin/cloudgateway" ]]; then
  die "$BIN_LINK exists and is not CloudGateway's link. Move it aside and rerun"
fi

# Preflight is done. Clear what a killed install left behind
take_lock
mkdir -p "$RELEASES_DIR"
chown root:root "$RELEASES_DIR"
chmod 0755 "$RELEASES_DIR"
restore_replaced
rm -rf "$INSTALL_DIR"/.work.* "$RELEASES_DIR"/.staging.*

# The work dir sits under root-owned /opt so no other user can swap verified files
WORK="$(mktemp -d "$INSTALL_DIR/.work.XXXXXX")"
STAGE=""
cleanup_temp() {
  rm -rf "$WORK"
  if [[ -n $STAGE ]]; then
    rm -rf "$STAGE"
  fi
  restore_replaced
}
trap cleanup_temp EXIT

# Copies from --from or downloads over HTTPS into the work dir, up to $2 bytes
fetch() {
  local url="https://github.com/$REPOSITORY/releases/download/linux-v$VERSION/$1"
  if [[ -n $FROM ]]; then
    cp "$FROM/$1" "$WORK/$1" || die "cannot read $FROM/$1"
  elif command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --connect-timeout 30 --max-time 900 \
      --max-filesize "$2" -o "$WORK/$1" "$url" || die "download failed: $url"
  else
    # wget can't keep redirects on HTTPS or cap a download's size
    die "install curl, or pass --from <dir>"
  fi
  (($(wc -c <"$WORK/$1") <= $2)) || die "$1 is larger than expected"
}

file_matches() {
  local size sum
  [[ -f $1 && ! -L $1 ]] || return 1
  size=$(($(wc -c <"$1")))
  sum="$(sha256sum "$1")"
  [[ $size == "$2" && ${sum%% *} == "$3" ]]
}

if [[ -z $VERSION ]]; then
  # With --from too, so a stale release left in that folder is never installed by mistake
  VERSION="$RELEASE_VERSION"
  [[ -n $VERSION || -n $FROM ]] || die "this installer has no stamped release. Pass --version <x.y.z> or --from <dir>"
fi
say "Verifying CloudGateway${VERSION:+ $VERSION} for $ARCH"
fetch manifest.json "$MAX_MANIFEST_BYTES"
fetch manifest.json.sig 64

[[ -n $PINNED_PUBLIC_KEY ]] || die "this installer has no pinned release key. Use install.sh from a published release"
openssl_version="$(openssl version 2>/dev/null || true)"
openssl_re='^OpenSSL ([0-9]+)[.]'
if [[ ! $openssl_version =~ $openssl_re ]] || ((BASH_REMATCH[1] < 3)); then
  die "verifying the release needs OpenSSL 3 or later, found: ${openssl_version:-none}"
fi
printf -- '-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n' "$PINNED_PUBLIC_KEY" >"$WORK/release.pub"
openssl pkeyutl -verify -pubin -inkey "$WORK/release.pub" -rawin \
  -in "$WORK/manifest.json" -sigfile "$WORK/manifest.json.sig" >/dev/null 2>&1 ||
  die "the release manifest signature does not verify. Refusing to install"

# Accepts exactly the canonical encoding release.Parse accepts. Entries must be
# strictly sorted, which also rejects duplicates and a second archive
malformed() { die "the release manifest is malformed: $1"; }
path_re='[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*'
version_line_re='^  "version": "([0-9.]+)",$'
ipc_line_re='^  "ipcVersion": [1-9][0-9]{0,17},$'
storage_line_re='^  "storageVersion": ([1-9][0-9]{0,17}),$'
entry_re="^    [{]\"arch\":\"(amd64|arm64)\",\"kind\":\"(archive|file)\",\"path\":\"($path_re)\",\"size\":$NUMBER,\"sha256\":\"([0-9a-f]{64})\"[}](,?)\$"
[[ $(tr -d '\000\r' <"$WORK/manifest.json" | wc -c) -eq $(wc -c <"$WORK/manifest.json") ]] || malformed "control bytes"
line_number=0
section=header
release_version=""
storage_version=""
previous_key=""
previous_comma=""
seen=" "
archive=""
files=""
while IFS= read -r line; do
  line_number=$((line_number + 1))
  case "$section:$line_number" in
    header:1) [[ $line == "{" ]] || malformed "line 1" ;;
    header:2) [[ $line == '  "schemaVersion": 1,' ]] || die "unsupported release manifest schema. Use the install.sh published with the release" ;;
    header:3)
      [[ $line =~ $version_line_re ]] || malformed "version"
      release_version="${BASH_REMATCH[1]}"
      [[ $release_version =~ $VERSION_RE ]] || malformed "version"
      ;;
    header:4) [[ $line =~ $ipc_line_re ]] || malformed "ipcVersion" ;;
    header:5)
      [[ $line =~ $storage_line_re ]] || malformed "storageVersion"
      storage_version="${BASH_REMATCH[1]}"
      ;;
    header:6)
      [[ $line == '  "entries": [' ]] || malformed "line 6"
      section=entries
      ;;
    entries:*)
      if [[ $line == "  ]" ]]; then
        [[ -n $previous_key && -z $previous_comma ]] || malformed "entries end"
        section=end
        continue
      fi
      [[ $line =~ $entry_re ]] || malformed "line $line_number"
      entry_arch="${BASH_REMATCH[1]}"
      entry_kind="${BASH_REMATCH[2]}"
      entry_path="${BASH_REMATCH[3]}"
      entry_size="${BASH_REMATCH[5]}"
      entry_sha="${BASH_REMATCH[6]}"
      entry_comma="${BASH_REMATCH[7]}"
      key="$entry_arch $entry_kind $entry_path"
      if [[ -n $previous_key ]] && [[ -z $previous_comma || ! $previous_key < $key ]]; then
        malformed "entries are not strictly sorted at line $line_number"
      fi
      if [[ $entry_kind == archive ]]; then
        [[ $entry_path == "cloudgateway-linux-$release_version-$entry_arch.tar.gz" && $entry_size != 0 ]] || malformed "archive $entry_path"
      fi
      seen="$seen$entry_arch:$entry_kind:$entry_path "
      if [[ $entry_arch == "$ARCH" ]]; then
        if [[ $entry_kind == archive ]]; then
          archive="$entry_path $entry_size $entry_sha"
        else
          files="$files$entry_path $entry_size $entry_sha"$'\n'
        fi
      fi
      previous_key="$key"
      previous_comma="$entry_comma"
      ;;
    end:*)
      [[ $line == "}" && $section == end ]] || malformed "line $line_number"
      section=done
      ;;
    *) malformed "line $line_number" ;;
  esac
done <"$WORK/manifest.json"
# read skips a last line without a newline, leaving it in line
[[ -z $line ]] || malformed "trailing data"
[[ $section == done ]] || malformed "truncated"
for arch in amd64 arm64; do
  if [[ $seen == *" $arch:"* ]]; then
    for required in "archive:cloudgateway-linux-$release_version-$arch.tar.gz" file:bin/cloudgateway file:bin/cloudgatewayd "file:$SERVICE"; do
      [[ $seen == *" $arch:$required "* ]] || malformed "no $arch ${required#*:}"
    done
  fi
done

[[ -z $VERSION || $VERSION == "$release_version" ]] || die "the manifest is for release $release_version, not $VERSION"
VERSION="$release_version"
[[ -n $archive ]] || die "release $VERSION has no $ARCH build"
read -r archive_name archive_size archive_sha <<<"$archive"

# A downgrade across a storage format change would leave state the daemon refuses
storage_floor=0
storage_re='"storageVersion": *([0-9]+)'
for storage_file in "$CURRENT_LINK/manifest.json" "$STATE_DIR/storage.json"; do
  if [[ -f $storage_file ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line =~ $storage_re ]] && ((BASH_REMATCH[1] > storage_floor)); then
        storage_floor="${BASH_REMATCH[1]}"
      fi
    done <"$storage_file"
  fi
done
if ((storage_version < storage_floor)); then
  die "release $VERSION reads storage format $storage_version, but this machine already uses format $storage_floor. Refusing a downgrade across a storage format change"
fi

fetch "$archive_name" "$archive_size"
file_matches "$WORK/$archive_name" "$archive_size" "$archive_sha" ||
  die "$archive_name does not match the signed manifest. Refusing to install"

# The archive must list exactly the manifest's files and their parent dirs, in
# the sorted order cloudgateway-release writes. That rules out traversal,
# absolute paths, extra entries, and duplicates before anything is extracted
expected_listing="$(
  while read -r path _; do
    dir="$path"
    while [[ $dir == */* ]]; do
      dir="${dir%/*}"
      echo "$dir/"
    done
    echo "$path"
  done <<<"${files%$'\n'}" | sort -u
)"
[[ $(tar -tzf "$WORK/$archive_name") == "$expected_listing" ]] ||
  die "$archive_name does not hold exactly the files in the signed manifest. Refusing to install"

STAGE="$(mktemp -d "$RELEASES_DIR/.staging.XXXXXX")"
tar -xzf "$WORK/$archive_name" -C "$STAGE" --no-same-owner || die "cannot extract $archive_name"
[[ -z $(find "$STAGE" ! -type f ! -type d) ]] || die "$archive_name holds entries other than files and directories"
while read -r path size sha; do
  file_matches "$STAGE/$path" "$size" "$sha" || die "$path does not match the signed manifest. Refusing to install"
done <<<"${files%$'\n'}"
cp "$WORK/manifest.json" "$WORK/manifest.json.sig" "$STAGE/"
chown -R root:root "$STAGE"
chmod -R u=rwX,go=rX "$STAGE"
chmod 0755 "$STAGE/bin/cloudgateway" "$STAGE/bin/cloudgatewayd"

# A same-version reinstall reuses a matching release, with its ownership and
# modes reset, so current never dangles. A damaged one is moved aside, and the
# exit trap restores it if the swap fails
target="$RELEASES_DIR/$VERSION"
reuse=0
if [[ -d $target ]] && cmp -s "$WORK/manifest.json" "$target/manifest.json" &&
  cmp -s "$WORK/manifest.json.sig" "$target/manifest.json.sig"; then
  reuse=1
  while read -r path size sha; do
    file_matches "$target/$path" "$size" "$sha" || reuse=0
  done <<<"${files%$'\n'}"
fi
if [[ $reuse -eq 1 ]]; then
  rm -rf "$STAGE"
  chown -R root:root "$target"
  chmod -R u=rwX,go=rX "$target"
  chmod 0755 "$target/bin/cloudgateway" "$target/bin/cloudgatewayd"
elif [[ -e $target ]]; then
  replaced="$(mktemp -d "$RELEASES_DIR/.replaced.XXXXXX")"
  mv "$target" "$replaced/$VERSION"
  mv "$STAGE" "$target"
  rm -rf "$replaced"
else
  mv "$STAGE" "$target"
fi
STAGE=""

mkdir -p "$(dirname "$UNIT_PATH")"
cp "$target/$SERVICE" "$UNIT_PATH.tmp"
chown root:root "$UNIT_PATH.tmp"
chmod 0644 "$UNIT_PATH.tmp"
mv -f "$UNIT_PATH.tmp" "$UNIT_PATH"

# cloudgatewayd refuses a config that is not root-owned or is group/world writable
if [[ -n $OPERATOR_UID ]]; then
  mkdir -p "$CONFIG_DIR"
  chown root:root "$CONFIG_DIR"
  chmod 0755 "$CONFIG_DIR"
  printf '{"operatorUid": %s}\n' "$OPERATOR_UID" >"$DAEMON_CONFIG.tmp"
  chown root:root "$DAEMON_CONFIG.tmp"
  chmod 0644 "$DAEMON_CONFIG.tmp"
  mv -f "$DAEMON_CONFIG.tmp" "$DAEMON_CONFIG"
  say "Enrolled $OPERATOR (uid $OPERATOR_UID) as the CloudGateway operator"
fi

# Flush the release to disk before current points at it
sync
previous="$(readlink "$CURRENT_LINK" 2>/dev/null || true)"
ln -sfn "releases/$VERSION" "$INSTALL_DIR/.current.tmp"
mv -T "$INSTALL_DIR/.current.tmp" "$CURRENT_LINK"
mkdir -p "$(dirname "$BIN_LINK")"
ln -sfn "$CURRENT_LINK/bin/cloudgateway" "$BIN_LINK"

# Enable every time so a rerun finishes an interrupted first install. restart
# also starts a stopped daemon. On update the daemon leaves the tunnel up and
# the new release adopts it
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl reset-failed "$SERVICE" 2>/dev/null || true
systemctl restart "$SERVICE"

# Keep the new and previous releases. A reinstall keeps everything
previous="${previous#releases/}"
[[ $previous != "$VERSION" ]] || previous=""
if [[ -n $previous ]]; then
  for dir in "$RELEASES_DIR"/*; do
    name="${dir##*/}"
    if [[ -d $dir && ! -L $dir && $name =~ $VERSION_RE && $name != "$VERSION" && $name != "$previous" ]]; then
      rm -rf "$dir"
    fi
  done
fi

say "Installed CloudGateway $VERSION${previous:+, replacing $previous}"
echo "Run 'cloudgateway login' as the operator to sign in"
