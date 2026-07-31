{ stdenv, glib, src }:

stdenv.mkDerivation {
  pname = "gnome-shell-extension-medialine";
  version = "1.4.0";
  inherit src;

  nativeBuildInputs = [ glib ];

  installPhase = ''
    runHook preInstall
    dest=$out/share/gnome-shell/extensions/medialine@funinkina.co.in
    mkdir -p $dest
    cp -r extension.js prefs.js metadata.json schemas helpers icons $dest/
    glib-compile-schemas $dest/schemas
    runHook postInstall
  '';
}
