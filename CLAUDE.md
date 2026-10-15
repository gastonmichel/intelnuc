# intelnuc

NixOS flake for `intelnuc`, a headless home server (user `gaston`) that runs Claude Code, Codex, gh, git and T3 Code, reached only over Tailscale SSH.

- `flake.nix`: inputs (`nixos-26.05` for the base system, `nixos-unstable` exposed as `pkgs.unstable`)
- `configuration.nix`: the whole system config
- `hardware-configuration.nix`: generated on the NUC by `nixos-generate-config`; don't hand-edit

## Conventions

- Agent tooling (claude-code, codex, t3code) comes from `pkgs.unstable`; everything else from stable.
- Nothing is exposed on the LAN. New services bind to `0.0.0.0` and rely on `tailscale0` being a trusted firewall interface.
- The server rebuilds itself daily from its checkout at `/home/gaston/intelnuc`, after `flake-update.service` commits and pushes `flake.lock`. Anything merged to `main` goes live at the next 04:00 run.

## Workflow

- After every change, commit and push to the default branch (`main`).
- Before pushing, check that the config evaluates:
  `nix eval --raw .#nixosConfigurations.intelnuc.config.system.build.toplevel.drvPath`
  (on macOS without Nix, run it in the `nixos/nix` Docker image).
- To apply on the server right away: `nixos-rebuild switch --flake ~/intelnuc#intelnuc --sudo`
