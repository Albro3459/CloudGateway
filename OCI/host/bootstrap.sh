#!/bin/bash

# Full regional host bootstrap. Fetched from GitHub and run by the cloud-init
# stub (OCI/terraform/stub-cloud-init.sh.tftpl), which has already written
# /etc/cloudlaunch/bootstrap.env, /etc/cloudlaunch/wireguard-server.key, the
# optional Firebase credential file, and extracted this repo's API/ and
# OCI/host/ into /opt/cloudlaunch/src. Runs as root with output already
# redirected to /var/log/wireguard-bootstrap.log by the stub.

set -euxo pipefail

set -a
source /etc/cloudlaunch/bootstrap.env
set +a

export DEBIAN_FRONTEND=noninteractive

SRC_DIR="/opt/cloudlaunch/src"

wait_for_apt() {
  while ps -eo comm= | grep -Eq '^(apt|apt-get|dpkg)$'; do
    echo "Waiting for other apt/dpkg process to finish..."
    sleep 5
  done
}

PRIMARY_IFACE="$(ip route show default | awk '/default/ { print $5; exit }')"

if [[ -z "$PRIMARY_IFACE" ]]; then
  echo "Unable to determine the primary network interface" >&2
  exit 1
fi

echo "==> Step 1/12: Installing required packages"
wait_for_apt
apt-get update
wait_for_apt
apt-get install -y wireguard iptables fail2ban unbound dns-root-data python3-venv python3-pip ca-certificates curl golang-go gettext-base
systemctl stop unbound || true

echo "==> Step 2/12: Preparing configuration directories"
# Essentially mkdir -p /etc/wireguard && chmod 700 /etc/wireguard
install -d -m 700 /etc/wireguard
install -d -m 755 /etc/sysctl.d
install -d -m 755 /etc/ssh/sshd_config.d
install -d -m 755 /etc/fail2ban/jail.d
install -d -m 755 /etc/unbound/unbound.conf.d
install -d -o unbound -g unbound -m 750 /var/lib/unbound
install -d -m 700 /etc/cloudlaunch
install -d -m 755 /opt/cloudlaunch/api
install -d -m 755 /etc/caddy
install -d -m 755 /var/log/caddy
install -d -m 755 /var/lib/caddy

echo "==> Step 3/12: Hardening SSH access"
SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%F_%H-%M-%S)"
cp /etc/ssh/sshd_config "$SSHD_BACKUP"
install -d -m 755 /run/sshd

cat > /etc/ssh/sshd_config.d/99-cloudlaunch-hardening.conf <<'SSHCONF'
PasswordAuthentication no
PermitRootLogin no
SSHCONF

sshd -t
systemctl reload-or-restart ssh || systemctl reload-or-restart sshd || systemctl start ssh
sshd -T | grep -E '^(passwordauthentication|permitrootlogin) ' || true

echo "==> Step 4/12: Configuring fail2ban"
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

echo "==> Step 5/12: Enabling IP forwarding"
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

echo "==> Step 6/12: Writing WireGuard configuration"
# Interface-only config. Peers are never written to this or any other file:
# Firebase is the single source of truth and cloudlaunch-sync-peers rebuilds
# the live peer set from it on every boot.
# xtrace stays off while the private key is in play.
set +x
cat > "/etc/wireguard/$WG_INTERFACE.conf" <<WGCONF
[Interface]
Address = $WG_ADDRESS_V4, $WG_ADDRESS_V6
ListenPort = $WG_LISTEN_PORT
PrivateKey = $(cat /etc/cloudlaunch/wireguard-server.key)

# PostUp
# IPv4
PostUp = iptables -I FORWARD 1 -i $WG_INTERFACE -j ACCEPT
PostUp = iptables -I FORWARD 2 -o $WG_INTERFACE -j ACCEPT
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

echo "==> Step 7/12: Writing unbound configuration"
if command -v unbound-anchor >/dev/null 2>&1; then
  if ! unbound-anchor -a /var/lib/unbound/root.key; then
    echo "unbound-anchor could not refresh the DNSSEC trust anchor; continuing without DNSSEC validation"
  fi
fi

if [[ -f /var/lib/unbound/root.key ]]; then
  chown unbound:unbound /var/lib/unbound/root.key
  chmod 640 /var/lib/unbound/root.key
