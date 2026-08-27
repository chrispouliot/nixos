{ lib, pkgs, inputs, ... }:

let
  # ------------------------------------------------------------
  # QCC2072 runtime Wi-Fi firmware
  # ------------------------------------------------------------

  # Pin the newer upstream Qualcomm runtime firmware independently of
  # the linux-firmware release currently provided by nixpkgs.
  #
  # Current nixpkgs firmware:
  #   WLAN.COL.1.0.c2-00074-QCACOLSWPL_V1_TO_SILICONZ-1
  #
  # This pinned firmware:
  #   WLAN.COL.1.0.c2-00228-QCACOLSWPL_V1_TO_SILICON-1
  qcc2072Firmware = pkgs.runCommand "qcc2072-firmware-00228" { } ''
    install -Dm644 \
      ${inputs.linux-firmware-qcc2072}/ath12k/QCC2072/hw1.0/firmware-2.bin \
      $out/lib/firmware/ath12k/QCC2072/hw1.0/firmware-2.bin
  '';


  # ------------------------------------------------------------
  # ASUS UX3407NA AudioReach topology
  # ------------------------------------------------------------

  # The machine driver requests a board-specific topology filename,
  # while linux-firmware currently provides only the generic Glymur
  # CRD topology. Install the stock Glymur topology under the filename
  # expected by this machine.
  #
  # MultiMedia1 intentionally remains a 4-channel frontend. The kernel
  # constrains the actual WSA backend to the two physical speakers.
  a14AudioTopology = pkgs.runCommand "a14-audio-topology" { } ''
    install -Dm644 \
      ${pkgs.linux-firmware}/lib/firmware/qcom/glymur/GLYMUR-CRD-tplg.bin \
      $out/lib/firmware/qcom/glymur/GLYMUR-ASUS-Zenbook-A14-UX3407NA-tplg.bin
  '';


  # ------------------------------------------------------------
  # ASUS UX3407NA two-speaker UCM
  # ------------------------------------------------------------

  # The current generic Glymur UCM assumes four WSA8845 speaker
  # devices split across WSA/swr0 and WSA2/swr3.
  #
  # The UX3407NA actually has two attached WSA8845 devices, both on
  # swr0. The two devices described on swr3 are unattached/nonexistent.
  #
  # Until the upstream Glymur/ASUS UCM is corrected, derive an A14
  # profile from the generic one and remove the nonexistent WSA2 side.
  a14Ucm = pkgs.runCommand "a14-ucm-two-speaker" {
    nativeBuildInputs = [
      pkgs.gnused
    ];
  } ''
    mkdir -p $out/share/alsa

    cp -a \
      ${pkgs.alsa-ucm-conf}/share/alsa/ucm2 \
      $out/share/alsa/ucm2

    chmod -R u+w $out/share/alsa/ucm2


    # ------------------------------------------------------------
    # ASUS UX3407NA card-name mapping
    # ------------------------------------------------------------

    ln -sf \
      ../../Qualcomm/glymur/GLYMUR-CRD.conf \
      $out/share/alsa/ucm2/conf.d/glymur/ASUSTeKCOMPUTERINC.-ZenbookA14UX3407NA-1.0-UX3407NA.conf


    # ------------------------------------------------------------
    # Keep only the two physical WSA8845 codecs on swr0
    # ------------------------------------------------------------

    # The current DT names the two real swr0 codecs WooferLeft and
    # TweeterLeft, despite them functioning as the laptop's two physical
    # stereo speakers.
    #
    # Remove only the nonexistent codecs currently described as
    # WooferRight/TweeterRight on swr3.
    for f in \
      $out/share/alsa/ucm2/codecs/wsa884x/four-speakers/SpeakerSeq.conf \
      $out/share/alsa/ucm2/codecs/wsa884x/four-speakers/DefaultEnableSeq.conf \
      $out/share/alsa/ucm2/codecs/wsa884x/four-speakers/init.conf
    do
      sed -i \
        -e '/WooferRight/d' \
        -e '/TweeterRight/d' \
        "$f"
    done


    # ------------------------------------------------------------
    # Remove WSA2/swr3 from the Glymur UCM
    # ------------------------------------------------------------

    # Only WSA/swr0 is physically populated on the UX3407NA.
    sed -i \
      -e '/Wsa2SpeakerEnableSeq/d' \
      -e '/Wsa2SpeakerDisableSeq/d' \
      $out/share/alsa/ucm2/Qualcomm/glymur/HiFi.conf


    # The generic four-speaker card initialization also configures the
    # WSA2 macro. Remove those commands for this machine.
    sed -i \
      '/WSA2/d' \
      $out/share/alsa/ucm2/codecs/qcom-lpass/wsa-macro/four-speakers/init.conf


    # ------------------------------------------------------------
    # Sanity checks
    # ------------------------------------------------------------

    # MultiMedia1 remains the stock four-channel AudioReach frontend.
    grep -q \
      'PlaybackChannels 4' \
      $out/share/alsa/ucm2/Qualcomm/glymur/HiFi.conf

    if grep -RqiE \
      'WooferRight|TweeterRight|Wsa2Speaker' \
      $out/share/alsa/ucm2/Qualcomm/glymur \
      $out/share/alsa/ucm2/codecs/wsa884x/four-speakers
    then
      echo "ERROR: nonexistent WSA2 speaker references remain in A14 UCM"
      exit 1
    fi

    echo "ASUS A14 two-speaker UCM prepared successfully"
  '';


  # ------------------------------------------------------------
  # Factory ASUS firmware
  # ------------------------------------------------------------

  # Proprietary ASUS/Qualcomm firmware extracted from the factory
  # Windows installation. Do not redistribute these files.
  a14Firmware = pkgs.runCommand "asus-a14-glymur-firmware" { } ''
    # ------------------------------------------------------------
    # ADSP / CDSP
    # ------------------------------------------------------------

    install -Dm644 ${./firmware/qcadsp8480.mbn} \
      $out/lib/firmware/qcom/glymur/ASUSTeK/UX3407NA/qcadsp8480.mbn

    install -Dm644 ${./firmware/qccdsp8480.mbn} \
      $out/lib/firmware/qcom/glymur/ASUSTeK/UX3407NA/qccdsp8480.mbn

    install -Dm644 ${./firmware/adsp_dtbs.elf} \
      $out/lib/firmware/qcom/glymur/ASUSTeK/UX3407NA/adsp_dtbs.elf

    install -Dm644 ${./firmware/cdsp_dtbs.elf} \
      $out/lib/firmware/qcom/glymur/ASUSTeK/UX3407NA/cdsp_dtbs.elf


    # ------------------------------------------------------------
    # Wi-Fi
    # ------------------------------------------------------------

    # Factory ASUS/NCM820A QCC2072 board data.
    #
    # linux-firmware supplies generic QCC2072 board-2.bin, but it does
    # not contain the ASUS 105b:e14f board entry. Provide the exact
    # factory Qualcomm BDF ELF as ath12k's board.bin fallback.
    #
    # Note that this is board/calibration data and is separate from
    # firmware-2.bin above.
    install -Dm644 ${./firmware/bdwlan_qcc2072_1p0_ncm820A.elf} \
      $out/lib/firmware/ath12k/QCC2072/hw1.0/board.bin


    # ------------------------------------------------------------
    # Bluetooth
    # ------------------------------------------------------------

    # Factory FastConnect C7700/NCM820A Bluetooth rampatch.
    install -Dm644 ${./firmware/hmtbtfw20.tlv} \
      $out/lib/firmware/qca/hmtbtfw20.tlv

    # Generic fallback NVM.
    install -Dm644 ${./firmware/hmtnv20.bin} \
      $out/lib/firmware/qca/hmtnv20.bin

    # Factory board-ID-specific NVM variants.
    install -Dm644 ${./firmware/hmtnv20.b3b} \
      $out/lib/firmware/qca/hmtnv20.b3b

    install -Dm644 ${./firmware/hmtnv20.b105} \
      $out/lib/firmware/qca/hmtnv20.b105

    install -Dm644 ${./firmware/hmtnv20.b107} \
      $out/lib/firmware/qca/hmtnv20.b107

    install -Dm644 ${./firmware/hmtnv20.b108} \
      $out/lib/firmware/qca/hmtnv20.b108

    install -Dm644 ${./firmware/hmtnv20.b10f} \
      $out/lib/firmware/qca/hmtnv20.b10f

    install -Dm644 ${./firmware/hmtnv20.b112} \
      $out/lib/firmware/qca/hmtnv20.b112
  '';

