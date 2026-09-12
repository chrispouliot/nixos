# Personal Hytale performance-mode integration

Install this only in Chris's NixOS configuration. It adds no dependency or
change to the public `hytale-launcher-arm-nix` repository.

Requires the already installed `/etc/nixos/a14-power-mode` directory and its
running service. It uses that service's existing request mechanism and reads
the existing controller's Python source at Nix build time.

## Install

Add the `imports` line to the existing `/etc/nixos/hytale.nix`:

```nix
{ pkgs, ... }:

{
  imports = [ ./a14-hytale-performance ];

  programs.hytale.enable = true;

  # Steam and other x86 programs: stock FEX via the same binfmt shim,
  # full Ubuntu RootFS, /bin/bash.
  programs.fex.rootfs = pkgs.fetchurl {
    name = "Ubuntu_24_04.sqsh";
    url = "https://rootfs.fex-emu.gg/Ubuntu_24_04/2026-08-11/Ubuntu_24_04.sqsh";
    hash = "sha256-KFSwbT/xuPblJhNb+23Vt7MKs6tz55rpM6PZ/tlZoXg=";
  };
  programs.fex.users = [ "chris" ];
  programs.fex.binBash = true;
}
```

Keep `hytale-arm.nixosModules.default` and `./hytale.nix` in your flake as they
are. No flake-input update, source checkout change, or upstream commit is needed.


This changes the generated Hytale hook, launcher script, and desktop entry.
It adds a tiny helper using the Python already required by a14-power-mode.
It does not modify the kernel patch or the FEX source/build settings. No reboot
is required. Close any old Hytale launcher before opening it again from GNOME.

## Expected behavior

- Launcher open: quiet + schedutil, unless another app holds a request.
- Click Play: the HytaleClient-specific hook requests performance + normal fans.
- Launcher exits: the game helper keeps its request active.
- Game exits: that request ends; quiet + schedutil return if no other requests exist.

Check `performancemode --status` once while in-game and again after quitting.
There is no need to launch Hytale from a terminal after installation. The
existing Hytale icon keeps the same desktop ID and name.

If launching fails, inspect:

```bash
tail -n 50 ~/.cache/hytale/fex-client.log
journalctl -b -u a14-power-mode.service --no-pager
```

If the service rejects a request, this helper reports the error and does not
start the game. If the service subsequently restarts, the helper logs that its
request was lost and keeps waiting for the game to exit, like performancemode.

## Why this is a separate helper

The current repository uses **FEX for HytaleClient**, not the older Box64 setup.
Its binfmt hook receives an open binary descriptor through `FEX_EXECVEFD`.
Our general performancemode command starts children with close_fds=True, which
would discard that descriptor. This helper uses fork/exec instead, preserves
inheritable descriptors and arguments, and closes only its own performance
socket in the game child. The supervisor retains that socket until FEX exits.
It runs as the normal user; it is neither setuid nor a privileged helper.

The local overlay changes only `pkgs.writeShellScript` calls whose name is
`hytale-binfmt-hook`, and only the final HytaleClient execution line in that
script. Launcher helper processes and other FEX programs keep their original
execution paths. The existing native Java substitution and FEX settings remain
in the original hook before the added supervisor.

Reviewed against upstream commit:
`a7de259c1bea4990a9c956de2d92905ab6fbd68e`.
The override verifies exactly one matching client exec in the named hook and
stops evaluation if that pattern changes. A future rename of the hook itself
requires reviewing this overlay too.

## Validation and rollback

Four host tests passed: preserving the FEX-style descriptor and arguments,
propagating exit status, refusing to launch on acquisition failure, cleanup
after a missing executable, and SIGTERM forwarding/cleanup. Tests used a pipe
as the request connection and ordinary native child processes. The target hook
matched exactly one client exec in the inspected repository. Native Nix
validation and the actual game launch still need testing on the A14.

```bash
python3 /etc/nixos/a14-hytale-performance/test_holder.py
```

To undo, remove `imports = [ ./a14-hytale-performance ];` and run the same
`nixos-rebuild switch` command. No public repository changes need reverting.
