<img src="assets/icon.svg" width="64" height="64" alt="">

# intelnuc

NixOS config for a headless Intel NUC home server running Claude Code, Codex, gh, git and [T3 Code](https://t3.codes), reached over Tailscale SSH.

## What it does

- **Tailscale**: Tailscale SSH enabled; the firewall trusts only `tailscale0`, so nothing is reachable from the LAN.
- **Wi-Fi**: NetworkManager with power saving off; connect with `nmtui`.
- **Users**: `gaston` (personal, sudo) and `concrete` (work, no sudo). Each has its own home directory, so logins for Claude Code, Codex, gh, gcloud, wrangler and bws stay separate. Docker is rootless, one daemon per user.
- **T3 Code**: `t3 serve` runs as a system service per user: `http://intelnuc:3773` (`gaston`) and `http://intelnuc:3774` (`concrete`) on the tailnet.
- **Never sleeps**: suspend and hibernate targets are disabled and logind ignores power, sleep and lid events. The kernel reboots itself 10s after a panic.
- **Daily updates**: at 04:00, `flake-update.service` pulls root's checkout at `/root/intelnuc`, runs `nix flake update`, then commits and pushes `flake.lock`. `nixos-upgrade` then switches to the result, and reboots between 03:30 and 06:00 only if the kernel or initrd changed. Old generations are garbage-collected weekly (kept 14 days).
- **Unstable agents**: `claude-code` and `codex` come from `nixos-unstable`, `t3code` from `nixos-unstable-small`; the base system tracks `nixos-26.05`.

## Install

1. Install NixOS 26.05 on the NUC. Label the root partition `nixos` and the EFI partition `boot`, as in the manual.
2. **BIOS**: press F2 at boot, then go to *Power → Secondary Power Settings → After Power Failure* and set it to **Power On**. This is what turns the NUC back on after a power cut; the OS can't control it.
3. Clone and apply as `gaston` (create that user in the installer; otherwise the config creates it with password `changeme`, which you should change with `passwd`).
   ```sh
   nix-shell -p gh git   # fresh NixOS has neither yet
   gh auth login && gh auth setup-git
   gh repo clone gastonmichel/intelnuc ~/intelnuc
   cd ~/intelnuc
   git config --global user.name "Gastón Michel" && git config --global user.email "<your email>"
   nixos-generate-config --show-hardware-config > hardware-configuration.nix
   git add hardware-configuration.nix && git commit -m "Add intelnuc hardware config" && git push
   NIX_CONFIG="experimental-features = nix-command flakes" nixos-rebuild switch --flake .#intelnuc --sudo
   ```
4. Join the tailnet: `sudo tailscale up --ssh`. Your tailnet policy must also allow SSH to this machine (the default policy does).
5. Move the checkout to root, which pushes with a deploy key limited to this repo:
   ```sh
   # on the NUC, as root
   ssh-keygen -t ed25519 -N '' -C root@intelnuc -f /root/.ssh/intelnuc_deploy
   # on your machine: gh repo deploy-key add <(ssh root@intelnuc cat /root/.ssh/intelnuc_deploy.pub) -R gastonmichel/intelnuc --allow-write -t root@intelnuc
   GIT_SSH_COMMAND='ssh -i /root/.ssh/intelnuc_deploy -o IdentitiesOnly=yes' git clone git@github.com:gastonmichel/intelnuc.git /root/intelnuc
   cd /root/intelnuc
   git config core.sshCommand 'ssh -i /root/.ssh/intelnuc_deploy -o IdentitiesOnly=yes'
   nixos-rebuild switch --flake .#intelnuc
   rm -rf /home/gaston/intelnuc
   ```
   From then on, manage the server over `ssh root@intelnuc` (see `CLAUDE.md`).
6. Sign in to the agents as each user (`ssh gaston@intelnuc`, `ssh concrete@intelnuc`): `claude`, `codex login`, `gh auth login`, `gcloud auth login`, `wrangler login`, `bws-set-token`. Then pair T3 Code clients with `t3 pair`.