fi

cat > /etc/unbound/unbound.conf.d/cloudlaunch-wireguard.conf <<UNBOUNDCONF
server:
  interface: $WG_DNS_ADDRESS_V4
  interface: $WG_DNS_ADDRESS_V6
  access-control: 127.0.0.0/8 allow
  access-control: ::1 allow
  access-control: $WG_NETWORK_V4 allow
  access-control: $WG_NETWORK_V6 allow
  do-ip4: yes
  do-ip6: yes
  do-udp: yes
  do-tcp: yes
  prefer-ip6: yes
  root-hints: "/usr/share/dns/root.hints"
  qname-minimisation: yes
  hide-identity: yes
  hide-version: yes
UNBOUNDCONF

unbound-checkconf
systemctl enable unbound

echo "==> Step 8/12: Installing CloudLaunch API package"
cp -R "$SRC_DIR/API/." /opt/cloudlaunch/api/

python3 -m venv /opt/cloudlaunch/api/.venv
/opt/cloudlaunch/api/.venv/bin/pip install --upgrade pip
/opt/cloudlaunch/api/.venv/bin/pip install /opt/cloudlaunch/api

cat > /usr/local/sbin/cloudlaunch-install-api <<'INSTALLAPI'
#!/bin/bash
set -euo pipefail

source /etc/cloudlaunch/bootstrap.env
REF="${1:-$SOURCE_REF}"
WORK_DIR="$(mktemp -d /tmp/cloudlaunch-api-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Fetching API source from $SOURCE_REPO at $REF"
curl --fail --silent --show-error --location --retry 5 --retry-delay 5 \
  "https://codeload.github.com/$SOURCE_REPO/tar.gz/$REF" -o "$WORK_DIR/src.tar.gz"
tar -xzf "$WORK_DIR/src.tar.gz" --strip-components=1 -C "$WORK_DIR" --wildcards '*/API'

if [[ ! -f "$WORK_DIR/API/pyproject.toml" ]]; then
  echo "Downloaded ref $REF does not contain API/pyproject.toml" >&2
  exit 1
fi

cp -R "$WORK_DIR/API/." /opt/cloudlaunch/api/
/opt/cloudlaunch/api/.venv/bin/pip install /opt/cloudlaunch/api
systemctl restart cloudlaunch-api
systemctl --no-pager --full status cloudlaunch-api || true
INSTALLAPI
chmod 755 /usr/local/sbin/cloudlaunch-install-api

echo "==> Step 9/12: Writing CloudLaunch API environment"
if [[ ! -f "$FIREBASE_CREDENTIALS_FILE" ]]; then
  echo "No Firebase credential file at $FIREBASE_CREDENTIALS_FILE; provision it manually before using the API"
fi

SERVER_PUBLIC_KEY="$(cat "/etc/wireguard/$WG_INTERFACE.publickey")"
cat > /etc/cloudlaunch/api.env <<APIENV
CLOUDLAUNCH_REGION_ID=$REGION_ID
CLOUDLAUNCH_API_PORT=$FASTAPI_PORT
CLOUDLAUNCH_FIREBASE_CREDENTIALS_FILE=$FIREBASE_CREDENTIALS_FILE
CLOUDLAUNCH_WG_INTERFACE=$WG_INTERFACE
CLOUDLAUNCH_WG_SERVER_PUBLIC_KEY=$SERVER_PUBLIC_KEY
CLOUDLAUNCH_WG_ENDPOINT_HOSTNAME=$WG_ENDPOINT_HOSTNAME
CLOUDLAUNCH_WG_PORT=$WG_LISTEN_PORT
CLOUDLAUNCH_WG_DNS_IPV4=$WG_DNS_ADDRESS_V4
CLOUDLAUNCH_WG_DNS_IPV6=$WG_DNS_ADDRESS_V6
CLOUDLAUNCH_WG_TUNNEL_IPV4_CIDR=$WG_NETWORK_V4
CLOUDLAUNCH_WG_TUNNEL_IPV6_CIDR=$WG_NETWORK_V6
APIENV
chmod 600 /etc/cloudlaunch/api.env

