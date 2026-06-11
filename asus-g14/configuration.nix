{ config, pkgs, lib, ... }:
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./xhci-suspend-fixes.nix
      ./cpu-max-freq.nix
      ./gamemode.nix
      ./helpers.nix
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.blacklistedKernelModules = ["hid_logitech_dj"]; # This was spamming my journalctl and seemed like my logitech mouse acted weird

  boot.kernelParams = [
    "acpi_backlight=native" # This allows backlight change when on Hybrid mode.
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

  # Enable cardwire for GPU on/off/hybrid support and nvidia lock
  services.cardwire = {
    enable = true;
    settings = {
      experimental_nvidia_block = true;
    };
  };
  
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
    ];
  };

  # List packages installed in system profile. To search, run:
  # Spam pkgs until I can figure out the with pkgs; and script var syntax
  environment.systemPackages = with pkgs; [
    vim wget git helix starship
    gnomeExtensions.appindicator
    gnomeExtensions.media-controls
    gnome-tweaks
    linux-firmware
    mission-center
    lm_sensors
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
    lshw lsof powertop nvtopPackages.full qastools
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?

}
