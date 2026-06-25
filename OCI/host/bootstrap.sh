#!/bin/bash

# Full regional host bootstrap. Fetched from GitHub and run by the cloud-init
# stub (OCI/terraform/stub-cloud-init.sh.tftpl), which has already written
# /etc/cloudgateway/bootstrap.env, /etc/cloudgateway/wireguard-server.key, the
# optional Firebase credential file, and extracted this repo's API/ and
# OCI/host/ into /opt/cloudgateway/src. Runs as root with output already
# redirected to /var/log/wireguard-bootstrap.log by the stub.

set -euo pipefail

BOOTSTRAP_STARTED_AT="$(date +%s)"

log() {
  local now
  now="$(date +%s)"
  printf '[%s +%ss] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$((now - BOOTSTRAP_STARTED_AT))" "$*"
}

set +x
set -a
source /etc/cloudgateway/bootstrap.env
set +a
set -x

export DEBIAN_FRONTEND=noninteractive

SRC_DIR="/opt/cloudgateway/src"
ADGUARD_HOME_VERSION="${ADGUARD_HOME_VERSION:-v0.107.77}"
ADGUARD_HOME_CONFIG="/etc/adguardhome/AdGuardHome.yaml"
ADGUARD_HOME_WORK_DIR="/var/lib/adguardhome"
ADGUARD_DNS_FILTER_URL="https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"
UNBOUND_LISTEN_PORT=5335

wait_for_apt() {
  while ps -eo comm= | grep -Eq '^(apt|apt-get|dpkg)$'; do
    log "Waiting for other apt/dpkg process to finish..."
    sleep 5
  done
}

# Quote a value for systemd EnvironmentFile parsing (the only parser of
# api.env): wrap in double quotes and escape backslash and double-quote so
# spaces and special characters survive intact.
systemd_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

adguard_arch() {
  case "$(uname -m)" in
    aarch64|arm64)
      echo "arm64"
      ;;
    x86_64|amd64)
      echo "amd64"
      ;;
    *)
      echo "Unsupported architecture for AdGuard Home: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

PRIMARY_IFACE="$(ip route show default | awk '/default/ { print $5; exit }')"

if [[ -z "$PRIMARY_IFACE" ]]; then
  echo "Unable to determine the primary network interface" >&2
  exit 1
fi

log "==> Step 1/13: Installing required packages"
wait_for_apt
apt-get update
wait_for_apt
apt-get install -y wireguard iptables fail2ban unbound dns-root-data python3-venv python3-pip ca-certificates curl gettext-base
systemctl stop unbound || true
systemctl stop adguardhome || true

log "==> Step 2/13: Preparing configuration directories"
# Essentially mkdir -p /etc/wireguard && chmod 700 /etc/wireguard
install -d -m 700 /etc/wireguard
install -d -m 755 /etc/sysctl.d
install -d -m 755 /etc/ssh/sshd_config.d
install -d -m 755 /etc/fail2ban/jail.d
install -d -m 755 /etc/unbound/unbound.conf.d
install -d -o unbound -g unbound -m 750 /var/lib/unbound
install -d -m 700 /etc/cloudgateway
install -d -m 755 /opt/cloudgateway/api
install -d -m 755 /etc/caddy
install -d -m 755 /var/log/caddy
install -d -m 755 /var/lib/caddy
install -d -m 755 /etc/adguardhome
install -d -m 755 "$ADGUARD_HOME_WORK_DIR"

log "==> Step 3/13: Hardening SSH access"
SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%F_%H-%M-%S)"
cp /etc/ssh/sshd_config "$SSHD_BACKUP"
install -d -m 755 /run/sshd

cat > /etc/ssh/sshd_config.d/99-cloudgateway-hardening.conf <<'SSHCONF'
PasswordAuthentication no
PermitRootLogin no
SSHCONF

sshd -t
systemctl reload-or-restart ssh || systemctl reload-or-restart sshd || systemctl start ssh
sshd -T | grep -E '^(passwordauthentication|permitrootlogin) ' || true

