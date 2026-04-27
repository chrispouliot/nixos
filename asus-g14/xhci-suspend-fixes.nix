{ config, lib, pkgs, ... }:

{
  ###########################################################################
  # AMD xHCI suspend-resume workarounds for Ryzen AI 300-series laptops
  #
  # Two complementary mitigations for the known kernel/firmware bug where
  # the AMD xHCI controller fails to resume cleanly, causing either:
  #   (a) USB devices to die after resume (rebind hook recovers from this)
  #   (b) all subsequent suspends to hang forever (kill script catches this
  #       and powers off before the laptop overheats in a closed bag)
  #
  # See:
  #   https://community.frame.work/t/workaround-xhci-host-controller-not-responding-at-resume-after-suspend/79119
  ###########################################################################

  # ---- Mitigation 1: rebind dead xHCI controller on resume ----------------
  systemd.services."xhci-rebind-on-resume" = {
    description = "Rebind dead xHCI controller after resume";
    after = [
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
      "suspend-then-hibernate.target"
    ];
    wantedBy = [
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
      "suspend-then-hibernate.target"
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "xhci-rebind" ''
        set -u

        log() {
          ${pkgs.util-linux}/bin/logger -t xhci-rebind "$1"
        }

        # Give the xHCI death a chance to actually appear in the journal.
        # The Framework community found systemd-sleep often fires before
        # the xHCI timeout completes, so we need to wait.
        sleep 3

        time_check="$(${pkgs.coreutils}/bin/date --iso-8601=seconds -d '-60 seconds')"

        dead_devices="$(${pkgs.systemd}/bin/journalctl \
          --output cat \
          --no-pager \
          -b -k \
          --since "$time_check" \
          --grep 'xHC restore state timeout|xHCI host controller not responding|HC died' \
          2>/dev/null \
          | ${pkgs.gnused}/bin/sed -n -E 's/^.*xhci_hcd[[:space:]]+([0-9]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]):.*$/\1/p' \
          | ${pkgs.coreutils}/bin/sort -u)"

        if [ -z "$dead_devices" ]; then
          log "no xHCI death detected after resume"
          exit 0
        fi

        for dev in $dead_devices; do
          if [ ! -e "/sys/bus/pci/drivers/xhci_hcd/$dev" ]; then
            log "device $dev not bound to xhci_hcd, skipping"
            continue
          fi

          log "rebinding xHCI controller $dev"

          if ! echo -n "$dev" > /sys/bus/pci/drivers/xhci_hcd/unbind 2>/dev/null; then
            log "failed to unbind $dev"
            continue
          fi

          sleep 2

          if ! echo -n "$dev" > /sys/bus/pci/drivers/xhci_hcd/bind 2>/dev/null; then
            log "failed to rebind $dev"
            continue
          fi

          log "successfully rebound $dev"
        done
      '';
    };
  };

  # ---- Mitigation 2: force poweroff after consecutive suspend failures ----
  # Counter persists in /run/suspend-failures (tmpfs, cleared on boot).
  # Successful suspend deletes the counter; consecutive failures increment it.
  # At threshold, force poweroff to prevent thermal damage in a closed bag.
  systemd.services.systemd-suspend = {
    serviceConfig.ExecStopPost = pkgs.writeShellScript "suspend-poweroff-on-fail" ''
      if [ "$EXIT_STATUS" != "0" ]; then
        count_file=/run/suspend-failures
        count=$(cat "$count_file" 2>/dev/null || echo 0)
        count=$((count + 1))
        echo "$count" > "$count_file"

        ${pkgs.util-linux}/bin/logger -t suspend-watchdog \
          "Suspend failed ($count consecutive)"

        if [ "$count" -ge 3 ]; then
          ${pkgs.systemd}/bin/systemctl poweroff --force
        fi
      else
        rm -f /run/suspend-failures
      fi
    '';
  };
}
