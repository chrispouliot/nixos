{ stdenv, fetchFromGitHub, glib, src }:

stdenv.mkDerivation {
  pname = "gnome-shell-extension-touchpad-speed-control";
  version = "local";
  inherit src;


  nativeBuildInputs = [ glib ];

  installPhase = ''
    runHook preInstall
    dest=$out/share/gnome-shell/extensions/touchpad-speed-control@ritesh
    mkdir -p $dest
    cp -r extension.js prefs.js metadata.json schemas icon.* $dest/
    glib-compile-schemas $dest/schemas
    runHook postInstall
  '';
}
