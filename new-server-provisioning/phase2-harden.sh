#!/usr/bin/env bash
#
# Base layer, phase 2. Run as the non-root sudo user created by
# phase1-create-user.sh — AFTER you have manually confirmed SSH access as
# that user still works. Reads NEW_USER / SSH_PORT from .env (written by
# phase 1) and hardens sshd, the firewall, fail2ban, unattended upgrades,
# and a few other base checks. Restarts sshd LAST, after everything else
# in this script has already run successfully.
#
# Usage (as the new sudo user, on the target box):
#   ./phase2-harden.sh

set -euo pipefail

ENV_FILE="$(dirname "$0")/.env"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
    die "run this as the non-root sudo user, not root."
fi

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found. Run phase1-create-user.sh first."
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${NEW_USER:?NEW_USER missing from $ENV_FILE}"
: "${SSH_PORT:?SSH_PORT missing from $ENV_FILE}"

if [ "$(whoami)" != "$NEW_USER" ]; then
    die "running as $(whoami), but .env says the expected user is $NEW_USER."
fi

say "Base layer — phase 2: harden SSH, firewall, updates"
echo "This assumes you have ALREADY confirmed SSH access as '$NEW_USER' works"
echo "and sudo works. If you have not done that, stop now and go do it —"
echo "this script changes the SSH port and disables root login and password"
echo "auth."
read -rp "Type 'yes' to continue: " CONFIRM
[ "$CONFIRM" = "yes" ] || die "aborted — nothing changed."

# --- sshd hardening (staged, not yet restarted) ----------------------------

say "Staging sshd config changes (not yet applied — sshd restarts last)"
SSHD_DROPIN="/etc/ssh/sshd_config.d/90-base-hardening.conf"
sudo tee "$SSHD_DROPIN" > /dev/null <<EOF
# Managed by phase2-harden.sh.
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
MaxAuthTries 3
EOF
sudo sshd -t || die "sshd config failed validation — check $SSHD_DROPIN. sshd was NOT restarted."

# --- firewall ---------------------------------------------------------------

say "Configuring ufw (default-deny, allow SSH on $SSH_PORT only)"
sudo ufw --force reset > /dev/null
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow "$SSH_PORT"/tcp
sudo ufw --force enable

# --- fail2ban ----------------------------------------------------------------

say "Installing and enabling fail2ban (SSH jail)"
sudo apt update -y
sudo apt install -y fail2ban
sudo tee /etc/fail2ban/jail.d/sshd.local > /dev/null <<EOF
# Managed by phase2-harden.sh.
[sshd]
enabled = true
port = $SSH_PORT
EOF
sudo systemctl enable --now fail2ban

# --- unattended security updates --------------------------------------------

say "Enabling unattended security updates"
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -f noninteractive unattended-upgrades
sudo systemctl enable --now unattended-upgrades

# --- AppArmor check (verify only, no install) -------------------------------

say "Checking AppArmor is active"
if sudo aa-status --enabled 2>/dev/null; then
    echo "AppArmor is enabled and enforcing."
else
    echo "WARNING: AppArmor is not active. This ships enabled by default on"
    echo "Ubuntu — if it's off, something upstream of this script disabled it."
fi

# --- /tmp, /var/tmp, /dev/shm mount flags -----------------------------------

say "Checking noexec/nosuid/nodev on tmp-family mounts"
echo "Not auto-applied — these are fstab/systemd-mount edits specific to"
echo "each box's existing layout. Current mount options, for reference:"
findmnt -no OPTIONS /tmp 2>/dev/null || echo "/tmp: not a separate mount"
findmnt -no OPTIONS /var/tmp 2>/dev/null || echo "/var/tmp: not a separate mount"
findmnt -no OPTIONS /dev/shm 2>/dev/null || echo "/dev/shm: not a separate mount"

# --- journald retention ------------------------------------------------------

say "Setting journald retention (90 days / 1G cap)"
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/90-base-retention.conf > /dev/null <<EOF
# Managed by phase2-harden.sh.
[Journal]
MaxRetentionSec=90day
SystemMaxUse=1G
EOF
sudo systemctl restart systemd-journald

# --- restart sshd last --------------------------------------------------------

say "Applying sshd changes — restarting sshd now"
echo "If this is the last step you see, sshd restarted successfully."
echo "KEEP YOUR CURRENT SSH SESSION OPEN. Test a NEW connection on port"
echo "$SSH_PORT before closing this one."
sudo systemctl restart ssh

say "Phase 2 complete."
cat <<EOF

Before closing this session:
  1. Open a NEW terminal.
  2. Confirm you can connect on the new port:
       ssh -p $SSH_PORT $NEW_USER@<this-box-ip>
  3. Confirm root login is refused:
       ssh -p $SSH_PORT root@<this-box-ip>
     (should be rejected)

If step 2 fails, you still have this session open — fix sshd_config and
retry `sudo systemctl restart ssh` before disconnecting.

Optional smoke test, run whenever you're ready (not wired into this script):
  sudo apt install -y lynis && sudo lynis audit system
EOF
