#!/usr/bin/env bash
# Interactive Tailscale-only Docker Swarm bootstrap for Ubuntu/Debian servers.
# Hardened baseline, not a claim of CIS or DISA-STIG certification.
# Run from a console or keep an existing root session open until SSH is verified.
set -Eeuo pipefail
umask 077

KEY_URL='https://raw.githubusercontent.com/artificialai223/artificialai223/refs/heads/master/mainkey.pubkey'
log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'printf "ERROR at line %s; no later hardening steps were applied.\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || die 'Run with sudo or as root.'
[[ -t 0 ]] || die 'Run interactively from a terminal.'
source /etc/os-release
[[ ${ID:-} == ubuntu || ${ID:-} == debian ]] || die 'Only Ubuntu and Debian are supported.'
command -v systemctl >/dev/null || die 'systemd is required.'

printf '1) Create a Swarm manager\n2) Join a Swarm as worker\n'
read -r -p 'Choose [1/2]: ' mode
[[ $mode == 1 || $mode == 2 ]] || die 'Choose 1 or 2.'
dokploy=no
if [[ $mode == 1 ]]; then
  read -r -p 'Install Dokploy on this manager? [y/N]: ' answer
  [[ $answer =~ ^[Yy]([Ee][Ss])?$ ]] && dokploy=yes
fi
read -r -p 'Server name (DNS label, e.g. swarm-01): ' server_name
[[ $server_name =~ ^[a-zA-Z][a-zA-Z0-9-]{0,62}$ && $server_name != *- ]] || die 'Invalid server name.'
if command -v tailscale >/dev/null && tailscale ip -4 >/dev/null 2>&1; then
  printf 'Existing Tailscale connection found; it will be reused.\n'
  ts_key=''
else
  read -r -s -p 'Tailscale auth key (tskey-auth-...): ' ts_key; printf '\n'
  [[ $ts_key == tskey-auth-* ]] || die 'Expected a Tailscale auth key.'
