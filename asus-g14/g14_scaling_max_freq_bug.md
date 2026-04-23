Asus G14 Issue on USB C power where CPU frequency is stuck at 2ghz after power platform change and does not raise to real hardware max.

When platform profile changes (eg Balanced -> Quiet) occurs, amd_pstate correctly clamps cpu scaling_max_freq to 2ghz, but does not set it back
to the correct maximum when the profile changes back to Balanced or Performance. This is especially evident when on USB C power and not the Asus power adapter.
Could be a kernel driver bug or a firmware decision to not accept USB C as adequate power deliver (but this would likely not allow for setting it back
to the maximum, which is possible to do manually)

Re-assert hardware max scaling_max_freq whenever AC is connected. This works around amd_pstate not raising the cap
when platform_profile transitions from quiet back to balanced/performance.

``` 
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

  # Also run on boot (in case system boots already plugged in after a low-power state)
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

  # Trigger on AC plug-in via udev.
  # Add a small delay so asusd's profile change completes first.
  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", KERNEL=="ACAD", ATTR{online}=="1", RUN+="${pkgs.bash}/bin/bash -c '(sleep 6; ${pkgs.systemd}/bin/systemctl start cpu-max-freq-on-ac.service) &'"
  '';
  ```
