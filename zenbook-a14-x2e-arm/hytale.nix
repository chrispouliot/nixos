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
  # Box64 from git master — currently UNUSED. For Hytale, master
  # regresses vs 0.4.2: deterministic bad-pointer SIGSEGV during
  # server boot / world load at every STRONGMEM level, where 0.4.2
  # defaults reached chunk streaming. Kept for retesting after
  # upstream fixes: swap pkgs.box64 for box64Master in
  # clientBox64Shim. Requires the box64-src flake input.
  #

  box64Master = pkgs.box64.overrideAttrs (_old: {
    version = "git-master";
    src = inputs.box64-src;
  });

  #
  # x86_64 librsvg from the binary cache.
  #
  # Provides the gdk-pixbuf SVG loader + loaders.cache for the x86
  # guest GTK stack (launcher and client). Without it the client
  # aborts in ensure_surface_for_gicon trying to load
  # image-missing.svg via inherited ARM pixbuf modules.
  #

  pkgsX86 = import inputs.nixpkgs {
    system = "x86_64-linux";
  };

  pixbufCache =
    "${pkgsX86.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache";

  #
  # Read version/hash from the pinned upstream Hytale flake.
  #
  # We deliberately DO NOT import its x86_64 package set.
  #

  upstreamPackageText =
    builtins.readFile "${inputs.hytale-launcher}/package.nix";

  upstreamLines =
    lib.splitString "\n" upstreamPackageText;

  captureFirst = regex:
    let
      matches =
        builtins.filter
          (x: x != null)
          (map (line: builtins.match regex line) upstreamLines);
    in
      if matches == [ ] then
        throw "Could not extract Hytale launcher metadata from upstream package.nix"
      else
        builtins.elemAt (builtins.head matches) 0;

  hytaleVersion =
    captureFirst ''.*version = "([^"]+)";.*'';

  hytaleHash =
    captureFirst ''.*sha256 = "([^"]+)";.*'';

  #
  # Official Hytale amd64 launcher.
  #
  # IMPORTANT:
  # This fetch is performed by the native aarch64 Nixpkgs, not the
  # upstream x86_64 package set.
  #

  hytaleZip = pkgs.fetchurl {
    url =
      "https://launcher.hytale.com/builds/release/linux/amd64/"
      + "hytale-launcher-${hytaleVersion}.zip";

    hash = hytaleHash;
  };

  #
  # Native ARM derivation that only unpacks the x86 launcher.
  #
  # We intentionally do NOT autoPatchelf it. FEX will execute the
  # original Linux amd64 binary against our Ubuntu x86 RootFS.
  #

  hytaleUnwrapped = pkgs.runCommand
    "hytale-launcher-amd64-${hytaleVersion}"
    {
      nativeBuildInputs = [
        pkgs.unzip
      ];
    }
    ''
      mkdir -p "$out/lib/hytale-launcher"

      unzip ${hytaleZip} -d unpacked

      install -m755 \
        unpacked/hytale-launcher \
        "$out/lib/hytale-launcher/hytale-launcher"
    '';

  #
  # Guest-compatible URL opener.
  #
  # Hytale's Go process cannot directly execute NixOS's native
  # aarch64 xdg-open wrapper. This guest-compatible shell script
  # forwards authentication URLs to the host OpenURI portal.
  #

  hytaleUrlOpener = pkgs.writeTextFile {
    name = "hytale-xdg-open";
    destination = "/bin/xdg-open";
    executable = true;

    text = ''#!/bin/sh

      if [ "$#" -ne 1 ]; then
        echo "Usage: xdg-open URL" >&2
        exit 64
      fi

      exec ${pkgs.glib}/bin/gdbus call \
        --session \
        --dest org.freedesktop.portal.Desktop \
        --object-path /org/freedesktop/portal/desktop \
        --method org.freedesktop.portal.OpenURI.OpenURI \
        "" \
        "$1" \
        "{}"
    '';
  };

  #
  # Per-app FEX configuration.
  #
  # FEX config precedence is environment > AppConfig > global config,
  # and environment variables are inherited by every child process.
  # Exporting FEX_MULTIBLOCK / FEX_DYNAMICL1CACHE from the wrapper
  # therefore leaked launcher-only workarounds into HytaleClient and
  # the bundled Java server. DynamicL1Cache=0 in particular blows up
  # Java's memory usage and previously got the server OOM-killed
  # during world load.
  #
  # AppConfig files are keyed on the guest binary's basename, so each
  # process gets exactly its own settings:
  #
  #   hytale-launcher : Multiblock=0, DynamicL1Cache=0
  #   HytaleClient    : Multiblock=0   (crashes on startup without it;
  #                                     DynamicL1Cache stays default)
  #   java            : Multiblock=0   (DynamicL1Cache=0 blows up heap
  #                                     -> OOM kill during world load)
  #

  launcherFexConfig = builtins.toJSON {
    Config = {
      Multiblock = "0";
      DynamicL1Cache = "0";
    };
  };

  javaFexConfig = builtins.toJSON {
    Config = {
      Multiblock = "0";
    };
  };

  clientFexConfig = builtins.toJSON {
    Config = {
      Multiblock = "0";
    };
  };

  #
  # Box64 shim for the game client.
  #
  # HytaleClient (.NET 10) suffers intermittent memory corruption
  # under FEX 2608 on Oryon-3 (stack-canary smashing, SIGSEGV/SIGABRT,
  # garbage bytes in parse buffers) regardless of FEX configuration.
  # Run only the client under Box64 instead; the launcher (Go) and
  # bundled Java server stay on FEX.
  #
  # The wrapper interposes this shim as Client/HytaleClient, renaming
  # the real ELF to HytaleClient.bin. Box64 resolves x86_64 guest
  # libraries from the FEX RootFS; GL/Vulkan are wrapped to native
  # host drivers by Box64 itself.
  #

  #
  # Native ARM libraries Box64 wraps for the client: GL/EGL from
  # /run/opengl-driver, plus display-stack libs. Everything else
  # (ssl, icu, dbus, ...) falls back to emulated x86 copies from the
  # FEX RootFS, which is fine.
  #

  box64NativeLibs = lib.makeLibraryPath (with pkgs; [
    libglvnd
    libpulseaudio
    wayland
    libxkbcommon
    libdecor
    xorg.libX11
    xorg.libxcb
    xorg.libXau
    xorg.libXdmcp
    xorg.libXext
    xorg.libXcursor
    xorg.libXrender
    xorg.libXfixes
    xorg.libXi
    xorg.libXrandr
    xorg.libXScrnSaver
    udev
  ]);

  clientBox64Shim = pkgs.writeScript "hytale-client-box64-shim" ''
    #!/bin/sh
    DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    ROOTFS="$HOME/.local/share/fex-emu/RootFS/Ubuntu_24_04-steam"

    # This script is interpreted by the RootFS x86 sh under FEX, and
    # FEX filters LD_LIBRARY_PATH across its exec boundary — plain
    # exports here never reach Box64. Carry the environment in argv
    # via native env(1) instead: FEX delegates the ARM binary to the
    # host, and env re-establishes the variables outside FEX.

    exec ${pkgs.coreutils}/bin/env \
      LD_LIBRARY_PATH="/run/opengl-driver/lib:${box64NativeLibs}" \
      __EGL_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/egl_vendor.d" \
      SDL_VIDEO_DRIVER=x11 \
      SDL_VIDEODRIVER=x11 \
      XKB_CONFIG_ROOT="${pkgs.xkeyboard-config}/share/X11/xkb" \
      XLOCALEDIR="${pkgs.xorg.libX11}/share/X11/locale" \
      BOX64_LD_LIBRARY_PATH="$DIR:$ROOTFS/usr/lib/x86_64-linux-gnu:$ROOTFS/lib/x86_64-linux-gnu:$ROOTFS/usr/lib" \
      ${pkgs.box64}/bin/box64 "$DIR/HytaleClient.bin" "$@" \
      2>>/tmp/hytale-client.log
  '';

  #
  # Native ARM Java for the bundled server.
  #
  # The Box64 client follows its x86 child processes itself, so the
  # java it spawns would run under Box64 (where the server dies in
  # ExceptionInInitializerError). But the server is a plain jar with
  # multi-arch JNI natives (zstd-jni ships linux/aarch64), and it
  # boots cleanly on native ARM Temurin 25+ (class file 69 needs
  # Java >= 25) — so skip emulation for the server entirely.
  #
  # Interpose java with a shim that execs native ARM java against
  # the same arguments. java.bin (the bundled x86 Temurin) is kept
  # as the updater's reference copy but never executed.
  #

  javaFexShim = pkgs.writeScript "hytale-java-native-shim" ''
    #!/bin/sh
    exec ${pkgs.temurin-bin-25}/bin/java "$@" \
      2>>/tmp/hytale-java.log
  '';

  #
  # Hytale launcher wrapper
  #

  hytaleLauncher = pkgs.writeShellScriptBin "hytale-launcher" ''
    set -e

    LAUNCHER_DIR="''${XDG_DATA_HOME:-$HOME/.local/share}/Hytale"
    LAUNCHER_BIN="$LAUNCHER_DIR/hytale-launcher"
    BUNDLED_BIN="${hytaleUnwrapped}/lib/hytale-launcher/hytale-launcher"
    HASH_FILE="$LAUNCHER_DIR/.nix-bundled-hash"
    TMP_DIR="$LAUNCHER_DIR/.nix-tmp"

    mkdir -p "$LAUNCHER_DIR" "$TMP_DIR"

    #
    # The official launcher self-updates.
    #
    # Copy it out of /nix/store into a writable directory so the
    # updater can replace it normally.
    #

    BUNDLED_HASH="$(
      ${pkgs.coreutils}/bin/sha256sum "$BUNDLED_BIN" |
      ${pkgs.coreutils}/bin/cut -d' ' -f1
    )"

    INSTALLED_HASH="$(
      ${pkgs.coreutils}/bin/cat "$HASH_FILE" 2>/dev/null || true
    )"

    if [ ! -x "$LAUNCHER_BIN" ] ||
       [ "$INSTALLED_HASH" != "$BUNDLED_HASH" ]; then

      ${pkgs.coreutils}/bin/install \
        -m755 \
        "$BUNDLED_BIN" \
        "$LAUNCHER_BIN"

      printf '%s\n' "$BUNDLED_HASH" > "$HASH_FILE"
    fi

    #
    # Install per-app FEX configs (see comment above). Written on
    # every launch so they stay in sync with this file.
    #

    mkdir -p "$HOME/.fex-emu/AppConfig"

    printf '%s\n' ${lib.escapeShellArg launcherFexConfig} \
      > "$HOME/.fex-emu/AppConfig/hytale-launcher.json"

    printf '%s\n' ${lib.escapeShellArg javaFexConfig} \
      > "$HOME/.fex-emu/AppConfig/java.json"

    printf '%s\n' ${lib.escapeShellArg clientFexConfig} \
      > "$HOME/.fex-emu/AppConfig/HytaleClient.json"

    #
    # Interpose the Box64 shim as the game client binary.
    #
    # If Client/HytaleClient is a real ELF (fresh install or a game
    # update replaced our shim), move it aside to HytaleClient.bin.
    # Then (re)install the shim so it always matches the current
    # store path.
    #

    CLIENT_DIR="$LAUNCHER_DIR/install/release/package/game/latest/Client"

    if [ -e "$CLIENT_DIR/HytaleClient" ]; then
      MAGIC="$(
        ${pkgs.coreutils}/bin/head -c 4 "$CLIENT_DIR/HytaleClient" |
        ${pkgs.coreutils}/bin/od -An -tx1 |
        ${pkgs.coreutils}/bin/tr -d ' \n'
      )"

      if [ "$MAGIC" = "7f454c46" ]; then
        ${pkgs.coreutils}/bin/mv -f \
          "$CLIENT_DIR/HytaleClient" \
          "$CLIENT_DIR/HytaleClient.bin"
      fi

      if [ -e "$CLIENT_DIR/HytaleClient.bin" ]; then
        ${pkgs.coreutils}/bin/install -m755 \
          ${clientBox64Shim} \
          "$CLIENT_DIR/HytaleClient"
      fi
    fi

    #
    # Interpose the FEX shim as the bundled java (same pattern).
    #

    JRE_BIN_DIR="$LAUNCHER_DIR/install/release/package/jre/latest/bin"

    if [ -e "$JRE_BIN_DIR/java" ]; then
      JMAGIC="$(
        ${pkgs.coreutils}/bin/head -c 4 "$JRE_BIN_DIR/java" |
        ${pkgs.coreutils}/bin/od -An -tx1 |
        ${pkgs.coreutils}/bin/tr -d ' \n'
      )"

      if [ "$JMAGIC" = "7f454c46" ]; then
        ${pkgs.coreutils}/bin/mv -f \
          "$JRE_BIN_DIR/java" \
          "$JRE_BIN_DIR/java.bin"
      fi

      if [ -e "$JRE_BIN_DIR/java.bin" ]; then
        ${pkgs.coreutils}/bin/install -m755 \
          ${javaFexShim} \
          "$JRE_BIN_DIR/java"
      fi
    fi

    #
    # Make Hytale use the guest-compatible URL opener.
    #

    export PATH="${hytaleUrlOpener}/bin:$PATH"
    export BROWSER="${hytaleUrlOpener}/bin/xdg-open"

    #
    # Upstream launcher workarounds.
    #

    export WEBKIT_DISABLE_COMPOSITING_MODE=1
    export WEBKIT_DISABLE_DMABUF_RENDERER=1

    #
    # Go's asynchronous signal-based preemption currently corrupts
    # the guest stack/return PC under FEX. Only affects Go programs,
    # so safe to let the client/server inherit it.
    #
    # NOTE: deliberately NO FEX_* exports here — those would override
    # the AppConfig files for all child processes.
    #

    export GODEBUG=asyncpreemptoff=1

    #
    # .NET 10 client: dual-mapped W^X JIT pages crash under FEX
    # (intermittent SIGSEGV/SIGABRT before window creation).
    # Inherited launcher -> client; only affects .NET.
    #

    export DOTNET_EnableWriteXorExecute=0

    #
    # .NET threadpool threads get small default stacks; FEX signal
    # frames overflow them -> "stack smashing detected" across all
    # threads and SIGSEGV/SIGABRT before window creation. 4 MiB
    # default stack size fixes it.
    #

    export DOTNET_DefaultStackSize=0x400000

    #
    # RootFS for all guest processes. Unlike the Multiblock knobs,
    # this is identical for every guest, so an env export is correct.
    #

    export FEX_ROOTFS="$HOME/.local/share/fex-emu/RootFS/Ubuntu_24_04-steam"

    #
    # x86 guest GTK: use the x86 librsvg pixbuf loader cache and strip
    # inherited ARM NixOS GTK/GIO module paths.
    #

    export GDK_PIXBUF_MODULE_FILE="${pixbufCache}"
    unset GDK_PIXBUF_MODULEDIR
    unset GIO_EXTRA_MODULES
    unset GIO_MODULE_DIR
    unset GTK_PATH
    unset GTK_EXE_PREFIX
    unset GTK_DATA_PREFIX

    #
    # Use Turnip from the x86 Ubuntu FEX RootFS.
    #

    export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.json
    unset VK_ICD_FILENAMES

    #
    # Allow Hytale's self-updater to stage files on the same
    # filesystem as its installation.
    #

    unset XDG_CACHE_HOME
    export TMPDIR="$TMP_DIR"

    #
    # Launch the official Linux amd64 launcher through FEX.
    #
    # Its x86/x86_64 child processes will subsequently be handled
    # by our existing FEX binfmt registrations.
    #

    exec ${fex}/bin/FEXBash \
      -c 'exec "$@"' \
      -- \
      "$LAUNCHER_BIN" \
      "$@"
  '';

  #
  # Desktop entry
  #

  hytaleDesktop = pkgs.makeDesktopItem {
    name = "hytale-launcher";

    desktopName = "Hytale Launcher";
    genericName = "Game Launcher";
    comment = "Official Hytale Launcher through FEX";

    exec = "${hytaleLauncher}/bin/hytale-launcher";
    icon = "hytale-launcher";

    terminal = false;
    startupNotify = true;

    categories = [
      "Game"
    ];

    keywords = [
      "hytale"
      "game"
      "launcher"
      "hypixel"
    ];

    startupWMClass = "com.hypixel.HytaleLauncher";
  };

  #
  # Combine the command-line wrapper and desktop entry into one
  # package exposed through environment.systemPackages.
  #

  hytaleFex = pkgs.symlinkJoin {
    name = "hytale-launcher-fex";

    paths = [
      hytaleLauncher
      hytaleDesktop
    ];
  };

in
{
  environment.systemPackages = [
    hytaleFex
  ];
}
