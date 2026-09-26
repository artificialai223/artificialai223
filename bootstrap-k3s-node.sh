#!/usr/bin/env bash
# bootstrap-k3s-node.sh
# Harden a fresh Ubuntu host, join it to Tailscale, and create/join a K3s cluster.
# Designed for hosts whose management and K3s node-to-node traffic use tailscale0.
# Public web ingress is expected to arrive through Cloudflare Tunnel, not ports 80/443.

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly SCRIPT_VERSION="1.2.2"
readonly SCRIPT_GIT_COMMIT="${BOOTSTRAP_GIT_COMMIT:-unpublished}"
readonly SSHID_URL="https://sshid.io/artificialai"
readonly SSHID_SYNC_INTERVAL="6h"
readonly POD_CIDR="10.42.0.0/16"
readonly SERVICE_CIDR="10.43.0.0/16"
readonly TS_UDP_PORT="41641"
readonly LOG_FILE="/var/log/k3s-node-bootstrap.log"

exec > >(tee -a "$LOG_FILE") 2>&1

trap 'rc=$?; echo; echo "[ERROR] Bootstrap failed at line $LINENO (exit $rc). Review $LOG_FILE" >&2; exit $rc' ERR

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script as root: sudo bash $0"
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Unable to identify the operating system."
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "This bootstrap is intentionally limited to Ubuntu. Detected: ${PRETTY_NAME:-unknown}"
  exit 1
fi

case "${VERSION_ID:-}" in
  22.04|24.04|26.04) ;;
  *)
    echo "WARNING: Ubuntu ${VERSION_ID:-unknown} has not been explicitly validated by this script."
    read -r -p "Continue anyway? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 1
    ;;
esac

if systemctl list-unit-files 2>/dev/null | grep -qE '^k3s(-agent)?\.service'; then
  echo "K3s appears to be installed already. This script will not overwrite an existing cluster node."
  exit 1
fi

line() { printf '%*s\n' 72 '' | tr ' ' '-'; }
section() { echo; line; echo " $*"; line; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

valid_hostname() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

valid_ipv4() {
  local ip=$1 IFS=. octets
  read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  local o
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1
  done
}

prompt_nonempty() {
  local prompt=$1 default=${2:-} value
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]: " value
      value=${value:-$default}
    else
      read -r -p "$prompt: " value
    fi
    [[ -n "$value" ]] && { printf '%s' "$value"; return; }
    echo "A value is required." >&2
  done
}

section "K3s node bootstrap v${SCRIPT_VERSION}"
echo "Build commit: ${SCRIPT_GIT_COMMIT}"
echo "This will:"
echo "  - apply host hardening suitable for a Kubernetes node"
echo "  - install and automatically refresh your SSHID public keys"
echo "  - disable password/root SSH"
echo "  - install and authenticate Tailscale"
echo "  - make Tailscale the K3s node-to-node underlay"
echo "  - block unsolicited public inbound traffic except Tailscale UDP ${TS_UDP_PORT}"
echo "  - install K3s as a new HA-capable server, joining server, or worker"
echo "  - install Longhorn host prerequisites"
echo "  - install a dynamic node MOTD"
echo
warn "After the firewall is enabled, ordinary public-IP SSH will stop accepting new connections."

DEFAULT_NODE_NAME=$(hostname -s 2>/dev/null || true)
[[ "$DEFAULT_NODE_NAME" =~ ^localhost$|^ubuntu$|^server$|^$ ]] && DEFAULT_NODE_NAME="k3s-node"

