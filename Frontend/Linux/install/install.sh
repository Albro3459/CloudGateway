#!/usr/bin/env bash
# Installs, updates, or uninstalls CloudGateway for Linux. Read it, then run it
# as root:
#   curl --proto '=https' --tlsv1.2 -fsSLO https://github.com/Albro3459/CloudGateway/releases/download/linux-v<version>/install.sh
#   sudo bash install.sh
#
# It installs only the release it was published with, after checking the
# archive against the size and SHA-256 stamped below
set -euo pipefail
# Byte order for sorting and plain tool output
export LC_ALL=C

# Stamped by cloudgateway-release build
RELEASE_VERSION=""
STORAGE_VERSION=""
AMD64_ARCHIVE_SIZE=""
AMD64_ARCHIVE_SHA256=""
ARM64_ARCHIVE_SIZE=""
ARM64_ARCHIVE_SHA256=""

REPOSITORY="Albro3459/CloudGateway"
SERVICE="cloudgatewayd.service"
# Matches release.ValidVersion and its 18-digit bound
NUMBER='(0|[1-9][0-9]{0,17})'
VERSION_RE="^$NUMBER[.]$NUMBER[.]$NUMBER\$"
# Release paths in the sorted order cloudgateway-release archives them
RELEASE_FILES=(bin/cloudgateway bin/cloudgatewayd "$SERVICE")

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
  install.sh [--operator <user>] [--from <dir>] [--yes]
  install.sh --uninstall [--purge]

Options:
  --operator <user>  Local user allowed to control CloudGateway, besides root.
                     Defaults to $SUDO_USER on first install, then keeps the
                     enrolled user. Use --operator root to allow only root
  --from <dir>       Use this release's archive in <dir> instead of
                     downloading it
  --yes              Answer yes to prompts, such as installing missing packages
  --uninstall        Stop CloudGateway and remove its files and network
                     changes. Keeps account data in /var/lib/cloudgateway, and
                     src_valid_mark=1 stays set, as with wg-quick
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
FROM=""
UNINSTALL=0
PURGE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --operator | --from)
      [[ $# -ge 2 && -n $2 ]] || die "$1 needs a value"
      case "$1" in
        --operator) OPERATOR="$2" ;;
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
if [[ $UNINSTALL -eq 1 && -n $OPERATOR$FROM ]]; then
  die "--uninstall takes only --purge and --yes"
fi
if [[ $PURGE -eq 1 && $UNINSTALL -eq 0 ]]; then
  die "--purge needs --uninstall"
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
  # -m keeps a new directory 0755 under any umask, so the check below passes
  mkdir -p -m 0755 "$INSTALL_DIR"
  # A chown would keep entries another user planted, such as a .lock symlink
  # -H checks a symlinked install dir's target, as -O does
  if [[ ! -O $INSTALL_DIR || -n $(find -H "$INSTALL_DIR" -maxdepth 0 \( -perm -020 -o -perm -002 \)) ]]; then
    die "$INSTALL_DIR is writable by a user other than root. Check what is in it, make it root-owned with mode 0755, and rerun"
  fi
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

[[ $RELEASE_VERSION =~ $VERSION_RE ]] ||
  die "this installer has no stamped release. Use install.sh from a published release"
VERSION="$RELEASE_VERSION"

case "$(uname -m)" in
  x86_64 | amd64) ARCH=amd64 archive_size="$AMD64_ARCHIVE_SIZE" archive_sha="$AMD64_ARCHIVE_SHA256" ;;
  aarch64 | arm64) ARCH=arm64 archive_size="$ARM64_ARCHIVE_SIZE" archive_sha="$ARM64_ARCHIVE_SHA256" ;;
  *) die "unsupported architecture $(uname -m). CloudGateway ships amd64 and arm64" ;;
esac
[[ -n $archive_sha ]] || die "release $VERSION has no $ARCH build"
archive_name="cloudgateway-linux-$VERSION-$ARCH.tar.gz"

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
if [[ $OS_ID != ubuntu || $OS_VERSION_ID != 24.04 ]]; then
  warn "CloudGateway is tested on Ubuntu 24.04 LTS. Continuing on unverified $OS_NAME"
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

# A downgrade across a storage format change would leave state the daemon refuses
storage_floor=0
storage_re='"storageVersion": *([0-9]+)'
if [[ -f $STATE_DIR/storage.json ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ $storage_re ]] && ((BASH_REMATCH[1] > storage_floor)); then
      storage_floor="${BASH_REMATCH[1]}"
    fi
  done <"$STATE_DIR/storage.json"
fi
if ((STORAGE_VERSION < storage_floor)); then
  die "release $VERSION reads storage format $STORAGE_VERSION, but this machine already uses format $storage_floor. Refusing a downgrade across a storage format change"
fi

say "Checking CloudGateway $VERSION for $ARCH"
fetch "$archive_name" "$archive_size"
file_matches "$WORK/$archive_name" "$archive_size" "$archive_sha" ||
  die "$archive_name does not match this installer's release. Refusing to install"

# The archive must list exactly the release files and bin/, in the sorted
# order cloudgateway-release writes. That rules out traversal, absolute paths,
# extra entries, and duplicates before anything is extracted
expected_listing="$(printf '%s\n' bin/ "${RELEASE_FILES[@]}")"
[[ $(tar -tzf "$WORK/$archive_name") == "$expected_listing" ]] ||
  die "$archive_name does not hold exactly the release files. Refusing to install"

STAGE="$(mktemp -d "$RELEASES_DIR/.staging.XXXXXX")"
tar -xzf "$WORK/$archive_name" -C "$STAGE" --no-same-owner || die "cannot extract $archive_name"
[[ -z $(find "$STAGE" ! -type f ! -type d) ]] || die "$archive_name holds entries other than files and directories"
chown -R root:root "$STAGE"
chmod -R u=rwX,go=rX "$STAGE"
chmod 0755 "$STAGE/bin/cloudgateway" "$STAGE/bin/cloudgatewayd"

# A same-version reinstall reuses a matching release, with its ownership and
# modes reset, so current never dangles. A damaged one is moved aside, and the
# exit trap restores it if the swap fails
target="$RELEASES_DIR/$VERSION"
reuse=0
if [[ -d $target && ! -L $target ]]; then
  reuse=1
  for path in "${RELEASE_FILES[@]}"; do
    if [[ ! -f $target/$path || -L $target/$path ]] || ! cmp -s "$STAGE/$path" "$target/$path"; then
      reuse=0
    fi
  done
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
previous="${previous#releases/}"
[[ $previous != "$VERSION" ]] || previous=""

# Type=exec returns once the daemon launches. A daemon that exits waits 2s to
# start again under a new invocation, so one still active on the same
# invocation after 5s started cleanly
invocation="$(systemctl show -p InvocationID --value "$SERVICE")"
sleep 5
if ! systemctl is-active --quiet "$SERVICE" || [[ $(systemctl show -p InvocationID --value "$SERVICE") != "$invocation" ]]; then
  die "$SERVICE did not stay running. Check journalctl -u $SERVICE${previous:+. Release $previous is kept, so its install.sh can go back}"
fi

# Keep the new and previous releases. A reinstall keeps everything
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
