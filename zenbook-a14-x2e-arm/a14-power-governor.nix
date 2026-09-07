{ pkgs, ... }:

let
  setGovernor = pkgs.writeShellScript "a14-set-power-governor" ''
    set -eu

    # Consume this request first. An event arriving during the check creates
    # another request, which the path unit processes after this run finishes.
    ${pkgs.coreutils}/bin/rm -f /run/a14-power-governor.pending

    governor=schedutil
    foundUcsi=0
    online=0

    # These are the supplies actually emitting the AC/BAT notifications.
    # Check every USB-C port: external power on either port is sufficient.
    for supply in /sys/class/power_supply/ucsi-source-psy-*/online; do
      [ -r "$supply" ] || continue
      foundUcsi=1
      read -r online < "$supply"
      if [ "$online" = 1 ]; then
        governor=performance
        break
      fi
    done

    # Fallback for kernels that do not expose UCSI supplies.
    if [ "$foundUcsi" = 0 ]; then
      supply=/sys/class/power_supply/qcom-battmgr-usb/online
      if [ -r "$supply" ]; then
        read -r online < "$supply"
        if [ "$online" = 1 ]; then
          governor=performance
        fi
      fi
    fi

    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
      [ -w "$policy/scaling_governor" ] || continue
      read -r current < "$policy/scaling_governor"
      if [ "$current" != "$governor" ]; then
        printf '%s\n' "$governor" > "$policy/scaling_governor"
      fi
    done

    printf 'Applied governor: %s (online=%s, UCSI=%s)\n' "$governor" "$online" "$foundUcsi"
  '';
in
{
  # Baseline until the power-source check runs.
  powerManagement.cpuFreqGovernor = "schedutil";

  systemd.services.a14-power-governor = {
    description = "Select CPU governor from AC power state";
    wantedBy = [ "multi-user.target" ];
    after = [ "cpufreq.service" ];
    # USB-C negotiation can generate several legitimate events in seconds.
    unitConfig.StartLimitBurst = 100;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${setGovernor}";
    };
  };

  systemd.paths.a14-power-governor = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = "/run/a14-power-governor.pending";
      Unit = "a14-power-governor.service";
    };
  };

  powerManagement.resumeCommands = ''
    ${pkgs.coreutils}/bin/touch /run/a14-power-governor.pending
  '';

  # Only UCSI source online transitions queue a governor check. Remember the
  # previous state per port in udev's database, so battery percentages and
  # repeated USB-C status notifications do not start the service.
  # A port's first notification also queues one initial synchronization.
  services.udev.extraRules = ''
    SUBSYSTEM!="power_supply", GOTO="a14_governor_end"
    KERNEL!="ucsi-source-psy-*", GOTO="a14_governor_end"
    ACTION!="add|change|remove", GOTO="a14_governor_end"
    ACTION=="remove", RUN+="${pkgs.coreutils}/bin/touch /run/a14-power-governor.pending", GOTO="a14_governor_end"
    ENV{POWER_SUPPLY_ONLINE}!="0|1", GOTO="a14_governor_end"

    IMPORT{db}="A14_GOVERNOR_ONLINE"
    ENV{POWER_SUPPLY_ONLINE}=="0", ENV{A14_GOVERNOR_ONLINE}=="0", GOTO="a14_governor_end"
    ENV{POWER_SUPPLY_ONLINE}=="1", ENV{A14_GOVERNOR_ONLINE}=="1", GOTO="a14_governor_end"

    ENV{A14_GOVERNOR_ONLINE}="$env{POWER_SUPPLY_ONLINE}"
    RUN+="${pkgs.coreutils}/bin/touch /run/a14-power-governor.pending"
    LABEL="a14_governor_end"
  '';
}
