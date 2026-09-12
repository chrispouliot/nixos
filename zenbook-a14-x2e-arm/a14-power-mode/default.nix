{ config, lib, pkgs, ... }:
let
  cfg = config.services.a14-power-mode;
  python = "${pkgs.python3}/bin/python3";
  controller = ./power_mode.py;
  command = pkgs.writeShellScriptBin "performancemode" ''
    exec ${python} ${controller} "$@"
  '';
in
{
  options.services.a14-power-mode = {
    enable = lib.mkEnableOption "A14 quiet defaults and per-command performance mode";
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "chris" ];
      description = "Existing local users allowed to request performance mode.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "aarch64-linux";
        message = "a14-power-mode is specific to the ARM ASUS UX3407NA.";
      }
      {
        assertion = !config.services.tlp.enable && !config.programs.gamemode.enable;
        message = "a14-power-mode owns the CPU governor. Disable TLP and GameMode to avoid competing writers.";
      }
    ];

    # Added to the existing custom A14 kernel; no separate module replacement.
    boot.kernelPatches = [ {
      name = "asus-ux3407na-persistent-fan-profile";
      patch = ./asus-glymur-ec-profile.patch;
    } ];
    boot.kernelModules = [ "asus-glymur-ec" ];
    powerManagement.cpuFreqGovernor = lib.mkForce "schedutil";
    services.power-profiles-daemon.enable = lib.mkForce false;

    # Known former charger-dependent governor service. Disabled units are masked
    # by NixOS, so any remaining old udev reference cannot restart the writer.
    systemd.services.a14-power-governor.enable = lib.mkForce false;
    systemd.timers.a14-power-governor.enable = lib.mkForce false;

    users.groups.a14-power-mode.members = cfg.users;
    environment.systemPackages = [ command ];
    systemd.services.a14-power-mode = {
      description = "A14 quiet defaults and performance requests";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-modules-load.service" "cpufreq.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${python} ${controller} --daemon";
        Restart = "on-failure";
        RestartSec = 5;
        User = "root";
        Group = "a14-power-mode";
        RuntimeDirectory = "a14-power-mode";
        RuntimeDirectoryMode = "0750";
        UMask = "0007";
        TimeoutStopSec = 15;
        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        PrivateTmp = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        # sysfs governor/profile writes are the service's intended privilege.
        ReadWritePaths = [ "/sys/devices" ];
      };
    };
  };
}
