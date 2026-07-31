{ pkgs, ... }:

let
  capture = pkgs.writeShellScript "lnl-clamp-capture" ''
    set -u
    PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.msr-tools pkgs.util-linux ]}
    dir=/var/log/lnl-clamp
    mkdir -p "$dir"
    log="$dir/$(date +%Y%m%d-%H%M%S).log"

    pre=$(cat /run/lnl-slp-s0-pre 2>/dev/null || echo 0)
    post=$(cat /sys/kernel/debug/pmc_core/slp_s0_residency_usec 2>/dev/null || echo 0)
    echo "slp_s0_usec pre=$pre post=$post delta=$((post - pre))" >> "$log"

    clamped=0
    low_streak=0
    for i in $(seq 1 90); do
      f=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | sort -n | tail -1)
      therm=$(rdmsr -p0 0x1B1 2>/dev/null || echo NA)
      reasons=$(rdmsr -p0 0x64F 2>/dev/null || echo NA)
      pl=$(rdmsr -p0 0x610 2>/dev/null || echo NA)
      psys=$(rdmsr -p0 0x65C 2>/dev/null || echo NA)
      mmio1=$(cat /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw 2>/dev/null || echo NA)
      mmio2=$(cat /sys/class/powercap/intel-rapl-mmio:0/constraint_1_power_limit_uw 2>/dev/null || echo NA)
      echo "t=''${i}s max_freq_khz=$f msr_1B1=$therm msr_64F=$reasons msr_610=$pl msr_65C=$psys mmio_pl1_uw=$mmio1 mmio_pl2_uw=$mmio2" >> "$log"
      if [ "$f" -lt 600000 ]; then
        low_streak=$((low_streak + 1))
        [ "$low_streak" -ge 3 ] && clamped=1
      else
        low_streak=0
      fi
      sleep 1
    done

    if [ "$clamped" = 1 ]; then
      echo "=== CLAMP DETECTED, kernel log follows ===" >> "$log"
      dmesg | tail -n 200 >> "$log"
    else
      mv "$log" "$log.clean"
    fi
  '';
in
{
  boot.kernelModules = [ "msr" ];

  systemd.services.lnl-clamp-logger = {
    wantedBy = [ "sleep.target" ];
    before = [ "sleep.target" ];
    unitConfig.StopWhenUnneeded = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      cat /sys/kernel/debug/pmc_core/slp_s0_residency_usec > /run/lnl-slp-s0-pre 2>/dev/null || echo 0 > /run/lnl-slp-s0-pre
    '';
    postStop = ''
      ${pkgs.systemd}/bin/systemd-run --unit=lnl-clamp-capture --collect ${capture}
    '';
  };
}