cat > /etc/cloudlaunch/origin.env <<ORIGINENV
CLOUDLAUNCH_API_HOSTNAME=$API_HOSTNAME
CLOUDLAUNCH_DASHBOARD_CORS_ORIGIN=$DASHBOARD_CORS_ORIGIN
CLOUDLAUNCH_CADDY_ACME_EMAIL=$CADDY_ACME_EMAIL
CLOUDLAUNCH_CLOUDFLARE_ORIGIN_PULL_CA_PATH=$CLOUDFLARE_ORIGIN_PULL_CA_PATH
ORIGINENV
chmod 644 /etc/cloudlaunch/origin.env

echo "==> Step 10/12: Installing Caddy origin proxy"
if ! id -u caddy >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy
fi

chown -R caddy:caddy /var/lib/caddy /var/log/caddy
install -d -m 755 "$(dirname "$CLOUDFLARE_ORIGIN_PULL_CA_PATH")"
curl -fsSL "$CLOUDFLARE_ORIGIN_PULL_CA_URL" -o "$CLOUDFLARE_ORIGIN_PULL_CA_PATH"
chmod 644 "$CLOUDFLARE_ORIGIN_PULL_CA_PATH"

GOBIN=/usr/local/bin go install "github.com/caddyserver/xcaddy/cmd/xcaddy@$XCADDY_VERSION"
/usr/local/bin/xcaddy build "$CADDY_VERSION" --with "$CADDY_RATE_LIMIT_MODULE" --output /usr/local/bin/caddy
chmod 755 /usr/local/bin/caddy

# Render the Caddyfile. envsubst gets an explicit variable list so Caddy's own
# {...} placeholders are left untouched.
envsubst '$API_HOSTNAME $DASHBOARD_CORS_ORIGIN $FASTAPI_PORT $CADDY_ACME_EMAIL $CLOUDFLARE_ORIGIN_PULL_CA_PATH $CADDY_API_RATE_LIMIT_EVENTS $CADDY_API_RATE_LIMIT_WINDOW' \
  < "$SRC_DIR/OCI/host/Caddyfile.template" > /etc/caddy/Caddyfile.rendered
if [[ -z "$CADDY_ACME_EMAIL" ]]; then
  grep -Ev '^[[:space:]]*email[[:space:]]*$' /etc/caddy/Caddyfile.rendered > /etc/caddy/Caddyfile
  rm -f /etc/caddy/Caddyfile.rendered
else
  mv /etc/caddy/Caddyfile.rendered /etc/caddy/Caddyfile
fi
chmod 644 /etc/caddy/Caddyfile

cat > /usr/local/sbin/cloudlaunch-origin-firewall <<'FIREWALL'
#!/bin/bash
set -euo pipefail

iptables -N CLOUDLAUNCH_HTTP_ORIGIN 2>/dev/null || true
iptables -F CLOUDLAUNCH_HTTP_ORIGIN
if ! iptables -C INPUT -p tcp -m multiport --dports 80,443 -j CLOUDLAUNCH_HTTP_ORIGIN 2>/dev/null; then
  iptables -I INPUT 1 -p tcp -m multiport --dports 80,443 -j CLOUDLAUNCH_HTTP_ORIGIN
fi
FIREWALL

for cidr in $CLOUDFLARE_IPV4_RANGES; do
  echo "iptables -A CLOUDLAUNCH_HTTP_ORIGIN -s $cidr -j ACCEPT" >> /usr/local/sbin/cloudlaunch-origin-firewall
done

cat >> /usr/local/sbin/cloudlaunch-origin-firewall <<'FIREWALL'
iptables -A CLOUDLAUNCH_HTTP_ORIGIN -j DROP

ip6tables -N CLOUDLAUNCH_HTTP_ORIGIN 2>/dev/null || true
ip6tables -F CLOUDLAUNCH_HTTP_ORIGIN
if ! ip6tables -C INPUT -p tcp -m multiport --dports 80,443 -j CLOUDLAUNCH_HTTP_ORIGIN 2>/dev/null; then
  ip6tables -I INPUT 1 -p tcp -m multiport --dports 80,443 -j CLOUDLAUNCH_HTTP_ORIGIN
fi
FIREWALL

for cidr in $CLOUDFLARE_IPV6_RANGES; do
  echo "ip6tables -A CLOUDLAUNCH_HTTP_ORIGIN -s $cidr -j ACCEPT" >> /usr/local/sbin/cloudlaunch-origin-firewall
