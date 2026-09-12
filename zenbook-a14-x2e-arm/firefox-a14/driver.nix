{ lib, stdenv, fetchurl, meson, ninja, pkg-config, libva, libdrm, libglvnd, libgbm }:
stdenv.mkDerivation {
  pname = "libva-v4l2-a14-test";
  version = "1.0.0-0e4ce1e";
  src = fetchurl {
    name = "libva-v4l2-0e4ce1e.tar.gz";
    url = "https://codeload.github.com/radxa-pkg/libva-v4l2/tar.gz/0e4ce1e05da1d0a92b342efc2090b9e4987035e1";
    hash = "sha256-at+L6z4Tdb15Zz6ikfJ52vOGyznLGNUJMNm9G7mKtiI=";
  };
  nativeBuildInputs = [ meson ninja pkg-config ];
  buildInputs = [ libva libdrm libglvnd libgbm ];
  mesonFlags = [ "-Dfastcv=disabled" ];
  meta = {
    description = "Experimental Iris VA-API bridge, isolated A14 test";
    homepage = "https://github.com/radxa-pkg/libva-v4l2";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
