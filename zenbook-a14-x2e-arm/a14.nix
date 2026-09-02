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

  # Keep the proven four-channel MultiMedia1 speaker frontend intact,
  # then add a separate stereo MultiMedia5 frontend and
  # DISPLAY_PORT_RX_2 backend for the built-in HDMI connector.
  #
  # The upstream macro library is pinned through flake.lock. The
  # board-specific root topology is kept as a normal source file so
  # M4 quoting is not altered by Nix string escaping.
  a14AudioTopology = pkgs.runCommand "a14-audio-topology-hdmi" {
    nativeBuildInputs = [
      pkgs.buildPackages.alsa-utils
      pkgs.buildPackages.gnum4
    ];
  } ''
    cp -a ${inputs.audioreach-topology} source
    chmod -R u+w source

    install -m644 \
      ${./patches/a14-hdmi-topology.m4} \
      source/GLYMUR-CRD.m4

    (
      cd source

      m4 -I . GLYMUR-CRD.m4 \
        > GLYMUR-ASUS-Zenbook-A14-UX3407NA.conf

      alsatplg \
        -c GLYMUR-ASUS-Zenbook-A14-UX3407NA.conf \
        -o GLYMUR-ASUS-Zenbook-A14-UX3407NA-tplg.bin
    )

    install -Dm644 \
      source/GLYMUR-ASUS-Zenbook-A14-UX3407NA-tplg.bin \
      $out/lib/firmware/qcom/glymur/GLYMUR-ASUS-Zenbook-A14-UX3407NA-tplg.bin
  '';


  # ------------------------------------------------------------
  # ASUS UX3407NA two-speaker UCM
  # ------------------------------------------------------------

  # Keep the always-available internal Speaker and Mic devices in UCM.
  #
  # Do NOT put HDMI in this HiFi verb. Qualcomm DP audio PCM hw:0,4
  # legitimately returns -EINVAL while no display is connected. ACP probes
  # every PCM in a UCM profile, so including HDMI here causes WirePlumber to
  # reject the entire HiFi profile whenever HDMI is unplugged, taking the
  # internal speakers and microphones down with it.
  #
  # HDMI is exposed separately at runtime by a14HdmiAudioHotplug below.
  a14Ucm = pkgs.runCommand "a14-ucm-two-speaker" {
    nativeBuildInputs = [
      pkgs.buildPackages.gnused
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

    # HDMI must not be part of the always-on UCM HiFi profile.
    if grep -qE \
      'HDMI2|DISPLAY_PORT_RX_2|DP2 Jack|CardId},4' \
      $out/share/alsa/ucm2/Qualcomm/glymur/HiFi.conf
    then
      echo "ERROR: HDMI leaked into the always-on A14 UCM HiFi profile"
      exit 1
    fi

    if grep -RqiE \
      'WooferRight|TweeterRight|Wsa2Speaker' \
      $out/share/alsa/ucm2/Qualcomm/glymur \
      $out/share/alsa/ucm2/codecs/wsa884x/four-speakers
    then
      echo "ERROR: nonexistent WSA2 speaker references remain in A14 UCM"
      exit 1
    fi

    echo "ASUS A14 always-on Speaker + Mic UCM prepared successfully"
  '';


  # ------------------------------------------------------------
  # ASUS UX3407NA HDMI hotplug bridge
  # ------------------------------------------------------------

  # The kernel/topology exposes HDMI as MultiMedia5 (hw:0,4), with
  # connection state reported by the read-only "DP2 Jack" ALSA control.
  # hw:0,4 cannot be prepared while HDMI is disconnected, so keep it out of
  # ACP/UCM probing and instantiate it only while the jack is actually on.
  #
  # PipeWire 1.6's PulseAudio compatibility layer provides a built-in
  # module-alsa-sink. The helper below loads that module on HDMI connect and
  # unloads it on disconnect. It retries once per second while the jack is on,
  # which also covers the small interval where the display link is detected
  # before its audio engine is ready.
  a14HdmiAudioHotplug = pkgs.writeShellApplication {
    name = "a14-hdmi-audio-hotplug";

    runtimeInputs = [
      pkgs.alsa-utils
      pkgs.pulseaudio
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnused
    ];

    text = ''
      sink_name="a14_hdmi"

      module_ids() {
        pactl list modules short 2>/dev/null | \
          awk -v sink="$sink_name" '
            $2 == "module-alsa-sink" && index($0, "sink_name=" sink) {
              print $1
            }
          ' || true
      }

      sink_loaded() {
        pactl list sinks short 2>/dev/null | \
          awk -v sink="$sink_name" '
            $2 == sink { found = 1 }
            END { exit !found }
          '
      }

      set_hdmi_mixer() {
        value="$1"
        amixer -c 0 cset \
          name='DISPLAY_PORT_RX_2 Audio Mixer MultiMedia5' \
          "$value" >/dev/null 2>&1 || true
      }

      unload_hdmi() {
        while IFS= read -r module_id; do
          if [ -n "$module_id" ]; then
            pactl unload-module "$module_id" >/dev/null 2>&1 || true
          fi
        done < <(module_ids)

        set_hdmi_mixer 0,0
      }

      load_hdmi() {
        if sink_loaded; then
          return 0
        fi

        # The AudioReach backend has a two-value mixer switch. Both channels
        # must be on; a scalar "1" only enabled the first one in testing.
        set_hdmi_mixer 1,1

        if pactl load-module module-alsa-sink \
          sink_name="$sink_name" \
          device=hw:0,4 \
          format=s16le \
          rate=48000 \
          channels=2 \
          channel_map=front-left,front-right \
          sink_properties=device.description=HDMI \
          >/dev/null 2>&1
        then
          return 0
        fi

        set_hdmi_mixer 0,0
        return 1
      }

      jack_state() {
        amixer -c 0 cget iface=CARD,name='DP2 Jack' 2>/dev/null | \
          sed -n 's/.*: values=\(on\|off\).*/\1/p' | \
          tail -n 1 || true
      }

      cleanup() {
        unload_hdmi
      }

      trap cleanup EXIT INT TERM

      # pipewire-pulse may be socket activated. Wait until pactl can talk to
      # it before inspecting or creating modules.
      until pactl info >/dev/null 2>&1; do
        sleep 1
      done

      # Remove any stale instance left by a prior helper/PipeWire restart.
      unload_hdmi

      last_state=""

      while true; do
        state="$(jack_state)"

        if [ "$state" = "on" ]; then
          # Keep retrying while connected in case the DP link/audio engine
          # needs another moment after the jack notification.
          load_hdmi || true
        else
          if [ "$last_state" = "on" ] || sink_loaded; then
            unload_hdmi
          fi
        fi

        last_state="$state"
        sleep 1
      done
    '';
  };


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
    ./agent-sandbox.nix
    ./fex.nix
    ./steam-arm64.nix
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

  # Use the corrected always-on Speaker + Mic UCM tree for programs launched
  # from the desktop/session as well as diagnostic ALSA utilities.
  environment.sessionVariables.ALSA_CONFIG_UCM2 =
    "${a14Ucm}/share/alsa/ucm2";

  # WirePlumber owns ALSA device/profile discovery, so this service also needs
  # the custom UCM path explicitly.
  systemd.user.services.wireplumber.environment.ALSA_CONFIG_UCM2 =
    "${a14Ucm}/share/alsa/ucm2";


  # ------------------------------------------------------------
  # ASUS UX3407NA speaker mapping + transparent 1.50x boost
  # ------------------------------------------------------------

  # MultiMedia1 is intentionally a four-channel frontend, while the two real
  # physical speakers occupy slots 0 and 2:
  #
  #   slot 0 -> physical left
  #   slot 1 -> unused
  #   slot 2 -> physical right
  #   slot 3 -> unused
  #
  # Tell PipeWire that layout so ordinary stereo FL/FR lands on slots 0/2.
  # Apply the 1.50x gain *inside* the real speaker node with WirePlumber's
  # internal filter graph. This gives desktop applications exactly one visible
  # internal output named "Speakers"; there is no separate raw/boosted sink.
  #
  # Force the A14 card to the UCM HiFi profile. HDMI is no longer part of that
  # profile, so HiFi remains valid whether a display is connected or not.
  environment.etc."wireplumber/wireplumber.conf.d/90-a14-speakers.conf".text = ''
    monitor.alsa.rules = [
      {
        matches = [
          {
            device.name = "alsa_card.platform-sound"
          }
        ]

        actions = {
          update-props = {
            api.alsa.use-acp = true
            api.alsa.use-ucm = true
            device.profile = "HiFi"
          }
        }
      }
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
            node.description = "Speakers"
            priority.session = 1400
          }
        }
      }
    ]

    node.filter-graph.rules = [
      {
        matches = [
          {
            node.name = "alsa_output.platform-sound.HiFi__Speaker__sink"
          }
        ]

        actions = {
          create-filter-graph = [
            {
              nodes = [
                {
                  type = builtin
                  name = gain
                  label = linear

                  control = {
                    Mult = 1.50
                    Add = 0.0
                  }
                }
              ]
            }
          ]
        }
      }
    ]
  '';


  # ------------------------------------------------------------
  # ASUS UX3407NA HDMI audio hotplug
  # ------------------------------------------------------------

  # Expose a conventional two-channel PipeWire sink named "HDMI" only while
  # DP2 Jack is connected. Keeping hw:0,4 out of UCM avoids ACP rejecting the
  # entire HiFi profile when no TV/receiver is present.
  systemd.user.services.a14-hdmi-audio-hotplug = {
    description = "ASUS A14 HDMI audio hotplug";

    wantedBy = [ "default.target" ];
    wants = [
      "pipewire-pulse.service"
      "wireplumber.service"
    ];
    after = [
      "pipewire-pulse.service"
      "wireplumber.service"
    ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${a14HdmiAudioHotplug}/bin/a14-hdmi-audio-hotplug";
      Restart = "always";
      RestartSec = 1;
    };
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
  networking.networkmanager.wifi.powersave = false;


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

    # Temporary MSM DP/eDP link-training diagnostics
    "drm.debug=0x100"

    # USB Hub / Display suspend fix
    "pm_async=off"
    "usbcore.quirks=2109:0817:k"

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

  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2109", ATTR{idProduct}=="2817", TEST=="power/control", ATTR{power/control}="on"
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2109", ATTR{idProduct}=="0817", TEST=="power/control", ATTR{power/control}="on"
  '';

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


  # Locally made agent sandbox
  programs.agentSandbox = {
    enable = true;
    defaultAgent = "opencode";
    extraTools = ["jq"];
    diskWarn = {
      enable = true;
      checkIntervalHours = 6;
      minFreeGiB = 80; # Nix store size, including host
      volumeWarnGiB = 30; # Podman volumes (per project combines)
    };
  };

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
    ripgrep
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

    alsa-utils
    dtc

    firefoxpwa
    mission-center
    menulibre
    prismlauncher
    ghostty

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
