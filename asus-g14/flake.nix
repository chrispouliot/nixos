{
  description = "My configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    cardwire = {
      url = "github:opengamingcollective/cardwire";
      #url = "path:/home/chris/Projects/cardwire";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    cardwire-toggle = {
      url = "github:chrispouliot/cardwire-toggle";
      #url = "path:/home/chris/Projects/cardwire-toggle";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-gaming-edge = {
      url = "github:powerofthe69/nix-gaming-edge";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nix-cachyos-kernel, cardwire, cardwire-toggle, nix-gaming-edge, ... }@inputs:
    {
      nixosConfigurations = {
        nixos = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            inherit inputs nix-cachyos-kernel;
          };
          modules = [
            # Cachyos Kernel
            ({ pkgs, ... }:
              {
                boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest-x86_64-v4;
                nixpkgs.overlays = [ nix-cachyos-kernel.overlays.pinned ];
                nix.settings.substituters = [ "https://attic.xuyh0120.win/lantian" ];
                nix.settings.trusted-public-keys = [ "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc=" ];
            })
            # Cachyos Proton
            ({ pkgs, ... }: {
              nix.settings = {
                substituters = [ "https://nix-cache.tokidoki.dev/tokidoki" ];
                trusted-public-keys = [ "tokidoki:MD4VWt3kK8Fmz3jkiGoNRJIW31/QAm7l1Dcgz2Xa4hk=" ];
              };

              nixpkgs.overlays = [
                nix-gaming-edge.overlays.proton-cachyos
              ];

              programs.steam = {
                enable = true;
                extraCompatPackages = [ pkgs.proton-cachyos-x86_64-v3 ];
              };
            })
            cardwire.nixosModules.default
            cardwire-toggle.nixosModules.default
            ./configuration.nix
          ];
        };
      };
    };
}
