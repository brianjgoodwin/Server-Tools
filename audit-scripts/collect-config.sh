#!/usr/bin/env bash
#
# Read-only config/state collector. Run ON the remote box. Writes a single
# tarball to /tmp, prints its path on the last line. Does not modify anything.
#
# Usage (from the remote box):
#   ./collect-config.sh
#
# Usage (from your Mac, one-liner):
#   ssh <host> 'bash -s' < collect-config.sh

set -euo pipefail

OUT="$(mktemp -d)/audit"
mkdir -p "$OUT"

run() {
    # $1 = output filename, rest = command. Never let one failing command
    # (e.g. a file that doesn't exist, or a command needing root) kill the run.
    local name="$1"; shift
    { "$@" ; } > "$OUT/$name" 2>&1 || echo "[command failed or needs root: $*]" >> "$OUT/$name"
}

# --- identity / OS -----------------------------------------------------
run hostname.txt hostname
run uname.txt uname -a
run os-release.txt cat /etc/os-release
run uptime.txt uptime

# Copy a root-owned directory's files by reading each one with sudo cat and
# writing it with our own shell, so the resulting files are owned by us
# (not root) and readable by the later tar step.
copy_dir_as_self() {
    local src="$1" dest="$2"
    mkdir -p "$dest"
    local found=0
    for f in "$src"/*; do
        [ -f "$f" ] || continue
        found=1
        sudo -n cat "$f" > "$dest/$(basename "$f")" 2>/dev/null \
            || echo "[needs root]" > "$dest/$(basename "$f").txt"
    done
    [ "$found" -eq 1 ] || echo "[directory empty or missing]" > "$dest/_note.txt"
}

# --- users / access ------------------------------------------------------
run passwd.txt cat /etc/passwd
run group.txt cat /etc/group
run sudoers.txt sudo -n cat /etc/sudoers
copy_dir_as_self /etc/sudoers.d "$OUT/sudoers.d"

mkdir -p "$OUT/authorized_keys"
for home in /root /home/*; do
    user=$(basename "$home")
    if sudo -n test -f "$home/.ssh/authorized_keys" 2>/dev/null; then
        sudo -n cat "$home/.ssh/authorized_keys" > "$OUT/authorized_keys/$user.txt" 2>/dev/null
    fi
done

# --- SSH config -----------------------------------------------------------
run sshd_config.txt sudo -n cat /etc/ssh/sshd_config
copy_dir_as_self /etc/ssh/sshd_config.d "$OUT/sshd_config.d"

# --- firewall / network ----------------------------------------------------
run ufw-status.txt sudo -n ufw status verbose
run iptables.txt sudo -n iptables -L -n -v
run nft-ruleset.txt sudo -n nft list ruleset
run listening-sockets.txt ss -tulpn

# --- packages ---------------------------------------------------------
run dpkg-selections.txt dpkg --get-selections
run apt-installed.txt apt list --installed

# --- services --------------------------------------------------------
run services-running.txt systemctl list-units --type=service --state=running --no-pager
run services-enabled.txt systemctl list-unit-files --state=enabled --no-pager

# --- scheduled jobs -----------------------------------------------------
mkdir -p "$OUT/crontabs"
for home in /root /home/*; do
    user=$(basename "$home")
    sudo -n crontab -u "$user" -l > "$OUT/crontabs/$user.txt" 2>/dev/null || true
done
run cron.d.txt sudo -n ls -la /etc/cron.d/
run systemd-timers.txt systemctl list-timers --all --no-pager

# --- disk / filesystem --------------------------------------------------
run df.txt df -h
run lsblk.txt lsblk

# --- web stack (harmless no-op if not present) ---------------------------
run php-version.txt php -v
run php-modules.txt php -m
copy_dir_as_self /etc/nginx/sites-enabled "$OUT/nginx-sites-enabled"
mkdir -p "$OUT/php-fpm-pool.d"
for d in /etc/php/*/fpm/pool.d; do
    [ -d "$d" ] && copy_dir_as_self "$d" "$OUT/php-fpm-pool.d"
done

# --- provisioning trace --------------------------------------------------
run cloud-init-log.txt sudo -n tail -n 200 /var/log/cloud-init.log

# --- package ---------------------------------------------------------
TARBALL="/tmp/audit-$(hostname)-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$TARBALL" -C "$(dirname "$OUT")" "$(basename "$OUT")"
rm -rf "$OUT"

echo "$TARBALL"
