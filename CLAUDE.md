# intelnuc

NixOS flake for `intelnuc`, a headless home server (users `gaston` and `concrete`) that runs Claude Code, Codex, gh, git and T3 Code, reached only over Tailscale SSH.

- `flake.nix`: inputs (`nixos-26.05` for the base system, `nixos-unstable` exposed as `pkgs.unstable`, `nixos-unstable-small` as `pkgs.unstable-small`)
- `configuration.nix`: the whole system config
- `hardware-configuration.nix`: generated on the NUC by `nixos-generate-config`; don't hand-edit

## Conventions

- Agent tooling (claude-code, codex, t3code) comes from `pkgs.unstable-small`; everything else from stable.
- Nothing is exposed on the LAN. New services bind to `0.0.0.0` and rely on `tailscale0` being a trusted firewall interface.
- The server rebuilds itself daily from its checkout at `/root/intelnuc`, after `flake-update.service` commits and pushes `flake.lock`. Anything merged to `main` goes live at the next 04:00 run.

## Users

- `gaston`: personal account, in `wheel` (sudo with password). T3 Code on `:3773`.
- `concrete`: work account, no sudo. T3 Code on `:3774`. Its logins (claude, codex, gh, gcloud, wrangler, doppler, bws) live in its own `$HOME` and stay separate from gaston's; keep it out of `wheel` and other root-equivalent groups (e.g. `docker`, which is why Docker is rootless).
- `root`: owns the server checkout at `/root/intelnuc` and is the only user that rebuilds. The server is managed from the Mac over `ssh root@intelnuc` (Tailscale SSH, no password).

## Workflow

After every change:

1. Check that the config evaluates. On macOS (no Nix), run it in Docker; the `intelnuc-nix` volume caches the store between runs, and `path:` avoids needing the worktree's `.git`:
   ```sh
   docker run --rm -v "$PWD":/src:ro -v intelnuc-nix:/nix nixos/nix \
     nix --extra-experimental-features 'nix-command flakes' \
     eval --raw 'path:/src#nixosConfigurations.intelnuc.config.system.build.toplevel.drvPath'
   ```
2. Commit and push to the default branch (`main`).
3. Update the server: pull, build, then switch.
   ```sh
   ssh root@intelnuc 'cd /root/intelnuc && git pull --ff-only && nixos-rebuild build --flake .#intelnuc && nixos-rebuild switch --flake .#intelnuc'
   ```
   Skip this to let the 04:00 run pick it up. If the switch breaks SSH, roll back from the console with `nixos-rebuild switch --rollback`.
