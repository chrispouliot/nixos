{
  description = "My configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel";
  };

  outputs = { nixpkgs, nix-cachyos-kernel, ... }: {
    nixosConfigurations = {
      nixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit nix-cachyos-kernel; };
        modules = [
          ./configuration.nix # Your system configuration.
                      (
            { pkgs, ... }:
            {
              boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest;
              nixpkgs.overlays = [ nix-cachyos-kernel.overlay ];
            }
          )
        ];
      };
    };
  };
}
