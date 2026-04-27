{ config, lib, pkgs, ... }:

{
  ###########################################################################
  # ASUS G14 CPU frequency workarounds
  #
  # On AC power, amd_pstate sometimes leaves scaling_max_freq capped at ~2GHz
  # after platform_profile transitions (e.g. quiet -> balanced/performance).
  # This module re-asserts the hardware max via three triggers:
  #   1. udev rule on AC plug-in
  #   2. periodic timer (in case udev misses an event)
  #   3. on boot (in case system started already plugged in)
  ###########################################################################

  # Core service: raise CPU scaling_max_freq to hardware max when on AC
  systemd.services.cpu-max-freq-on-ac = {
    description = "Raise CPU scaling_max_freq to hardware max when on AC";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "set-max-freq-on-ac" ''
        if [ "$(cat /sys/class/power_supply/ACAD/online 2>/dev/null)" = "1" ]; then
          for cpu_dir in /sys/devices/system/cpu/cpu*/cpufreq; do
            if [ -f "$cpu_dir/cpuinfo_max_freq" ] && [ -w "$cpu_dir/scaling_max_freq" ]; then
              cat "$cpu_dir/cpuinfo_max_freq" > "$cpu_dir/scaling_max_freq"
            fi
          done
        fi
      '';
    };
  };

  # Trigger 1: run on boot in case the system started already plugged in
  systemd.services.cpu-max-freq-boot = {
    description = "Raise CPU scaling_max_freq on boot if on AC";
    wantedBy = [ "multi-user.target" ];
    after = [ "asusd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.systemd}/bin/systemctl start cpu-max-freq-on-ac.service";
    };
  };

  # Trigger 2: udev rule on AC plug-in.
  # Small delay lets asusd's profile change settle before we re-assert.
  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", KERNEL=="ACAD", ATTR{online}=="1", RUN+="${pkgs.bash}/bin/bash -c '(sleep 6; ${pkgs.systemd}/bin/systemctl start cpu-max-freq-on-ac.service) &'"
  '';

  # Trigger 3: periodic watchdog in case udev misses an event
  systemd.timers.cpu-max-freq-watchdog = {
    description = "Periodically re-assert CPU scaling_max_freq on AC";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "60s";
      OnUnitActiveSec = "60s";
      Unit = "cpu-max-freq-on-ac.service";
    };
  };
}
