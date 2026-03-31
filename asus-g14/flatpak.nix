{ config, pkgs, ... }:
let
  # We point directly to 'gnugrep' instead of 'grep'
  grep = pkgs.gnugrep;
  # Declare the Flatpaks
  desiredFlatpaks = [
    # "org.onlyoffice.desktopeditors"
    "com.github.tchx84.Flatseal"
    "dev.qwery.AddWater"
    "us.zoom.Zoom"
    "dev.vencord.Vesktop"
    "com.jeffser.Nocturne"
    "de.schmidhuberj.tubefeeder"
  ];
in {
  system.userActivationScripts.flatpakManagement = {
    text = ''
      # Ensure the Flathub repo is added
      ${pkgs.flatpak}/bin/flatpak remote-add --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo

      # Get currently installed Flatpaks
      installedFlatpaks=$(${pkgs.flatpak}/bin/flatpak list --app --columns=application)

      # Install or re-install the Flatpaks you DO want
      for app in ${toString desiredFlatpaks}; do
        echo "Ensuring $app is installed."
        ${pkgs.flatpak}/bin/flatpak install -y flathub $app
      done

      # Remove unused Flatpaks
      ${pkgs.flatpak}/bin/flatpak uninstall --unused -y

      # Update all installed Flatpaks
      ${pkgs.flatpak}/bin/flatpak update -y
    '';
  };
}
