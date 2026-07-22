{ stdenv, writeText }:

let
  uuid = "notif-icon-color@chris.local";

  metadata = writeText "metadata.json" ''
    {
      "uuid": "${uuid}",
      "name": "Notification Icon Color",
      "description": "Force full-color app icons in GNOME notifications (body + header source icon)",
      "shell-version": ["50"],
      "session-modes": ["user", "unlock-dialog"],
      "version": 1
    }
  '';

  extensionJs = writeText "extension.js" ''
    import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
    export default class NotifIconColor extends Extension {
        enable() {}
        disable() {}
    }
  '';

  stylesheet = writeText "stylesheet.css" ''
    .message .message-box .message-icon {
        -st-icon-style: regular !important;
    }

    .message .message-header .message-source-icon {
        -st-icon-style: regular !important;
    }
  '';

in
stdenv.mkDerivation {
  pname = "gnome-shell-extension-notif-icon-color";
  version = "1";

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    dest=$out/share/gnome-shell/extensions/${uuid}
    mkdir -p $dest
    cp ${metadata}    $dest/metadata.json
    cp ${extensionJs} $dest/extension.js
    cp ${stylesheet}  $dest/stylesheet.css
    runHook postInstall
  '';
}
