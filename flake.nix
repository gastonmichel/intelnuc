{
  description = "NixOS configuration for intelnuc (headless coding-agent home server)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, nixpkgs-unstable, ... }:
    {
      nixosConfigurations.intelnuc = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          {
            # Exposes pkgs.unstable.* for packages that should track nixos-unstable.
            nixpkgs.overlays = [
              (final: prev: {
                unstable = import nixpkgs-unstable {
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
