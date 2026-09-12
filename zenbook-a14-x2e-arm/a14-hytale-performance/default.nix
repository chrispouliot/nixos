# Personal integration only. Does not modify the hytale-arm input or its repo.
{ config, lib, pkgs, ... }:
let
  holder = pkgs.writeShellScript "a14-hytale-performance" ''
    exec ${pkgs.python3}/bin/python3 ${./hold-performance.py} ${../a14-power-mode/power_mode.py} "$@"
  '';
  # Matches the final HytaleClient exec, not the launcher's helper-process path.
  clientTail = '' "$1" "$2" "''${args[@]}" 2>"$log"'';
in
{
  assertions = [
    {
      assertion = config.programs.hytale.enable && config.services.a14-power-mode.enable;
      message = "a14-hytale-performance requires Hytale and the existing a14-power-mode module.";
    }
  ];

  nixpkgs.overlays = [
    (final: prev: {
      writeShellScript = name: text:
        prev.writeShellScript name (
          if name != "hytale-binfmt-hook" then text else
          let
            lines = lib.splitString "\n" text;
            isClientExec = line: lib.hasInfix "exec " line && lib.hasInfix clientTail line;
            matches = builtins.filter isClientExec lines;
          in
          if builtins.length matches != 1 then
            throw "a14-hytale-performance: Hytale's client hook changed; review this personal override before rebuilding."
          else
            lib.concatStringsSep "\n" (map
              (line: if isClientExec line then
                lib.replaceStrings [ "exec " ] [ "exec ${holder} " ] line
              else line)
              lines)
        );
    })
  ];
}
