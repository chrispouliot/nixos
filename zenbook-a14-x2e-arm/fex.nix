{ inputs, pkgs, ... }:

let
  # Point nixpkgs-fex at nixos-unstable >= 2026-08-2x: fex 2608 + box64 0.4.4.
  # (Your main nixpkgs 56c02bc still has fex 2605 / box64 0.4.2.)
  fexPkgs = import inputs.nixpkgs-fex { system = pkgs.stdenv.hostPlatform.system; };
  fex = fexPkgs.fex;

  # Immutable, hash-verified Steam RootFS in /nix/store.
  steamRootFS = pkgs.fetchurl {
    name = "Ubuntu_24_04.sqsh";
    url = "https://rootfs.fex-emu.gg/Ubuntu_24_04/2026-08-11/Ubuntu_24_04.sqsh";
    hash = "sha256-KFSwbT/xuPblJhNb+23Vt7MKs6tz55rpM6PZ/tlZoXg=";
  };

  # Global FEX config (Steam). Hytale never sees this: it runs with
  # FEX_APP_CONFIG_LOCATION pointing at its own directory and its own FEXServer.
  fexConfig = pkgs.writeText "fex-config.json" (builtins.toJSON {
    Config = { RootFS = "${steamRootFS}"; };
    ThunksDB = { };
  });

  fexCompat = pkgs.symlinkJoin {
    name = "fex-with-interpreter-alias";
    paths = [ fex ];
    postBuild = ''ln -s ${fex}/bin/FEX "$out/bin/FEXInterpreter"'';
  };

  # binfmt_misc interpreter shim. With flag O the kernel hands the binary over
  # as AT_EXECFD; that auxv entry does not survive another execv, so it is
  # re-exported as FEX_EXECVEFD, which FEX reads at startup and treats exactly
  # like a binfmt launch (argv[0] preservation included). If the calling
  # process has FEX_BINFMT_HOOK set (ignored under AT_SECURE), the hook gets
  # the exec and decides what runs. Cost for Steam etc.: one extra execv.
  fexBinfmt = pkgs.runCommandCC "fex-binfmt" { } ''
    mkdir -p $out/bin
    $CC -O2 -Wall -o $out/bin/fex-binfmt -x c - <<'EOF'
    #define _GNU_SOURCE
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    #include <sys/auxv.h>
    int main(int argc, char **argv) {
      unsigned long fd = getauxval(AT_EXECFD);
      if (fd) { char b[24]; snprintf(b, sizeof b, "%lu", fd); setenv("FEX_EXECVEFD", b, 1); }
      const char *hook = secure_getenv("FEX_BINFMT_HOOK");
      if (hook && *hook) execv(hook, argv);
      execv("${fex}/bin/FEX", argv);
      perror("fex-binfmt");
      return 127;
    }
    EOF
  '';

  fexInterp = {
    interpreter = "${fexBinfmt}/bin/fex-binfmt";
    preserveArgvZero = true;
    openBinary = true;
    matchCredentials = true;
    fixBinary = true;
    wrapInterpreterInShell = false;
  };
in
{
  environment.systemPackages = [
    fexCompat
    pkgs.squashfuse
  ];

  systemd.tmpfiles.rules = [
    "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
  ];

  # ~/.fex-emu/Config.json -> read-only Nix file; FEXConfig cannot mutate it.
  systemd.user.tmpfiles.users.chris.rules = [
    "d %h/.fex-emu 0700 - - -"
    "L+ %h/.fex-emu/Config.json - - - - ${fexConfig}"
  ];

  # The names are load-bearing. When FEX is not launched by the kernel
  # directly it probes /proc/sys/fs/binfmt_misc/FEX-x86_64 and FEX-x86 to
  # decide it may leave child execve() to the kernel (ExecveHandler,
  # IsBinfmtCompatible); otherwise it re-launches itself and bypasses the shim.
  # emulatedSystems forces the name x86_64-linux, so it is gone — re-add
  # nix.settings.extra-platforms = [ "x86_64-linux" ] if you relied on it.
  boot.binfmt.registrations = {
    FEX-x86_64 = fexInterp // {
      magicOrExtension = ''\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00'';
      mask = ''\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'';
    };

    # EM_386 (machine 3), not NixOS's i686-linux EM_486 magic.
    FEX-x86 = fexInterp // {
      magicOrExtension = ''\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00'';
      mask = ''\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'';
    };
  };
}
