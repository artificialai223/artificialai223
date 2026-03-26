#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RESET="\e[0m"
info()    { echo -e "${BLUE}[INFO]${RESET} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error()   { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }

umask 077
[[ $EUID -ne 0 ]] && error "This script MUST be run as root."

USER_NAME="artificialai"
SSH_URL="https://raw.githubusercontent.com/artificialai223/artificialai223/refs/heads/master/mainkey.pubkey"

SSH_DIR="/home/$USER_NAME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

# -------------------------
# User Setup
# -------------------------
if id "$USER_NAME" &>/dev/null; then
    warn "User '$USER_NAME' already exists."
else
    info "Creating user '$USER_NAME'"
    useradd --create-home --shell /bin/bash --user-group "$USER_NAME" || error "User creation failed"
    success "User created"
fi

# Lock password (SSH-key-only login)
info "Locking user password to enforce SSH‑key‑only login"
passwd -l "$USER_NAME"
success "Password locked — SSH password login disabled"

info "Adding '$USER_NAME' to 'sudo' group"
usermod -aG sudo "$USER_NAME"
success "User added to sudo"

# -------------------------
# SSH Setup
# -------------------------
info "Setting up secure SSH directory"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$USER_NAME:$USER_NAME" "$SSH_DIR"

TMP=$(mktemp)
info "Downloading SSH public key"
curl --fail --silent --show-error --location "$SSH_URL" -o "$TMP" || error "Download failed"
success "Key downloaded"

touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
chown "$USER_NAME:$USER_NAME" "$AUTHORIZED_KEYS"

if grep -Fxq "$(cat "$TMP")" "$AUTHORIZED_KEYS"; then
    warn "Key already installed — skipping"
else
    info "Installing SSH key"
    cat "$TMP" >> "$AUTHORIZED_KEYS"
    chown "$USER_NAME:$USER_NAME" "$AUTHORIZED_KEYS"
    success "SSH key installed"
fi

rm -f "$TMP"

# -------------------------
# Passwordless sudo su -
# -------------------------
info "Configuring passwordless sudo for user"

SUDOERS_FILE="/etc/sudoers.d/99-$USER_NAME-nopasswd"
echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"

visudo -cf "$SUDOERS_FILE" &>/dev/null || {
    rm -f "$SUDOERS_FILE"
    error "sudoers validation FAILED — config rolled back"
}

success "Passwordless sudo enabled"

# -------------------------
# Done
# -------------------------
success "Setup complete!"
echo -e "${BLUE}--------------------------------------${RESET}"
echo -e "${GREEN}User:${RESET}        $USER_NAME"
echo -e "${GREEN}Password:${RESET}    LOCKED"
echo -e "${GREEN}SSH Login:${RESET}   KEY‑ONLY"
echo -e "${GREEN}Sudo:${RESET}        Passwordless"
echo -e "${BLUE}--------------------------------------${RESET}"
