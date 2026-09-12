# Firefox VA-API decoding on the A14

Revision 4 replaces the earlier Firefox-only FFmpeg fork with the successfully
tested Iris VA-API bridge. Your normal Firefox command and desktop launcher use:

Firefox VA-API backend → stock FFmpeg/libva → libva-v4l2 → Iris hardware.

Your A14 test confirmed H.264, HEVC and VP9 hardware frames in the same Firefox
155.0.1 decoder process, including codec switching. AV1 used software decoding;
the pinned bridge does not support AV1.

## Replace the existing module

Keep both existing imports: `./firefox-a14` and `./a14-vaapi-kernel` (using the
relative paths already present in your configuration). The required Iris kernel
patches must remain enabled. This package does not add or duplicate them.

Download the updated `firefox-a14-nixos.tar.gz`, then run:

```bash
cd ~/Downloads
tar -xzf firefox-a14-nixos.tar.gz
sudo mkdir -p /etc/nixos/firefox-a14
sudo cp firefox-a14/{default.nix,packages.nix,driver.nix,README.md} /etc/nixos/firefox-a14/
```

If `/etc/nixos` is Git-backed, stage the new driver and updated files so the
flake includes them (use your normal repository ownership workflow):

```bash
sudo git -C /etc/nixos add firefox-a14
```

Then rebuild without updating your flake lock:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#a14
```

Fully quit normal Firefox and the test browser, then open Firefox through its
normal desktop icon or the `firefox` command. Existing running processes keep
their old environment and libraries until you restart them. No reboot is needed
if you are already running the kernel with the two tested Iris patches.

With unchanged Nixpkgs inputs this reuses the driver you already built and the
normal cached Firefox/FFmpeg packages; only the small Firefox wrapper and system
configuration change. It does not modify Firefox source or trigger another
kernel build by itself. Unrelated pending system changes can still need builds.

The old `p010-drm-descriptor.patch` and `v4l2-per-codec-probing.patch`, if present
in `/etc/nixos/firefox-a14`, are no longer referenced. They can be left there or
removed. The earlier FFmpeg pin is no longer used by this module.

## Settings and scope

The Firefox wrapper sets:

- `LIBVA_DRIVER_NAME=v4l2`
- `LIBVA_DRIVERS_PATH=<the pinned driver's store path>/lib/dri`
- `IRIS_VAAPI_COPY=gpu`

These settings apply to Firefox and processes it launches. They are not added
to the desktop session or system environment. Separately launched Moonlight
keeps its existing decoder selection. No global VA driver registration is added.

The module supplies these Firefox preferences through NixOS:

```nix
"media.hardware-video-decoding.enabled" = true;
"media.hardware-video-decoding.force-enabled" = true;
"media.hardware-video-decoding-vulkan.enabled" = false;
"media.hevc.enabled" = true;
```

They use `lib.mkDefault`, so explicit definitions elsewhere in your NixOS config
can override them. They follow your existing `programs.firefox.preferencesStatus`
(default `locked` in NixOS). The old `media.ffmpeg.vaapi.enabled` preference in
the test script is not used by Firefox 155; the hardware decoding preferences
above control the tested path.

Existing Firefox policies, extension policies, autoconfig and native messaging
hosts continue to be handled by the normal NixOS Firefox module. The launcher
uses normal profile selection, preserving bookmarks, passwords and extensions.
No separate test profile or debug logging is enabled by this module.

Keep only one package assignment for the browser: this import sets
`programs.firefox.package`. If another module explicitly sets that option,
remove the old assignment. Avoid installing a competing `pkgs.firefox` through
`environment.systemPackages`, user packages, or Home Manager. If Home Manager
owns your Firefox package instead, it can use the `.firefox` package below, but
its preferences must also be configured there.

## Check the installed configuration

Before or after switching, inspect the final wrapper arguments:

```bash
nix eval --json /etc/nixos#nixosConfigurations.a14.config.programs.firefox.finalPackage.makeWrapperArgs
```

