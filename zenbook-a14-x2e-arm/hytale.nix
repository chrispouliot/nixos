{ pkgs, ... }:

{
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
