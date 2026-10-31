# Server-Tools

Scripts to take a fresh Hetzner Ubuntu box from a root console to a hardened,
non-root-only server. Opinionated. Built for two machines — a Kirby host and
a dev box — not every machine.

## Tutorial

Get a root console on a new Hetzner box. Clone this repo onto it. Run
`new-server-provisioning/phase1-create-user.sh`. It'll ask you three
questions and set a sudo password. When it's done, it stops and tells you to
open a new terminal and SSH in as the user you just created. Do that. Make
sure `sudo` works. Then, as that user, run `phase2-harden.sh`. Keep your
first session open until you've confirmed a second one connects on the new
port. That's it — you have a server.

## How-to

- **Re-run phase 1 on a box that already has it?** Don't — it refuses, on
  purpose. Delete its `.env` first if you really mean it.
- **Change the SSH port after the fact?** Edit
  `/etc/ssh/sshd_config.d/90-base-hardening.conf`, then `sudo ufw allow
  <port>/tcp` before you restart `ssh`, not after.
- **Add a passwordless sudo command?** Edit the `/etc/sudoers.d/90-*-base`
  file phase 1 wrote. Match the command *and its flags* exactly, or it falls
  through to a password prompt.
- **Test changes before touching a real box?** Lima. `limactl start
  template://ubuntu`, copy the scripts over, break it, delete it.

## Reference

Script-level detail — flags, exit behavior, what each file writes — lives in
the scripts themselves, not here. Read the header comment at the top of
each `.sh` file. `.env.example` (once it exists) documents phase 2's inputs.

## Explanation

Two phases, not one, because the single fastest way to lock yourself out of
a fresh VPS is disabling root SSH before confirming the replacement login
actually works. The pause between them is the whole point.

Sudo is scoped, not blanket `NOPASSWD: ALL`, because a stolen SSH key
shouldn't hand over root for free. The account still needs a real password —
it's sudo-only, never usable over SSH, since password auth is off.

The SSH port change and `fail2ban` are both honest noise reduction, not real
security. Said so here because every checklist blog post pretends otherwise.

This exists because a decade-old PHP flaw got weaponized in October 2026 and
patching it by hand, on a box nobody had audited in years, was the moment
this stopped being optional.
