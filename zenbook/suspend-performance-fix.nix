{ pkgs, ... }:

{
  systemd.services.suspend-perf-profile = {
    wantedBy = [ "sleep.target" ];
    before = [ "sleep.target" ];
    unitConfig.StopWhenUnneeded = true;
    path = [ pkgs.power-profiles-daemon ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      powerprofilesctl get > /run/pre-suspend-profile
      powerprofilesctl set performance
    '';
    postStop = ''
      powerprofilesctl set "$(cat /run/pre-suspend-profile 2>/dev/null || echo balanced)"
    '';
  };
}
