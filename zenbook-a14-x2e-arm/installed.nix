{ lib, pkgs, ... }:

{
  networking.hostName = "a14";

  # ------------------------------------------------------------
  # Bootloader
  # ------------------------------------------------------------

  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 5;

    # Explicit for clarity; this is also automatically enabled when
    # hardware.deviceTree.enable=true and hardware.deviceTree.name is set.
    installDeviceTree = true;
  };

  boot.loader.efi = {
    canTouchEfiVariables = false;
    efiSysMountPoint = "/boot";
  };

  # Don't spam kernel messages over the login/desktop console.
  boot.consoleLogLevel = lib.mkForce 3;

  # CPU Boost
  systemd.tmpfiles.rules = [
    "w /sys/devices/system/cpu/cpufreq/boost - - - - 1"
  ];


  # ------------------------------------------------------------
  # GNOME
  # ------------------------------------------------------------

  services.xserver.enable = true;
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Gnome enable contacts sync and address book for WebDav
  services.gnome.evolution-data-server.enable = true;
  services.gnome.gnome-online-accounts.enable = true;

  services.gnome.gnome-keyring.enable = true;
  security.pam.services.login.enableGnomeKeyring = true;

  hardware.graphics.enable = true;

  # Audio userspace. Hardware audio bring-up can be fixed separately.
  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  nix = {
    daemonCPUSchedPolicy = "idle";
    daemonIOSchedClass = "idle";

    settings = {
      cores = 16; # 16 out of 18

      experimental-features = [
      "nix-command"
      "flakes"
      ];
    };
  };

  # ------------------------------------------------------------
  # Bluetooth
  # ------------------------------------------------------------

  # Enable the userspace stack even though QCC2072 firmware bring-up
  # still needs additional kernel work.
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };


  # ------------------------------------------------------------
  # User
  # ------------------------------------------------------------

  users.users.chris = {
    isNormalUser = true;
    description = "Chris";

    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
      "render"
    ];
  };


  # ------------------------------------------------------------
  # Administration
  # ------------------------------------------------------------

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  services.openssh.enable = true;

  system.stateVersion = "26.11";
}
