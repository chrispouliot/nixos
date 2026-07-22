{ config, pkgs, lib, inputs, ... }:
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./xhci-suspend-fixes.nix
      ./cpu-max-freq.nix
      ./gamemode.nix
      ./helpers.nix
      ./agent-sandbox.nix
      ./dock-recover.nix
      ./asus-fan-curves.nix
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.blacklistedKernelModules = ["hid_logitech_dj"]; # This was spamming my journalctl and seemed like my logitech mouse acted weird

  boot.extraModulePackages = [ config.boot.kernelPackages.acpi_call ];
  boot.kernelModules = [ "acpi_call" ];

  boot.kernelParams = [
    "acpi_backlight=native" # This allows backlight change when on Hybrid mode.
    "thunderbolt.clx=0" # Disable TB4 CLx states (low power lane management) to see if it helps with flaky USB connections
  ];

  boot.initrd.kernelModules = [ "amdgpu" ]; # Load AMD first to help with eDP enumeration vs Nvidia race condition

  # Fix the Asus BIOS ACPI that would trigger dGPU wakeup on battery tick decrease
  boot.initrd.prepend = [ "${./acpi-override.cpio}" ];

  # Enable Flakes
  nix.settings.experimental-features = ["nix-command" "flakes"];

  networking.hostName = "nixos"; # Define your hostname.

  # Enable zram swap
  zramSwap.enable = true;

  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "America/Vancouver";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_CA.UTF-8";

  # Env vars
  environment.variables = {
    #GSK_RENDERER = "gl"; # use new openGL renderer instead of vulkan for gtk vulkan slowdown on nvidia bug
    # This stops the nvidia dGPU from being used for vulkan stuff?
    # Also removes gnome-shell from appearing in nvidia-smi with small resource usage
    # https://gitlab.gnome.org/GNOME/mutter/-/issues/2969
    #__EGL_VENDOR_LIBRARY_FILENAMES="/${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json";
    #__GLX_VENDOR_LIBRARY_NAME="mesa";
  };

  # Enable the GNOME Desktop Environment.
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Gnome experimental features
  programs.dconf.profiles.user.databases = [
    {
      lockAll = true; # prevents overriding
      settings = {
        "org/gnome/mutter" = {
          experimental-features = ["scale-monitor-framebuffer" "xwayland-native-scaling" "variable-refresh-rate"];
          workspaces-only-on-primary = false;
        };
      };
    }
  ];

  # Gnome enable contacts sync and address book for WebDav
  services.gnome.evolution-data-server.enable = true;
  services.gnome.gnome-online-accounts.enable = true;

  services.gnome.gnome-keyring.enable = true;
  security.pam.services.login.enableGnomeKeyring = true;

  # Fix TB4 PCIE d3cold issues and log spam
  services.udev.extraRules = ''
    ACTION=="add|bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x0b26", ATTR{d3cold_allowed}="0"
  '';
  powerManagement.resumeCommands = ''
    ${pkgs.pciutils}/bin/lspci -s 02: >/dev/null 2>&1 || true
    # only the TB bridge subtree, not the whole PCI tree
    for b in /sys/bus/pci/devices/0000:02:0*.0/rescan; do echo 1 > "$b" 2>/dev/null || true; done
  '';


  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Graphics for AMD
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
  # Graphics for Nvidia
  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = ["nvidia" "amdgpu"];
  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true; # Required for proper dynamic boost
    powerManagement.finegrained = false;
    dynamicBoost.enable = true; # Needed to use more than 55w base on laptop
    open = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      nvidiaBusId = "PCI:64:0:0";
      amdgpuBusId = "PCI:65:0:0";
    };
  };

  # NixOS Flake-based llm agent sandboxes
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

  # Asusctl
  services.asusd.enable = true;

  # Clean up older nixos generations, free up space
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 15d";
  };

  # Enable linux-firmware incase that helps with compatability on laptop
  hardware.enableRedistributableFirmware = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable direnv for automatic env loading per directory, especially for nix-shell envs
  programs.direnv = {
    enable = true;
    settings = {
      global = {
        log_format = "-";
        log_filter = "^$";
        hide_env_diff = true;
      };
    };
  };

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.chris = {
    isNormalUser = true;
    description = "chris";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = [];
  };

  services = {
    syncthing = {
        enable = true;
        group = "users";
        user = "chris";
        dataDir = "/home/chris/Documents";    # Default folder for new synced folders
        configDir = "/home/chris/.config/syncthing";   # Folder for Syncthing's settings and keys
    };
  };

  programs.firefox.enable = true;
  programs.firefox.nativeMessagingHosts.packages = [ pkgs.firefoxpwa ];

  # Enable tailscale
  services.tailscale.enable = true;

  # Proton bridge
  services.protonmail-bridge = {
    enable = true;
    path = with pkgs; [ pass gnupg ];
  };
  security.pki.certificateFiles = [ ./protonmail-bridge-cert.pem ]; # The Bridge SSL Cert

  # Enable cardwire for GPU on/off/hybrid support and nvidia lock
  services.cardwire = {
    enable = true;
    settings = {
      experimental_nvidia_block = true;
    };
  };

  # Locally made Openbubbles GTK app
  programs.bubbles.enable = true;

  # Firmware updates
  services.fwupd.enable = true;

  # Allow unfree software
  nixpkgs.config.allowUnfree = true;

  # Declare wanted flatpaks
  services.flatpak = {
    enable = true;
    uninstallUnmanaged = false;
    update.auto = { enable = true; onCalendar = "weekly"; };

    packages = [
      "org.onlyoffice.desktopeditors"
      "com.github.tchx84.Flatseal"
      "dev.qwery.AddWater"
      "us.zoom.Zoom"
      "com.jeffser.Nocturne"
      "io.m51.Gelly"
      "de.schmidhuberj.tubefeeder"
      "page.codeberg.libre_menu_editor.LibreMenuEditor"
      "com.moonlight_stream.Moonlight"
      "io.github.alainm23.planify"
      "io.github.tanaybhomia.Whisp"
      "dev.nicx.mimick"
    ];
  };

  # Vesktop needs old electron for now
  nixpkgs.config.permittedInsecurePackages = [
    "electron-40.10.5"
  ];

  environment.systemPackages = with pkgs; [
    # Local apps / extensions
    (pkgs.callPackage ./pkgs/touchpad-speed-control.nix { src = inputs.touchpad-speed-control; })
    (pkgs.callPackage ./pkgs/stamp.nix { src = inputs.stamp; })
    (pkgs.callPackage ./pkgs/notif-icon-colour.nix { }) # Local gnome extension, src in file directly
    (pkgs.callPackage ./pkgs/medialine.nix { src = inputs.medialine; })

    # Gnome specific
    gnomeExtensions.appindicator
    # gnomeExtensions.medialine # Not available in nixpkgs yet, manual install
    gnomeExtensions.steal-my-focus-window
    gnome-tweaks
    glycin-loaders # Temporary fix for gnome-contacts not coming with it (avatar loading)

    linux-firmware
    mission-center
    firefoxpwa
    mangohud
    prismlauncher
    brave
    vesktop
    obsidian
    zed-editor
    feishin
    vscode
    flatpak-builder
    collabora-desktop
    menulibre

    # Device utils
    pciutils
    lm_sensors
    vim wget git helix starship ghostty
    lshw lsof powertop nvtopPackages.full qastools
    gnupg pass # This is for keychain protonmail bridge stuff
  ];


  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?

}
