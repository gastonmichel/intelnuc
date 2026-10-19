<img src="assets/icon.svg" width="64" height="64" alt="">

# intelnuc

NixOS config for a headless Intel NUC home server running Claude Code, Codex, gh, git and [T3 Code](https://t3.codes), reached over Tailscale SSH.

## What it does

- **Tailscale**: Tailscale SSH enabled; the firewall trusts only `tailscale0`, so nothing is reachable from the LAN.
- **Wi-Fi**: NetworkManager with power saving off; connect with `nmtui`.
- **T3 Code**: `t3 serve` runs as a system service on port 3773 as `gaston`, at `http://intelnuc:3773` on the tailnet.
- **Never sleeps**: suspend and hibernate targets are disabled and logind ignores power, sleep and lid events. The kernel reboots itself 10s after a panic.
- **Daily updates**: at 04:00, `flake-update.service` pulls the repo, runs `nix flake update`, then commits and pushes `flake.lock`. `nixos-upgrade` then switches to the result, and reboots between 03:30 and 06:00 only if the kernel or initrd changed. Old generations are garbage-collected weekly (kept 14 days).
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
5. Sign in to the agents: `claude`, `codex login`. Then pair T3 Code clients with `t3 pair`.

The daily update pushes as `gaston`, so the `gh auth setup-git` in step 3 has to stay valid.