log "==> Step 4/13: Configuring fail2ban"
cat > /etc/fail2ban/jail.d/sshd.local <<'FAIL2BAN'
[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
FAIL2BAN

systemctl enable fail2ban
systemctl restart fail2ban
systemctl --no-pager --full status fail2ban || true
fail2ban-client status || true
fail2ban-client status sshd || true

log "==> Step 5/13: Enabling IP forwarding"
# IP forwarding
cat > /etc/sysctl.d/99-wireguard-forwarding.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
SYSCTL

# Apply IP forwarding changes
sysctl --system

log "==> Step 6/13: Writing WireGuard configuration"
# Interface-only config. Peers are never written to this or any other file:
# Firebase is the single source of truth and cloudgateway-sync-peers rebuilds
# the live peer set from it on every boot.
# xtrace stays off while the private key is in play.
set +x
cat > "/etc/wireguard/$WG_INTERFACE.conf" <<WGCONF
[Interface]
Address = $WG_ADDRESS_V4, $WG_ADDRESS_V6
ListenPort = $WG_LISTEN_PORT
PrivateKey = $(cat /etc/cloudgateway/wireguard-server.key)

# PostUp
# IPv4
# Do not let VPN clients reach OCI instance metadata. user_data should not be accessible secrets
PostUp = iptables -I FORWARD 1 -i $WG_INTERFACE -d 169.254.169.254/32 -j DROP
PostUp = iptables -I FORWARD 2 -i $WG_INTERFACE -j ACCEPT
PostUp = iptables -I FORWARD 3 -o $WG_INTERFACE -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s $WG_NETWORK_V4 -o $PRIMARY_IFACE -j MASQUERADE
PostUp = iptables -I INPUT 1 -p udp --dport $WG_LISTEN_PORT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostUp = iptables -I INPUT 2 -p udp --dport $WG_LISTEN_PORT -m conntrack --ctstate NEW -m limit --limit $WG_RATE_LIMIT --limit-burst $WG_RATE_LIMIT_BURST -j ACCEPT
PostUp = iptables -I INPUT 3 -p udp --dport $WG_LISTEN_PORT -j DROP
PostUp = iptables -I INPUT 4 -i $WG_INTERFACE -d $WG_DNS_ADDRESS_V4 -p udp --dport 53 -j ACCEPT
PostUp = iptables -I INPUT 5 -i $WG_INTERFACE -d $WG_DNS_ADDRESS_V4 -p tcp --dport 53 -j ACCEPT
# IPv6
PostUp = ip6tables -I FORWARD 1 -i $WG_INTERFACE -j ACCEPT
PostUp = ip6tables -I FORWARD 2 -o $WG_INTERFACE -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -s $WG_NETWORK_V6 -o $PRIMARY_IFACE -j MASQUERADE
PostUp = ip6tables -I INPUT 1 -p udp --dport $WG_LISTEN_PORT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostUp = ip6tables -I INPUT 2 -p udp --dport $WG_LISTEN_PORT -m conntrack --ctstate NEW -m limit --limit $WG_RATE_LIMIT --limit-burst $WG_RATE_LIMIT_BURST -j ACCEPT
PostUp = ip6tables -I INPUT 3 -p udp --dport $WG_LISTEN_PORT -j DROP
PostUp = ip6tables -I INPUT 4 -i $WG_INTERFACE -d $WG_DNS_ADDRESS_V6 -p udp --dport 53 -j ACCEPT
PostUp = ip6tables -I INPUT 5 -i $WG_INTERFACE -d $WG_DNS_ADDRESS_V6 -p tcp --dport 53 -j ACCEPT

# PostDown
# IPv4
PostDown = iptables -D FORWARD -i $WG_INTERFACE -d 169.254.169.254/32 -j DROP
PostDown = iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT
PostDown = iptables -D FORWARD -o $WG_INTERFACE -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s $WG_NETWORK_V4 -o $PRIMARY_IFACE -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport $WG_LISTEN_PORT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = iptables -D INPUT -p udp --dport $WG_LISTEN_PORT -m conntrack --ctstate NEW -m limit --limit $WG_RATE_LIMIT --limit-burst $WG_RATE_LIMIT_BURST -j ACCEPT
PostDown = iptables -D INPUT -p udp --dport $WG_LISTEN_PORT -j DROP
PostDown = iptables -D INPUT -i $WG_INTERFACE -d $WG_DNS_ADDRESS_V4 -p udp --dport 53 -j ACCEPT
PostDown = iptables -D INPUT -i $WG_INTERFACE -d $WG_DNS_ADDRESS_V4 -p tcp --dport 53 -j ACCEPT
# IPv6
PostDown = ip6tables -D FORWARD -i $WG_INTERFACE -j ACCEPT
PostDown = ip6tables -D FORWARD -o $WG_INTERFACE -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -s $WG_NETWORK_V6 -o $PRIMARY_IFACE -j MASQUERADE
PostDown = ip6tables -D INPUT -p udp --dport $WG_LISTEN_PORT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = ip6tables -D INPUT -p udp --dport $WG_LISTEN_PORT -m conntrack --ctstate NEW -m limit --limit $WG_RATE_LIMIT --limit-burst $WG_RATE_LIMIT_BURST -j ACCEPT
PostDown = ip6tables -D INPUT -p udp --dport $WG_LISTEN_PORT -j DROP
PostDown = ip6tables -D INPUT -i $WG_INTERFACE -d $WG_DNS_ADDRESS_V6 -p udp --dport 53 -j ACCEPT
PostDown = ip6tables -D INPUT -i $WG_INTERFACE -d $WG_DNS_ADDRESS_V6 -p tcp --dport 53 -j ACCEPT
WGCONF
set -x

chmod 600 "/etc/wireguard/$WG_INTERFACE.conf"

awk '/^PrivateKey/ { print $3 }' "/etc/wireguard/$WG_INTERFACE.conf" | wg pubkey > "/etc/wireguard/$WG_INTERFACE.publickey"
chmod 600 "/etc/wireguard/$WG_INTERFACE.publickey"

log "==> Step 7/13: Installing AdGuard Home"
ADGUARD_ARCH="$(adguard_arch)"
ADGUARD_WORK_DIR="$(mktemp -d /tmp/cloudgateway-adguardhome-XXXXXX)"
ADGUARD_TARBALL="$ADGUARD_WORK_DIR/AdGuardHome.tar.gz"
curl --fail --silent --show-error --location --retry 5 --retry-delay 5 \
  "https://github.com/AdguardTeam/AdGuardHome/releases/download/$ADGUARD_HOME_VERSION/AdGuardHome_linux_$ADGUARD_ARCH.tar.gz" \
  -o "$ADGUARD_TARBALL"
tar -xzf "$ADGUARD_TARBALL" -C "$ADGUARD_WORK_DIR"
install -m 755 "$ADGUARD_WORK_DIR/AdGuardHome/AdGuardHome" /usr/local/bin/AdGuardHome
rm -rf "$ADGUARD_WORK_DIR"

log "==> Step 8/13: Writing DNS resolver configuration"
if command -v unbound-anchor >/dev/null 2>&1; then
  if ! unbound-anchor -a /var/lib/unbound/root.key; then
    log "unbound-anchor could not refresh the DNSSEC trust anchor; continuing without DNSSEC validation"
  fi
fi

if [[ -f /var/lib/unbound/root.key ]]; then
  chown unbound:unbound /var/lib/unbound/root.key
  chmod 640 /var/lib/unbound/root.key
fi

cat > /etc/unbound/unbound.conf.d/cloudgateway-wireguard.conf <<UNBOUNDCONF
server:
  interface: 127.0.0.1
  interface: ::1
  port: $UNBOUND_LISTEN_PORT
  access-control: 127.0.0.0/8 allow
  access-control: ::1 allow
  do-ip4: yes
  do-ip6: yes
  do-udp: yes
  do-tcp: yes
  prefer-ip6: yes
  root-hints: "/usr/share/dns/root.hints"
  qname-minimisation: yes
  hide-identity: yes
  hide-version: yes
  verbosity: 0
  log-queries: no
UNBOUNDCONF

unbound-checkconf
systemctl enable unbound

cat > "$ADGUARD_HOME_CONFIG" <<ADGUARDCONF
http:
  address: 127.0.0.1:3000
  session_ttl: 720h
users: []
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
dns:
  bind_hosts:
    - $WG_DNS_ADDRESS_V4
    - $WG_DNS_ADDRESS_V6
  port: 53
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - 127.0.0.1:$UNBOUND_LISTEN_PORT
  upstream_dns_file: ""
  bootstrap_dns: []
  fallback_dns: []
  upstream_mode: load_balance
  fastest_timeout: 1s
  use_http3_upstreams: false
  use_private_ptr_resolvers: false
  local_ptr_upstreams: []
  allowed_clients:
    - 127.0.0.0/8
    - ::1/128
    - $WG_NETWORK_V4
    - $WG_NETWORK_V6
  disallowed_clients: []
  blocked_hosts: []
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_enabled: true
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  bogus_nxdomain: []
  enable_dnssec: false
  aaaa_disabled: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  upstream_timeout: 10s
  serve_plain_dns: true
  hostsfile_enabled: true
filtering:
  protection_enabled: true
  filtering_enabled: true
  blocking_mode: default
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_response_ttl: 10
  protection_disabled_until: null
  parental_block_host: ""
  safebrowsing_block_host: ""
  parental_enabled: false
  safe_search:
    enabled: false
    bing: false
    duckduckgo: false
    google: false
    pixabay: false
    yandex: false
    youtube: false
  safebrowsing_enabled: false
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  rewrites: []
  safe_fs_patterns: []
  cache_time: 30
  filters_update_interval: 24
  blocked_services:
    ids: []
    schedule:
      time_zone: UTC
querylog:
  enabled: false
  file_enabled: false
  interval: 2160h
  size_memory: 1000
  ignored: []
  ignored_enabled: false
  dir_path: ""
statistics:
  enabled: false
  interval: 24h
  ignored: []
  ignored_enabled: false
  dir_path: ""
filters:
  - enabled: true
    url: $ADGUARD_DNS_FILTER_URL
    name: AdGuard DNS filter
    id: 1
whitelist_filters: []
user_rules: []
dhcp:
  enabled: false
  interface_name: ""
  local_domain_name: lan
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 0
  port_dns_over_tls: 0
  port_dns_over_quic: 0
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
clients:
  persistent: []
  runtime_sources:
    whois: false
    arp: false
    rdns: false
    dhcp: false
    hosts: false
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 34
ADGUARDCONF
chmod 600 "$ADGUARD_HOME_CONFIG"
/usr/local/bin/AdGuardHome --no-check-update --config "$ADGUARD_HOME_CONFIG" --work-dir "$ADGUARD_HOME_WORK_DIR" --check-config

cat > /etc/systemd/system/adguardhome.service <<UNIT
[Unit]
Description=AdGuard Home DNS filter for CloudGateway VPN clients
After=network-online.target wg-quick@$WG_INTERFACE.service unbound.service
Wants=network-online.target wg-quick@$WG_INTERFACE.service unbound.service

[Service]
Type=simple
ExecStart=/usr/local/bin/AdGuardHome --no-check-update --config $ADGUARD_HOME_CONFIG --work-dir $ADGUARD_HOME_WORK_DIR
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable adguardhome

log "==> Step 9/13: Installing CloudGateway API package"
cp -R "$SRC_DIR/API/." /opt/cloudgateway/api/

python3 -m venv /opt/cloudgateway/api/.venv
/opt/cloudgateway/api/.venv/bin/pip install --upgrade pip
/opt/cloudgateway/api/.venv/bin/pip install /opt/cloudgateway/api

cat > /usr/local/sbin/cloudgateway-install-api <<'INSTALLAPI'
#!/bin/bash
set -euo pipefail

source /etc/cloudgateway/bootstrap.env
REF="${1:-$SOURCE_REF}"
WORK_DIR="$(mktemp -d /tmp/cloudgateway-api-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Fetching API source from $SOURCE_REPO at $REF"
curl --fail --silent --show-error --location --retry 5 --retry-delay 5 \
  "https://codeload.github.com/$SOURCE_REPO/tar.gz/$REF" -o "$WORK_DIR/src.tar.gz"
tar -xzf "$WORK_DIR/src.tar.gz" --strip-components=1 -C "$WORK_DIR" --wildcards '*/API'

if [[ ! -f "$WORK_DIR/API/pyproject.toml" ]]; then
  echo "Downloaded ref $REF does not contain API/pyproject.toml" >&2
  exit 1
fi

cp -R "$WORK_DIR/API/." /opt/cloudgateway/api/
/opt/cloudgateway/api/.venv/bin/pip install /opt/cloudgateway/api
systemctl restart cloudgateway-api
systemctl --no-pager --full status cloudgateway-api || true
INSTALLAPI
chmod 755 /usr/local/sbin/cloudgateway-install-api

log "==> Step 10/13: Writing CloudGateway API environment"
if [[ ! -f "$FIREBASE_CREDENTIALS_FILE" ]]; then
  log "No Firebase credential file at $FIREBASE_CREDENTIALS_FILE; provision it manually before using the API"
fi

SERVER_PUBLIC_KEY="$(cat "/etc/wireguard/$WG_INTERFACE.publickey")"
set +x
cat > /etc/cloudgateway/api.env <<APIENV
CLOUDGATEWAY_REGION_ID=$REGION_ID
CLOUDGATEWAY_API_PORT=$FASTAPI_PORT
CLOUDGATEWAY_API_HOSTNAME=$API_HOSTNAME
CLOUDGATEWAY_DASHBOARD_CORS_ORIGIN=$DASHBOARD_CORS_ORIGIN
CLOUDGATEWAY_FIREBASE_CREDENTIALS_FILE=$FIREBASE_CREDENTIALS_FILE
CLOUDGATEWAY_WG_INTERFACE=$WG_INTERFACE
CLOUDGATEWAY_WG_SERVER_PUBLIC_KEY=$SERVER_PUBLIC_KEY
CLOUDGATEWAY_WG_ENDPOINT_HOSTNAME=$WG_ENDPOINT_HOSTNAME
CLOUDGATEWAY_WG_PORT=$WG_LISTEN_PORT
CLOUDGATEWAY_WG_DNS_IPV4=$WG_DNS_ADDRESS_V4
CLOUDGATEWAY_WG_DNS_IPV6=$WG_DNS_ADDRESS_V6
CLOUDGATEWAY_WG_TUNNEL_IPV4_CIDR=$WG_NETWORK_V4
CLOUDGATEWAY_WG_TUNNEL_IPV6_CIDR=$WG_NETWORK_V6
CLOUDGATEWAY_REGION_DISPLAY_NAME=$(systemd_quote "$REGION_DISPLAY_NAME")
CLOUDGATEWAY_REGION_DISPLAY_ORDER=$REGION_DISPLAY_ORDER
CLOUDGATEWAY_REGION_CAPACITY_LIMIT=$REGION_CAPACITY_LIMIT
CLOUDGATEWAY_SES_REGION=$(systemd_quote "$SES_REGION")
CLOUDGATEWAY_SES_SENDER=$(systemd_quote "$SES_SENDER")
CLOUDGATEWAY_AWS_ACCESS_KEY_ID=$(systemd_quote "$AWS_ACCESS_KEY_ID")
CLOUDGATEWAY_AWS_SECRET_ACCESS_KEY=$(systemd_quote "$AWS_SECRET_ACCESS_KEY")
APIENV
set -x
chmod 600 /etc/cloudgateway/api.env

cat > /etc/cloudgateway/origin.env <<ORIGINENV
CLOUDGATEWAY_API_HOSTNAME=$API_HOSTNAME
CLOUDGATEWAY_DASHBOARD_CORS_ORIGIN=$DASHBOARD_CORS_ORIGIN
CLOUDGATEWAY_CADDY_ACME_EMAIL=$CADDY_ACME_EMAIL
CLOUDGATEWAY_CLOUDFLARE_ORIGIN_PULL_CA_PATH=$CLOUDFLARE_ORIGIN_PULL_CA_PATH
ORIGINENV
chmod 644 /etc/cloudgateway/origin.env

log "==> Step 11/13: Installing Caddy origin proxy"
if ! id -u caddy >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy
fi

chown -R caddy:caddy /var/lib/caddy /var/log/caddy
# Origin cert/key were written by the stub as root before the caddy user existed.
chown caddy:caddy "$ORIGIN_CERT_PATH" "$ORIGIN_KEY_PATH"

log "Downloading Cloudflare Origin Pull CA"
install -d -m 755 "$(dirname "$CLOUDFLARE_ORIGIN_PULL_CA_PATH")"
curl -fsSL "$CLOUDFLARE_ORIGIN_PULL_CA_URL" -o "$CLOUDFLARE_ORIGIN_PULL_CA_PATH"
chmod 644 "$CLOUDFLARE_ORIGIN_PULL_CA_PATH"

log "Downloading prebuilt Caddy binary"
CADDY_BINARY_ASSET="cloudgateway-caddy-linux-arm64"
CADDY_BINARY_URL="https://github.com/$SOURCE_REPO/releases/download/$CADDY_BINARY_TAG/$CADDY_BINARY_ASSET"
CADDY_WORK_DIR="$(mktemp -d /tmp/cloudgateway-caddy-XXXXXX)"
CADDY_BINARY_TMP="$CADDY_WORK_DIR/$CADDY_BINARY_ASSET"
curl --fail --silent --show-error --location --retry 5 --retry-delay 5 \
  "$CADDY_BINARY_URL" \
  -o "$CADDY_BINARY_TMP"

log "Verifying prebuilt Caddy binary"
printf '%s  %s\n' "$CADDY_BINARY_SHA256" "$CADDY_BINARY_TMP" | sha256sum -c -
install -m 755 "$CADDY_BINARY_TMP" /usr/local/bin/caddy

if ! /usr/local/bin/caddy list-modules | grep -Fq 'http.handlers.rate_limit'; then
  echo "Prebuilt Caddy binary does not include http.handlers.rate_limit" >&2
  exit 1
fi

log "Rendering and validating Caddyfile"
# Render the Caddyfile. envsubst gets an explicit variable list so Caddy's own
# {...} placeholders are left untouched.
envsubst '$API_HOSTNAME $DASHBOARD_CORS_ORIGIN $FASTAPI_PORT $CADDY_ACME_EMAIL $CLOUDFLARE_ORIGIN_PULL_CA_PATH $ORIGIN_CERT_PATH $ORIGIN_KEY_PATH $CADDY_API_RATE_LIMIT_EVENTS $CADDY_API_RATE_LIMIT_WINDOW' \
  < "$SRC_DIR/OCI/host/Caddyfile.template" > /etc/caddy/Caddyfile.rendered
if [[ -z "$CADDY_ACME_EMAIL" ]]; then
  grep -Ev '^[[:space:]]*email[[:space:]]*$' /etc/caddy/Caddyfile.rendered > /etc/caddy/Caddyfile
  rm -f /etc/caddy/Caddyfile.rendered
else
  mv /etc/caddy/Caddyfile.rendered /etc/caddy/Caddyfile
fi
chmod 644 /etc/caddy/Caddyfile
/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile

cat > /usr/local/sbin/cloudgateway-origin-firewall <<'FIREWALL'
#!/bin/bash
set -euo pipefail

iptables -N CLOUDGATEWAY_HTTP_ORIGIN 2>/dev/null || true
iptables -F CLOUDGATEWAY_HTTP_ORIGIN
if ! iptables -C INPUT -p tcp -m multiport --dports 80,443 -j CLOUDGATEWAY_HTTP_ORIGIN 2>/dev/null; then
  iptables -I INPUT 1 -p tcp -m multiport --dports 80,443 -j CLOUDGATEWAY_HTTP_ORIGIN
fi
FIREWALL

for cidr in $CLOUDFLARE_IPV4_RANGES; do
  echo "iptables -A CLOUDGATEWAY_HTTP_ORIGIN -s $cidr -j ACCEPT" >> /usr/local/sbin/cloudgateway-origin-firewall
done

cat >> /usr/local/sbin/cloudgateway-origin-firewall <<'FIREWALL'
iptables -A CLOUDGATEWAY_HTTP_ORIGIN -j DROP

ip6tables -N CLOUDGATEWAY_HTTP_ORIGIN 2>/dev/null || true
ip6tables -F CLOUDGATEWAY_HTTP_ORIGIN
if ! ip6tables -C INPUT -p tcp -m multiport --dports 80,443 -j CLOUDGATEWAY_HTTP_ORIGIN 2>/dev/null; then
  ip6tables -I INPUT 1 -p tcp -m multiport --dports 80,443 -j CLOUDGATEWAY_HTTP_ORIGIN
fi
FIREWALL

for cidr in $CLOUDFLARE_IPV6_RANGES; do
  echo "ip6tables -A CLOUDGATEWAY_HTTP_ORIGIN -s $cidr -j ACCEPT" >> /usr/local/sbin/cloudgateway-origin-firewall
done

cat >> /usr/local/sbin/cloudgateway-origin-firewall <<'FIREWALL'
ip6tables -A CLOUDGATEWAY_HTTP_ORIGIN -j DROP
FIREWALL

chmod 755 /usr/local/sbin/cloudgateway-origin-firewall

cat > /etc/systemd/system/cloudgateway-origin-firewall.service <<'UNIT'
[Unit]
Description=CloudGateway Cloudflare-only HTTP/HTTPS origin firewall
Wants=network-online.target
After=network-online.target
Before=caddy.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cloudgateway-origin-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/caddy.service <<'UNIT'
[Unit]
Description=Caddy origin proxy
Documentation=https://caddyserver.com/docs/
After=network-online.target cloudgateway-origin-firewall.service cloudgateway-api.service
Wants=network-online.target cloudgateway-origin-firewall.service

[Service]
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/lib/caddy /var/log/caddy

[Install]
WantedBy=multi-user.target
UNIT

/usr/local/sbin/cloudgateway-origin-firewall
systemctl daemon-reload
systemctl enable cloudgateway-origin-firewall
systemctl enable caddy

log "==> Step 12/13: Writing CloudGateway API and peer sync services"
cat > /etc/systemd/system/cloudgateway-api.service <<UNIT
[Unit]
Description=CloudGateway regional API
Wants=network-online.target
After=network-online.target wg-quick@$WG_INTERFACE.service
ConditionPathExists=/opt/cloudgateway/api/.venv/bin/uvicorn

[Service]
User=root
WorkingDirectory=/opt/cloudgateway/api
EnvironmentFile=/etc/cloudgateway/api.env
ExecStart=/opt/cloudgateway/api/.venv/bin/uvicorn src.main:app --host 127.0.0.1 --port \$CLOUDGATEWAY_API_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# Rebuilds the live wg peer set from Firebase on every boot. Retries via
# systemd until Firebase is reachable; an empty region syncs successfully.
cat > /etc/systemd/system/cloudgateway-sync-peers.service <<UNIT
[Unit]
Description=CloudGateway WireGuard peer sync from Firebase
Wants=network-online.target
After=network-online.target wg-quick@$WG_INTERFACE.service
ConditionPathExists=/opt/cloudgateway/api/.venv/bin/cloudgateway-sync-peers

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/cloudgateway/api.env
ExecStart=/opt/cloudgateway/api/.venv/bin/cloudgateway-sync-peers
Restart=on-failure
RestartSec=30
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable cloudgateway-api
systemctl enable cloudgateway-sync-peers

log "==> Step 13/13: Starting WireGuard, AdGuard Home, unbound, CloudGateway API, and Caddy"
# Start Wireguard
systemctl enable --now "wg-quick@$WG_INTERFACE"

for _ in $(seq 1 30); do
  if ip -4 addr show dev "$WG_INTERFACE" | grep -Fq "$WG_DNS_ADDRESS_V4/" && ip -6 addr show dev "$WG_INTERFACE" | grep -Fq "$WG_DNS_ADDRESS_V6/"; then
    break
  fi

  log "Waiting for $WG_INTERFACE to receive $WG_DNS_ADDRESS_V4 and $WG_DNS_ADDRESS_V6..."
  sleep 1
done

if ! ip -4 addr show dev "$WG_INTERFACE" | grep -Fq "$WG_DNS_ADDRESS_V4/"; then
  echo "$WG_INTERFACE never received $WG_DNS_ADDRESS_V4" >&2
  exit 1
fi

if ! ip -6 addr show dev "$WG_INTERFACE" | grep -Fq "$WG_DNS_ADDRESS_V6/"; then
  echo "$WG_INTERFACE never received $WG_DNS_ADDRESS_V6" >&2
  exit 1
fi

systemctl restart unbound
systemctl restart adguardhome
systemctl restart cloudgateway-api
systemctl restart cloudgateway-origin-firewall
systemctl restart caddy

# First sync. On a brand-new region (no region doc / no clients) this succeeds
# with an empty peer set; if Firebase credentials are not provisioned yet it
# fails here and systemd keeps retrying in the background.
systemctl start cloudgateway-sync-peers || true

# Status check (coalesce because fail would end the script when this is just a status check)
systemctl --no-pager --full status "wg-quick@$WG_INTERFACE" || true
wg show || true
systemctl --no-pager --full status adguardhome || true
systemctl --no-pager --full status unbound || true
systemctl --no-pager --full status cloudgateway-api || true
systemctl --no-pager --full status cloudgateway-sync-peers || true
systemctl --no-pager --full status cloudgateway-origin-firewall || true
systemctl --no-pager --full status caddy || true

# Self-register this region in Firestore (IP, public key, endpoint), enabling it only once
# the full Cloudflare path validates (proxy + AOP + firewall + Caddy). DNS records are managed
# by Terraform, not here. Idempotent: re-run `cloudgateway-register-region` if Firebase or the
# edge was not ready at boot.
log "Waiting for the CloudGateway API to answer locally before registering the region..."
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$FASTAPI_PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

log "==> Registering region in Firestore"
# Run via systemd-run so api.env is parsed by systemd (the same parser the
# long-running services use), not the shell. This keeps a single env-file format
# and avoids shell metacharacter pitfalls in quoted values. --wait propagates
# the register exit code; --collect cleans up the transient unit.
if systemd-run --quiet --pipe --wait --collect \
  --property=WorkingDirectory=/opt/cloudgateway/api \
  --property=EnvironmentFile=/etc/cloudgateway/api.env \
  /opt/cloudgateway/api/.venv/bin/cloudgateway-register-region; then
  log "Region registered"
else
  log "WARN: region registration failed; re-run 'cloudgateway-register-region' once Firebase is reachable" >&2
fi

log "WireGuard public key:"
cat "/etc/wireguard/$WG_INTERFACE.publickey"
log "==> Bootstrap complete"
