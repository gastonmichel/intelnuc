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

  # Agent tooling tracks nixos-unstable so it stays close to upstream releases.
  # T3 Code moves fastest, so it comes from nixos-unstable-small.
  t3code = pkgs.unstable-small.t3code.override { enableClaude = true; };
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
    pkgs.unstable.claude-code
    pkgs.unstable.codex
    t3code
    pkgs.gh
    pkgs.git
    pkgs.nodejs
    pkgs.vim
    pkgs.tmux
    pkgs.htop
    pkgs.curl
    pkgs.wget
    pkgs.ripgrep
    pkgs.fd
    pkgs.jq
  ];

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
