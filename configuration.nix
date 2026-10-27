{
  config,
  lib,
  pkgs,
  ...
}:

let
  user = "gaston";
  home = "/home/${user}";
  # Checkout of this repo on the server; daily upgrades build from here.
  repoDir = "${home}/intelnuc";
  t3codePort = 3773;

  # Agent tooling (Claude Code, Codex, T3 Code) comes from nixos-unstable-small,
  # which picks up upstream releases days before nixos-unstable.
  t3code = pkgs.unstable-small.t3code.override {
    enableClaude = true;
    t3code-unwrapped = t3codeUnwrapped;
  };

  # Pin a newer T3 Code than nixpkgs ships. Only applies while nixpkgs is older,
  # so the pin retires itself once unstable-small catches up.
  t3codePin = {
    version = "0.1.3";
    srcHash = "sha256-xxmwaHPkXzR0CAtknCc6raAzcnPtmw8wxF3YO3WcbE4=";
    pnpmDepsHash = "sha256-ZLWw3MSdx0nnK88cm2asDvDXG4vCJOY+1NKF3ugMEGc=";
  };
  t3codeUnwrapped =
    let
      upstream = pkgs.unstable-small.t3code.unwrapped;
    in
    if lib.versionOlder upstream.version t3codePin.version then
      upstream.overrideAttrs (
        finalAttrs: old: {
          inherit (t3codePin) version;
          src = old.src.override {
            tag = "v${t3codePin.version}";
            hash = t3codePin.srcHash;
          };
          pnpmDeps = old.pnpmDeps.overrideAttrs {
            inherit (finalAttrs) version src;
            outputHash = t3codePin.pnpmDepsHash;
          };
        }
      )
    else
      upstream;

  # Newer npm than the one bundled with Node.js; takes priority over it on PATH.
  # Drop it once nodejs_26 bundles this version or later.
  npmPin = {
    version = "12.2.1";
    hash = "sha256-IovWSq7yMnDb29LPPV71xGdgLvOMQGYkbO8ZhK2rmmc=";
  };
  npm = lib.hiPrio (
    pkgs.stdenvNoCC.mkDerivation {
      pname = "npm";
      inherit (npmPin) version;
      src = pkgs.fetchurl {
        url = "https://registry.npmjs.org/npm/-/npm-${npmPin.version}.tgz";
        inherit (npmPin) hash;
      };
      nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
      installPhase = ''
        mkdir -p $out/lib/node_modules/npm
        cp -r . $out/lib/node_modules/npm
        for cmd in npm npx; do
          makeWrapper ${pkgs.nodejs_26}/bin/node $out/bin/$cmd \
            --add-flags $out/lib/node_modules/npm/bin/$cmd-cli.js
        done
      '';
    }
  );

  # Bitwarden Secrets Manager CLI. The access token is kept encrypted with the
  # TPM and host key via systemd-creds; store it once with `bws-set-token`.
  bwsTokenCred = "${home}/.config/bws/token.cred";
  systemdCreds = "${config.systemd.package}/bin/systemd-creds";
  bws = pkgs.symlinkJoin {
    name = "bws-wrapped";
    paths = [
      (pkgs.writeShellScriptBin "bws" ''
        if [ -z "''${BWS_ACCESS_TOKEN:-}" ] && [ -f ${bwsTokenCred} ]; then
          BWS_ACCESS_TOKEN=$(${systemdCreds} --user decrypt --name=bws-token ${bwsTokenCred} -) || exit 1
          export BWS_ACCESS_TOKEN
        fi
        exec ${pkgs.bws}/bin/bws "$@"
      '')
      (pkgs.writeShellScriptBin "bws-set-token" ''
        set -euo pipefail
        install -d -m 700 "$(dirname ${bwsTokenCred})"
        read -rsp "Bitwarden access token: " token; echo
        printf '%s' "$token" | ${systemdCreds} --user encrypt --with-key=host+tpm2 \
          --name=bws-token - ${bwsTokenCred}
        chmod 600 ${bwsTokenCred}
        echo "Saved to ${bwsTokenCred}"
      '')
    ];
  };
