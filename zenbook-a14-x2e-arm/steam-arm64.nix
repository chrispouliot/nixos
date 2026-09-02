{ lib, pkgs, ... }:

let
  # This becomes HOME only for the native ARM64 Steam process tree.
  # The working x86/FEX installation continues to use Chris's real HOME.
  isolatedHomeName = ".steam-arm64-home";

  # Reuse only Valve's packaged icon assets. The x86 launcher and its desktop
  # entry are not included in the ARM64 package.
  steamIconSource = pkgs.steam-unwrapped;

  # Steam-managed compatibility components required for x86 games on ARM64.
  #
  # Nix declares which tools must be present.  Steam owns their mutable depot
  # contents and keeps them updated inside the isolated ARM64 Steam tree.
  requiredSteamToolAppIds = [
    "3127680" # FEX for native x86/i386 Linux games
    "4185400" # Steam Linux Runtime 4.0 - ARM64
    "4628740" # Proton 11.0 - ARM64
  ];

  requiredSteamToolAppIdsString =
    lib.concatStringsSep " " requiredSteamToolAppIds;

  steamArm64Inner = pkgs.writeShellScript "steam-arm64-inner" ''
    set -eo pipefail

    realHome="$HOME"
    armHome="$realHome/${isolatedHomeName}"

    export HOME="$armHome"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_CACHE_HOME="$HOME/.cache"
    export XDG_DATA_HOME="$HOME/.local/share"
    export XDG_STATE_HOME="$HOME/.local/state"

    steamRoot="$HOME/.local/share/Steam"
    steamAppsDir="$steamRoot/steamapps"
    clientDir="$steamRoot/steamrtarm64"
    runtimeDir="$steamRoot/steam-runtime-steamrt-arm64"
    steamLibDir="$steamRoot/lib/aarch64-linux-gnu"

    runtimeUrl="https://repo.steampowered.com/steamrt3c/images/latest-public-beta/steam-runtime-steamrt-arm64.tar.xz"
    manifestUrl="https://client-update.fastly.steamstatic.com/steam_client_publicbeta_linuxarm64"
    clientCdn="https://client-update.steamstatic.com"

    mkdir -p \
      "$HOME/.config" \
      "$HOME/.cache" \
      "$HOME/.local/share" \
      "$HOME/.local/state" \
      "$HOME/.steam" \
      "$steamRoot" \
      "$steamAppsDir" \
      "$steamRoot/package" \
      "$steamRoot/compatibilitytools.d" \
      "$steamLibDir"

    # Native ARM Steam currently lives on Valve's public-beta branch.
    printf '%s\n' publicbeta > "$steamRoot/package/beta"

    if [ ! -d "$runtimeDir" ]; then
      echo "Downloading Valve's ARM64 Steam Runtime..."
      runtimeArchive="$steamRoot/.steam-runtime-arm64.tar.xz.part"

      ${pkgs.curl}/bin/curl \
        --fail \
        --location \
        --retry 5 \
        --output "$runtimeArchive" \
        "$runtimeUrl"

      ${pkgs.gnutar}/bin/tar -xJf "$runtimeArchive" -C "$steamRoot"
      rm -f "$runtimeArchive"
    fi

    if [ ! -x "$clientDir/steam" ]; then
      echo "Downloading Valve's experimental native ARM64 Steam client..."

      targetFile="$(${pkgs.curl}/bin/curl --fail --silent --show-error --location "$manifestUrl" \
        | ${pkgs.gnugrep}/bin/grep -ao 'bins_linuxarm64_linuxarm64\.zip\.[^"]*' \
        | ${pkgs.gnugrep}/bin/grep -v '\.vz\.' \
        | ${pkgs.gnused}/bin/sed -n '1p')"

      if [ -z "$targetFile" ]; then
        echo "Could not find the ARM64 client archive in Valve's manifest." >&2
        exit 1
      fi

      clientArchive="$steamRoot/.steam-client-arm64.zip.part"

      ${pkgs.curl}/bin/curl \
        --fail \
        --location \
        --retry 5 \
        --output "$clientArchive" \
        "$clientCdn/$targetFile"

      ${pkgs.unzip}/bin/unzip -q -o "$clientArchive" -d "$steamRoot"
      rm -f "$clientArchive"
    fi

    # Keep every conventional Steam link inside the isolated HOME.
    ln -sfn "$steamRoot" "$HOME/.steam/steam"
    ln -sfn "$steamRoot" "$HOME/.steam/root"
    ln -sfn "$steamRoot/linuxarm64" "$HOME/.steam/sdkarm64"

    # Supply the compatibility SONAMEs used by the current experimental client.
    runtimePlatform="$(${pkgs.findutils}/bin/find "$runtimeDir" \
      -mindepth 1 -maxdepth 1 -type d -name 'steamrt3c_platform_*' -print \
      | ${pkgs.coreutils}/bin/sort \
      | ${pkgs.gnused}/bin/sed -n '1p')"

    linkRuntimeLibrary() {
      soname="$1"
      pattern="$2"

      if [ -z "$runtimePlatform" ]; then
        return 0
      fi

      runtimeLibDir="$runtimePlatform/files/lib/aarch64-linux-gnu"
      target="$(${pkgs.findutils}/bin/find "$runtimeLibDir" \
        -mindepth 1 -maxdepth 1 -name "$pattern" -print 2>/dev/null \
        | ${pkgs.coreutils}/bin/sort -V \
        | ${pkgs.gnused}/bin/sed -n '1p')"

      if [ -n "$target" ]; then
        ln -sfn "$target" "$steamLibDir/$soname"
      fi
    }

    linkRuntimeLibrary "libibus-1.0.so.5" "libibus-1.0.so.5*"
    linkRuntimeLibrary "libgtk-x11-2.0.so.0" "libgtk-x11-2.0.so.0*"
    linkRuntimeLibrary "libgdk-x11-2.0.so.0" "libgdk-x11-2.0.so.0*"

    # Steam still uses the legacy GTK2 AppIndicator stack for its tray icon.
    # Current nixpkgs removed these packages with the wider GTK2 cleanup, but
    # Valve ships compatible AArch64 copies in the client runtime.
    linkRuntimeLibrary "libappindicator.so.1" "libappindicator.so.1*"
    linkRuntimeLibrary "libdbusmenu-glib.so.4" "libdbusmenu-glib.so.4*"
    linkRuntimeLibrary "libdbusmenu-gtk.so.4" "libdbusmenu-gtk.so.4*"
    linkRuntimeLibrary "libindicator.so.7" "libindicator.so.7*"

    # libvpx is a multi-output package. Its default coercion is the `bin`
    # output on current nixpkgs; the shared object is in `out`.
    libvpxTarget="$(${pkgs.findutils}/bin/find ${pkgs.libvpx.out}/lib \
      -mindepth 1 -maxdepth 1 -name 'libvpx.so.*' -print \
      | ${pkgs.coreutils}/bin/sort -V \
      | ${pkgs.gnused}/bin/sed -n '$p')"

    if [ -n "$libvpxTarget" ]; then
      ln -sfn "$libvpxTarget" "$steamLibDir/libvpx.so.6"
    fi

    # Some ARM client archives have lost executable bits in the past.
    for binary in \
      steam \
      steamwebhelper \
      steamwebhelper.sh \
      gldriverquery \
      vulkandriverquery \
      steamsysinfo
    do
      if [ -e "$clientDir/$binary" ]; then
        chmod u+x "$clientDir/$binary"
      fi
    done

    unset GIO_EXTRA_MODULES
    unset VK_ICD_FILENAMES

    # Select the native AArch64 Turnip ICD provided by NixOS.
    if [ -z "$VK_DRIVER_FILES" ]; then
      for icd in /run/opengl-driver/share/vulkan/icd.d/freedreno_icd*.json; do
        if [ -e "$icd" ]; then
          export VK_DRIVER_FILES="$icd"
          break
        fi
      done
    fi

    # Steam starts runtime helpers by basename through `sh -c`, so their
    # directory must be on PATH.  On ordinary distributions the Steam
    # launcher/runtime setup supplies this implicitly; buildFHSEnv does not.
    runtimeHelperPath=""

    for helperDir in \
      "$runtimePlatform/files/bin" \
      "$runtimeDir/bin" \
      "$runtimeDir/pressure-vessel/bin" \
      "$clientDir"
    do
      if [ -d "$helperDir" ]; then
        runtimeHelperPath="$runtimeHelperPath:$helperDir"
      fi
    done

    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin$runtimeHelperPath:$PATH"
    export LD_LIBRARY_PATH="$steamLibDir:/run/opengl-driver/lib:/usr/lib:$LD_LIBRARY_PATH"

    echo "ARM64 Steam HOME: $HOME"
    echo "ARM64 Steam root: $steamRoot"

    # Queue required Steam tools without an install dialog.  `+app_install` is
    # a Steam client console command accepted on its command line.  A manifest
    # appears as soon as Steam has accepted an install, so later launches leave
    # in-progress/completed downloads to Steam and do not queue duplicates.
    installArgs=()

    for appId in ${requiredSteamToolAppIdsString}; do
      if [ ! -s "$steamAppsDir/appmanifest_$appId.acf" ]; then
        echo "Queuing required ARM64 Steam tool AppID $appId..."
        installArgs+=( "+app_install" "$appId" )
      fi
    done

    # Run dependency checks from inside this exact FHS environment.
    if [ "$#" -gt 0 ] && [ "$1" = "--diagnose" ]; then
      module="$clientDir/vgui2_s.so"

      echo
      echo "FHS dependency diagnostic"
      echo "Module: $module"
      echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
      echo

      file "$module" || true
      echo
      ldd "$module" || true

      echo
      echo "Runtime helper diagnostic"
      echo "PATH: $PATH"
      echo "steam-runtime-launcher-service: $(command -v steam-runtime-launcher-service || echo missing)"
      echo "lsof: $(command -v lsof || echo missing)"
      exit 0
    fi

    # Steam returns 42 when an installed update asks the launcher to restart
    # the client. Keep the FHS environment and isolated HOME in place while
    # honoring that request.
    while true; do
      set +e
      "$clientDir/steam" "''${installArgs[@]}" "$@"
      exitCode="$?"
      set -e

      if [ "$exitCode" -eq 42 ]; then
        echo "Steam requested a client restart. Restarting..."
        continue
      fi

      exit "$exitCode"
    done
  '';

  steamArm64Fhs = pkgs.buildFHSEnv {
    name = "steam-arm64";

    multiArch = false;
    includeClosures = true;
    privateTmp = true;

    # Command-line tools expected by Steam and Pressure Vessel.
    targetPkgs = p: with p; [
      bash
      bubblewrap
      coreutils
      curl
      file
      gawk
      glibc.bin
      lsb-release
      lsof
      pciutils
      procps
      unzip
      usbutils
      util-linux
      xdg-utils
      xz
      zenity
    ];

    # Native AArch64 libraries. Using multiPkgs makes buildFHSEnv link library
    # outputs into /usr/lib instead of selecting packages' `bin` outputs.
    multiPkgs = p: with p; [
      alsa-lib
      atk
      bzip2
      cairo
      cups
      dbus
      expat
      fontconfig
      freetype
      gdk-pixbuf
      glib
      glibc
      gtk2
      gtk3
      libGL
      libcap
      libdrm
      libgbm
      libice
      libpulseaudio
      libsm
      libva
      libvdpau
      libvpx.out
      libx11
      libxcb
      libxcomposite
      libxcursor
      libxcrypt
      libxdamage
      libxext
      libxfixes
      libxi
      libxinerama
      libxrandr
      libxrender
      libxscrnsaver
      libxtst
      libxkbcommon
      networkmanager
      nspr
      nss
      openal
      pango
      pipewire
      udev
      libudev0-shim
      vulkan-loader
      wayland
      zlib
    ];

    profile = ''
      unset GIO_EXTRA_MODULES

      export SDL_JOYSTICK_DISABLE_UDEV=1
      export GTK_IM_MODULE=xim

      export LIBGL_DRIVERS_PATH=/run/opengl-driver/lib/dri
      export __EGL_VENDOR_LIBRARY_DIRS=/run/opengl-driver/share/glvnd/egl_vendor.d
      export LIBVA_DRIVERS_PATH=/run/opengl-driver/lib/dri
      export VDPAU_DRIVER_PATH=/run/opengl-driver/lib/vdpau
    '';

    # Pressure Vessel expects a real /usr/sbin/ldconfig rather than a symlink
    # that can turn into a loop inside its nested container.
    extraBuildCommands = ''
      if [ -e "$out/usr/bin/ldconfig" ]; then
        mkdir -p "$out/usr/sbin"
        cp -f "$out/usr/bin/ldconfig" "$out/usr/sbin/ldconfig"
      fi
    '';

    extraBwrapArgs = [
      "--bind-try /tmp/dumps /tmp/dumps"
    ];

    runScript = steamArm64Inner;
  };

  steamArm64Desktop = pkgs.makeDesktopItem {
    name = "steam-arm64";
    desktopName = "Steam (ARM64 Experimental)";
    genericName = "Game Platform";
    comment = "Launch Valve's experimental native ARM64 Steam client";

    exec = "${steamArm64Fhs}/bin/steam-arm64 %U";
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

  steamArm64 = pkgs.symlinkJoin {
    name = "steam-arm64-with-desktop";

    paths = [
      steamArm64Fhs
      steamArm64Desktop
    ];

    postBuild = ''
      mkdir -p "$out/share"

      if [ -d ${steamIconSource}/share/icons ]; then
        ln -s ${steamIconSource}/share/icons "$out/share/icons"
      fi

      if [ -d ${steamIconSource}/share/pixmaps ]; then
        ln -s ${steamIconSource}/share/pixmaps "$out/share/pixmaps"
      fi
    '';
  };
in
{
  environment.systemPackages = [
    steamArm64
  ];
}
