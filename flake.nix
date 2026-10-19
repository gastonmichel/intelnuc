{
  description = "NixOS configuration for intelnuc (headless coding-agent home server)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-unstable-small.url = "github:NixOS/nixpkgs/nixos-unstable-small";
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-unstable,
      nixpkgs-unstable-small,
      ...
    }:
    {
      nixosConfigurations.intelnuc = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          {
            # Exposes pkgs.unstable.* (nixos-unstable) and pkgs.unstable-small.*
            # (nixos-unstable-small, which picks up package bumps days earlier).
            nixpkgs.overlays = [
              (final: prev: {
                unstable = import nixpkgs-unstable {
                  inherit (prev.stdenv.hostPlatform) system;
                  config.allowUnfree = true;
                };
                unstable-small = import nixpkgs-unstable-small {
                  inherit (prev.stdenv.hostPlatform) system;
                  config.allowUnfree = true;
                };
              })
            ];
          }
          ./hardware-configuration.nix
          ./configuration.nix
        ];
      };
    };
}