in
{
  imports = [
    ./fex.nix
    ./steam.nix
    ./hytale.nix
    ./helpers.nix
  ];
  # ------------------------------------------------------------
  # Device tree
  # ------------------------------------------------------------

  # Use the DTB already built by the custom Glymur kernel, but apply
  # board-specific fixes as separate DT overlays.
  #
  # This means editing a14-ec-overlay.dts only rebuilds the DTB
  # package rather than rebuilding the entire kernel.
  hardware.deviceTree = {
    enable = true;

    # Exact ASUS Zenbook A14 UX3407NA device tree to install.
    name = "qcom/glymur-asus-zenbook-a14-ux3407na.dtb";

    # Avoid processing every DTB produced by the kernel.
    filter = "glymur-asus-zenbook-a14-ux3407na.dtb";

    overlays = [
      {
        name = "asus-a14-ec";
        filter = "glymur-asus-zenbook-a14-ux3407na.dtb";
        dtsFile = ./patches/a14-ec-overlay.dts;
      }
    ];
  };

  # Memory
    swapDevices = [
    {
      device = "/swapfile";
      size = 16 * 1024; # MiB: 16 GiB
      priority = 10;
    }
  ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100;
  };


  # ------------------------------------------------------------
  # Initrd
  # ------------------------------------------------------------

  boot.initrd.systemd.tpm2.enable = false;


  # ------------------------------------------------------------
  # ASUS UX3407NA audio
  # ------------------------------------------------------------

  # Use the corrected two-speaker UCM tree for programs launched from
  # the desktop/session as well as diagnostic ALSA utilities.
  environment.sessionVariables.ALSA_CONFIG_UCM2 =
    "${a14Ucm}/share/alsa/ucm2";

  # WirePlumber owns ALSA device/profile discovery, so this is the
  # service that actually needs the custom UCM path.
  systemd.user.services.wireplumber.environment.ALSA_CONFIG_UCM2 =
    "${a14Ucm}/share/alsa/ucm2";


  # ------------------------------------------------------------
  # ASUS UX3407NA physical speaker channel mapping
  # ------------------------------------------------------------

  # The underlying AudioReach PCM is four channels, but the two
  # physical stereo speakers are carried in PCM slots 0 and 2:
  #
  #   slot 0 -> physical left
  #   slot 1 -> unused
  #   slot 2 -> physical right
  #   slot 3 -> unused
  #
  # PipeWire otherwise assumes FL,FR,RL,RR and sends stereo Right to
  # slot 1. Describe the actual Qualcomm channel order so stereo
  # Left/Right reaches both physical speakers.
  environment.etc."wireplumber/wireplumber.conf.d/90-a14-speakers.conf".text = ''
    monitor.alsa.rules = [
      {
        matches = [
          {
            node.name = "alsa_output.platform-sound.HiFi__Speaker__sink"
          }
        ]

        actions = {
          update-props = {
            audio.channels = 4
            audio.position = [ FL RL FR RR ]
          }
        }
      }
    ]
  '';


  # ------------------------------------------------------------
  # ASUS UX3407NA virtual speaker boost
  # ------------------------------------------------------------

  # Create a separate stereo sink for GNOME/applications instead of
  # inserting a filter directly into the unusual four-channel A14
  # hardware node.
  #
  # The virtual sink's normal 0-100% volume control is applied first,
  # followed by a fixed 1.50x software gain:
  #
  #    desktop   effective old scale
  #       0%   ->   0%
  #      50%   ->  75%
  #      67%   -> ~100%
  #     100%   -> 150%
  #
  # The resulting FL/FR stereo stream is forwarded to the real A14
  # hardware sink. Its FL/RL/FR/RR mapping above then places:
  #
  #   FL -> PCM slot 0 -> physical left speaker
  #   FR -> PCM slot 2 -> physical right speaker
  #
  # Keep the hardware WSA8845 gain limits unchanged; this is purely
  # software amplification.
  services.pipewire.extraConfig.pipewire."95-a14-speaker-boost" = {
    "context.modules" = [
      {
        name = "libpipewire-module-filter-chain";

        args = {
          "node.description" = "A14 Speaker Boost";
          "media.name" = "A14 Speaker Boost";

          "filter.graph" = {
            nodes = [
              {
                type = "builtin";
                name = "gain";
                label = "linear";

                control = {
                  Mult = 1.50;
                  Add = 0.0;
                };
              }
            ];
          };

          # Virtual stereo sink exposed to GNOME/applications.
          "capture.props" = {
            "node.name" = "a14_boosted";
            "node.description" = "Built-in Audio Speakers";
            "media.class" = "Audio/Sink";

            "audio.channels" = 2;
            "audio.position" = [
              "FL"
              "FR"
            ];

            "node.virtual" = true;

            # Prefer this virtual speaker sink to the raw ALSA sink.
            "priority.session" = 1400;
          };

          # Processed stream sent to the real A14 speaker node.
          "playback.props" = {
            "node.name" = "a14_boosted_output";

            "target.object" =
              "alsa_output.platform-sound.HiFi__Speaker__sink";

            "audio.channels" = 2;
            "audio.position" = [
              "FL"
              "FR"
            ];

            "node.passive" = true;
          };
        };
      }
    ];
  };


  # ------------------------------------------------------------
  # Early-boot hardware modules
  # ------------------------------------------------------------

  # These modules must be present in stage-1.
  #
  # tcsrcc-glymur is especially important: without it the Glymur
  # USB PHYs defer because their reference clock provider at
  # 1fd5000.clock-controller never becomes available.
  boot.initrd.availableKernelModules = [
    # Glymur TCSR clock provider.
    "tcsrcc-glymur"

    # Internal NVMe / PCIe PHY.
    "phy_qcom_qmp_pcie"

    # USB PHY stack.
    "phy_qcom_m31_eusb2"
    "phy_qcom_eusb2_repeater"
    "phy_qcom_qmp_usb"
    "phy_qcom_qmp_usbc"

    # USB Attached SCSI support.
    "uas"

    # Internal keyboard / Qualcomm I2C path.
    "gpi"
    "i2c_qcom_geni"
    "i2c_hid_of"
  ];

  # Force the platform-critical pieces to load during stage-1 rather
  # than relying entirely on automatic module loading.
  boot.initrd.kernelModules = [
    # Required clock provider for the USB PHYs.
    "tcsrcc-glymur"

    # Internal NVMe / PCIe PHY.
    "phy_qcom_qmp_pcie"

    # USB PHY stack.
    "phy_qcom_m31_eusb2"
    "phy_qcom_eusb2_repeater"
    "phy_qcom_qmp_usb"
    "phy_qcom_qmp_usbc"

    # Internal keyboard / Qualcomm I2C path.
    "gpi"
    "i2c_qcom_geni"
    "i2c_hid_of"
  ];

  # ASUS Glymur EC driver. The DT overlay supplies the UX3407NA EC
  # node needed for this driver to bind.
  boot.kernelModules = [
    "asus-glymur-ec"
  ];


  # ------------------------------------------------------------
  # Firmware
  # ------------------------------------------------------------

  # Standard linux-firmware package set.
  hardware.enableRedistributableFirmware = true;
  hardware.enableAllFirmware = true;

  # Put the pinned QCC2072 runtime firmware and our factory ASUS
  # firmware ahead of generic linux-firmware.
  #
  # hardware.firmware resolves duplicate paths using the first package
  # in the list, so this makes our 00228 firmware-2.bin override the
  # older 00074 copy currently provided by linux-firmware.
  hardware.firmware = lib.mkBefore [
    qcc2072Firmware
    a14AudioTopology
    a14Firmware
  ];

  # Keep firmware uncompressed during bring-up so firmware loading
  # remains as simple as possible.
  hardware.firmwareCompression = "none";


  # ------------------------------------------------------------
  # CPU frequency scaling / EAS
  # ------------------------------------------------------------

  # SCMI cpufreq should expose the X2 performance domains. With the
  # Glymur CPU capacity data + Energy Model available, EAS should
  # activate automatically.
  powerManagement.cpuFreqGovernor = "schedutil";


  # ------------------------------------------------------------
  # Networking
  # ------------------------------------------------------------

  networking.networkmanager.enable = true;


  # ------------------------------------------------------------
  # Platform configuration
  # ------------------------------------------------------------

  # There is currently no useful TPM support on this platform.
  systemd.tpm2.enable = false;

  # Avoid trying to build unsupported filesystems such as ZFS against
  # the bleeding-edge Glymur kernel.
  boot.supportedFilesystems = lib.mkForce [
    "ext4"
    "vfat"
    "btrfs"
    "xfs"
  ];


  # ------------------------------------------------------------
  # Kernel parameters
  # ------------------------------------------------------------

  boot.kernelParams = [
    "console=tty1"
    "consoleblank=0"

    # Deep suspend currently causes GPU/power-domain problems.
    # s2idle has resumed cleanly without Adreno fault loops.
    "mem_sleep_default=s2idle"
  ];

  # Keep useful kernel output available during bring-up.
  # installed.nix currently overrides this to 3 for the installed OS.
  boot.consoleLogLevel = 7;


  # ------------------------------------------------------------
  # Services
  # ------------------------------------------------------------

  # Enable Tailscale.
  services.tailscale.enable = true;

  services.syncthing = {
    enable = true;
    group = "users";
    user = "chris";
    dataDir = "/home/chris/Documents";
    configDir = "/home/chris/.config/syncthing";
  };

  # Locally made OpenBubbles GTK app.
  programs.bubbles.enable = true;

  # Proton Bridge.
  #
  # GNOME Keyring/Secret Service is enabled by installed.nix, so
  # Bridge does not need pass/gnupg explicitly added to its PATH.
  services.protonmail-bridge.enable = true;

  security.pki.certificateFiles = [
    ./protonmail-bridge-cert.pem
  ];


  # ------------------------------------------------------------
  # Flatpaks
  # ------------------------------------------------------------

  services.flatpak = {
    enable = true;
    uninstallUnmanaged = false;

    update.auto = {
      enable = true;
      onCalendar = "weekly";
    };

    packages = [
      "org.onlyoffice.desktopeditors"
      "com.github.tchx84.Flatseal"
      "dev.qwery.AddWater"
      "com.jeffser.Nocturne"
      "de.schmidhuberj.tubefeeder"
      "page.codeberg.libre_menu_editor.LibreMenuEditor"
      "com.moonlight_stream.Moonlight"
      "io.github.alainm23.planify"
      "io.github.tanaybhomia.Whisp"
      "org.zotero.Zotero"
    ];
  };


  # ------------------------------------------------------------
  # Packages
  # ------------------------------------------------------------

  programs.firefox.enable = true;
  programs.firefox.nativeMessagingHosts.packages = [ pkgs.firefoxpwa ];

  environment.systemPackages = with pkgs; [
    # Local apps / extensions
    (pkgs.callPackage ./pkgs/touchpad-speed-control.nix {
      src = inputs.touchpad-speed-control;
    })

    # Local GNOME extension, source is contained in the package file.
    (pkgs.callPackage ./pkgs/notif-icon-colour.nix { })

    (pkgs.callPackage ./pkgs/medialine.nix {
      src = inputs.medialine;
    })

    gnomeExtensions.appindicator
    # gnomeExtensions.medialine # Not available in nixpkgs yet, manual install
    gnomeExtensions.steal-my-focus-window

    git
    vim

    pciutils
    usbutils
    ethtool
    iw

    lm_sensors

    drm_info
    mesa-demos
    vulkan-tools
    kmscube

    dtc

    firefoxpwa
    mission-center
    menulibre
    prismlauncher

    # Vesktop Electron bug fix: appindicator wouldn't show with
    # Electron 43, so temporarily use Electron 42.
    ((vesktop.override {
      electron_43 = electron_42;
    }).overrideAttrs (_old: {
      preBuild = ''
        cp -r ${electron_42.dist} electron-dist
        chmod -R u+w electron-dist
      '';
    }))
  ];
}
