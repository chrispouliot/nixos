# This is a fix for the Nvidia backlight re-enabling itself after HDMI/USB C hotplug and disabling laptop display brightness changes
# After hotplug, the kernel fires a hotplug event that wakes the nvidia dGPU and Gnome re-enumerates backlight devices and starts using the nvidia backlight
# which re-enabled itself and the brightness slider nolonger changes the display brightness (amd). This is because nvidia_0 shows up before the amd backlight handler
# This uses inotifywait to watch for writes to the nvidia backlight file, and mirrors it to the amd iGPU (also translates the raw brightness numbers)

{ config, lib, pkgs, ... }:

let
  cfg = config.services.nvidia-backlight-mirror;
in
{
  options.services.nvidia-backlight-mirror = {
    enable = lib.mkEnableOption "Nvidia <> AMD backlight mirror for hybrid graphics laptops";

    nvidiaDevice = lib.mkOption {
      type = lib.types.str;
      default = "nvidia_0";
      description = "Name of the Nvidia backlight device under /sys/class/backlight/.";
    };

    amdDevice = lib.mkOption {
      type = lib.types.str;
      default = "amdgpu_bl1";
      description = "Name of the AMD backlight device under /sys/class/backlight/ that actually drives the panel.";
    };

    waitSeconds = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "How long to wait for the Nvidia backlight to appear before assuming Integrated mode and exiting cleanly.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nvidia-backlight-mirror = {
      description = "Mirror ${cfg.nvidiaDevice} backlight writes to ${cfg.amdDevice} (GNOME hybrid graphics workaround)";
      wantedBy = [ "graphical.target" ];
      after = [ "systemd-udev-settle.service" ];
      path = with pkgs; [ inotify-tools coreutils ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "5s";
        ExecStart = pkgs.writeShellScript "nvidia-backlight-mirror" ''
          set -eu
          NV=/sys/class/backlight/${cfg.nvidiaDevice}
          AMD=/sys/class/backlight/${cfg.amdDevice}

          # Wait briefly for the Nvidia backlight to appear.
          # If it doesn't show up, we're likely in Integrated mode — exit cleanly.
          for i in $(seq 1 ${toString cfg.waitSeconds}); do
            [ -f "$NV/brightness" ] && break
            sleep 1
          done

          if [ ! -f "$NV/brightness" ]; then
            echo "${cfg.nvidiaDevice} not present (likely Integrated mode); nothing to mirror."
            exit 0
          fi

          if [ ! -f "$AMD/brightness" ]; then
            echo "${cfg.amdDevice} not present; cannot mirror." >&2
            exit 1
          fi

          NV_MAX=$(cat $NV/max_brightness)
          AMD_MAX=$(cat $AMD/max_brightness)

          echo "Mirroring $NV (max=$NV_MAX) > $AMD (max=$AMD_MAX)"

          while inotifywait -qq -e modify $NV/brightness; do
            VAL=$(cat $NV/brightness)
            SCALED=$(( VAL * AMD_MAX / NV_MAX )) # AMD and Nvidia backlights use different values
            echo $SCALED > $AMD/brightness
          done
        '';
      };
    };
  };
}
