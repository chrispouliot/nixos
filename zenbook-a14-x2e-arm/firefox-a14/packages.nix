# Firefox and FFmpeg follow the consuming system's Nixpkgs.
# Only the small, hardware-tested VA driver source is pinned.
{ pkgs }:
let
  lib = pkgs.lib;
  driver = pkgs.callPackage ./driver.nix { };
  firefox = pkgs.firefox.overrideAttrs (old:
    assert lib.assertMsg (old ? makeWrapperArgs)
      "firefox-a14: the Nixpkgs Firefox wrapper interface changed; review the per-application environment integration.";
    {
      makeWrapperArgs = old.makeWrapperArgs ++ [
        "--set" "LIBVA_DRIVER_NAME" "v4l2"
        "--set" "LIBVA_DRIVERS_PATH" "${driver}/lib/dri"
        "--set" "IRIS_VAAPI_COPY" "gpu"
      ];
      passthru = (old.passthru or { }) // {
        a14VaapiDriver = driver;
      };
    });
in
assert lib.assertMsg (pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isAarch64)
  "firefox-a14: this package is intended for the tested AArch64 Iris setup.";
{
  inherit driver firefox;
}
