{
  lib,
  stdenv,
  src,
  # build tools
  meson,
  ninja,
  pkg-config,
  gettext,
  blueprint-compiler,
  desktop-file-utils,
  wrapGAppsHook4,
  glib, # glib-compile-resources / glib-compile-schemas
  # libraries
  gtk4,
  libadwaita,
  evolution-data-server-gtk4, # camel, libedataserver(ui4), libebook, libedata-book
  gsettings-desktop-schemas,
  gst_all_1,
  libsoup_3,
  libportal-gtk4,
  libpsl,
  nss,
  webkitgtk_6_0,
  libical, # pulled in transitively by EDS headers
}:

stdenv.mkDerivation rec {
  pname = "stamp";
  version = "0.4.0-unstable-2026-07-03";

  inherit src;

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    gettext
    blueprint-compiler
    desktop-file-utils
    glib
    wrapGAppsHook4
  ];

  buildInputs = [
    gtk4
    glib
    libadwaita
    evolution-data-server-gtk4
    gsettings-desktop-schemas
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good # runtime: notification sound playback
    libsoup_3
    libportal-gtk4
    libpsl
    nss
    webkitgtk_6_0
    libical
  ];

  meta = with lib; {
    description = "Email client for GNOME";
    homepage = "https://gitlab.gnome.org/jbrummer/stamp";
    license = licenses.gpl3Plus;
    mainProgram = "stamp";
    platforms = platforms.linux;
  };
}
