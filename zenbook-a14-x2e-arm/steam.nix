{ inputs, lib, pkgs, ... }:

let
  #
  # FEX
  #

  fexPkgs = import inputs.nixpkgs-fex {
    system = pkgs.stdenv.hostPlatform.system;
  };

  fex = fexPkgs.fex;

  #
  # Steam
  #

  # Valve's normal x86 Steam bootstrap from nixpkgs.
  steamBootstrap = pkgs.steam-unwrapped;

  #
  # Vulkan / Turnip
  #

  # Host-visible Vulkan ICD descriptor for the x86/i386 Turnip
  # driver inside our FEX Ubuntu RootFS.
  #
  # libvulkan_freedreno.so is resolved from the FEX RootFS.
  freedrenoIcd = pkgs.writeText "freedreno_icd.json" ''
    {
        "ICD": {
            "api_version": "1.4.354",
            "library_path": "libvulkan_freedreno.so"
        },
        "file_format_version": "1.0.1"
    }
  '';

  #
  # Steam launcher
  #

  steamLauncher = pkgs.writeShellScriptBin "steam" ''
    export STEAMOS=1
    export STEAM_RUNTIME=1

    # Workaround for the current FEX / steamwebhelper dynamic-L1-cache
    # issue.
    export FEX_DYNAMICL1CACHEDECREASECOUNTHEURISTIC=0

    # Prevent x86 Steam from trying to load ARM-native NixOS
    # GIO modules.
    unset GIO_EXTRA_MODULES

    # Use the x86/i386 Turnip driver from the configured FEX RootFS.
    export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.json
    unset VK_ICD_FILENAMES

    # Pressure Vessel expects conventional FHS paths.
    #
    # /usr/bin is particularly important because Pressure Vessel's
    # initial bubblewrap test executes "true".
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${pkgs.lib.makeBinPath [
      pkgs.pulseaudio
      pkgs.zenity
      pkgs.lsb-release
    ]}:$PATH"

    # Launch Valve's x86 Steam client through FEX.
    exec ${fex}/bin/FEXBash \
      -c 'exec /bin/bash ${steamBootstrap}/bin/steam "$@"' \
      -- "$@"
  '';

  #
  # Desktop entry
  #

  steamDesktop = pkgs.makeDesktopItem {
    name = "steam-fex";

    desktopName = "Steam";
    genericName = "Game Platform";
    comment = "Launch Steam through FEX";

    exec = "${steamLauncher}/bin/steam %U";
    icon = "steam";

    terminal = false;

    categories = [
      "Game"
      "Network"
    ];

    mimeTypes = [
      "x-scheme-handler/steam"
    ];

    startupWMClass = "Steam";
  };

  #
  # Final package
  #

  # Combine our launcher and desktop entry, while borrowing Valve's
  # normal Steam icons from steam-unwrapped.
  steamFex = pkgs.symlinkJoin {
    name = "steam-fex";

    paths = [
      steamLauncher
      steamDesktop
    ];

    postBuild = ''
      mkdir -p "$out/share"

      if [ -d ${steamBootstrap}/share/icons ]; then
        ln -s ${steamBootstrap}/share/icons \
          "$out/share/icons"
      fi

      if [ -d ${steamBootstrap}/share/pixmaps ]; then
        ln -s ${steamBootstrap}/share/pixmaps \
          "$out/share/pixmaps"
      fi
    '';
  };

in
{
  #
  # Packages
  #

  environment.systemPackages = [
    steamFex

    pkgs.pulseaudio
    pkgs.zenity
    pkgs.lsb-release
  ];

  #
  # Pressure Vessel / NixOS compatibility
  #

  # Pressure Vessel needs /etc/host.conf to be a real file.
  #
  # environment.etc would normally create:
  #
  #   /etc/host.conf -> /etc/static/host.conf
  #
  # which caused problems inside Pressure Vessel.
  system.activationScripts.steamHostConf =
    lib.stringAfter [ "etc" ] ''
      rm -f /etc/host.conf
      printf 'multi on\n' > /etc/host.conf
      chmod 0644 /etc/host.conf
    '';

  #
  # Minimal FHS compatibility
  #

  systemd.tmpfiles.rules = [
    #
    # Pressure Vessel's initial bwrap test constructs:
    #
    #   /bin -> /usr/bin
    #
    # and executes "true".
    #
    # NixOS normally has no /usr/bin/true.
    #
    "d /usr/bin 0755 root root -"
    "L+ /usr/bin/true - - - - ${pkgs.coreutils}/bin/true"

    #
    # Conventional directories Pressure Vessel probes/binds.
    #
    "d /usr/lib 0755 root root -"
    "d /usr/lib32 0755 root root -"
    "d /usr/lib64 0755 root root -"

    "d /usr/share 0755 root root -"
    "d /usr/share/vulkan 0755 root root -"
    "d /usr/share/vulkan/icd.d 0755 root root -"

    #
    # Turnip ICD visible at the conventional location expected by
    # Steam / Pressure Vessel.
    #
    "L+ /usr/share/vulkan/icd.d/freedreno_icd.json - - - - ${freedrenoIcd}"
  ];
}
