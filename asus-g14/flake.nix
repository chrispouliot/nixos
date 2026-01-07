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
         # (
         #   { pkgs, ... }:
         #   {
         #     boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest-x86_64-v4;
         #     nixpkgs.overlays = [ nix-cachyos-kernel.overlays.pinned];
         #     nix.settings.substituters = [ "https://attic.xuyh0120.win/lantian" ];
         #     nix.settings.trusted-public-keys = [ "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc=" ];
         #   }
         # )
          ./configuration.nix # Your system configuration.
        ];
      };
    };
  };
}
