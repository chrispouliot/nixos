{ inputs, pkgs, ... }:

let
  fexPkgs = import inputs.nixpkgs-fex {
    system = pkgs.stdenv.hostPlatform.system;
  };

  fex = fexPkgs.fex;

  # Immutable, hash-verified Steam RootFS.
  #
  # Nix downloads this into /nix/store. Because the store is read-only,
  # neither Hytale nor any other application can modify Steam's RootFS.
  steamRootFS = pkgs.fetchurl {
    name = "Ubuntu_24_04.sqsh";

    url =
      "https://rootfs.fex-emu.gg/Ubuntu_24_04/2026-08-11/Ubuntu_24_04.sqsh";

    hash = "sha256-KFSwbT/xuPblJhNb+23Vt7MKs6tz55rpM6PZ/tlZoXg=";
  };

  # Declarative global FEX configuration. Steam uses this RootFS unless
  # an application-specific wrapper explicitly overrides FEX_ROOTFS.
  fexConfig = pkgs.writeText "fex-config.json" (
    builtins.toJSON {
      Config = {
        RootFS = "${steamRootFS}";
      };

      ThunksDB = { };
    }
  );

  fexCompat = pkgs.symlinkJoin {
    name = "fex-with-interpreter-alias";

    paths = [
      fex
    ];

    postBuild = ''
      ln -s ${fex}/bin/FEX "$out/bin/FEXInterpreter"
    '';
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

  # Install the declarative FEX configuration in Chris's home directory.
  #
  # Config.json becomes a symlink to the generated, read-only Nix file.
  # FEXConfig will therefore not be able to modify the global configuration;
  # changes must be made here and applied with nixos-rebuild.
  systemd.user.tmpfiles.users.chris.rules = [
    "d %h/.fex-emu 0700 - - -"
    "L+ %h/.fex-emu/Config.json - - - - ${fexConfig}"
  ];

  boot.binfmt = {
    # Let NixOS provide the normal x86_64 ELF registration.
    emulatedSystems = [
      "x86_64-linux"
    ];

    registrations = {
      x86_64-linux = {
        interpreter = "${fex}/bin/FEX";

        preserveArgvZero = true;
        openBinary = true;
        matchCredentials = true;
        fixBinary = true;
        wrapInterpreterInShell = false;
      };

      # FEX 32-bit x86 registration.
      #
      # Do NOT use NixOS's i686-linux magic here: that currently
      # identifies EM_486 (machine 6), whereas Steam's 32-bit
      # client is EM_386 (machine 3).
      FEX-x86 = {
        recognitionType = "magic";
        offset = 0;

        magicOrExtension =
          ''\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00'';

        mask =
          ''\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'';

        interpreter = "${fex}/bin/FEX";

        preserveArgvZero = true;
        openBinary = true;
        matchCredentials = true;
        fixBinary = true;
        wrapInterpreterInShell = false;
      };
    };
  };
}
