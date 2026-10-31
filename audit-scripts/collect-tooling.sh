#!/usr/bin/env bash
#
# Read-only personal-tooling audit. Run ON the remote box. Writes a single
# tarball to /tmp, prints its path on the last line. Does not modify anything.
#
# Captures: installed packages (apt + manual), language toolchains, and
# shell history (Atuin if present, else plain bash/zsh history files) — the
# goal is to find which CLI tools are actually reached for, not which are
# merely installed.
#
# Usage (from your Mac):
#   ssh <host> 'bash -s' < collect-tooling.sh

set -euo pipefail

OUT="$(mktemp -d)/tooling"
mkdir -p "$OUT"

run() {
    local name="$1"; shift
    { "$@" ; } > "$OUT/$name" 2>&1 || echo "[command failed or not available: $*]" >> "$OUT/$name"
}

# --- identity ------------------------------------------------------------
run hostname.txt hostname
run shell.txt bash -c 'echo "login shell: $SHELL"'

# --- packages --------------------------------------------------------------
run dpkg-selections.txt dpkg --get-selections
run apt-manual.txt apt-mark showmanual

# --- language toolchains / manual installs --------------------------------
run go-version.txt go version
run python-version.txt python3 --version
run pip-list.txt pip3 list --user
run npm-global.txt npm list -g --depth=0
run cargo-list.txt cargo install --list
run usr-local-bin.txt ls -la /usr/local/bin
run opt-dirs.txt ls -la /opt

# --- shell history ---------------------------------------------------------
# Prefer Atuin if it's set up -- it's a richer, deduped record than the
# plain history file. Fall back to bash/zsh history otherwise.
if command -v atuin &>/dev/null; then
    run atuin-top-commands.txt atuin stats
    run atuin-history-dump.txt atuin history list --format "{command}"
else
    echo "[atuin not installed]" > "$OUT/atuin-top-commands.txt"
fi

run bash-history.txt cat ~/.bash_history
run zsh-history.txt cat ~/.zsh_history

# --- package -----------------------------------------------------------
TARBALL="/tmp/tooling-$(hostname)-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$TARBALL" -C "$(dirname "$OUT")" "$(basename "$OUT")"
rm -rf "$OUT"

echo "$TARBALL"
