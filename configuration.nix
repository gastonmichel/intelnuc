{
  config,
  lib,
  pkgs,
  ...
}:

let
  user = "gaston";
  # Work account, isolated from gaston: its own logins and no sudo.
  workUser = "concrete";
  # Checkout of this repo on the server, owned by root so only root (managed
  # over `ssh root@intelnuc`) can change what the daily upgrade builds.
  repoDir = "/root/intelnuc";
  t3codePort = 3773;
  workT3codePort = 3774;

  # Agent tooling (Claude Code, Codex, T3 Code) comes from nixos-unstable-small,
  # which picks up upstream releases days before nixos-unstable.
  t3code = t3codePkgs.t3code.override {
    enableClaude = true;
    inherit codex;
    inherit (pkgs.unstable-small) claude-code;
    t3code-unwrapped = t3codeUnwrapped;
  };

  # unstable-small often ships a T3 Code whose Electron Hydra hasn't built yet,
  # which would compile here for hours. Use nixos-unstable's build when it has
  # the same version (usually cached), and unstable-small only when it's newer.
  t3codePkgs =
    if
      lib.versionOlder pkgs.unstable.t3code.unwrapped.version pkgs.unstable-small.t3code.unwrapped.version
    then
      pkgs.unstable-small
    else
      pkgs.unstable;

  # nixpkgs' cargo setup hook now makes Rust builds link the system AWS-LC,
  # which codex doesn't depend on yet (fixed upstream in NixOS/nixpkgs@16b463698a),
  # so unstable-small's codex fails to build. Fall back to nixos-unstable's,
  # which is prebuilt in the binary cache, until the fix lands; this retires itself.
  codex =
    let
      upstream = pkgs.unstable-small.codex;
    in
    if lib.any (p: lib.getName p == "aws-lc") upstream.buildInputs then
      upstream
    else
      pkgs.unstable.codex;

  # Pin a newer T3 Code than nixpkgs ships. Only applies while nixpkgs is older,
  # so the pin retires itself once unstable-small catches up.
  t3codePin = {
    version = "0.1.3";
    srcHash = "sha256-xxmwaHPkXzR0CAtknCc6raAzcnPtmw8wxF3YO3WcbE4=";
    pnpmDepsHash = "sha256-ZLWw3MSdx0nnK88cm2asDvDXG4vCJOY+1NKF3ugMEGc=";
  };
  t3codeUnwrapped =
    let
      upstream = t3codePkgs.t3code.unwrapped;
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

  # Chainlink CRE CLI, not in nixpkgs: the official prebuilt release.
  crePin = {
    version = "1.39.0";
    hash = "sha256-6EDulF03QfvHajyuc3SbyaFzDMWMa6vF5lwlZ0E8evA=";
  };
  cre = pkgs.stdenv.mkDerivation {
    pname = "cre";
    inherit (crePin) version;
    src = pkgs.fetchurl {
      url = "https://github.com/smartcontractkit/cre-cli/releases/download/v${crePin.version}/cre_linux_amd64.tar.gz";
      inherit (crePin) hash;
    };
    sourceRoot = ".";
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];
    installPhase = ''
      install -Dm755 cre_v${crePin.version}_linux_amd64 $out/bin/cre
    '';
  };

  # Bitwarden Secrets Manager CLI. The access token is kept encrypted with the
  # TPM and host key via systemd-creds; store it once per user with `bws-set-token`.
  bwsTokenCred = "$HOME/.config/bws/token.cred";
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

  # One T3 Code server per user, so agents run with that user's logins.
  t3codeService = user: port: {
    description = "T3 Code server (${user})";
    after = [
      "network-online.target"
      "tailscaled.service"
      "user@${toString config.users.users.${user}.uid}.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    # Agents spawned by the server need the same tools as an interactive shell.
    path = [
      "/run/wrappers"
      "/etc/profiles/per-user/${user}"
      "/run/current-system/sw"
    ];
    environment = {
      HOME = "/home/${user}";
      # The user's rootless Docker daemon, kept running by linger.
      XDG_RUNTIME_DIR = "/run/user/${toString config.users.users.${user}.uid}";
      DOCKER_HOST = "unix:///run/user/${toString config.users.users.${user}.uid}/docker.sock";
    };
    serviceConfig = {
      User = user;
      Group = "users";
      WorkingDirectory = "/home/${user}";
      ExecStart = "${t3code}/bin/t3 serve --host 0.0.0.0 --port ${toString port}";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # No browser on a headless box: CLIs that open one (wrangler login, ...) print
  # the URL instead of failing.
  xdgOpen = pkgs.writeShellScriptBin "xdg-open" ''
    echo "Open in your browser: $1" >&2
  '';
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
    uid = 1000;
    description = "Gastón Michel";
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    # Change with `passwd` on first login.
    initialPassword = "changeme";
    openssh.authorizedKeys.keys = [ ];
    # Starts the user's systemd instance (rootless Docker) at boot.
    linger = true;
  };

  # Log in with `ssh concrete@intelnuc` (Tailscale SSH). Not in wheel, and home
  # directories are 700, so its logins stay separate from gaston's.
  users.users.${workUser} = {
    isNormalUser = true;
    uid = 1001;
    description = "Concrete (work)";
    linger = true;
  };

  # Rootless Docker per user: the docker group would be root-equivalent and
  # break the isolation between users.
  virtualisation.docker.rootless = {
    enable = true;
    setSocketVariable = true;
  };

  # ---------------------------------------------------------------------------
  # Packages
  # ---------------------------------------------------------------------------
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = [
    pkgs.unstable-small.claude-code
    codex
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
    pkgs.unstable-small.wrangler
    pkgs.unstable-small.doppler
    pkgs.openssl
    pkgs.google-cloud-sdk
    pkgs.python3
    pkgs.pnpm
    pkgs.bun
    pkgs.terraform
    bws
    cre
    xdgOpen
  ];

  # Nix manages Doppler's version; its self-updater can't write to the store.
  environment.variables.DOPPLER_ENABLE_VERSION_CHECK = "false";

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
  # T3 Code's headless browser (chrome-headless-shell, downloaded to ~/.t3/tools).
  # `t3 browser setup` only knows apt; these are the libraries it would install.
  programs.nix-ld.libraries = [
    pkgs.glib
    pkgs.nspr
    pkgs.nss
    pkgs.at-spi2-core
    pkgs.dbus
    pkgs.libx11
    pkgs.libxcb
    pkgs.libxcomposite
    pkgs.libxdamage
    pkgs.libxext
    pkgs.libxfixes
    pkgs.libxrandr
    pkgs.libxkbcommon
    pkgs.libgbm
    pkgs.alsa-lib
    pkgs.expat
  ];

  # ---------------------------------------------------------------------------
  # T3 Code servers, reachable over the tailnet at http://intelnuc:3773 (gaston)
  # and http://intelnuc:3774 (concrete). Pair a device with `t3 pair` as that user.
  # ---------------------------------------------------------------------------
  systemd.services.t3code = t3codeService user t3codePort;
  systemd.services.t3code-concrete = t3codeService workUser workT3codePort;

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
    # Runs as root; pushes with the repo's deploy key (core.sshCommand).
    environment.HOME = "/root";
    serviceConfig = {
      Type = "oneshot";
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

  # Lets root push flake.lock over SSH without a trust-on-first-use prompt.
  programs.ssh.knownHosts."github.com".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

  # A failed flake update still lets the upgrade run with the current lock.
  systemd.services.nixos-upgrade = {
    wants = [ "flake-update.service" ];
    after = [ "flake-update.service" ];
  };

  system.autoUpgrade = {
    enable = true;
    flake = "${repoDir}#intelnuc";
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