in
{
  networking.hostName = "intelnuc";
  time.timeZone = "America/Argentina/Buenos_Aires";
  i18n.defaultLocale = "en_US.UTF-8";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ---------------------------------------------------------------------------
  # Availability: never sleep, recover from crashes.
  # Booting after a power cut is a firmware setting, see README.md.
  # ---------------------------------------------------------------------------
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  services.logind.settings.Login = {
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    IdleAction = "ignore";
  };

  # Reboot 10s after a kernel panic instead of hanging.
  boot.kernel.sysctl = {
    "kernel.panic" = 10;
    "kernel.panic_on_oops" = 1;
  };

  # ---------------------------------------------------------------------------
  # Networking: everything is reached over Tailscale.
  # ---------------------------------------------------------------------------
  # Wi-Fi via NetworkManager: `nmtui` or `nmcli device wifi connect <ssid> password <pass>`.
  networking.networkmanager = {
    enable = true;
    # Power saving causes latency spikes and dropped connections on an always-on box.
    wifi.powersave = false;
  };

  services.tailscale = {
    enable = true;
    openFirewall = true;
    # Only applied automatically with an authKeyFile; otherwise run
    # `sudo tailscale up --ssh` once after install.
    extraUpFlags = [ "--ssh" ];
  };

  networking.firewall = {
    enable = true;
    # Nothing is exposed on the LAN; tailnet peers can reach every port.
    trustedInterfaces = [ "tailscale0" ];
  };

  # Fallback if Tailscale SSH is unavailable; reachable over the tailnet only.
  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ---------------------------------------------------------------------------
  # User
  # ---------------------------------------------------------------------------
  users.users.${user} = {
    isNormalUser = true;
    description = "Gastón Michel";
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    # Change with `passwd` on first login.
    initialPassword = "changeme";
    openssh.authorizedKeys.keys = [ ];
  };

  # ---------------------------------------------------------------------------
  # Packages
  # ---------------------------------------------------------------------------
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = [
    pkgs.unstable-small.claude-code
    pkgs.unstable-small.codex
    t3code
    pkgs.gh
    pkgs.git
    pkgs.nodejs_26
    npm
    pkgs.vim
    pkgs.tmux
    pkgs.htop
    pkgs.curl
    pkgs.wget
    pkgs.ripgrep
    pkgs.fd
    pkgs.jq
    pkgs.wrangler
    bws
  ];

  # Forward OSC 52 clipboard writes (e.g. Claude Code's /copy) to the SSH
  # client's terminal so copies land on the local machine.
  programs.tmux = {
    enable = true;
    extraConfig = ''
      set -s set-clipboard on
      set -g allow-passthrough on
    '';
  };

  # Lets agents run prebuilt binaries pulled in by npm, MCP servers, etc.
  programs.nix-ld.enable = true;

  # ---------------------------------------------------------------------------
  # T3 Code server, reachable at http://intelnuc:3773 over the tailnet.
  # Pair a device with `t3 pair`.
  # ---------------------------------------------------------------------------
  systemd.services.t3code = {
    description = "T3 Code server";
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    # Agents spawned by the server need the same tools as an interactive shell.
    path = [
      "/run/wrappers"
      "/etc/profiles/per-user/${user}"
      "/run/current-system/sw"
    ];
    environment.HOME = home;
    serviceConfig = {
      User = user;
      Group = "users";
      WorkingDirectory = home;
      ExecStart = "${t3code}/bin/t3 serve --host 0.0.0.0 --port ${toString t3codePort}";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # ---------------------------------------------------------------------------
  # Daily updates: bump flake.lock, push it, rebuild, reboot if the kernel changed.
  # ---------------------------------------------------------------------------
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  systemd.services.flake-update = {
    description = "Update intelnuc flake inputs";
    path = [
      pkgs.git
      pkgs.openssh
      pkgs.gh
      config.nix.package
    ];
    environment.HOME = home;
    serviceConfig = {
      Type = "oneshot";
      User = user;
      WorkingDirectory = repoDir;
    };
    script = ''
      git pull --ff-only || echo "warning: git pull failed, updating local checkout anyway"
      nix flake update
      if ! git diff --quiet -- flake.lock; then
        git -c user.name=intelnuc -c user.email=intelnuc@localhost \
          commit -m "flake.lock: daily update" -- flake.lock
        git push || echo "warning: git push failed"
      fi
    '';
  };

  # A failed flake update still lets the upgrade run with the current lock.
  systemd.services.nixos-upgrade = {
    wants = [ "flake-update.service" ];
    after = [ "flake-update.service" ];
  };

  system.autoUpgrade = {
    enable = true;
    # path: avoids git's ownership check when root reads gaston's checkout.
    flake = "path:${repoDir}#intelnuc";
    flags = [ "-L" ];
    dates = "04:00";
    randomizedDelaySec = "30min";
    allowReboot = true;
    rebootWindow = {
      lower = "03:30";
      upper = "06:00";
    };
  };

  system.stateVersion = "26.05";
}
