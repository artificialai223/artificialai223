#!/bin/bash

# Configuration & Colors
LOG_FILE="/var/log/host_lockdown.log"
GREEN='\033

print_stage() {
    echo -e "${BLUE}${NC} $1..."
}

update_status() {
    if [ $? -eq 0 ]; then
        STATUS["$1"]="SUCCESS"
        echo -e "${GREEN}[OK]${NC} $1 completed."
    else
        STATUS["$1"]="FAILED"
        echo -e "${RED}${NC} $1 failed. Check $LOG_FILE"
    fi
}

# 0. Root Check
if]; then
   echo -e "${RED}This script must be run as root.${NC}"
   exit 1
fi

# Clear previous log
: > "$LOG_FILE"

print_stage "Updating system packages"
apt update &>> "$LOG_FILE" && apt full-upgrade -y &>> "$LOG_FILE"
update_status "System Update"

print_stage "Installing security tools (UFW, Fail2Ban, Auditd)"
apt install -y ufw fail2ban unattended-upgrades auditd curl &>> "$LOG_FILE"
update_status "Tool Installation"

print_stage "Installing artificialai223 SSH key"
# The user's provided command
curl -fsSL https://raw.githubusercontent.com/artificialai223/artificialai223/refs/heads/master/sshkeyinstall.sh | bash &>> "$LOG_FILE"
update_status "SSH Key Installation"

print_stage "Randomizing and Securing SSH (Port $SSH_PORT)"
# Configure Port, Disable Root, Disable Passwords [3, 4, 1]
sed -i "s/^#*Port.*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
# Validate syntax before restarting
sshd -t &>> "$LOG_FILE"
if [ $? -eq 0 ]; then
    systemctl restart ssh &>> "$LOG_FILE"
    update_status "SSH Hardening"
else
    STATUS="FAILED (Invalid Config)"
    echo -e "${RED}${NC} SSH config syntax invalid. Reverting to default port for safety."
    SSH_PORT=22
fi

print_stage "Configuring UFW Firewall"
ufw default deny incoming &>> "$LOG_FILE"
ufw default allow outgoing &>> "$LOG_FILE"
ufw allow "$SSH_PORT"/tcp &>> "$LOG_FILE" # Allow the new random port
echo "y" | ufw enable &>> "$LOG_FILE"
update_status "Firewall Configuration"

print_stage "Applying Kernel Hardening (sysctl)"
cat <<EOF > /etc/sysctl.d/99-hardening.conf
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.tcp_syncookies = 1
kernel.dmesg_restrict = 1
kernel.randomize_va_space = 2
EOF
sysctl -p /etc/sysctl.d/99-hardening.conf &>> "$LOG_FILE"
update_status "Kernel Hardening"

print_stage "Finalizing Automation & Updates"
systemctl enable fail2ban &>> "$LOG_FILE"
echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades
update_status "Automation Setup"

# Final Summary
echo -e "\n${YELLOW}========================================${NC}"
echo -e "${YELLOW}           LOCKDOWN SUMMARY             ${NC}"
echo -e "${YELLOW}========================================${NC}"
for task in "${!STATUS[@]}"; do
    color=$GREEN
   } == *"FAILED"* ]] && color=$RED
    printf "%-30s : %b%s%b\n" "$task" "$color" "${STATUS[$task]}" "$NC"
done
echo -e "----------------------------------------"
echo -e "Final SSH Port      : ${GREEN}$SSH_PORT${NC}"
echo -e "Full Log Location   : $LOG_FILE"
echo -e "${YELLOW}========================================${NC}"
echo -e "${RED}IMPORTANT:${NC} Do not close this session. Test connection on port $SSH_PORT in a new window first!"