fi
if [[ $mode == 2 ]]; then
  read -r -p 'Manager Tailscale IPv4 address (100.x.y.z): ' manager_ip
  [[ $manager_ip =~ ^100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die 'Use a manager Tailscale IPv4 address.'
  read -r -s -p 'Swarm WORKER join token (SWMTKN-...): ' join_token; printf '\n'
  [[ $join_token == SWMTKN-1-* ]] || die 'Expected a Swarm join token.'
fi

log 'Installing prerequisites and the administrator SSH key'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg openssh-server sudo python3 pciutils nftables unattended-upgrades apt-listchanges openssl iproute2 auditd apparmor apparmor-utils fail2ban mokutil
if ! id administrator &>/dev/null; then useradd -m -s /bin/bash administrator; fi
usermod -aG sudo administrator
install -d -m 0700 -o administrator -g administrator /home/administrator/.ssh
key_file=$(mktemp)
curl -fLsS --retry 3 --connect-timeout 10 "$KEY_URL" -o "$key_file"
[[ $(wc -l < "$key_file") -eq 1 ]] || die 'Expected exactly one SSH public key.'
ssh-keygen -l -f "$key_file" >/dev/null || die 'Downloaded SSH key is invalid.'
touch /home/administrator/.ssh/authorized_keys
if ! grep -Fxqf "$key_file" /home/administrator/.ssh/authorized_keys; then
  cat "$key_file" >> /home/administrator/.ssh/authorized_keys
fi
rm -f "$key_file"
chown administrator:administrator /home/administrator/.ssh/authorized_keys
chmod 0600 /home/administrator/.ssh/authorized_keys
printf 'administrator ALL=(ALL:ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/90-administrator
chmod 0440 /etc/sudoers.d/90-administrator
visudo -cf /etc/sudoers.d/90-administrator >/dev/null
hostnamectl set-hostname "$server_name"

log 'Installing and connecting Tailscale'
if ! command -v tailscale >/dev/null; then
  curl -fLsS https://tailscale.com/install.sh -o /tmp/haven-tailscale-install.sh
  sh /tmp/haven-tailscale-install.sh
  rm -f /tmp/haven-tailscale-install.sh
fi
systemctl enable --now tailscaled
if [[ -n $ts_key ]]; then
  tailscale up --auth-key="$ts_key" --hostname="$server_name" --accept-routes=false --ssh=false
fi
unset ts_key
ts_ip=$(tailscale ip -4 | head -n1)
[[ $ts_ip =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Tailscale IPv4 address unavailable.'
tailscale status >/dev/null || die 'Tailscale is offline.'
printf 'Tailnet address: %s\n' "$ts_ip"

log 'Installing Docker Engine from the official repository if necessary'
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  arch=$(dpkg --print-architecture)
  codename=${VERSION_CODENAME:-}
  [[ -n $codename ]] || die 'Could not determine distro codename.'
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' "$arch" "$ID" "$codename" >/etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
docker info >/dev/null
if [[ $(docker info --format '{{.Swarm.LocalNodeState}}') != inactive ]]; then
  die 'This host already belongs to a Swarm; refusing to overwrite its membership.'
fi

gpu_ready=no
if lspci -nn | grep -Eiq 'NVIDIA.*(VGA|3D|Display)|\[(0300|0302|0380)\].*NVIDIA'; then
  log 'NVIDIA GPU detected'
  if ! command -v nvidia-smi >/dev/null || ! nvidia-smi -L >/dev/null 2>&1; then
    apt-get install -y "linux-headers-$(uname -r)" dkms
    if [[ $ID == ubuntu ]]; then
      apt-get install -y ubuntu-drivers-common
      ubuntu-drivers --gpgpu install
    elif [[ ${VERSION_ID:-} == 12 || ${VERSION_ID:-} == 13 ]]; then
      # Add only missing Debian repository components; retain distro signing.
      candidate=$(apt-cache policy nvidia-driver 2>/dev/null | awk '/Candidate:/ {print $2}')
      if [[ -z $candidate || $candidate == '(none)' ]]; then
        cat >/etc/apt/sources.list.d/haven-nvidia-components.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${VERSION_CODENAME} ${VERSION_CODENAME}-updates
Components: contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: ${VERSION_CODENAME}-security
Components: contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
        apt-get update
      fi
      candidate=$(apt-cache policy nvidia-driver 2>/dev/null | awk '/Candidate:/ {print $2}')
      [[ -n $candidate && $candidate != '(none)' ]] || die 'NVIDIA driver unavailable for this Debian release.'
      apt-get install -y nvidia-driver
    else
      die 'Automatic NVIDIA installation supports Ubuntu and Debian 12/13.'
    fi
    modprobe nvidia 2>/dev/null || true
    if ! nvidia-smi -L >/dev/null 2>&1; then
      if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
        die 'Driver installed but cannot load yet. Reboot, complete any Secure Boot MOK enrollment, then rerun. The existing Tailscale login can be reused.'
      fi
      die 'Driver installed but cannot load yet. Reboot and rerun; the existing Tailscale login can be reused.'
    fi
  fi
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    >/etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker --set-as-default
  systemctl restart docker
  docker info --format '{{json .Runtimes}}' | grep -q nvidia || die 'NVIDIA Docker runtime unavailable.'
  docker run --rm --gpus all --entrypoint nvidia-smi nvidia/cuda:12.9.1-base-ubuntu24.04 -L \
    || die 'NVIDIA container runtime test failed; Swarm has not been created.'
  gpu_ready=yes
fi

log 'Configuring Docker daemon hardening and log rotation'
python3 - <<'PY'
import json
from pathlib import Path
p = Path('/etc/docker/daemon.json')
d = json.loads(p.read_text()) if p.exists() else {}
d['live-restore'] = True
d['userland-proxy'] = False
d.setdefault('log-driver', 'json-file')
if d['log-driver'] == 'json-file':
    d.setdefault('log-opts', {}).update({'max-size': '10m', 'max-file': '3'})
p.write_text(json.dumps(d, indent=2) + '\n')
PY
dockerd --validate --config-file /etc/docker/daemon.json >/dev/null
systemctl restart docker

log 'Creating or joining the Swarm over Tailscale'
if [[ $mode == 1 ]]; then
  docker swarm init --advertise-addr "$ts_ip" --data-path-addr "$ts_ip" --listen-addr "$ts_ip:2377"
else
  docker swarm join --token "$join_token" --advertise-addr "$ts_ip" --data-path-addr "$ts_ip" --listen-addr "$ts_ip:2377" "$manager_ip:2377"
  unset join_token
fi
if [[ $gpu_ready == yes ]]; then
  log 'Labelling this node as GPU-capable'
  # Scheduler placement hint. It does not reserve GPUs or prevent overcommit.
  if [[ $mode == 1 ]]; then
    docker node update --label-add gpu=nvidia "$(docker info --format '{{.Name}}')"
  else
    printf 'On the manager, run: docker node update --label-add gpu=nvidia %s\n' "$server_name"
  fi
fi

if [[ $dokploy == yes ]]; then
  log 'Installing Dokploy using its existing-Swarm procedure'
  for port in 80 443 3000; do
    if ss -lnt "( sport = :$port )" | grep -qE 'LISTEN'; then die "Port $port is occupied."; fi
  done
  docker network create --driver overlay --attachable dokploy-network
  install -d -m 0755 /etc/dokploy
  openssl rand -hex 32 | docker secret create dokploy_postgres_password -
  openssl rand -hex 32 | docker secret create dokploy_auth_secret -
  docker service create --name dokploy-postgres --constraint 'node.role==manager' \
    --network dokploy-network --env POSTGRES_USER=dokploy --env POSTGRES_DB=dokploy \
    --secret source=dokploy_postgres_password,target=/run/secrets/postgres_password \
    --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
    --mount type=volume,source=dokploy-postgres,target=/var/lib/postgresql/data postgres:16
  docker service create --name dokploy --replicas 1 --network dokploy-network \
    --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
    --mount type=bind,source=/etc/dokploy,target=/etc/dokploy \
    --mount type=volume,source=dokploy,target=/root/.docker \
    --secret source=dokploy_postgres_password,target=/run/secrets/postgres_password \
    --secret source=dokploy_auth_secret,target=/run/secrets/dokploy_auth_secret \
    --publish published=3000,target=3000,mode=host \
    --update-parallelism 1 --update-order stop-first --constraint 'node.role==manager' \
    --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
    --env BETTER_AUTH_SECRET_FILE=/run/secrets/dokploy_auth_secret dokploy/dokploy:latest
  for i in $(seq 1 60); do
    [[ -f /etc/dokploy/traefik/traefik.yml ]] && break
    sleep 2
  done
  [[ -f /etc/dokploy/traefik/traefik.yml ]] || die 'Dokploy did not generate Traefik config; inspect docker service logs dokploy.'
  docker run -d --name dokploy-traefik --restart always \
    -v /etc/dokploy/traefik/traefik.yml:/etc/traefik/traefik.yml \
    -v /etc/dokploy/traefik/dynamic:/etc/dokploy/traefik/dynamic \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -p 80:80/tcp -p 443:443/tcp -p 443:443/udp traefik:v3.6.7
  docker network connect dokploy-network dokploy-traefik
fi

log 'Validating services before restricting inbound traffic'
systemctl is-active --quiet ssh || systemctl start ssh
systemctl is-active --quiet tailscaled
docker info >/dev/null
tailscale status >/dev/null
if ss -lnt '( sport = :2375 or sport = :2376 )' | grep -q LISTEN; then
  die 'Docker TCP API is listening; disable it before applying the private-host baseline.'
fi
if [[ $dokploy == yes ]]; then
  curl -fsS --retry 10 --retry-delay 3 --max-time 10 "http://${ts_ip}:3000" -o /dev/null \
    || die 'Dokploy UI is not responding; firewall has not been changed.'
fi

log 'Hardening SSH, automatic security updates, and firewall'
install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/01-haven-tailnet.conf <<'SSH'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
X11Forwarding no
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 30
AllowAgentForwarding no
AllowUsers administrator
SSH
sshd -t
[[ $(sshd -T | awk '/^passwordauthentication / {print $2}') == no ]] || die 'Effective SSH config still permits passwords.'
[[ $(sshd -T | awk '/^permitrootlogin / {print $2}') == no ]] || die 'Effective SSH config still permits root login.'
systemctl reload ssh
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT
systemctl enable --now unattended-upgrades
cat >/etc/sysctl.d/80-haven-hardening.conf <<'SYSCTL'
# Host protections selected to avoid changing Docker forwarding or Tailscale routes.
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
SYSCTL
sysctl -p /etc/sysctl.d/80-haven-hardening.conf >/dev/null
cat >/etc/fail2ban/jail.d/80-haven-sshd.local <<'JAIL'
[sshd]
enabled = true
backend = systemd
mode = aggressive
maxretry = 5
findtime = 10m
bantime = 1h
JAIL
systemctl enable --now fail2ban
systemctl enable --now apparmor
cat >/etc/audit/rules.d/80-haven.rules <<'AUDIT'
-w /etc/ssh/sshd_config -p wa -k host-ssh
-w /etc/ssh/sshd_config.d -p wa -k host-ssh
-w /etc/sudoers -p wa -k host-sudo
-w /etc/sudoers.d -p wa -k host-sudo
-w /etc/docker/daemon.json -p wa -k host-docker
AUDIT
systemctl enable --now auditd
augenrules --load

# Earlier priority than Docker's iptables-nft filter hooks: catches DNAT/published
# container ports in FORWARD, as well as host INPUT. Existing firewall rules stay.
# This policy permits outbound connections (Cloudflare Tunnel, registries, Tailscale).
cat >/etc/nftables.d-haven.conf <<'NFT'
table inet haven_private {
  chain input {
    type filter hook input priority -110; policy accept;
    iifname "lo" accept
    ct state established,related accept
    iifname "tailscale0" accept
    udp dport 41641 accept
    drop
  }
  chain forward {
    type filter hook forward priority -110; policy accept;
    ct state established,related accept
    iifname "tailscale0" accept
    iifname "docker*" accept
    iifname "br-*" accept
    oifname "docker*" drop
    oifname "br-*" drop
  }
}
NFT
nft -c -f /etc/nftables.d-haven.conf
cat >/usr/local/sbin/haven-firewall <<'FW'
#!/usr/bin/env bash
set -euo pipefail
nft delete table inet haven_private 2>/dev/null || true
nft -f /etc/nftables.d-haven.conf
FW
chmod 0755 /usr/local/sbin/haven-firewall
cat >/etc/systemd/system/haven-firewall.service <<'UNIT'
[Unit]
Description=Restrict host and Docker inbound traffic to Tailscale
After=network-online.target tailscaled.service docker.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/haven-firewall
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now haven-firewall.service
nft list table inet haven_private >/dev/null

printf '\nDone. SSH: ssh administrator@%s\n' "$ts_ip"
if [[ $dokploy == yes ]]; then
  printf 'Dokploy UI: http://%s:3000\n' "$ts_ip"
  printf 'Cloudflare Tunnel can point to http://127.0.0.1:3000 (dashboard) or http://127.0.0.1:80 (Traefik apps).\n'
fi
if [[ $mode == 1 ]]; then
  printf 'Worker join token (keep private): sudo docker swarm join-token worker\n'
fi
if [[ $dokploy == yes ]]; then
  printf 'Finish in Dokploy: enable passkeys/2FA, use least-privilege roles, isolate Compose projects,\n'
  printf 'use internal database credentials, configure encrypted backups and test a restore.\n'
  printf 'Apply HSTS/rate limits per public app, and configure external logs and alerts.\n'
fi
printf 'Verify a NEW SSH session over Tailscale before closing this one.\n'
printf 'Review upstream/provider firewalls too; UDP 41641 is allowed for Tailscale transport.\n'
