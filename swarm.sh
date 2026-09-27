#!/usr/bin/env bash
# Run on the Swarm manager. Bootstraps two fresh Ubuntu/Debian managers in parallel.
# The node installer is embedded below; no GitHub download is needed at runtime.
set -Eeuo pipefail
set +x
umask 077
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }
[[ $EUID == 0 && -t 0 ]] || die 'Run as root from an interactive terminal on the manager.'
command -v systemd-run >/dev/null || die 'systemd is required.'

installer=$(mktemp /root/haven-node-installer.XXXXXXXX.sh)
trap 'rm -f "$installer"' EXIT
awk '/^__HAVEN_INSTALLER_PAYLOAD__$/ {p=1;next} /^__HAVEN_EMBED_END__$/ {exit} p {print}' "$0" | base64 -d | gzip -d >"$installer"
bash -n "$installer"
chmod 0700 "$installer"

read -r -p 'New manager 1 public/bootstrap IPv4: ' ip1
read -r -p 'New manager 1 hostname: ' name1
read -r -s -p 'New manager 1 root SSH password: ' pass1; printf '\n'
read -r -p 'New manager 2 public/bootstrap IPv4: ' ip2
read -r -p 'New manager 2 hostname: ' name2
read -r -s -p 'New manager 2 root SSH password: ' pass2; printf '\n'
for addr in "$ip1" "$ip2"; do
  [[ $addr =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die 'Use literal IPv4 addresses for bootstrap.'
done
[[ $ip1 != "$ip2" ]] || die 'New manager IPs must be different.'
for name in "$name1" "$name2"; do
  [[ $name =~ ^[a-zA-Z][a-zA-Z0-9-]{0,62}$ && $name != *- ]] || die 'Invalid manager hostname.'
done
[[ $name1 != "$name2" ]] || die 'New manager hostnames must be different.'
read -r -s -p 'Reusable Tailscale auth key (used on both new managers): ' ts_auth; printf '\n'
[[ $ts_auth == tskey-auth-* ]] || die 'Expected a Tailscale auth key.'

note 'Preparing manager and provisioning SSH key'
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y sshpass openssh-client >/dev/null
install -d -m 0700 /root/.ssh
key=/root/.ssh/haven-cluster-provisioning
if [[ ! -f $key ]]; then ssh-keygen -q -t ed25519 -N '' -f "$key" -C 'haven-cluster-provisioning'; fi
[[ -f $key.pub ]] || die 'Provisioning public key is missing.'
chmod 0600 "$key"

# Apply the same hardening and MOTD to the original manager before joining peers.
manager_name=$(hostname -s)
[[ $name1 != "$manager_name" && $name2 != "$manager_name" ]] || die 'New manager hostnames must differ from the original manager.'
manager_dokploy=no
if docker service inspect dokploy >/dev/null 2>&1; then
  manager_dokploy=yes
else
  read -r -p 'Install Dokploy on the manager? [y/N]: ' answer
  if [[ $answer =~ ^[Yy]([Ee][Ss])?$ ]]; then manager_dokploy=yes; fi
fi
if ! tailscale ip -4 >/dev/null 2>&1; then
  note 'Manager is not connected to Tailscale; using the same auth key on it too'
  export HAVEN_TAILSCALE_AUTH_KEY="$ts_auth"
fi
export HAVEN_MODE=1 HAVEN_SERVER_NAME="$manager_name" HAVEN_DOKPLOY="$manager_dokploy"
bash "$installer"
unset HAVEN_MODE HAVEN_SERVER_NAME HAVEN_DOKPLOY HAVEN_TAILSCALE_AUTH_KEY
manager_ts=$(tailscale ip -4 | head -n1)
manager_token=$(docker swarm join-token -q manager)

# Add the manager's dedicated key for post-hardening checks via sudo.
install -d -m 0700 -o administrator -g administrator /home/administrator/.ssh
touch /home/administrator/.ssh/authorized_keys
grep -Fxqf "$key.pub" /home/administrator/.ssh/authorized_keys || cat "$key.pub" >>/home/administrator/.ssh/authorized_keys
chown administrator:administrator /home/administrator/.ssh/authorized_keys
chmod 0600 /home/administrator/.ssh/authorized_keys

ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -o ConnectionAttempts=1 -i "$key" -p 6278)
boot_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ConnectionAttempts=1 -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1)
sshpass_ssh() { local pw=$1; shift; sshpass -d 3 ssh "${boot_opts[@]}" "$@" 3<<<"$pw"; }
sshpass_scp() { local pw=$1; shift; sshpass -d 3 scp "${boot_opts[@]}" "$@" 3<<<"$pw"; }
key_ssh() { local target=$1; shift; ssh "${ssh_opts[@]}" "administrator@$target" "$@"; }

