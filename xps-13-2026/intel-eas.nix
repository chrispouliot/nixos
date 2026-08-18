# Intel Energy Aware Scheduling (kernel >= 6.16, hybrid, no SMT).
# intel_pstate passive + schedutil enables EAS; PPD is patched so the
# GNOME power toggle still sets EPP in passive mode without clobbering
# the governor. Keep ppd-passive-epp.patch next to this file.
{ pkgs, ... }:

{
  boot.kernelParams = [ "intel_pstate=passive" ];
  powerManagement.cpuFreqGovernor = "schedutil";

  nixpkgs.overlays = [
    (final: prev: {
      power-profiles-daemon = prev.power-profiles-daemon.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./ppd-passive-epp.patch ];
      });
    })
  ];
}
