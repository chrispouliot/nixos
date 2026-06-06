{
  description = "My configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    cardwire = {
      url = "github:opengamingcollective/cardwire";
      #url = "path:/home/chris/Projects/cardwire";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    cardwire-toggle = {
      #url = "github:chrispouliot/cardwire-toggle";
      url = "path:/home/chris/Projects/cardwire-toggle";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";
    nix-gaming-edge = {
      url = "github:powerofthe69/nix-gaming-edge";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nix-cachyos-kernel, cardwire, cardwire-toggle, nix-flatpak, nix-gaming-edge, ... }@inputs:
    {
      nixosConfigurations = {
        nixos = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            inherit inputs;
          };
          modules = [
            # Temporary firefox fix for 26.05
              {
                nixpkgs.overlays = [
                (final: prev: {
                  firefoxpwa-unwrapped = prev.firefoxpwa-unwrapped.overrideAttrs (old: {
                    postInstall = (old.postInstall or "") + ''
                      mkdir -p $out/lib/firefoxpwa
                    '';
                  });
                })
              ];
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
                  "https://nix-cache.tokidoki.dev/tokidoki"
                ];
                extra-trusted-public-keys = [
                  "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
                  "tokidoki:MD4VWt3kK8Fmz3jkiGoNRJIW31/QAm7l1Dcgz2Xa4hk="
                ];
              };
              
              boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest-x86_64-v4;
              programs.steam = {
                enable = true;
                extraCompatPackages = [ pkgs.proton-cachyos-x86_64-v3 ];
              };
            })
            # Cardwire GPU switching and gnome toggle extension
            cardwire.nixosModules.default
            cardwire-toggle.nixosModules.default
            nix-flatpak.nixosModules.nix-flatpak
            ./configuration.nix
          ];
        };
      };
    };
}
