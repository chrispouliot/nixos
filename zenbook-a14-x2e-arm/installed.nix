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
    canTouchEfiVariables = true;
    efiSysMountPoint = "/boot";
  };

  # Don't spam kernel messages over the login/desktop console.
  boot.consoleLogLevel = lib.mkForce 3;


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

  services.openssh.enable = true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  system.stateVersion = "26.11";
}
