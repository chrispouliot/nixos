{
  description = "My configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    cardwire = {
      url = "github:opengamingcollective/cardwire/v0.10.0";
      #url = "path:/home/chris/Projects/cardwire";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    cardwire-toggle = {
      url = "github:chrispouliot/cardwire-toggle";
      #url = "path:/home/chris/Projects/cardwire-toggle";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";
    nix-gaming-edge = {
      url = "github:powerofthe69/nix-gaming-edge";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    wsf = {
      url = "path:/home/chris/Projects/wayland-scroll-factor";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    touchpad-speed-control = {
      url = "git+file:///home/chris/Projects/touchpad-speed-control";
      flake = false;
    };
  };

  outputs = { nixpkgs, nix-cachyos-kernel, cardwire, cardwire-toggle, nix-flatpak, nix-gaming-edge, wsf, ... }@inputs:
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
