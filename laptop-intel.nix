# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./flatpak.nix
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_cachyos;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "laptop"; # Define your hostname.

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "America/Vancouver";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_CA.UTF-8";

  # Set to schedutil and passive so Energy Aware Scheduling works for Intel Lunar Lake
  powerManagement.cpuFreqGovernor = "schedutil";
  boot.kernelParams = [ "intel_pstate=passive" ];
  # Enable TLP and disable Gnome's built-in PPD
  services.power-profiles-daemon.enable = false;
  services.tlp = {
    enable = true;
    settings = {
      CPU_DRIVER_OPMODE_ON_AC="passive";
      CPU_DRIVER_OPMODE_ON_BAT="passive";

      CPU_SCALING_GOVERNOR_ON_AC = "schedutil";
      CPU_SCALING_GOVERNOR_ON_BAT = "schedutil";
      #CPU_SCALING_MIN_FREQ_ON_AC=423000;
      #CPU_SCALING_MAX_FREQ_ON_AC=4000000;
      #CPU_SCALING_MIN_FREQ_ON_BAT=423000;
      #CPU_SCALING_MAX_FREQ_ON_BAT=3800000;
      #CPU_BOOST_ON_AC=0;
      #CPU_BOOST_ON_BAT=0;
      CPU_MIN_PERF_ON_AC=0;
      CPU_MAX_PERF_ON_AC=90;
      CPU_MIN_PERF_ON_BAT=0;
      CPU_MAX_PERF_ON_BAT=65;

      #Optional helps save long term battery health
      #START_CHARGE_THRESH_BAT0 = 40; # 40 and below it starts to charge
      #STOP_CHARGE_THRESH_BAT0 = 80; # 80 and above it stops charging

      };
  };

  # Enable the X11 windowing system.
  services.xserver.enable = true;
  # Swap win and alt keys for my keyboard in windows mode
  services.xserver.xkb.options = "['altwin:swap_alt_win']";

  # Enable the GNOME Desktop Environment.
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

    # Gnome experimental features
  programs.dconf.profiles.user.databases = [
    {
      lockAll = true; # prevents overriding
      settings = {
        "org/gnome/mutter" = {
          experimental-features = ["scale-monitor-framebuffer" "xwayland-native-scaling"];
        };
        "org/gnome/desktop/input-sources" = {
          xkb-options = [ "altwin:swap_alt_win"];
        };
      };
    }
  ];

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;


  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver # LIBVA_DRIVER_NAME=iHD
      intel-vaapi-driver # LIBVA_DRIVER_NAME=i965 (older but works better for Firefox/Chromium)
      libvdpau-va-gl
    ];
  };
  environment.sessionVariables = { LIBVA_DRIVER_NAME = "iHD"; }; # Force intel-media-driver

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.chris = {
    isNormalUser = true;
    description = "chris";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [
    #  thunderbird
    ];
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

  # Framework fan control systemd program, needed by fanctl gnome extension
  hardware.fw-fanctrl.enable = true;

  # Configure Firefox PWA
  programs.firefox.nativeMessagingHosts.packages = [ pkgs.firefoxpwa ];

  # Flatpak and Flathub
  services.flatpak.enable = true;

  # Install firefox.
  programs.firefox.enable = true;

  # Enable tailscale
  services.tailscale.enable = true;

  # Enable steam
  programs.steam.enable = true;

  # Firmware updates
  services.fwupd.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
  #  vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
  #  wget
    vim wget git helix
    gnomeExtensions.appindicator
    gnomeExtensions.framework-fan-control
    gnome-tweaks
    linux-firmware
    firefoxpwa
    mission-center
    spotify
    spotify-player
    sbctl
    lm_sensors
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