provision_worker() {
  local ip=$1 name=$2 pw=$3 stage remote_dir attempt worker_ts before after state
  local logfile="/var/log/haven-provision-${name}.log"
  exec > >(tee -a "$logfile") 2>&1
  note "$name: checking initial root SSH access on port 22"
  sshpass_ssh "$pw" "root@$ip" 'test "$(id -u)" = 0' || die "$name: root/password SSH on port 22 failed."
  stage=$(mktemp -d "/root/haven-stage-${name}.XXXXXXXX")
  trap 'if [[ ${reboot_in_progress:-no} == yes ]]; then touch /root/haven-manager-reboot.blocked; fi; rm -rf "${stage:-/root/never-created-haven-stage}"' EXIT
  remote_dir="/root/haven-bootstrap-${name}"
  cp "$installer" "$stage/installer.sh"
  cp "$key.pub" "$stage/manager.pub"
  {
    printf 'export HAVEN_MODE=3\n'
    printf 'export HAVEN_SERVER_NAME=%q\n' "$name"
    printf 'export HAVEN_MANAGER_IP=%q\n' "$manager_ts"
    printf 'export HAVEN_MANAGER_TOKEN=%q\n' "$manager_token"
    printf 'export HAVEN_TAILSCALE_AUTH_KEY=%q\n' "$ts_auth"
  } >"$stage/bootstrap.env"
cat >"$stage/run.sh" <<'RUN'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
cd "$(dirname "$0")"
if ! id administrator >/dev/null 2>&1; then useradd -m -s /bin/bash administrator; fi
install -d -m 0700 -o administrator -g administrator /home/administrator/.ssh
touch /home/administrator/.ssh/authorized_keys
grep -Fxqf manager.pub /home/administrator/.ssh/authorized_keys || cat manager.pub >>/home/administrator/.ssh/authorized_keys
chown administrator:administrator /home/administrator/.ssh/authorized_keys
chmod 0600 /home/administrator/.ssh/authorized_keys
source ./bootstrap.env
if ! bash ./installer.sh > ./install.log 2>&1; then
  if grep -q 'Driver installed but cannot load yet. Reboot' ./install.log && [[ ! -e ./driver-rebooted ]]; then
    touch ./driver-rebooted
    cat >/etc/systemd/system/haven-gpu-resume.service <<EOF
[Unit]
Description=Resume Haven worker provisioning after NVIDIA driver reboot
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash $(pwd)/run.sh
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable haven-gpu-resume.service
    systemctl reboot
    exit 0
  fi
  rm -f ./bootstrap.env
  exit 1
fi
tailscale ip -4 > ./tailscale-ip
touch ./complete
rm -f ./bootstrap.env
if systemctl is-enabled --quiet haven-gpu-resume.service 2>/dev/null; then
  systemctl disable haven-gpu-resume.service
fi
RUN
  chmod 0700 "$stage/run.sh" "$stage/bootstrap.env"
  note "$name: transferring bootstrap files and starting detached installation"
  sshpass_ssh "$pw" "root@$ip" "mkdir -p '$remote_dir' && chmod 700 '$remote_dir'"
  sshpass_scp "$pw" -r "$stage/." "root@$ip:$remote_dir/"
  rm -rf "$stage"
  # systemd owns the installation so sshd restarting cannot kill the process.
  sshpass_ssh "$pw" "root@$ip" "systemd-run --unit=haven-provision-${name} --collect '$remote_dir/run.sh'"
  unset pw

  note "$name: waiting for new key-only SSH on public port 6278"
  for attempt in $(seq 1 120); do
    if key_ssh "$ip" "sudo -n test -f '$remote_dir/complete'" >/dev/null 2>&1; then break; fi
    sleep 10
  done
  if ! key_ssh "$ip" "sudo -n test -f '$remote_dir/complete'" >/dev/null 2>&1; then
    die "$name: provisioning did not complete or public port 6278 is blocked. See $logfile and $remote_dir/install.log on the worker."
  fi
  worker_ts=$(key_ssh "$ip" "sudo -n cat '$remote_dir/tailscale-ip'" | head -n1)
  [[ $worker_ts =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$name: Tailscale address unavailable."
  key_ssh "$worker_ts" 'test "$(sudo -n docker info --format "{{.Swarm.ControlAvailable}}")" = true && sudo -n tailscale status >/dev/null'
  note "$name: waiting until all three managers are Ready before any validation reboot"
  for attempt in $(seq 1 120); do
    if [[ $(docker node inspect -f '{{.Status.State}}' "$name1" 2>/dev/null || true) == ready && \
          $(docker node inspect -f '{{.Status.State}}' "$name2" 2>/dev/null || true) == ready ]]; then break; fi
    sleep 10
  done
  [[ $(docker node inspect -f '{{.Status.State}}' "$name1" 2>/dev/null || true) == ready && \
     $(docker node inspect -f '{{.Status.State}}' "$name2" 2>/dev/null || true) == ready ]] || die 'All three managers did not become Ready; no validation reboot was started.'
  # Only one voting manager may be down at a time in a three-manager Swarm.
  exec {reboot_lock}>/root/haven-manager-reboot.lock
  flock -x "$reboot_lock"
  [[ ! -e /root/haven-manager-reboot.blocked ]] || die 'A previous manager failed reboot validation; further manager reboots are blocked.'
  reboot_in_progress=yes
  before=$(key_ssh "$ip" 'cat /proc/sys/kernel/random/boot_id')
  note "$name: rebooting and waiting for a changed boot ID"
  key_ssh "$ip" 'sudo -n systemctl reboot' >/dev/null 2>&1 || true
  after=''
  for attempt in $(seq 1 60); do
    sleep 10
    after=$(key_ssh "$ip" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
    if [[ -n $after && $after != "$before" ]]; then break; fi
  done
  [[ -n $after && $after != "$before" ]] || die "$name: a completed reboot and SSH reconnection were not verified."
  key_ssh "$ip" 'sudo -n tailscale status >/dev/null && sudo -n test "$(sudo -n docker info --format "{{.Swarm.LocalNodeState}}")" = active && sudo -n test "$(sudo -n docker info --format "{{.Swarm.ControlAvailable}}")" = true && sudo -n nft list table inet haven_private >/dev/null && test "$(sudo -n sshd -T | awk '\''/^passwordauthentication / {print $2}'\'')" = no && sudo -n test -x /etc/update-motd.d/00-haven-status'
  key_ssh "$worker_ts" 'true'
  state=''
  for attempt in $(seq 1 24); do
    state=$(docker node inspect -f '{{.Status.State}}' "$name" 2>/dev/null || true)
    if [[ $state == ready ]]; then break; fi
    sleep 5
  done
  [[ $state == ready ]] || die "$name: rebooted, but the manager does not report its Swarm node as Ready."
  reboot_in_progress=no
  flock -u "$reboot_lock"
  exec {reboot_lock}>&-
  if key_ssh "$ip" 'sudo -n nvidia-smi -L >/dev/null 2>&1'; then
    docker node update --label-add gpu=nvidia "$name"
    note "$name: NVIDIA GPU runtime verified and Swarm GPU label applied"
  fi
  note "$name: verified public and tailnet SSH, Tailscale, Swarm, firewall and MOTD after reboot"
}

note 'Provisioning both new managers concurrently'
provision_worker "$ip1" "$name1" "$pass1" & pid1=$!
provision_worker "$ip2" "$name2" "$pass2" & pid2=$!
unset pass1 pass2 ts_auth manager_token
set +e
wait "$pid1"; result1=$?
wait "$pid2"; result2=$?
set -e
printf '\nManager results: %s=%s, %s=%s\n' "$name1" "$result1" "$name2" "$result2"
docker node ls
[[ $result1 == 0 && $result2 == 0 ]] || die 'At least one manager failed. Read its /var/log/haven-provision-NAME.log and remote install.log.'
printf 'Manager SSH: ssh -p 6278 administrator@%s\n' "$manager_ts"
printf 'Private manager provisioning key: %s (retain securely for cluster administration).\n' "$key"
exit 0

: <<'__HAVEN_EMBED_END__'
__HAVEN_INSTALLER_PAYLOAD__
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
Qqd0Oyu0Rj1W2iuElRXQhi319H/ZRhVGBF0AAA==
__HAVEN_EMBED_END__
