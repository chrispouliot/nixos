# Import this module from the existing A14 NixOS configuration.
{ lib, pkgs, ... }:
let
  packages = import ./packages.nix { inherit pkgs; };
in {
  programs.firefox = {
    enable = true;
    package = packages.firefox;
    preferences = {
      "media.hardware-video-decoding.enabled" = lib.mkDefault true;
      "media.hardware-video-decoding.force-enabled" = lib.mkDefault true;
      "media.hardware-video-decoding-vulkan.enabled" = lib.mkDefault false;
      "media.hevc.enabled" = lib.mkDefault true;
    };
  };
}
