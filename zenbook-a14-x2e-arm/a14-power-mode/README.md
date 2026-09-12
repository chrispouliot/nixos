# A14 quiet defaults and performancemode

For Chris's ASUS Zenbook A14 UX3407NA, NixOS, and the pinned Glymur kernel
7.2.0-rc5-next-20260731. The fan commands are the same 0/1 presets already
validated with the temporary driver on this laptop.

| State | CPU governor, all three policies | EC fan preset |
| --- | --- | --- |
| Default on AC and battery | schedutil | Quiet (1) |
| At least one performance request | performance | Normal (0) |
| Last request ends | schedutil | Quiet (1) |

This package supplies a kernel patch, a NixOS module, a small privileged service,
and the `performancemode` command. It does not require GameMode, use LD_PRELOAD,
change frequency caps, or issue raw SCMI commands. The governor's actual effect
on clock speed remains subject to the SCMI behavior already investigated.

## Install

In a flake's modules

```nix
./a14-power-mode
{
  services.a14-power-mode.enable = true;
  services.a14-power-mode.users = [ "chris" ];
}
```

The module rejects an enabled TLP or GameMode configuration, since both could
otherwise write the governor. This controller is intended to be the sole owner
of the two mode settings.

## Verify after reboot

```bash
performancemode --status
```

Expected: `mode` is `quiet`, `active` is 0, all governors are `schedutil`, and
`fan_request` has `desired=1`, `last_requested=1`, `last_error=0`, `suspended=0`.
These fan fields describe acknowledged EC requests, not hardware readback.
The mode name describes the selected policy, not a measured CPU clock.

Test a request without generating CPU load:

```bash
performancemode sh -c 'performancemode --status; sleep 10'
performancemode --status
```

During the first command, expect performance governors and fan request 0.
Afterwards, expect schedutil and fan request 1. Release is processed
asynchronously; if the immediate status query still sees a request, check once
more after a second. Fans may have identical RPM at the current temperature.

Check that quiet remains selected after more than 60 seconds, after unplugging
and reconnecting AC, and after one normal suspend/resume. This replaces the
trial's 60-second expiry with persistent driver state.

## Run applications

Native Moonlight (use the actual executable name on your installation):

```bash
performancemode moonlight
```

Steam per-game launch options:

```text
performancemode %command%
```

Put the wrapper outside FEX/Proton/Box64. It runs on the host, while the game
continues to run as your normal user with its usual environment. A container
must be able to see the wrapper, its Nix store dependencies, and the host
`/run/a14-power-mode/control.sock`; launch from the host if it cannot. Do not add
`sudo` to application launch commands.

For an explicit manual request, keep this running in a terminal:

```bash
performancemode --hold
```

Ctrl+C releases that request. Other running requests keep performance mode
active. You can bind this terminal command to a GNOME keyboard shortcut.

Multiple wrapped applications are supported. The service counts live socket
connections; closing one does not undo another's request. A normal exit or a
crashed/killed wrapper closes its connection, so there is no persistent lock
file to leave performance mode stuck on. The application is launched only
after the service acknowledges both requested settings. The wrapper preserves
the command's exit status and forwards SIGINT, SIGTERM and SIGHUP.

Wrap a foreground command that remains alive for the game session. A launcher
that hands work to an existing instance or detaches and immediately exits ends
its request early; use `--hold` in that situation. Wrapping the Steam client
itself holds performance mode for Steam's whole lifetime. Killing only the
wrapper releases its request even if a descendant game continues running.

## Driver and service behavior

- `fan_profile` accepts only 0 (normal) and 1 (quiet); it is root-writable.
- Quiet follows the tested normal -> quiet command sequence. Reapplying an
  already acknowledged unchanged profile does not issue another EC command.
- The driver remembers the requested preset, requests normal before suspend,
  and reapplies the requested preset after resume. Shutdown/unbind requests
  normal. Control is restricted to the UX3407NA device-tree compatible.
- This is an EC preset, not a custom fan curve or a Windows-equivalent TDP mode.
- Normal fans are requested before the performance governor. Returning to quiet
  lowers the governor first. Errors reject a new request, are logged, and are
  retried; partially applied settings are restored to the active/default mode.
- Every five seconds the service reads the governors and driver request state,
  writing only if they differ or need retrying. It does not poll charger state
  or repeatedly renew a quiet timer.
- If the service fails or is restarted, existing request connections are lost.
  It restarts in quiet mode; wrappers report the lost connection, and games
  remain running. Relaunch a wrapper or use `--hold` to request performance again.

## Troubleshooting and rollback

```bash
systemctl status a14-power-mode.service
journalctl -b -u a14-power-mode.service --no-pager
systemctl is-enabled a14-power-governor.service
```

The former governor service should be masked. If `fan_profile` is missing,
check that you rebooted into the newly built generation rather than only
switching userspace. `fan_profile_trial` is deliberately not accepted.

If anything goes wrong, boot the previous NixOS generation. To permanently
remove this setup, remove the new import and enable block and rebuild/reboot.
The old charger automation becomes active again on rollback if its original
source is still present. No unrelated kernel patches are removed by this module.

## Validation included

The patch was applied with `--fuzz=0` to the supplied original driver and a
version with tab indentation. Controller tests cover overlapping requests,
failed-transition rollback, command exit status, missing commands, malformed
requests, manual-request termination, service shutdown, and write ordering.

This environment prohibits UNIX sockets, so those local checks used an
anonymous-pipe stream simulation and simulated sysfs/EC responses. The real
process/socket SIGKILL test is included but was skipped here. On a host that
supports UNIX sockets, the full tests use temporary paths and simulated
hardware without touching actual governors or fans:

```bash
python3 /etc/nixos/a14-power-mode/test_power_mode.py
```

A Nix evaluation, kernel compilation, and real persistent-profile/resume test
still need to run on the A14. This package does not claim those checks passed.