done

cat >> /usr/local/sbin/cloudlaunch-origin-firewall <<'FIREWALL'
ip6tables -A CLOUDLAUNCH_HTTP_ORIGIN -j DROP
FIREWALL

chmod 755 /usr/local/sbin/cloudlaunch-origin-firewall

cat > /etc/systemd/system/cloudlaunch-origin-firewall.service <<'UNIT'
[Unit]
Description=CloudLaunch Cloudflare-only HTTP/HTTPS origin firewall
Wants=network-online.target
After=network-online.target
Before=caddy.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cloudlaunch-origin-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/caddy.service <<'UNIT'
[Unit]
Description=Caddy origin proxy
Documentation=https://caddyserver.com/docs/
After=network-online.target cloudlaunch-origin-firewall.service cloudlaunch-api.service
Wants=network-online.target cloudlaunch-origin-firewall.service

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

/usr/local/sbin/cloudlaunch-origin-firewall
/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable cloudlaunch-origin-firewall
systemctl enable caddy

echo "==> Step 11/12: Writing CloudLaunch API and peer sync services"
cat > /etc/systemd/system/cloudlaunch-api.service <<UNIT
[Unit]
Description=CloudLaunch regional API
Wants=network-online.target
After=network-online.target wg-quick@$WG_INTERFACE.service
ConditionPathExists=/opt/cloudlaunch/api/.venv/bin/uvicorn

[Service]
User=root
WorkingDirectory=/opt/cloudlaunch/api
EnvironmentFile=/etc/cloudlaunch/api.env
ExecStart=/opt/cloudlaunch/api/.venv/bin/uvicorn cloudlaunch_api.main:app --host 127.0.0.1 --port \$CLOUDLAUNCH_API_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# Rebuilds the live wg peer set from Firebase on every boot. Retries via
# systemd until Firebase is reachable; an empty region syncs successfully.
cat > /etc/systemd/system/cloudlaunch-sync-peers.service <<UNIT
[Unit]
Description=CloudLaunch WireGuard peer sync from Firebase
Wants=network-online.target
After=network-online.target wg-quick@$WG_INTERFACE.service
ConditionPathExists=/opt/cloudlaunch/api/.venv/bin/cloudlaunch-sync-peers

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/cloudlaunch/api.env
ExecStart=/opt/cloudlaunch/api/.venv/bin/cloudlaunch-sync-peers
Restart=on-failure
RestartSec=30
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable cloudlaunch-api
systemctl enable cloudlaunch-sync-peers

echo "==> Step 12/12: Starting WireGuard, unbound, CloudLaunch API, and Caddy"
# Start Wireguard
systemctl enable --now "wg-quick@$WG_INTERFACE"

for _ in $(seq 1 30); do
  if ip -4 addr show dev "$WG_INTERFACE" | grep -Fq "$WG_DNS_ADDRESS_V4/" && ip -6 addr show dev "$WG_INTERFACE" | grep -Fq "$WG_DNS_ADDRESS_V6/"; then
    break
  fi

  echo "Waiting for $WG_INTERFACE to receive $WG_DNS_ADDRESS_V4 and $WG_DNS_ADDRESS_V6..."
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
systemctl restart cloudlaunch-api
systemctl restart cloudlaunch-origin-firewall
systemctl restart caddy

# First sync. On a brand-new region (no region doc / no clients) this succeeds
# with an empty peer set; if Firebase credentials are not provisioned yet it
# fails here and systemd keeps retrying in the background.
systemctl start cloudlaunch-sync-peers || true

# Status check (coalesce because fail would end the script when this is just a status check)
systemctl --no-pager --full status "wg-quick@$WG_INTERFACE" || true
wg show || true
systemctl --no-pager --full status unbound || true
systemctl --no-pager --full status cloudlaunch-api || true
systemctl --no-pager --full status cloudlaunch-sync-peers || true
systemctl --no-pager --full status cloudlaunch-origin-firewall || true
systemctl --no-pager --full status caddy || true

echo "WireGuard public key:"
cat "/etc/wireguard/$WG_INTERFACE.publickey"
echo "==> Bootstrap complete"
