{
  description = "NixOS bring-up for ASUS Zenbook A14 UX3407NA";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";
    
    hytale-arm.url = "github:chrispouliot/hytale-launcher-arm-nix";

    decibels-src = {
      url = "git+file:///home/chris/Projects/decibels?ref=wip/resume-state&submodules=1";
      flake = false;
    };

    a14.url = "path:/home/chris/Projects/linux-zenbook-a14-arm";

    bubbles = {
      #url = "git+file:///home/chris/Projects/bubbles";
      url = "github:chrispouliot/Bubbles";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    vireo = {
      url = "git+file:///home/chris/Projects/vireo?ref=nix-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    wsf = {
      url = "github:daniel-g-carrasco/wayland-scroll-factor";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    touchpad-speed-control = {
      url = "github:ritesh-777/touchpad-speed-control";
      flake = false;
    };

    medialine = {
      url = "github:funinkina/medialine";
      flake = false;
    };

    calendar = {
      url = "github:chrispouliot/calendar";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      hytale-arm,
      nix-flatpak,
      decibels-src,
      a14,
      bubbles,
      vireo,
      wsf,
      calendar,
      ...
    }:
    let
      targetSystem = "aarch64-linux";

      # This package set is intended to run natively on the A14.
      #
      # The normal NixOS/GNOME userspace should therefore come from
      # aarch64-linux binary caches instead of being cross-compiled.
      pkgsNative = import nixpkgs {
        localSystem.system = targetSystem;

        config = {
          allowUnfree = true;
        };
      };

      a14System = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit inputs;
        };

        modules = [
          # Firefox with custom FFMPEG with l4v2 video decode
          ./firefox-a14
          
          # Power mode settings (schedutil + quiet default, performancemode command for performance governor
          # and normal fans)
          ./a14-power-mode
          {
            services.a14-power-mode.enable = true;
            services.a14-power-mode.users = [ "chris" ];
          }
          # Wayland Scroll Factor, allows changing touchpad speed
          wsf.nixosModules.default
          {
            nixpkgs.overlays = [ wsf.overlays.default ];
            programs.wsf.enable = true;
          }

          # Custom fex-patched hytale launcher for arm
          hytale-arm.nixosModules.default
          ./hytale.nix

          # Locally made Bubbles app (Openbubbles GTK)
          bubbles.nixosModules.default

          # Local email app
          ({ pkgs, ... }: {
            environment.systemPackages = [
              vireo.packages.${pkgs.system}.default
            ];
          })

          # Personal calendar app, replaces GNOME Calendar
          ({ pkgs, ... }: {
            environment.systemPackages = [
              calendar.packages.${pkgs.stdenv.hostPlatform.system}.default
            ];
          })
          # Decibels with stateful resume
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
          # Declarative Flatpaks
          nix-flatpak.nixosModules.nix-flatpak

          # Generated from the actual internal NVMe layout.
          ./hardware-configuration.nix

          # Common A14 platform/kernel/firmware configuration.
          a14.nixosModules.default
          ./personal.nix

          # Installed-system configuration: GNOME, systemd-boot,
          # users, SSH, PipeWire, etc.
          ./installed.nix

          {
            nixpkgs.pkgs = pkgsNative;
          }
        ];
      };
    in
    {
      # ------------------------------------------------------------
      # Build outputs from the x86_64 build VM
      # ------------------------------------------------------------

      packages.x86_64-linux.iso = a14.lib.mkIso {
        buildSystem = "x86_64-linux";
        firmwareSource = ./firmware;
      };
      packages.aarch64-linux.iso = a14.lib.mkIso {
        firmwareSource = ./firmware;
      };

      # ------------------------------------------------------------
      # Installed A14 system
      # ------------------------------------------------------------

      nixosConfigurations.a14 = a14System;
    };
}
