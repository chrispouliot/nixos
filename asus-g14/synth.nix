# synth.nix
#
# Turns a project's flake devShell into a coding-agent sandbox image.
# Evaluated on demand by the agent-sandbox launcher, roughly:
#
#   nix build --impure --expr 'import ./synth.nix {
#     projectPath = "/abs/path"; system = "x86_64-linux";
#     agentCommand = "pi";
#     agentNpmPackage = "@earendil-works/pi-coding-agent";  # npm-installed at runtime
#     agentNixPackage = "";                                  # or: baked from nixpkgs
#     agentNixpkgs = "";                                     # or: alt nixpkgs for the agent
#     extraTools = [ ];
#   }'
#
# An agent is provided one of two ways:
#   - agentNpmPackage != ""  -> installed into ~/.npm-global on first run (Pi).
#   - agentNixPackage != ""  -> a nixpkgs attribute baked into the image, so it
#                               is already on PATH (OpenCode, Claude Code: their
#                               upstream distributions ship prebuilt binaries that
#                               need an FHS loader the nix image lacks, whereas the
#                               nixpkgs builds are patched to run here).
# Exactly one is expected to be set; if both are empty the command must already
# be on the devShell PATH.
#
# By default the nixpkgs-provided agent (agentNixPackage) is resolved against the
# PROJECT's nixpkgs, matching the devShell. Set agentNixpkgs to a nixpkgs source
# path (e.g. the host's `pkgs.path`) to resolve the agent against that instead, so
# its version is consistent across projects and independent of each project's pin.
# The agent's closure is self-contained, so mixing a differently-pinned agent into
# the project's shell is fine. allowUnfree is enabled for that alternate import, so
# unfree agents (claude-code) evaluate without the NIXPKGS_ALLOW_UNFREE dance.
#
# Assumptions about the project flake:
#   - it has  devShells.${system}.default
#   - its nixpkgs input is named  nixpkgs
{ projectPath
, system
, agentCommand
, agentNpmPackage ? ""
, agentNixPackage ? ""
, agentNixpkgs ? ""
, extraTools ? [ ]
}:
let
  proj = builtins.getFlake projectPath;
  pkgs = proj.inputs.nixpkgs.legacyPackages.${system};

  # Where the nixpkgs-provided agent (agentNixPackage) is resolved from. Defaults
  # to the project's nixpkgs; when agentNixpkgs is set, re-import that nixpkgs
  # source instead (with allowUnfree, so unfree agents evaluate cleanly here).
  # extraTools and the devShell always stay on the project's `pkgs`.
  agentPkgs =
    if agentNixpkgs != ""
    then import agentNixpkgs { inherit system; config.allowUnfree = true; }
    else pkgs;

  devShell = proj.devShells.${system}.default
    or (throw "agent-sandbox: ${projectPath} has no devShells.${system}.default");

  installViaNpm = agentNpmPackage != "";

  # The npm path installs the agent on first run (it isn't in nixpkgs), then
  # execs it. The nix path has nothing to install — the command is already on
  # PATH from the baked nixpkgs package — so it only needs the env scaffolding.
  installSnippet =
    if installViaNpm then ''
      export NPM_CONFIG_PREFIX="$HOME/.npm-global"
      export npm_config_cache="$HOME/.npm-global/.cache"
      export PATH="$HOME/.npm-global/bin:$PATH"
      # Extract tarballs without restoring archived ownership (we run as root
      # with CAP_CHOWN dropped, so same-owner chown would fail).
      export TAR_OPTIONS=--no-same-owner
      mkdir -p "$HOME/.npm-global"
      if [ -n "''${AGENT_SANDBOX_UPDATE:-}" ]; then
        echo "agent-sandbox: updating ${agentNpmPackage} ..." >&2
        npm install -g --force ${agentNpmPackage}@latest >&2
      elif ! command -v ${agentCommand} > /dev/null 2>&1; then
        echo "agent-sandbox: installing ${agentNpmPackage} ..." >&2
        npm install -g ${agentNpmPackage} >&2
      fi
    '' else ''
      if [ -n "''${AGENT_SANDBOX_UPDATE:-}" ]; then
        echo "agent-sandbox: ${agentCommand} comes from nixpkgs; --update is a no-op." >&2
        echo "  upgrade it by bumping the relevant nixpkgs input (nix flake update) and relaunching." >&2
      fi
    '';

  entrypoint = pkgs.writeShellScriptBin "agent-entrypoint" ''
    set -euo pipefail
    mkdir -p "$HOME/.cargo" "$HOME/.cache/uv"
    # Pi isolates sessions per project via this dir; create it when set.
    if [ -n "''${PI_CODING_AGENT_SESSION_DIR:-}" ]; then
      mkdir -p "$PI_CODING_AGENT_SESSION_DIR"
    fi
    ${installSnippet}
    exec ${agentCommand} "$@"
  '';
in
pkgs.dockerTools.buildNixShellImage {
  # The image IS the project's devShell, plus the agent runtime.
  drv = pkgs.mkShell {
    inputsFrom = [ devShell ];
    packages = [ pkgs.nodejs pkgs.git pkgs.cacert pkgs.coreutils pkgs.curl pkgs.ripgrep pkgs.fd entrypoint ]
      ++ (pkgs.lib.optional (agentNixPackage != "") agentPkgs.${agentNixPackage})
      ++ builtins.map (n: pkgs.${n}) extraTools;
  };
  tag = "latest";
  # Run as container-root; under rootless podman this maps to your host user,
  # so files written to /work come back owned by you and the home volume is writable.
  uid = 0;
  gid = 0;
  homeDirectory = "/root";
  # Set up the devShell env, then launch the agent. Container exits when it quits.
  run = "agent-entrypoint";
}
