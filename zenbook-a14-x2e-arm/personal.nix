{ lib, pkgs, inputs, ... }:
{
  imports = [
    ./agent-sandbox.nix
    ./a14-vaapi-kernel
    ./steam-arm64.nix
    ./helpers.nix
    ./a14-dock-boot-recovery.nix
  ];
  hardware.a14DockBootRecovery.enable = true; # My TB4/USB4 dock needs some help
  hardware.enableAllFirmware = true;

  hardware.asus.zenbookA14 = {
    firmwareSource = ./firmware;
    audio.speakerGain = 1.50;
    experimental.scmiMailbox = true;
    diagnostics.verbose = true;
    diagnostics.ramoops32GiB.enable = true;
  };

  # Memory
    swapDevices = [
    {
      device = "/swapfile";
      size = 16 * 1024; # MiB: 16 GiB
      priority = 10;
    }
  ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100;
  };



  networking.networkmanager.enable = true;
  networking.networkmanager.wifi.powersave = false;
  # Enable Tailscale.
  services.tailscale.enable = true;

  # Dev shells automatically enabling on .envrc file
  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    nix-direnv.enable = true;
  }; 

  services.syncthing = {
    enable = true;
    group = "users";
    user = "chris";
    dataDir = "/home/chris/Documents";
    configDir = "/home/chris/.config/syncthing";
  };

  # Locally made OpenBubbles GTK app.
  programs.bubbles.enable = true;

  # Proton Bridge.
  #
  # GNOME Keyring/Secret Service is enabled by installed.nix, so
  # Bridge does not need pass/gnupg explicitly added to its PATH.
  services.protonmail-bridge.enable = true;

  security.pki.certificateFiles = [
    ./protonmail-bridge-cert.pem
  ];


  # Locally made agent sandbox
  programs.agentSandbox = {
    enable = true;
    defaultAgent = "opencode";
    extraTools = ["jq"];
    diskWarn = {
      enable = true;
      checkIntervalHours = 6;
      minFreeGiB = 80; # Nix store size, including host
      volumeWarnGiB = 30; # Podman volumes (per project combines)
    };
  };

  # ------------------------------------------------------------
  # Flatpaks
  # ------------------------------------------------------------

  services.flatpak = {
    enable = true;
    uninstallUnmanaged = false;

    update.auto = {
      enable = true;
      onCalendar = "weekly";
    };

    packages = [
      "org.onlyoffice.desktopeditors"
      "com.github.tchx84.Flatseal"
      "dev.qwery.AddWater"
      "com.jeffser.Nocturne"
      "de.schmidhuberj.tubefeeder"
      "page.codeberg.libre_menu_editor.LibreMenuEditor"
      "com.moonlight_stream.Moonlight"
      "io.github.alainm23.planify"
      "io.github.tanaybhomia.Whisp"
      "org.zotero.Zotero"
      "md.obsidian.Obsidian"
    ];
  };


  # ------------------------------------------------------------
  # Packages
  # ------------------------------------------------------------

  programs.firefox.nativeMessagingHosts.packages = [ pkgs.firefoxpwa ];

  environment.systemPackages = with pkgs; [
    # Local apps / extensions
    (pkgs.callPackage ./pkgs/touchpad-speed-control.nix {
      src = inputs.touchpad-speed-control;
    })

    # Local GNOME extension, source is contained in the package file.
    (pkgs.callPackage ./pkgs/notif-icon-colour.nix { })

    (pkgs.callPackage ./pkgs/medialine.nix {
      src = inputs.medialine;
    })

    gnomeExtensions.appindicator
    # gnomeExtensions.medialine # Not available in nixpkgs yet, manual install
    gnomeExtensions.steal-my-focus-window

    git
    ripgrep
    vim

    pciutils
    usbutils
    ethtool
    iw

    lm_sensors

    drm_info
    mesa-demos
    vulkan-tools
    kmscube

    alsa-utils
    dtc

    firefoxpwa
    brave-origin
    mission-center
    menulibre
    prismlauncher
    ghostty
    mangohud

    # Vesktop Electron bug fix: appindicator wouldn't show with
    # Electron 43, so temporarily use Electron 42.
    ((vesktop.override {
      electron_43 = electron_42;
    }).overrideAttrs (_old: {
      preBuild = ''
        cp -r ${electron_42.dist} electron-dist
        chmod -R u+w electron-dist
      '';
    }))
  ];
}
