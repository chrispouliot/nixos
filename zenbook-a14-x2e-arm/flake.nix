{
  description = "NixOS bring-up for ASUS Zenbook A14 UX3407NA";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";
    
    box64-src = {
      url = "github:ptitSeb/box64";
      flake = false;
    };

    decibels-src = {
      url = "git+file:///home/chris/Projects/decibels?ref=wip/resume-state&submodules=1";
      flake = false;
    };

    hytale-launcher.url = "github:JPyke3/hytale-launcher-nix";

    nixpkgs-fex.url = "github:NixOS/nixpkgs/master";

    glymur-kernel = {
      url = "github:linux-msm/laptops-kernel/51231839d5ef007638bd1c3500e6a76b337a66f3";
      flake = false;
    };

    # Source used to build the board-specific AudioReach topology.
    # The exact revision is pinned in flake.lock.
    audioreach-topology = {
      url = "github:linux-msm/audioreach-topology";
      flake = false;
    };

    # QCC2072 Wi-Fi firmware update from 2026-08-12.
    #
    # Contains:
    # WLAN.COL.1.0.c2-00228-QCACOLSWPL_V1_TO_SILICON-1
    linux-firmware-qcc2072 = {
      url = "git+https://gitlab.com/kernel-firmware/linux-firmware.git?rev=25c06030aa434817928ace452c06f095f14729d3";
      flake = false;
    };

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
      nix-flatpak,
      decibels-src,
      glymur-kernel,
      bubbles,
      vireo,
      wsf,
      calendar,
      ...
    }:
    let
      # ------------------------------------------------------------
      # Architectures
      # ------------------------------------------------------------

      buildSystem = "x86_64-linux";
      targetSystem = "aarch64-linux";

      bootstrapPkgs = nixpkgs.legacyPackages.${buildSystem};


      # ------------------------------------------------------------
      # Patched nixpkgs used by the cross-built installer ISO
      # ------------------------------------------------------------

      # The installer ISO needs explicit device-tree support so GRUB can
      # load the ASUS UX3407NA DTB before starting the custom kernel.
      patchedNixpkgs =
        (bootstrapPkgs.applyPatches {
          name = "nixpkgs-a14";

          src = nixpkgs;

          patches = [
            (bootstrapPkgs.fetchpatch {
              # nixos/iso-image: add devicetree support
              url = "https://github.com/NixOS/nixpkgs/commit/de1fdb6310af8f70c98746ba4550dc2799a03621.patch";
              hash = "sha256-brqJxblmqWFAk8JgxmxXeHoiaWiQtsCsOzht/WlH5eE=";
            })
          ];
        }).overrideAttrs
          {
            allowSubstitutes = true;
          };


      # ------------------------------------------------------------
      # Cross-built ARM64 installer ISO
      # ------------------------------------------------------------

      # Build on x86_64, produce ARM64.
      pkgsCross = import patchedNixpkgs {
        localSystem.system = buildSystem;
        crossSystem.system = targetSystem;

        allowUnsupportedSystem = true;

        config = {
          allowUnfree = true;
        };
      };

      a14KernelPackagesCross = pkgsCross.callPackage ./kernel.nix {
        glymurSrc = glymur-kernel;
      };

      a14Iso = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit inputs;
        };

        modules = [
          "${patchedNixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"

          ./a14.nix

          {
            nixpkgs.pkgs = pkgsCross;
            boot.kernelPackages = a14KernelPackagesCross;
          }
        ];
      };


      # ------------------------------------------------------------
      # Native ARM64 installed system
      # ------------------------------------------------------------

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

      a14KernelPackagesNative = pkgsNative.callPackage ./kernel.nix {
        glymurSrc = glymur-kernel;
      };

      a14System = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit inputs;
        };

        modules = [
          # Wayland Scroll Factor, allows changing touchpad speed
          wsf.nixosModules.default
          {
            nixpkgs.overlays = [ wsf.overlays.default ];
            programs.wsf.enable = true;
          }

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
          ./a14.nix

          # Installed-system configuration: GNOME, systemd-boot,
          # users, SSH, PipeWire, etc.
          ./installed.nix

          {
            nixpkgs.pkgs = pkgsNative;
            boot.kernelPackages = a14KernelPackagesNative;
          }
        ];
      };
    in
    {
      # ------------------------------------------------------------
      # Build outputs from the x86_64 build VM
      # ------------------------------------------------------------

      packages.${buildSystem} = {
        default = a14Iso.config.system.build.isoImage;

        iso = a14Iso.config.system.build.isoImage;

        kernel = a14KernelPackagesCross.kernel;
      };


      # ------------------------------------------------------------
      # Installed A14 system
      # ------------------------------------------------------------

      nixosConfigurations.a14 = a14System;
    };
}
