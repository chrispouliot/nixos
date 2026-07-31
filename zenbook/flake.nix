{
  description = "My configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Pinned to specific 7.0.12 kernel
    #nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/16b69e2ee5d498b0a6c4e7347a2a8400bf25d50d";
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    # Hytale flatpak didnt launch correctly
    hytale-launcher.url = "github:JPyke3/hytale-launcher-nix";
    # Gnome Audio Player with local file playback resume support
    decibels-src = {
      url = "git+file:///home/chris/Projects/decibels?ref=wip/resume-state&submodules=1";
      flake = false;
    };
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";
    nix-gaming-edge = {
      url = "github:powerofthe69/nix-gaming-edge";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    wsf = {
      # url = "path:/home/chris/Projects/wayland-scroll-factor";
      url = "github:daniel-g-carrasco/wayland-scroll-factor";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    touchpad-speed-control = {
      url = "git+file:///home/chris/Projects/touchpad-speed-control";
      flake = false;
    };
    medialine = {
      url = "github:funinkina/medialine";
      flake = false;
    };
    bubbles = {
      #url = "git+file:///home/chris/Projects/bubbles";
      url = "github:chrispouliot/Bubbles";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    calendar = {
      url = "github:chrispouliot/calendar";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nix-cachyos-kernel, hytale-launcher, decibels-src, nix-flatpak, nix-gaming-edge, wsf, bubbles, calendar, ... }@inputs:
    {
      nixosConfigurations = {
        nixos = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            inherit inputs;
          };
          modules = [
            wsf.nixosModules.default
            {
              nixpkgs.overlays = [ wsf.overlays.default ];
              programs.wsf.enable = true;
            }
            # Cachyos Kernel and proton
            ({ pkgs, ... }:
            {
              nixpkgs.overlays = [
                nix-cachyos-kernel.overlays.pinned
                nix-gaming-edge.overlays.proton-cachyos
              ];

              nix.settings = {
                extra-substituters = [
                  "https://attic.xuyh0120.win/lantian"
                ];
                extra-trusted-public-keys = [
                  "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
                ];
              };

              boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest-x86_64-v4;
              programs.steam = {
                enable = true;

                extraPackages = with pkgs; [
                  adwaita-icon-theme
                ];
                extraCompatPackages = [ pkgs.proton-cachyos-x86_64-v3 ];

               package = pkgs.steam.override {
                 extraEnv = {
                   XCURSOR_THEME = "Adwaita";
                   XCURSOR_SIZE = "48";
                   XCURSOR_PATH = "/usr/share/icons";
                 };
               };
              };
            })
            {
            nixpkgs.overlays = [
              (final: prev: {
                decibels = prev.decibels.overrideAttrs (old: {
                  src = decibels-src;
                  version = "${old.version}-local";
                });
              })
              ];
            }
            # Personal calendar app, replaces Gnome Calendar
            ({ pkgs, ... }: {
              environment.systemPackages = [
                calendar.packages.${pkgs.stdenv.hostPlatform.system}.default
              ];
            })
            # Hytale
            { environment.systemPackages = [
                hytale-launcher.packages.x86_64-linux.default
              ];
            }
            nix-flatpak.nixosModules.nix-flatpak
            # Locally made Bubbles app (Openbubbles GTK)
            bubbles.nixosModules.default
            ./configuration.nix
          ];
        };
      };
    };
}