while true; do
  NODE_NAME=$(prompt_nonempty "Node/device name" "$DEFAULT_NODE_NAME")
  if [[ "$NODE_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    break
  fi
  echo "Use a DNS-safe hostname containing only letters, numbers and hyphens." >&2
done
NODE_NAME=${NODE_NAME,,}

DEFAULT_ADMIN="${SUDO_USER:-}"
if [[ -z "$DEFAULT_ADMIN" || "$DEFAULT_ADMIN" == "root" ]]; then
  if id ubuntu &>/dev/null; then
    DEFAULT_ADMIN="ubuntu"
  else
    DEFAULT_ADMIN="clusteradmin"
  fi
fi
ADMIN_USER=$(prompt_nonempty "Administrative SSH user" "$DEFAULT_ADMIN")

if [[ ! "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  fail "Invalid Linux username: $ADMIN_USER"
fi
[[ "$ADMIN_USER" != "root" ]] || fail "Choose a non-root administrative SSH user; root SSH is disabled by this bootstrap."

if id "$ADMIN_USER" &>/dev/null; then
  info "Using existing user $ADMIN_USER"
else
  info "Creating locked-password administrator $ADMIN_USER"
  useradd --create-home --shell /bin/bash "$ADMIN_USER"
  passwd -l "$ADMIN_USER" >/dev/null
fi
usermod -aG sudo "$ADMIN_USER"

cat > "/etc/sudoers.d/90-${ADMIN_USER}-bootstrap-admin" <<EOF_SUDO
${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD: ALL
EOF_SUDO
chmod 0440 "/etc/sudoers.d/90-${ADMIN_USER}-bootstrap-admin"
visudo -cf "/etc/sudoers.d/90-${ADMIN_USER}-bootstrap-admin" >/dev/null

section "Hostname"
hostnamectl set-hostname "$NODE_NAME"
cat > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg <<'EOF_CLOUD'
preserve_hostname: true
EOF_CLOUD

if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
  sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 ${NODE_NAME}/" /etc/hosts
else
  printf '127.0.1.1 %s\n' "$NODE_NAME" >> /etc/hosts
fi

section "Base packages and security updates"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y full-upgrade
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq openssl openssh-server sudo ufw fail2ban \
  unattended-upgrades auditd apparmor apparmor-utils chrony \
  open-iscsi nfs-common cryptsetup dmsetup iproute2 iputils-ping \
  dnsutils lsof socat conntrack ethtool

systemctl enable --now ssh
systemctl enable --now apparmor || true
systemctl enable --now auditd || true
systemctl enable --now chrony || true
systemctl enable --now iscsid

# Daily security updates. Avoid uncontrolled reboots; Kubernetes-aware reboot
# orchestration (for example kured) can be added later at cluster level.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF_UPDATES'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF_UPDATES
cat > /etc/apt/apt.conf.d/52k3s-bootstrap-unattended <<'EOF_UNATTENDED'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
EOF_UNATTENDED
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

section "SSH ID public key sync"
ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
SCRIPT_SHA256=$(sha256sum "$0" | awk '{print $1}')
[[ "$SCRIPT_GIT_COMMIT" =~ ^[A-Za-z0-9._+-]{1,80}$ ]] || fail "BOOTSTRAP_GIT_COMMIT contains unsupported characters."

# Persist non-secret bootstrap metadata for MOTD/support tooling.
# BOOTSTRAP_GIT_COMMIT can be exported by an immutable GitHub release/commit
# wrapper before invoking this script; otherwise the build is marked unpublished.
cat > /etc/k3s-node-bootstrap.conf <<EOF_BOOTSTRAP_META
BOOTSTRAP_VERSION='${SCRIPT_VERSION}'
BOOTSTRAP_GIT_COMMIT='${SCRIPT_GIT_COMMIT}'
BOOTSTRAP_SCRIPT_SHA256='${SCRIPT_SHA256}'
BOOTSTRAP_ADMIN_USER='${ADMIN_USER}'
BOOTSTRAP_ADMIN_HOME='${ADMIN_HOME}'
EOF_BOOTSTRAP_META
chmod 0644 /etc/k3s-node-bootstrap.conf
install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME/.ssh"
touch "$ADMIN_HOME/.ssh/authorized_keys"
chown "$ADMIN_USER:$ADMIN_USER" "$ADMIN_HOME/.ssh/authorized_keys"
chmod 0600 "$ADMIN_HOME/.ssh/authorized_keys"

# Keep SSHID-managed keys separate from manually installed break-glass keys.
# OpenSSH is configured below to accept both files. The sync is atomic and
# keeps the last-known-good SSHID file if the remote service is unavailable or
# returns invalid/empty content.
cat > /usr/local/sbin/sync-sshid-keys <<'EOF_SSHID_SYNC'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly SSHID_URL="https://sshid.io/artificialai"
readonly SSH_DIR="${HOME}/.ssh"
readonly TARGET="${SSH_DIR}/authorized_keys_sshid"
readonly LAST_SUCCESS="${SSH_DIR}/.sshid-last-success"
readonly CHANGE_LOG="${SSH_DIR}/.sshid-key-changes.log"
readonly KEY_RE='^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+'
readonly MAX_CHANGE_LOG_LINES=200

install -d -m 0700 "$SSH_DIR"
RAW=$(mktemp "${SSH_DIR}/.sshid-raw.XXXXXX")
CLEAN=$(mktemp "${SSH_DIR}/.sshid-clean.XXXXXX")
OLD_IDS=$(mktemp "${SSH_DIR}/.sshid-old.XXXXXX")
NEW_IDS=$(mktemp "${SSH_DIR}/.sshid-new.XXXXXX")
DIFF_IDS=$(mktemp "${SSH_DIR}/.sshid-diff.XXXXXX")
FP_FILE=$(mktemp "${SSH_DIR}/.sshid-fp.XXXXXX")
LOG_TMP=$(mktemp "${SSH_DIR}/.sshid-log.XXXXXX")
trap 'rm -f "$RAW" "$CLEAN" "$OLD_IDS" "$NEW_IDS" "$DIFF_IDS" "$FP_FILE" "$LOG_TMP"' EXIT

curl --proto '=https' --tlsv1.2 -fsS \
  --connect-timeout 10 --max-time 30 \
  "$SSHID_URL" -o "$RAW"

# Normalize CRLF, ignore blank/comment-only lines, and reject the entire update
# if any returned key line is not a recognizable OpenSSH public-key format.
sed -i 's/\r$//' "$RAW"
if ! awk '
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*#/ { next }
  $1 ~ /^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)$/ { next }
  { exit 1 }
' "$RAW"; then
  echo "SSHID sync refused: response contained an unrecognized line." >&2
  exit 1
fi

awk '
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*#/ { next }
  !seen[$0]++ { print }
' "$RAW" > "$CLEAN"

KEY_COUNT=$(grep -Ec "$KEY_RE" "$CLEAN" || true)
if [[ "$KEY_COUNT" -lt 1 ]]; then
  echo "SSHID sync refused: no valid SSH public keys were returned." >&2
  exit 1
fi

# Compare key identity (algorithm + key blob), intentionally ignoring comments.
if [[ -s "$TARGET" ]]; then
  awk 'NF >= 2 { print $1 " " $2 }' "$TARGET" | sort -u > "$OLD_IDS"
else
  : > "$OLD_IDS"
fi
awk 'NF >= 2 { print $1 " " $2 }' "$CLEAN" | sort -u > "$NEW_IDS"

fingerprint_identity() {
  local identity=$1 fp keytype
  printf '%s\n' "$identity" > "$FP_FILE"
  fp=$(ssh-keygen -lf "$FP_FILE" -E sha256 2>/dev/null | awk '{print $2}' | head -n1 || true)
  keytype=${identity%% *}
  printf '%s %s' "${fp:-SHA256:unavailable}" "$keytype"
}

log_changes() {
  local action=$1 source_file=$2 identity details
  while IFS= read -r identity; do
    [[ -n "$identity" ]] || continue
    details=$(fingerprint_identity "$identity")
    printf '%s %-7s %s\n' "$(date --iso-8601=seconds)" "$action" "$details" >> "$CHANGE_LOG"
    echo "SSHID key ${action,,}: ${details}"
  done < "$source_file"
}

# comm requires sorted inputs; both identity files are sorted above.
comm -13 "$OLD_IDS" "$NEW_IDS" > "$DIFF_IDS"
log_changes "ADDED" "$DIFF_IDS"
comm -23 "$OLD_IDS" "$NEW_IDS" > "$DIFF_IDS"
log_changes "REMOVED" "$DIFF_IDS"

# Keep a useful local audit trail without allowing this tiny state file to grow
# forever. The MOTD displays only the most recent 10 entries.
if [[ -f "$CHANGE_LOG" ]]; then
  tail -n "$MAX_CHANGE_LOG_LINES" "$CHANGE_LOG" > "$LOG_TMP"
  mv -f "$LOG_TMP" "$CHANGE_LOG"
  chmod 0600 "$CHANGE_LOG"
fi

chmod 0600 "$CLEAN"
# Same-directory rename makes the replacement atomic: sshd sees either the old
# complete file or the new complete file, never a partially downloaded file.
mv -f "$CLEAN" "$TARGET"
printf '%s\n' "$(date --iso-8601=seconds)" > "$LAST_SUCCESS"
chmod 0600 "$TARGET" "$LAST_SUCCESS"
echo "SSHID sync successful: installed ${KEY_COUNT} key(s) from ${SSHID_URL}."
EOF_SSHID_SYNC
chmod 0755 /usr/local/sbin/sync-sshid-keys

cat > /etc/systemd/system/sshid-key-sync.service <<EOF_SSHID_SERVICE
[Unit]
Description=Refresh SSH public keys from SSHID
Documentation=https://sshid.io/artificialai
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=${ADMIN_USER}
Group=${ADMIN_USER}
Environment=HOME=${ADMIN_HOME}
ExecStart=/usr/local/sbin/sync-sshid-keys
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${ADMIN_HOME}/.ssh
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=
AmbientCapabilities=
UMask=0077
EOF_SSHID_SERVICE

cat > /etc/systemd/system/sshid-key-sync.timer <<EOF_SSHID_TIMER
[Unit]
Description=Periodically refresh SSHID public keys

[Timer]
OnBootSec=2min
OnUnitActiveSec=${SSHID_SYNC_INTERVAL}
RandomizedDelaySec=10min
Persistent=true
Unit=sshid-key-sync.service

[Install]
WantedBy=timers.target
EOF_SSHID_TIMER

systemctl daemon-reload
# Populate the key file before password/root SSH is disabled. If this first
# fetch fails, abort now so the machine cannot be accidentally locked out.
systemctl start sshid-key-sync.service
systemctl enable --now sshid-key-sync.timer

SSHID_KEY_FILE="$ADMIN_HOME/.ssh/authorized_keys_sshid"
[[ -s "$SSHID_KEY_FILE" ]] || fail "SSHID key sync completed without creating $SSHID_KEY_FILE"
KEY_COUNT=$(grep -Ec '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+' "$SSHID_KEY_FILE" || true)
info "Installed $KEY_COUNT SSHID public key(s) for $ADMIN_USER from $SSHID_URL"
info "SSHID keys will refresh every $SSHID_SYNC_INTERVAL; failed refreshes keep the last-known-good keys."

section "SSH hardening"
cat > /etc/ssh/sshd_config.d/99-k3s-node-hardening.conf <<EOF_SSH
# Managed by bootstrap-k3s-node.sh
Protocol 2
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys_sshid
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
X11Forwarding no
AllowAgentForwarding no
PermitUserEnvironment no
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
UsePAM yes
AllowUsers ${ADMIN_USER}
EOF_SSH
sshd -t
systemctl reload ssh

# Root SSH is disabled, but we intentionally preserve any provider-console root
# credential as a break-glass path if Tailscale is ever unavailable.

section "Kernel and host hardening"
cat > /etc/sysctl.d/99-k3s-node-hardening.conf <<'EOF_SYSCTL'
# Required/expected for Kubernetes networking.
net.ipv4.ip_forward = 1

# Network hardening that is compatible with a multi-interface Kubernetes host.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.tcp_syncookies = 1
# Loose reverse-path filtering avoids breaking overlay/VPN traffic.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Kernel information exposure / common local hardening.
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
EOF_SYSCTL
sysctl --system >/dev/null

cat > /etc/security/limits.d/99-k3s-node-hardening.conf <<'EOF_LIMITS'
* hard core 0
root hard core 0
EOF_LIMITS

cat > /etc/profile.d/99-secure-umask.sh <<'EOF_UMASK'
umask 027
EOF_UMASK
chmod 0644 /etc/profile.d/99-secure-umask.sh

# Kubernetes is still safest with swap disabled unless kubelet swap support is
# deliberately configured.
swapoff -a || true
if grep -Eq '^[^#].+[[:space:]]swap[[:space:]]' /etc/fstab; then
  cp -a /etc/fstab "/etc/fstab.pre-k3s.$(date +%Y%m%d%H%M%S)"
  sed -i -E '/^[^#].+[[:space:]]swap[[:space:]]/ s/^/# disabled-by-k3s-bootstrap: /' /etc/fstab
fi

section "Fail2ban"
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF_F2B'
[sshd]
enabled = true
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
EOF_F2B
systemctl enable --now fail2ban
systemctl restart fail2ban

section "Tailscale"
CODENAME="${VERSION_CODENAME:-}"
[[ -n "$CODENAME" ]] || fail "Unable to determine Ubuntu codename."
install -d -m 0755 /usr/share/keyrings
# The bootstrap uses umask 027 globally. APT drops privileges to the _apt user
# while verifying repositories, so repository keyrings and source-list files
# must be world-readable. Download to temporary files, validate they are
# non-empty, then install explicitly with mode 0644.
TS_KEY_TMP=$(mktemp)
TS_LIST_TMP=$(mktemp)
trap 'rm -f "${TS_KEY_TMP:-}" "${TS_LIST_TMP:-}"' RETURN

curl --proto '=https' --tlsv1.2 -fsSL \
  "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" \
  -o "$TS_KEY_TMP"
curl --proto '=https' --tlsv1.2 -fsSL \
  "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.tailscale-keyring.list" \
  -o "$TS_LIST_TMP"

[[ -s "$TS_KEY_TMP" ]] || fail "Downloaded Tailscale APT keyring is empty."
[[ -s "$TS_LIST_TMP" ]] || fail "Downloaded Tailscale APT source list is empty."

install -o root -g root -m 0644 "$TS_KEY_TMP" /usr/share/keyrings/tailscale-archive-keyring.gpg
install -o root -g root -m 0644 "$TS_LIST_TMP" /etc/apt/sources.list.d/tailscale.list
rm -f "$TS_KEY_TMP" "$TS_LIST_TMP"
trap - RETURN

apt-get update
apt-get install -y tailscale
systemctl enable --now tailscaled

read -r -s -p "Tailscale auth key (leave blank for browser/device authentication): " TS_AUTH_KEY
echo
if [[ -n "$TS_AUTH_KEY" ]]; then
  tailscale up --auth-key="$TS_AUTH_KEY" --hostname="$NODE_NAME" --accept-dns=true
  unset TS_AUTH_KEY
else
  info "Tailscale will print an authentication URL if this machine is not already authorised."
  tailscale up --hostname="$NODE_NAME" --accept-dns=true
fi

# Keep the Linux client on the stable release line automatically.
tailscale set --auto-update=true >/dev/null 2>&1 || true

info "Waiting for a Tailscale IPv4 address..."
TS_IP=""
for _ in $(seq 1 60); do
  TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  [[ -n "$TS_IP" ]] && break
  sleep 2
done
[[ -n "$TS_IP" ]] || fail "Tailscale did not become connected within the expected time."
info "Tailscale IPv4: $TS_IP"

read -r -p "K3s internal/node IP [$TS_IP]: " NODE_IP
NODE_IP=${NODE_IP:-$TS_IP}
valid_ipv4 "$NODE_IP" || fail "Invalid IPv4 address: $NODE_IP"
ip -4 addr show dev tailscale0 | grep -Fq " $NODE_IP/" || \
  fail "The K3s internal IP must be assigned to tailscale0. This design uses Tailscale as the private underlay."

section "Firewall"
# K3s documents UFW exceptions for the pod/service CIDRs. Tailscale is the only
# trusted host-management / inter-node interface. Public 80/443/22 remain closed.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw allow in on tailscale0 comment 'Trusted Tailscale underlay'
ufw allow "${TS_UDP_PORT}/udp" comment 'Tailscale direct WireGuard transport'
ufw allow from "$POD_CIDR" to any comment 'K3s pod CIDR'
ufw allow from "$SERVICE_CIDR" to any comment 'K3s service CIDR'
# Permit pod forwarding and cross-node overlay forwarding while leaving the
# host itself closed on public interfaces.
ufw route allow from "$POD_CIDR" to any comment 'K3s pod egress/forwarding'
ufw route allow from any to "$POD_CIDR" comment 'K3s pod ingress/forwarding'
ufw route allow in on tailscale0 comment 'K3s overlay over Tailscale'
ufw --force enable
ufw reload

section "K3s role"
echo "  1) New cluster - first K3s server, embedded etcd cluster-init"
echo "  2) Join existing cluster as another server/control-plane/etcd member"
echo "  3) Join existing cluster as worker/agent only"
while true; do
  read -r -p "Select role [1/2/3]: " ROLE_CHOICE
  [[ "$ROLE_CHOICE" =~ ^[123]$ ]] && break
  echo "Choose 1, 2 or 3."
done

MASTER_IP=""
JOIN_TOKEN=""
if [[ "$ROLE_CHOICE" != "1" ]]; then
  while true; do
    MASTER_IP=$(prompt_nonempty "Existing K3s server Tailscale/internal IP")
    valid_ipv4 "$MASTER_IP" && break
    echo "Enter a valid IPv4 address." >&2
  done

  read -r -s -p "K3s cluster token/join key: " JOIN_TOKEN
  echo
  [[ -n "$JOIN_TOKEN" ]] || fail "A K3s join token is required."

  info "Checking Tailscale reachability to $MASTER_IP"
  if ! timeout 10 tailscale ping --c 1 "$MASTER_IP" >/dev/null 2>&1; then
    warn "Tailscale ping did not succeed. Continuing, but the K3s join may fail."
  fi
  if ! timeout 5 bash -c "</dev/tcp/${MASTER_IP}/6443" 2>/dev/null; then
    fail "Cannot reach K3s API/supervisor at ${MASTER_IP}:6443 over the selected network."
  fi
fi

section "K3s configuration"
install -d -m 0700 /etc/rancher/k3s
install -d -m 0750 /etc/rancher/k3s/config.yaml.d

# Cluster administrators on server nodes may read the kubeconfig without making
# it world-readable.
groupadd -f k3s-admin
usermod -aG k3s-admin "$ADMIN_USER"

cat > /etc/rancher/k3s/config.yaml <<EOF_K3S
node-name: "${NODE_NAME}"
node-ip: "${NODE_IP}"
flannel-iface: "tailscale0"
kube-proxy-arg:
  - "nodeport-addresses=100.64.0.0/10"
EOF_K3S
chmod 0600 /etc/rancher/k3s/config.yaml

if [[ "$ROLE_CHOICE" == "1" ]]; then
  CLUSTER_TOKEN=$(openssl rand -hex 32)
  cat >> /etc/rancher/k3s/config.yaml <<EOF_NEW
cluster-cidr: "${POD_CIDR}"
service-cidr: "${SERVICE_CIDR}"
cluster-init: true
token: "${CLUSTER_TOKEN}"
advertise-address: "${NODE_IP}"
tls-san:
  - "${NODE_IP}"
  - "${NODE_NAME}"
secrets-encryption: true
disable:
  - servicelb
write-kubeconfig-mode: "0640"
write-kubeconfig-group: "k3s-admin"
EOF_NEW
  unset CLUSTER_TOKEN
elif [[ "$ROLE_CHOICE" == "2" ]]; then
  cat >> /etc/rancher/k3s/config.yaml <<EOF_JOIN_SERVER
cluster-cidr: "${POD_CIDR}"
service-cidr: "${SERVICE_CIDR}"
server: "https://${MASTER_IP}:6443"
token: "${JOIN_TOKEN}"
advertise-address: "${NODE_IP}"
tls-san:
  - "${NODE_IP}"
  - "${NODE_NAME}"
secrets-encryption: true
disable:
  - servicelb
write-kubeconfig-mode: "0640"
write-kubeconfig-group: "k3s-admin"
EOF_JOIN_SERVER
else
  cat >> /etc/rancher/k3s/config.yaml <<EOF_JOIN_AGENT
server: "https://${MASTER_IP}:6443"
token: "${JOIN_TOKEN}"
EOF_JOIN_AGENT
fi
unset JOIN_TOKEN
chmod 0600 /etc/rancher/k3s/config.yaml

# K3s installs and maintains containerd, kubectl, crictl and the systemd unit.
K3S_INSTALLER=$(mktemp)
curl --proto '=https' --tlsv1.2 -sfL https://get.k3s.io -o "$K3S_INSTALLER"
chmod 0700 "$K3S_INSTALLER"
if [[ "$ROLE_CHOICE" == "3" ]]; then
  INSTALL_K3S_CHANNEL=stable INSTALL_K3S_EXEC=agent sh "$K3S_INSTALLER"
  K3S_SERVICE="k3s-agent"
else
  INSTALL_K3S_CHANNEL=stable INSTALL_K3S_EXEC=server sh "$K3S_INSTALLER"
  K3S_SERVICE="k3s"
fi
rm -f "$K3S_INSTALLER"

systemctl enable --now "$K3S_SERVICE"

section "K3s health checks"
info "Waiting for ${K3S_SERVICE} to become active..."
for _ in $(seq 1 60); do
  systemctl is-active --quiet "$K3S_SERVICE" && break
  sleep 2
done
systemctl is-active --quiet "$K3S_SERVICE" || {
  journalctl -u "$K3S_SERVICE" -n 80 --no-pager || true
  fail "$K3S_SERVICE did not become active."
}

if [[ "$ROLE_CHOICE" != "3" ]]; then
  info "Waiting for this node to report Ready..."
  READY=0
  for _ in $(seq 1 90); do
    if k3s kubectl get node "$NODE_NAME" --no-headers 2>/dev/null | grep -q ' Ready '; then
      READY=1
      break
    fi
    sleep 2
  done
  if [[ "$READY" -ne 1 ]]; then
    k3s kubectl get nodes -o wide || true
    fail "K3s started, but this server did not become Ready."
  fi

  # Verify the packaged DNS deployment is available; this catches many firewall/CNI failures.
  info "Checking CoreDNS rollout..."
  if ! timeout 120 k3s kubectl -n kube-system rollout status deployment/coredns >/dev/null 2>&1; then
    warn "CoreDNS is not yet fully available. Check 'k3s kubectl -n kube-system get pods -o wide'."
  fi

  install -d -m 0750 -o "$ADMIN_USER" -g k3s-admin "$ADMIN_HOME/.kube"
  ln -sfn /etc/rancher/k3s/k3s.yaml "$ADMIN_HOME/.kube/config"
  chown -h "$ADMIN_USER":k3s-admin "$ADMIN_HOME/.kube/config"
fi

section "MOTD"
# Take full ownership of login MOTD output. Remove Ubuntu/provider snippets and
# blank the static MOTD so PAM displays only our dynamic node dashboard.
if [[ -d /etc/update-motd.d ]]; then
  find /etc/update-motd.d -mindepth 1 -maxdepth 1 -type f -delete
  find /etc/update-motd.d -mindepth 1 -maxdepth 1 -type l -delete
fi
install -d -m 0755 /etc/update-motd.d
rm -f /etc/motd
install -m 0644 /dev/null /etc/motd

cat > /etc/update-motd.d/00-k3s-node <<'EOF_MOTD' 
#!/usr/bin/env bash
set +e

# shellcheck disable=SC1091
[[ -r /etc/k3s-node-bootstrap.conf ]] && source /etc/k3s-node-bootstrap.conf

HOST=$(hostname -s)
OS=$(awk -F= '/^PRETTY_NAME=/{gsub(/^"|"$/, "", $2); print $2}' /etc/os-release)
TSIP=$(timeout 1 tailscale ip -4 2>/dev/null | head -n1)
TSSTATE=$(systemctl is-active tailscaled 2>/dev/null)
if systemctl list-unit-files 2>/dev/null | grep -q '^k3s-agent.service'; then
  K3SSVC=k3s-agent
  ROLE=worker
else
  K3SSVC=k3s
  ROLE=server
fi
K3SSTATE=$(systemctl is-active "$K3SSVC" 2>/dev/null)
K3SVERSION=$(k3s --version 2>/dev/null | awk 'NR==1{print $3}' || true)
UP=$(uptime -p 2>/dev/null | sed 's/^up //')
MEM=$(free -h | awk '/^Mem:/{print $3 " / " $2}')
ROOTDISK=$(df -h / | awk 'NR==2{print $3 " / " $2 " (" $5 ")"}')
LOAD=$(awk '{print $1", "$2", "$3}' /proc/loadavg)
UFW=$(ufw status 2>/dev/null | awk 'NR==1{$1=""; sub(/^ /,""); print}')
SSHIDSYNC=$(systemctl is-active sshid-key-sync.timer 2>/dev/null)
ADMIN_HOME=${BOOTSTRAP_ADMIN_HOME:-/home/${BOOTSTRAP_ADMIN_USER:-}}
SSHIDLAST=$(cat "${ADMIN_HOME}/.ssh/.sshid-last-success" 2>/dev/null || true)
SSHIDCHANGELOG="${ADMIN_HOME}/.ssh/.sshid-key-changes.log"

printf '\n'
printf '=======================================================================\n'
printf '  K3s Cloud Node: %s\n' "$HOST"
printf '=======================================================================\n'
printf '  Bootstrap       : v%s\n' "${BOOTSTRAP_VERSION:-unknown}"
printf '  Build commit    : %s\n' "${BOOTSTRAP_GIT_COMMIT:-unknown}"
printf '  Script SHA256   : %s\n' "${BOOTSTRAP_SCRIPT_SHA256:-unknown}"
printf '  K3s version     : %s\n' "${K3SVERSION:-unknown}"
printf '  Role            : %s\n' "$ROLE"
printf '  OS              : %s\n' "$OS"
printf '  Tailscale IP    : %s\n' "${TSIP:-unavailable}"
printf '  Tailscale       : %s\n' "${TSSTATE:-unknown}"
printf '  K3s             : %s\n' "${K3SSTATE:-unknown}"
printf '  Uptime          : %s\n' "${UP:-unknown}"
printf '  Memory          : %s\n' "${MEM:-unknown}"
printf '  Root disk       : %s\n' "${ROOTDISK:-unknown}"
printf '  Load            : %s\n' "$LOAD"
printf '  Firewall        : %s\n' "${UFW:-unknown}"
printf '  SSHID sync      : %s%s\n' "${SSHIDSYNC:-unknown}" "${SSHIDLAST:+ (last: $SSHIDLAST)}"
printf '-----------------------------------------------------------------------\n'
printf '  Public inbound  : denied (except UDP/41641 for Tailscale)\n'
printf '  Administration  : Tailscale + SSH public key\n'
if [[ "$K3SSVC" == "k3s" ]]; then
  NODES=$(timeout 2 k3s kubectl get nodes --no-headers 2>/dev/null | awk '{printf "%s=%s ", $1, $2}')
  [[ -n "$NODES" ]] && printf '  Cluster          : %s\n' "$NODES"
fi
printf '-----------------------------------------------------------------------\n'
printf '  SSHID key changes (latest 10)\n'
if [[ -s "$SSHIDCHANGELOG" ]]; then
  tail -n 10 "$SSHIDCHANGELOG" 2>/dev/null | sed 's/^/    /'
else
  printf '    No key changes recorded.\n'
fi
printf '=======================================================================\n\n'
EOF_MOTD
chmod 0755 /etc/update-motd.d/00-k3s-node

if [[ -f /etc/default/motd-news ]]; then
  sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
fi
# Disable Ubuntu news refresh units when present. They are unnecessary once
# the distro MOTD snippets are removed, and this prevents future package
# updates from repopulating provider/Ubuntu news content at login.
systemctl disable --now motd-news.timer motd-news.service >/dev/null 2>&1 || true

# Some cloud images recreate update-motd snippets during package hooks. Keep
# our ownership explicit by recording the expected sole executable snippet.
info "MOTD takeover complete: only /etc/update-motd.d/00-k3s-node will run at login."

section "Final validation"
TS_BACKEND=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"' || echo unknown)
[[ "$TS_BACKEND" == "Running" ]] || warn "Tailscale backend state: $TS_BACKEND"

if [[ "$MASTER_IP" != "" ]]; then
  PEER_PATH=$(tailscale status 2>/dev/null | grep -F "$MASTER_IP" || true)
  if [[ -n "$PEER_PATH" ]]; then
    info "Tailscale peer status: $PEER_PATH"
  fi
fi

printf '\nBootstrap complete.\n'
printf '  Bootstrap       : v%s (%s)\n' "$SCRIPT_VERSION" "$SCRIPT_GIT_COMMIT"
printf '  Node name       : %s\n' "$NODE_NAME"
printf '  Admin user      : %s\n' "$ADMIN_USER"
printf '  Tailscale IP    : %s\n' "$TS_IP"
printf '  K3s node IP     : %s\n' "$NODE_IP"
printf '  K3s service     : %s\n' "$K3S_SERVICE"
printf '  Public SSH      : BLOCKED by UFW\n'
printf '  Tailscale SSH   : ssh %s@%s\n' "$ADMIN_USER" "$TS_IP"
printf '  Longhorn prereq : open-iscsi installed and iscsid enabled\n'
printf '  SSHID key sync  : every %s via systemd timer\n' "$SSHID_SYNC_INTERVAL"

if [[ "$ROLE_CHOICE" == "1" ]]; then
  printf '\nJoin additional SERVER nodes with the token from:\n'
  printf '  sudo cat /var/lib/rancher/k3s/server/token\n'
  printf '\nFor HA embedded etcd, add two more server nodes for a total of three.\n'
elif [[ "$ROLE_CHOICE" == "2" ]]; then
  printf '\nCurrent cluster nodes:\n'
  k3s kubectl get nodes -o wide || true
fi

printf '\nIMPORTANT: before using Longhorn heavily, verify node-to-node Tailscale paths are direct:\n'
printf '  tailscale status\n'
printf '  tailscale ping <peer-tailscale-ip>\n'
printf 'Relayed DERP/peer-relay paths are not suitable for latency-sensitive storage replication.\n'
printf '\nLog: %s\n' "$LOG_FILE"
