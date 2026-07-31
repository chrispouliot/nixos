# Module to add two new scripts. nixupgrade and nixrebuild

{ pkgs, ... }:

let
  nixupgrade = pkgs.writeShellScriptBin "nixupgrade" ''
    set -e
    sudo nix flake update --flake /etc/nixos
    sudo nixos-rebuild switch --flake /etc/nixos
  '';
  # Rebuild without updating flake inputs
  nixrebuild = pkgs.writeShellScriptBin "nixrebuild" ''
    set -e
    sudo nixos-rebuild switch --flake /etc/nixos
  '';
in
{
  environment.systemPackages = [ nixupgrade nixrebuild ];
}
