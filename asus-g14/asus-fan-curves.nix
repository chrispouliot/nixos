{ config, pkgs, ... }:

let
  applyFanCurves = pkgs.writeShellApplication {
    name = "apply-asus-fan-curves";

    runtimeInputs = [
      config.services.asusd.package
      pkgs.coreutils
    ];

    text = ''
      # Wait until asusd's D-Bus interface is ready.
      attempts=0
      until asusctl fan-curve --mod-profile balanced >/dev/null 2>&1; do
        attempts=$((attempts + 1))

        if [ "$attempts" -ge 30 ]; then
          echo "asusd did not become ready" >&2
          exit 1
        fi

        sleep 1
      done

      set_curve() {
        profile="$1"
        fan="$2"
        curve="$3"

        echo "Setting $profile $fan curve"
        asusctl fan-curve \
          --mod-profile "$profile" \
          --fan "$fan" \
          --data "$curve"
      }

      #
      # QUIET
      #

      set_curve quiet cpu \
        '40c:0%,55c:0%,65c:0%,72c:0%,76c:15%,82c:30%,88c:55%,95c:100%'

      set_curve quiet gpu \
        '40c:0%,55c:0%,65c:0%,70c:0%,74c:20%,79c:40%,83c:70%,86c:100%'

      set_curve quiet mid \
        '40c:0%,55c:0%,68c:0%,75c:0%,80c:15%,85c:35%,90c:65%,95c:100%'

      #
      # BALANCED
      #

      set_curve balanced cpu \
        '40c:0%,55c:0%,62c:0%,68c:0%,72c:15%,78c:30%,85c:55%,95c:100%'

      set_curve balanced gpu \
        '40c:0%,55c:0%,65c:0%,68c:0%,72c:20%,77c:35%,82c:60%,86c:100%'

      set_curve balanced mid \
        '40c:0%,55c:0%,65c:0%,72c:0%,76c:15%,82c:35%,88c:65%,95c:100%'

      #
      # PERFORMANCE
      #

      set_curve performance cpu \
        '40c:0%,50c:0%,60c:0%,65c:0%,68c:20%,74c:35%,80c:60%,88c:100%'

      set_curve performance gpu \
        '40c:0%,50c:0%,60c:0%,65c:0%,68c:25%,74c:55%,80c:85%,86c:100%'

      set_curve performance mid \
        '40c:0%,55c:0%,65c:0%,68c:0%,72c:20%,78c:50%,84c:80%,90c:100%'

      # Curve parsing initially creates disabled curve objects, so enable
      # every fan after all three curves for each profile have been written.
      for profile in quiet balanced performance; do
        asusctl fan-curve \
          --mod-profile "$profile" \
          --enable-fan-curves true
      done

      # Reapply the currently active profile last.
      case "$(cat /sys/firmware/acpi/platform_profile)" in
        low-power)
          active_profile=quiet
          ;;
        balanced)
          active_profile=balanced
          ;;
        performance)
          active_profile=performance
          ;;
        *)
          active_profile=balanced
          ;;
      esac

      asusctl fan-curve \
        --mod-profile "$active_profile" \
        --enable-fan-curves true

      echo "ASUS fan curves applied; active profile: $active_profile"
    '';
  };
in
{
  services.asusd = {
    enable = true;
  };

  systemd.services.asus-fan-curves = {
    description = "Apply declarative ASUS fan curves";

    wantedBy = [ "multi-user.target" ];
    after = [
      "asusd.service"
      "dbus.service"
    ];
    requires = [ "asusd.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${applyFanCurves}/bin/apply-asus-fan-curves";
    };

    # Changing any curve above changes the script's store path and reruns
    # the service during nixos-rebuild switch.
    restartTriggers = [ applyFanCurves ];
  };

  # Reapply after resume. The service remains inactive after completing,
  # so it can be started repeatedly.
  environment.etc."systemd/system-sleep/asus-fan-curves".source =
    pkgs.writeShellScript "asus-fan-curves-sleep-hook" ''
      if [ "$1" = "post" ]; then
        ${pkgs.systemd}/bin/systemctl \
          --no-block start asus-fan-curves.service
      fi
    '';

  # Reapply when AC power is connected or disconnected.
  services.udev.extraRules = ''
    ACTION=="change", SUBSYSTEM=="power_supply", ATTR{type}=="Mains", RUN+="${pkgs.systemd}/bin/systemctl --no-block start asus-fan-curves.service"
  '';
}
