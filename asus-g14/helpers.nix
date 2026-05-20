# Module to add two new scripts. nixupgrade and nixrebuild

{ pkgs, ... }:

let
  # Updating nvidia drivers requires nvidia dGPU to be present. Switch to hybrid then back to integrated.
  nixupgrade = pkgs.writeShellScriptBin "nixupgrade" ''
    set -e
    trap 'sudo cardwire set integrated' EXIT
    sudo cardwire set hybrid
    sudo nix flake update --flake /etc/nixos
    sudo nixos-rebuild switch --flake /etc/nixos
  '';
  # Rebuild without updating flake inputs
  nixrebuild = pkgs.writeShellScriptBin "nixrebuild" ''
    set -e
    trap 'sudo cardwire set integrated' EXIT
    sudo cardwire set hybrid
    sudo nixos-rebuild switch --flake /etc/nixos
  '';
in
{
  environment.systemPackages = [ nixupgrade nixrebuild ];
}