The result should include `LIBVA_DRIVER_NAME`, `v4l2`, `LIBVA_DRIVERS_PATH`, and
the `libva-v4l2-a14-test` driver path. Its `-test` name is retained deliberately
to reuse the exact driver from the successful hardware test.

After restarting Firefox, open `about:policies` to check the active preferences.
Test H.264, HEVC in MP4, and VP9 in the same browser session. `about:support`
shows capability information but does not prove a particular video is using
hardware decoding. The previous test's decoder logs supplied that evidence.

For a normal-profile log capture, fully close Firefox first, then run:

```bash
mkdir -p "$HOME/.local/state/firefox-a14-normal"
MOZ_LOG='timestamp,sync,PlatformDecoderModule:5,FFmpegVideo:5' \
MOZ_LOG_FILE="$HOME/.local/state/firefox-a14-normal/firefox.log" \
IRIS_VAAPI_DEBUG=1 firefox
```

The environment changes on this command are temporary. Hardware playback should
produce `VA-API FFmpeg init successful` followed by `VA-API frame` messages.
Early capability checks can mention software decoders even when actual playback
uses VA-API. Logs can contain media URLs and file paths.

## Limitations

- AV1 uses software decoding with this bridge. Sites selecting AV1 can therefore
  still use CPU decoding; H.264/VP9 selection is a separate website/browser choice.
- Firefox needs a supported container as well as a supported video codec. The
  HEVC MKV test failed during metadata parsing; remuxing the same video into MP4
  with the `hvc1` tag worked. Remuxing copies the video without re-encoding.
- The tests cover the supplied samples, not every resolution, profile, HDR mode,
  or streaming site. They establish functional decoding, not an end-to-end
  zero-copy or power-efficiency guarantee.
- The two Iris patches modify the shared kernel driver. Decode-order output is
  opt-in per session, and the other patch raises the buffer allocation ceiling.
  Keep checking your usual direct-V4L2 applications after kernel changes.

## Updates and reuse

Firefox and its stock FFmpeg dependencies follow your system's Nixpkgs. There is
no Firefox version pin, FFmpeg source pin, new flake input or module lock file.
The normal Nixpkgs wrapper selects the matching FFmpeg ABI. Browser updates can
use the ordinary binary cache, and this module adds no browser source patches.

Only `libva-v4l2` is pinned, to
`0e4ce1e05da1d0a92b342efc2090b9e4987035e1`. Nixpkgs changes to its compiler or
libraries may rebuild this small driver. Updating the bridge source requires
updating its revision/hash and checking any changed kernel requirements.

For another declarative consumer:

```nix
let
  a14Firefox = import ./firefox-a14/packages.nix { inherit pkgs; };
in {
  # a14Firefox.firefox is the normal browser with its per-process environment.
  # a14Firefox.driver is the pinned VA driver.
}
```

Importing `default.nix` through NixOS is the recommended installation because it
also sets the hardware-decoding preferences.

## Validation and rollback

Checked against Nixpkgs `d6524aaca2ff07876657ae2b323f24be4874944b` for
`aarch64-linux`: final NixOS wrapper retains the environment settings; compiled
Firefox and its library selection match stock Nixpkgs; the driver derivation is
identical to the hardware-tested one; sample policies, preferences, extension
settings, autoconfig and native messaging survive; the module does not change
kernel or global environment configuration. The final switch and normal-profile
playback must be performed on your laptop.

Use a previous NixOS generation to return to your prior patched-FFmpeg setup.
Removing this import and keeping `programs.firefox.enable = true` instead returns
to stock Firefox without this bridge. Keep the kernel-patch import unless you
also intend a kernel rollback/rebuild.

Sources: [VA-API bridge](https://github.com/radxa-pkg/libva-v4l2/tree/0e4ce1e05da1d0a92b342efc2090b9e4987035e1),
[A14 kernel](https://github.com/chrispouliot/linux-zenbook-a14-arm).
