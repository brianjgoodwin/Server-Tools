#!/usr/bin/env bash
#
# Base layer, phase 1. Run ONCE, as root, on a brand-new box — over the
# Hetzner cloud console, not SSH. Creates a non-root sudo user, scopes sudo
# deliberately (no blanket NOPASSWD), seeds /etc/skel, and installs the
# user's SSH key. Writes everything phase 2 will need into a .env file next
# to this script, then PAUSES — it does not touch sshd, the firewall, or
# root login. You must manually verify SSH access as the new user before
# running phase2-harden.sh.
#
# Usage (as root, on the target box):
#   ./phase1-create-user.sh

set -euo pipefail

ENV_FILE="$(dirname "$0")/.env"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    die "run this as root (phase 1 only — phase 2 runs as the new user)."
fi

if [ -f "$ENV_FILE" ]; then
    die "$ENV_FILE already exists. Phase 1 is meant to run once per box. Remove it first if you really want to re-run this."
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
case "$SCRIPT_DIR" in
    /root|/root/*)
        die "this repo is cloned under /root ($SCRIPT_DIR) — phase 2 runs as the new non-root user and can't reach anything under /root (mode 700). Re-clone it somewhere world-traversable, e.g. /opt/server-tools, and run phase 1 again."
        ;;
esac

say "Base layer — phase 1: create non-root sudo user"
echo "This will prompt for a username and an SSH public key, create the"
echo "user, scope sudo narrowly, and write $ENV_FILE for phase 2."
echo "It will NOT touch sshd, the firewall, or root login."

# --- gather input ---------------------------------------------------------

read -rp "Username for the new sudo user: " NEW_USER
[ -n "$NEW_USER" ] || die "username cannot be empty."
id "$NEW_USER" >/dev/null 2>&1 && die "user '$NEW_USER' already exists."

echo
echo "Paste the SSH public key for $NEW_USER (single line, e.g. contents of"
echo "id_ed25519.pub), then press enter:"
read -rp "> " NEW_USER_PUBKEY
[ -n "$NEW_USER_PUBKEY" ] || die "SSH public key cannot be empty — key-only auth is the whole point."

read -rp "SSH port to use from phase 2 onward [22]: " SSH_PORT
SSH_PORT="${SSH_PORT:-22}"

echo
echo "Set a sudo password for $NEW_USER. This is NOT an SSH login method —"
echo "password authentication over SSH is disabled in phase 2 regardless."
echo "It's needed because sudo is scoped to a narrow allowlist (see below);"
echo "anything outside that allowlist, including phase 2 itself, prompts"
echo "for this password rather than running passwordlessly."
while true; do
    read -rsp "Sudo password for $NEW_USER: " NEW_USER_PASSWORD
    echo
    read -rsp "Confirm: " NEW_USER_PASSWORD_CONFIRM
    echo
    [ -n "$NEW_USER_PASSWORD" ] || { echo "Password cannot be empty."; continue; }
    [ "$NEW_USER_PASSWORD" = "$NEW_USER_PASSWORD_CONFIRM" ] && break
    echo "Passwords didn't match — try again."
done

# --- create user ------------------------------------------------------------

say "Creating user '$NEW_USER'"
adduser --disabled-password --gecos "" "$NEW_USER"
usermod -aG sudo "$NEW_USER"
echo "$NEW_USER:$NEW_USER_PASSWORD" | chpasswd
unset NEW_USER_PASSWORD NEW_USER_PASSWORD_CONFIRM

# --- scope sudo deliberately -----------------------------------------------
#
# No blanket NOPASSWD. A small, explicit allowlist of low-risk commands run
# constantly; password required for everything else, including anything
# that could itself change the sudo/SSH/firewall posture.

say "Scoping sudo for '$NEW_USER' (no blanket NOPASSWD)"
SUDOERS_FILE="/etc/sudoers.d/90-${NEW_USER}-base"
cat > "$SUDOERS_FILE" <<EOF
# Managed by phase1-create-user.sh. Narrow, explicit allowlist only —
# everything else for $NEW_USER requires a password.
#
# sudoers matches commands VERBATIM, including flags. "apt update" and
# "apt update -q" are different rules — adding a flag to a command below
# without updating the line here silently falls through to a password
# prompt, not a clear error.
$NEW_USER ALL=(root) NOPASSWD: /usr/bin/apt update, /usr/bin/apt upgrade -y
EOF
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" || die "generated sudoers file failed validation — check $SUDOERS_FILE"

# --- /etc/skel --------------------------------------------------------------
#
# Seeds dotfiles for every future user created on this box, not just this
# one. If new-server-provisioning/skel/ doesn't exist yet, this is a no-op —
# it's wired up ahead of the dotfiles content existing, not instead of it.

SKEL_SRC="$(dirname "$0")/skel"
if [ -d "$SKEL_SRC" ]; then
    say "Copying skel additions into /etc/skel"
    cp -rT "$SKEL_SRC" /etc/skel
else
    say "No skel/ directory found next to this script — skipping (not an error)"
fi

# --- SSH key ----------------------------------------------------------------

say "Installing SSH key for '$NEW_USER'"
NEW_USER_HOME="/home/$NEW_USER"
install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$NEW_USER_HOME/.ssh"
echo "$NEW_USER_PUBKEY" > "$NEW_USER_HOME/.ssh/authorized_keys"
chmod 600 "$NEW_USER_HOME/.ssh/authorized_keys"
chown "$NEW_USER:$NEW_USER" "$NEW_USER_HOME/.ssh/authorized_keys"

# --- write phase 2's .env ---------------------------------------------------

say "Writing $ENV_FILE for phase 2"
cat > "$ENV_FILE" <<EOF
# Generated by phase1-create-user.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Consumed by phase2-harden.sh. Not committed — see .gitignore.
NEW_USER=$NEW_USER
SSH_PORT=$SSH_PORT
EOF
chmod 600 "$ENV_FILE"
chown "$NEW_USER:$NEW_USER" "$ENV_FILE"

# --- pause -------------------------------------------------------------------

say "Phase 1 complete. DO NOT run phase 2 yet."
cat <<EOF

Next steps:
  1. Open a NEW terminal (keep this console session open as a fallback).
  2. SSH in as the new user on the CURRENT port (still 22 until phase 2 runs):
       ssh $NEW_USER@<this-box-ip>
  3. Confirm sudo works:
       sudo apt update
  4. Only once that works, come back and run:
       ./phase2-harden.sh
     as '$NEW_USER' (not root).

Phase 2 will change the SSH port to $SSH_PORT, disable root login, and
disable password auth — if step 2 or 3 above fails, fix it now while root
login over the console is still available.
EOF
