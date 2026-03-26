#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# --------------------------------------
#  COLOUR DEFINITIONS
# --------------------------------------
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RESET="\e[0m"

info()    { echo -e "${BLUE}[INFO]${RESET} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error()   { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }

# --------------------------------------
#  SECURITY STARTUP
# --------------------------------------
umask 077

# Require root
[[ $EUID -ne 0 ]] && error "This script MUST be run as root."

# --------------------------------------
#  CONFIG
# --------------------------------------
USER_NAME="artificialai"
SSH_URL="https://raw.githubusercontent.com/artificialai223/artificialai223/refs/heads/master/mainkey.pubkey"

SSH_DIR="/home/$USER_NAME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

# --------------------------------------
#  USER MANAGEMENT
# --------------------------------------
if id "$USER_NAME" &>/dev/null; then
    warn "User '$USER_NAME' already exists."
else
    info "Creating user '$USER_NAME'"
    useradd --create-home --shell /bin/bash --user-group "$USER_NAME" || error "User creation failed"
    success "User created"
fi

info "Adding '$USER_NAME' to 'sudo' group"
usermod -aG sudo "$USER_NAME"
success "User added to sudo"

# --------------------------------------
#  SSH DIRECTORY SETUP
# --------------------------------------
info "Preparing secure SSH directory"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$USER_NAME:$USER_NAME" "$SSH_DIR"
success ".ssh directory ready"

# --------------------------------------
#  DOWNLOAD KEY (NO HASH VERIFICATION)
# --------------------------------------
TMP=$(mktemp)

info "Downloading SSH public key"
curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 "$SSH_URL" -o "$TMP" \
    || error "SSH key download failed"

success "Key downloaded"

# --------------------------------------
#  INSTALL KEY SAFELY
# --------------------------------------
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

# --------------------------------------
#  DONE
# --------------------------------------
success "Setup complete!"
echo -e "${BLUE}--------------------------------------${RESET}"
echo -e "${GREEN}User:${RESET}        $USER_NAME"
echo -e "${GREEN}SSH Key:${RESET}     Installed"
echo -e "${GREEN}Sudo Access:${RESET} Enabled"
echo -e "${BLUE}--------------------------------------${RESET}"
