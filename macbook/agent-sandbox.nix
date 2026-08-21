{ config, lib, pkgs, ... }:

let
  cfg = config.programs.agentSandbox;

  hostHome =
    "/Users/${cfg.darwin.hostUser}";

  agentHome =
    "/Users/${cfg.darwin.user}";

  stateDir =
    "${hostHome}/.local/share/agent-sandbox";

  #
  # One canonical OpenCode configuration.
  #
  canonicalOpenCodeConfig =
    "${hostHome}/.config/opencode";

  #
  # Linux gets its own mutable OpenCode runtime data.
  #
  linuxOpenCodeData =
    "${stateDir}/linux/opencode/data/opencode";

  extraToolsNix =
    "[ "
    + lib.concatMapStringsSep " "
        (name: "\"${name}\"")
        cfg.extraTools
    + " ]";

  dnsFlags =
    lib.concatMapStringsSep " "
      (server: "--dns=${lib.escapeShellArg server}")
      cfg.dns;

  #
  # Privileged helper for native macOS projects.
  #
  darwinRootHelper =
    pkgs.writeShellScriptBin
      "agent-sandbox-darwin-root"
      ''
        set -euo pipefail

        if [ "$(/usr/bin/id -u)" -ne 0 ]; then
          echo "agent-sandbox: Darwin helper must run as root" >&2
          exit 1
        fi

        if [ "$#" -ne 1 ]; then
          echo "Usage: agent-sandbox-darwin-root PROJECT" >&2
          exit 2
        fi

        HOST_USER="${cfg.darwin.hostUser}"
        AGENT_USER="${cfg.darwin.user}"
        AGENT_GROUP="${cfg.darwin.group}"

        HOST_HOME="${hostHome}"
        AGENT_HOME="${agentHome}"

        PROJECT_ROOT="${cfg.darwin.projectRoot}"

        OPENCODE_CONFIG="${canonicalOpenCodeConfig}"

        DERIVED_DATA_ROOT="${cfg.darwin.derivedDataRoot}"

        NIX_BIN="${config.nix.package}/bin/nix"
        OPENCODE_BIN="${pkgs.opencode}/bin/opencode"
        GIT_BIN="${pkgs.git}/bin/git"

        PROJECT="$(${pkgs.coreutils}/bin/realpath "$1")"
        PROJECT_ROOT="$(${pkgs.coreutils}/bin/realpath "$PROJECT_ROOT")"

        #
        # Safety boundary.
        #
        # The privileged helper may operate only on projects beneath
        # the configured project root.
        #
        case "$PROJECT" in
          "$PROJECT_ROOT"|"$PROJECT_ROOT"/*)
            ;;
          *)
            echo "agent-sandbox: refusing Darwin project outside:" >&2
            echo "  $PROJECT_ROOT" >&2
            echo >&2
            echo "Requested:" >&2
            echo "  $PROJECT" >&2
            exit 1
            ;;
        esac

        if [ ! -f "$PROJECT/flake.nix" ]; then
          echo "agent-sandbox: no flake.nix found in:" >&2
          echo "  $PROJECT" >&2
          exit 1
        fi

        if ! /usr/bin/id "$AGENT_USER" >/dev/null 2>&1; then
          echo "agent-sandbox: macOS agent user does not exist:" >&2
          echo "  $AGENT_USER" >&2
          exit 1
        fi

        if [ ! -d "$OPENCODE_CONFIG" ]; then
          echo "agent-sandbox: OpenCode config does not exist:" >&2
          echo "  $OPENCODE_CONFIG" >&2
          exit 1
        fi

        #
        # Build a stable private DerivedData path for this repository.
        #
        PROJECT_NAME="$(
          ${pkgs.coreutils}/bin/basename "$PROJECT" \
            | ${pkgs.coreutils}/bin/tr -c 'a-zA-Z0-9_.-' '-' \
            | ${pkgs.gnused}/bin/sed 's/^[.-]*//' \
            | ${pkgs.coreutils}/bin/cut -c1-40
        )"

        if [ -z "$PROJECT_NAME" ]; then
          PROJECT_NAME="project"
        fi

        PROJECT_HASH="$(
          printf '%s' "$PROJECT" \
            | ${pkgs.coreutils}/bin/sha256sum \
            | ${pkgs.coreutils}/bin/cut -c1-10
        )"

        AGENT_DERIVED_DATA="$DERIVED_DATA_ROOT/$PROJECT_NAME-$PROJECT_HASH"

        /bin/mkdir -p \
          "$AGENT_DERIVED_DATA"

        /usr/sbin/chown -R \
          "$AGENT_USER:$AGENT_GROUP" \
          "$DERIVED_DATA_ROOT"

        #
        # macOS ACL helpers.
        #
        # Always use Apple's /bin/chmod rather than a GNU chmod from Nix.
        #
        add_search_acl() {
          path="$1"

          [ -d "$path" ] || return 0

          if ! /bin/ls -lde "$path" \
            | /usr/bin/grep -F "user:$AGENT_USER allow" \
            | /usr/bin/grep -F "search" \
            >/dev/null 2>&1
          then
            /bin/chmod +a \
              "user:$AGENT_USER allow search" \
              "$path"
          fi
        }

        #
        # Shared OpenCode configuration is read-only.
        #
        grant_read_tree() {
          path="$1"

          READ_ACE="user:$AGENT_USER allow list,search,read,execute,readattr,readextattr,readsecurity"

          READ_INHERIT_ACE="user:$AGENT_USER allow list,search,read,execute,readattr,readextattr,readsecurity,file_inherit,directory_inherit"

          if ! /bin/ls -lde "$path" \
            | /usr/bin/grep -F "user:$AGENT_USER allow" \
            | /usr/bin/grep -F "file_inherit" \
            >/dev/null 2>&1
          then
            /bin/chmod -R +a \
              "$READ_ACE" \
              "$path"

            /bin/chmod +a \
              "$READ_INHERIT_ACE" \
              "$path"
          fi
        }

        #
        # Source repository is shared writable.
        #
        # Both users receive inheritable ACLs so files created by one
        # remain writable by the other.
        #
        grant_project_access() {
          path="$1"

          AGENT_ACCESS_ACE="user:$AGENT_USER allow list,search,add_file,add_subdirectory,delete_child,read,write,append,execute,delete,readattr,writeattr,readextattr,writeextattr,readsecurity"

          AGENT_INHERIT_ACE="user:$AGENT_USER allow list,search,add_file,add_subdirectory,delete_child,read,write,append,execute,delete,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit"

          HOST_ACCESS_ACE="user:$HOST_USER allow list,search,add_file,add_subdirectory,delete_child,read,write,append,execute,delete,readattr,writeattr,readextattr,writeextattr,readsecurity"

          HOST_INHERIT_ACE="user:$HOST_USER allow list,search,add_file,add_subdirectory,delete_child,read,write,append,execute,delete,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit"

          if ! /bin/ls -lde "$path" \
            | /usr/bin/grep -F "user:$AGENT_USER allow" \
            | /usr/bin/grep -F "file_inherit" \
            >/dev/null 2>&1
          then
            echo "agent-sandbox: granting agent access to project..." >&2

            /bin/chmod -R +a \
              "$AGENT_ACCESS_ACE" \
              "$path"

            /bin/chmod +a \
              "$AGENT_INHERIT_ACE" \
              "$path"
          fi

          if ! /bin/ls -lde "$path" \
            | /usr/bin/grep -F "user:$HOST_USER allow" \
            | /usr/bin/grep -F "file_inherit" \
            >/dev/null 2>&1
          then
            echo "agent-sandbox: adding host compatibility ACL..." >&2

            /bin/chmod -R +a \
              "$HOST_ACCESS_ACE" \
              "$path"

            /bin/chmod +a \
              "$HOST_INHERIT_ACE" \
              "$path"
          fi
        }

        #
        # Git metadata is intentionally shared through a Unix group.
        #
        prepare_shared_git_repo() {
          gitdir="$PROJECT/.git"

          if [ ! -d "$gitdir" ]; then
            return 0
          fi

          echo "agent-sandbox: preparing shared Git metadata..." >&2

          /usr/sbin/chown -R \
            "$HOST_USER:$AGENT_GROUP" \
            "$gitdir"

          /bin/chmod -R \
            g+rwX \
            "$gitdir"

          /usr/bin/find \
            "$gitdir" \
            -type d \
            -exec /bin/chmod g+s {} \;

          #
          # Run git config as the actual repository owner rather than root.
          #
          /usr/bin/sudo \
            -u "$HOST_USER" \
            -H \
            "$GIT_BIN" \
            -C "$PROJECT" \
            config core.sharedRepository group
        }

        #
        # Agent may traverse the relevant parent directories without
        # receiving permission to list unrelated contents.
        #
        add_search_acl "$HOST_HOME"
        add_search_acl "$HOST_HOME/.config"
        add_search_acl "$PROJECT_ROOT"

        #
        # Shared canonical OpenCode configuration.
        #
        grant_read_tree "$OPENCODE_CONFIG"

        #
        # Shared source repository.
        #
        grant_project_access "$PROJECT"

        #
        # Shared Git object database.
        #
        prepare_shared_git_repo

        #
        # Private agent OpenCode data.
        #
        /bin/mkdir -p \
          "$AGENT_HOME/.config" \
          "$AGENT_HOME/.local/share" \
          "$AGENT_HOME/.local/share/opencode"

        /usr/sbin/chown \
          "$AGENT_USER:$AGENT_GROUP" \
          "$AGENT_HOME/.config" \
          "$AGENT_HOME/.local" \
          "$AGENT_HOME/.local/share"

        /usr/sbin/chown -R \
          "$AGENT_USER:$AGENT_GROUP" \
          "$AGENT_HOME/.local/share/opencode"

        #
        # Agent's OpenCode config points to the canonical host config.
        #
        AGENT_CONFIG="$AGENT_HOME/.config/opencode"

        if [ -L "$AGENT_CONFIG" ]; then
          /bin/rm "$AGENT_CONFIG"
        elif [ -e "$AGENT_CONFIG" ]; then
          echo "agent-sandbox: refusing to replace existing agent config:" >&2
          echo "  $AGENT_CONFIG" >&2
          echo >&2
          echo "Move/remove that directory and retry." >&2
          exit 1
        fi

        /bin/ln -s \
          "$OPENCODE_CONFIG" \
          "$AGENT_CONFIG"

        /usr/sbin/chown -h \
          "$AGENT_USER:$AGENT_GROUP" \
          "$AGENT_CONFIG"

        #
        # Environment presented to the dedicated agent account.
        #
        ENV_ARGS=(
          "HOME=$AGENT_HOME"
          "USER=$AGENT_USER"
          "LOGNAME=$AGENT_USER"
          "TERM=xterm-256color"

          "NIX_CONFIG=experimental-features = nix-command flakes"

          #
          # Project build scripts use this instead of a shared .derivedData.
          #
          "AGENT_DERIVED_DATA_PATH=$AGENT_DERIVED_DATA"

          #
          # Git normally rejects repositories owned by another UID.
          #
          "GIT_CONFIG_COUNT=1"
          "GIT_CONFIG_KEY_0=safe.directory"
          "GIT_CONFIG_VALUE_0=$PROJECT"
        )

        ${lib.optionalString (cfg.darwin.developerDir != null) ''
          ENV_ARGS+=(
            "DEVELOPER_DIR=${cfg.darwin.developerDir}"
          )
        ''}

        echo "agent-sandbox: starting OpenCode as '$AGENT_USER'..." >&2
        echo "agent-sandbox: project:     $PROJECT" >&2
        echo "agent-sandbox: config:      $OPENCODE_CONFIG (read-only)" >&2
        echo "agent-sandbox: data:        $AGENT_HOME/.local/share/opencode" >&2
        echo "agent-sandbox: DerivedData: $AGENT_DERIVED_DATA" >&2

        cd "$PROJECT"

        #
        # path:$PROJECT avoids Nix's git+file/libgit2 ownership check.
        #
        exec /usr/bin/sudo \
          -u "$AGENT_USER" \
          -H \
          /usr/bin/env \
          "''${ENV_ARGS[@]}" \
          /bin/zsh \
          -c '
            umask 0002

            NIX_BIN="$1"
            PROJECT="$2"
            OPENCODE_BIN="$3"

            exec "$NIX_BIN" \
              develop "path:$PROJECT" \
              --command "$OPENCODE_BIN"
          ' \
          -- \
          "$NIX_BIN" \
          "$PROJECT" \
          "$OPENCODE_BIN"
      '';

  launcherTools = [
    pkgs.coreutils
    pkgs.podman
    pkgs.gawk
    pkgs.gnused
    pkgs.jq
    config.nix.package
  ];

  launcher =
    pkgs.writeShellScriptBin
      "agent-sandbox"
      ''
        set -euo pipefail

        export PATH=${lib.makeBinPath launcherTools}:$PATH

        LINUX_SYSTEM="${cfg.targetSystem}"
        DARWIN_SYSTEM="${cfg.darwin.targetSystem}"

        PODMAN_MACHINE="${cfg.machine.name}"
        PODMAN_CPUS="${toString cfg.machine.cpus}"
        PODMAN_MEMORY="${toString cfg.machine.memory}"
        PODMAN_DISK_SIZE="${toString cfg.machine.diskSize}"

        BUILDER_IMAGE="${cfg.builderImage}"
        AGENT_MEMORY="${cfg.memory}"

        NIX_BIN="${config.nix.package}/bin/nix"

        STATE_DIR="${stateDir}"

        OPENCODE_CONFIG="${canonicalOpenCodeConfig}"
        OPENCODE_DATA="${linuxOpenCodeData}"

        SYNTH_SRC="${./synth.nix}"
        SYNTH="$STATE_DIR/synth.nix"

        BUILD_DIR="$STATE_DIR/builds"
        BUILD_EXPR="$STATE_DIR/build-opencode.nix"

        EXTRA_TOOLS='${extraToolsNix}'

        mkdir -p \
          "$STATE_DIR" \
          "$BUILD_DIR" \
          "$STATE_DIR/projects" \
          "$OPENCODE_CONFIG" \
          "$OPENCODE_DATA"

        cp -f "$SYNTH_SRC" "$SYNTH"

        usage() {
          cat <<'EOF'
Usage:
  agent-sandbox
  agent-sandbox --linux
  agent-sandbox --darwin
  agent-sandbox --print-backend

Backend selection:
  1. --linux / --darwin
  2. flake output agentSandbox.backend
  3. aarch64-linux if available
  4. otherwise aarch64-darwin
EOF
        }

        FORCE_BACKEND=""
        PRINT_BACKEND=0

        while [ "$#" -gt 0 ]; do
          case "$1" in
            --linux)
              FORCE_BACKEND="linux"
              ;;

            --darwin)
              FORCE_BACKEND="darwin"
              ;;

            --print-backend)
              PRINT_BACKEND=1
              ;;

            -h|--help)
              usage
              exit 0
              ;;

            *)
              echo "agent-sandbox: unknown argument: $1" >&2
              usage >&2
              exit 2
              ;;
          esac

          shift
        done

        PROJECT="$(realpath "$PWD")"

        if [ ! -f "$PROJECT/flake.nix" ]; then
          echo "agent-sandbox: no flake.nix found in:" >&2
          echo "  $PROJECT" >&2
          exit 1
        fi

        detect_backend() {
          if [ -n "$FORCE_BACKEND" ]; then
            printf '%s\n' "$FORCE_BACKEND"
            return
          fi

          HINT="$(
            "$NIX_BIN" eval \
              --raw \
              "$PROJECT#agentSandbox.backend" \
              2>/dev/null \
              || true
          )"

          case "$HINT" in
            linux|darwin)
              printf '%s\n' "$HINT"
              return
              ;;

            "")
              ;;

            *)
              echo \
                "agent-sandbox: invalid agentSandbox.backend '$HINT'" \
                >&2
              exit 1
              ;;
          esac

          HAS_LINUX="$(
            "$NIX_BIN" eval \
              --json \
              "$PROJECT#devShells.$LINUX_SYSTEM" \
              --apply 'x: builtins.hasAttr "default" x' \
              2>/dev/null \
              || printf 'false'
          )"

          HAS_DARWIN="$(
            "$NIX_BIN" eval \
              --json \
              "$PROJECT#devShells.$DARWIN_SYSTEM" \
              --apply 'x: builtins.hasAttr "default" x' \
              2>/dev/null \
              || printf 'false'
          )"

          if [ "$HAS_LINUX" = "true" ]; then
            printf '%s\n' "linux"
          elif [ "$HAS_DARWIN" = "true" ]; then
            printf '%s\n' "darwin"
          else
            echo "agent-sandbox: project exposes neither:" >&2
            echo "  devShells.$LINUX_SYSTEM.default" >&2
            echo "  devShells.$DARWIN_SYSTEM.default" >&2
            exit 1
          fi
        }

        BACKEND="$(detect_backend)"

        if [ "$PRINT_BACKEND" = "1" ]; then
          printf '%s\n' "$BACKEND"
          exit 0
        fi

        echo "agent-sandbox: selected backend: $BACKEND" >&2

        #
        # Native macOS backend.
        #
        if [ "$BACKEND" = "darwin" ]; then
          if [ "${if cfg.darwin.enable then "1" else "0"}" != "1" ]; then
            echo "agent-sandbox: Darwin backend is disabled" >&2
            exit 1
          fi

          exec /usr/bin/sudo \
            ${darwinRootHelper}/bin/agent-sandbox-darwin-root \
            "$PROJECT"
        fi

        #
        # Linux / Podman backend.
        #
        machine_exists() {
          podman machine inspect "$PODMAN_MACHINE" >/dev/null 2>&1
        }

        machine_running() {
          podman info >/dev/null 2>&1
        }

        cleanup() {
          rc=$?

          trap - EXIT INT TERM HUP

          if [ "${if cfg.stopMachineOnExit then "1" else "0"}" = "1" ]; then
            if machine_exists; then
              RUNNING="$(
                podman ps -q 2>/dev/null || true
              )"

              if [ -z "$RUNNING" ]; then
                echo "agent-sandbox: stopping Podman Machine..." >&2

                podman machine stop "$PODMAN_MACHINE" \
                  >/dev/null 2>&1 \
                  || true
              else
                echo \
                  "agent-sandbox: other Podman containers are running; leaving machine active" \
                  >&2
              fi
            fi
          fi

          exit "$rc"
        }

        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP

        if ! machine_exists; then
          echo "agent-sandbox: creating Podman Machine..." >&2
          echo "  CPUs:   $PODMAN_CPUS" >&2
          echo "  Memory: $PODMAN_MEMORY MiB" >&2
          echo "  Disk:   $PODMAN_DISK_SIZE GiB" >&2

          podman machine init \
            --cpus "$PODMAN_CPUS" \
            --memory "$PODMAN_MEMORY" \
            --disk-size "$PODMAN_DISK_SIZE" \
            "$PODMAN_MACHINE"
        fi

        if ! machine_running; then
          echo "agent-sandbox: starting Podman Machine..." >&2

          podman machine start "$PODMAN_MACHINE"

          if ! machine_running; then
            echo "agent-sandbox: Podman Machine started but is unreachable" >&2
            exit 1
          fi
        fi

        #
        # Podman Machine shares the host user's home.
        #
        case "$PROJECT" in
          "$HOME"|"$HOME"/*)
            ;;

          *)
            echo "agent-sandbox: Linux project must be below:" >&2
            echo "  $HOME" >&2
            exit 1
            ;;
        esac

        BASE="$(
          basename "$PROJECT" \
            | tr -c 'a-zA-Z0-9_.-' '-' \
            | sed 's/^[.-]*//' \
            | cut -c1-40
        )"

        [ -n "$BASE" ] || BASE="project"

        HASH="$(
          printf '%s' "$PROJECT" \
            | sha256sum \
            | cut -c1-10
        )"

        KEY="$BASE-$HASH"
        IMGKEY="$KEY-opencode"

        REF="agent-sandbox:$IMGKEY"

        FP_FILE="$STATE_DIR/fp-$IMGKEY"

        printf '%s' \
          "$PROJECT" \
          > "$STATE_DIR/projects/$KEY"

        FP="$(
          (
            cat \
              "$PROJECT/flake.nix" \
              "$PROJECT/flake.lock" \
              "$SYNTH" \
              2>/dev/null \
              || true
          ) \
            | sha256sum \
            | cut -c1-32
        )|$LINUX_SYSTEM|$EXTRA_TOOLS"

        if \
          [ -f "$FP_FILE" ] \
          && [ "$(cat "$FP_FILE")" = "$FP" ] \
          && podman image exists "$REF"
        then
          echo "agent-sandbox: image is current" >&2
        else
          echo \
            "agent-sandbox: building devShells.$LINUX_SYSTEM.default..." \
            >&2

          cat > "$BUILD_EXPR" <<EOF
import /state/synth.nix {
  projectPath = builtins.getEnv "AGENT_PROJECT";
  system = builtins.getEnv "AGENT_SYSTEM";

  agentCommand = "opencode";
  agentNpmPackage = "";
  agentNixPackage = "opencode";
  agentNixpkgs = "";

  extraTools = $EXTRA_TOOLS;
}
EOF

          IMAGE_ARCHIVE="$BUILD_DIR/$IMGKEY.tar.gz"

          NIX_VOLUME="$(
            printf '%s' "agentsb-nix-$LINUX_SYSTEM" \
              | tr -c 'a-zA-Z0-9_.-' '-'
          )"

          NIX_CONFIG_VALUE="experimental-features = nix-command flakes
sandbox = false"

          ${lib.optionalString (cfg.substituters != null) ''
            NIX_CONFIG_VALUE="$NIX_CONFIG_VALUE
substituters = ${lib.concatStringsSep " " cfg.substituters}"
          ''}

          podman run --rm \
            -e "AGENT_PROJECT=$PROJECT" \
            -e "AGENT_SYSTEM=$LINUX_SYSTEM" \
            -e "NIX_CONFIG=$NIX_CONFIG_VALUE" \
            -e NIXPKGS_ALLOW_UNFREE=1 \
            -v "$PROJECT:$PROJECT:ro" \
            -v "$STATE_DIR:/state:rw" \
            -v "$NIX_VOLUME:/nix:copy" \
            "$BUILDER_IMAGE" \
            sh -lc '
              set -eu

              OUT="$(
                nix build \
                  --impure \
                  --fallback \
                  --no-link \
                  --print-out-paths \
                  --expr "import /state/build-opencode.nix"
              )"

              cp -L \
                "$OUT" \
                "/state/builds/'"$IMGKEY"'.tar.gz"
            '

          if [ ! -f "$IMAGE_ARCHIVE" ]; then
            echo \
              "agent-sandbox: Nix build finished without an OCI archive" \
              >&2
            exit 1
          fi

          LOAD_OUTPUT="$(
            podman load -i "$IMAGE_ARCHIVE"
          )"

          echo "$LOAD_OUTPUT" >&2

          LOADED="$(
            printf '%s\n' "$LOAD_OUTPUT" \
              | sed -n 's/^Loaded image: //p' \
              | tail -n1
          )"

          if [ -z "$LOADED" ]; then
            LOADED="$(
              printf '%s\n' "$LOAD_OUTPUT" \
                | awk -F': ' '/Loaded image/{print $NF}' \
                | tail -n1
            )"
          fi

          if [ -z "$LOADED" ]; then
            echo \
              "agent-sandbox: unable to determine loaded image" \
              >&2
            exit 1
          fi

          podman tag \
            "$LOADED" \
            "$REF"

          printf '%s' \
            "$FP" \
            > "$FP_FILE"

          rm -f "$IMAGE_ARCHIVE"
        fi

        #
        # Keep high-I/O Linux build/dependency directories inside the VM.
        #
        SHADOW_MOUNTS=()

        if [ -f "$PROJECT/Cargo.toml" ]; then
          SHADOW_MOUNTS+=(
            -v "agentsb-target-$IMGKEY:$PROJECT/target"
          )
        fi

        if \
          [ -f "$PROJECT/pyproject.toml" ] \
          || [ -f "$PROJECT/setup.py" ] \
          || [ -f "$PROJECT/requirements.txt" ] \
          || [ -f "$PROJECT/uv.lock" ]
        then
          SHADOW_MOUNTS+=(
            -v "agentsb-venv-$IMGKEY:$PROJECT/.venv"
          )
        fi

        if [ -f "$PROJECT/package.json" ]; then
          SHADOW_MOUNTS+=(
            -v "agentsb-node-$IMGKEY:$PROJECT/node_modules"
          )
        fi

        echo "agent-sandbox: starting OpenCode in Linux..." >&2
        echo "agent-sandbox: config: $OPENCODE_CONFIG (read-only)" >&2
        echo "agent-sandbox: data:   $OPENCODE_DATA" >&2

        podman run --rm -it \
          --name "agentsb-$IMGKEY" \
          --replace \
          --cap-drop=ALL \
          --security-opt=no-new-privileges \
          ${dnsFlags} \
          --pids-limit=1024 \
          --memory="''${AGENT_SANDBOX_MEM:-$AGENT_MEMORY}" \
          -v "$PROJECT:$PROJECT:rw" \
          -w "$PROJECT" \
          --tmpfs /tmp:rw,size=2g,mode=1777 \
          -v "$OPENCODE_CONFIG:/root/.config/opencode:ro" \
          -v "$OPENCODE_DATA:/root/.local/share/opencode:rw" \
          "''${SHADOW_MOUNTS[@]}" \
          "$REF"
      '';

in
{
  options.programs.agentSandbox.enable =
    lib.mkEnableOption
      "isolated OpenCode development environment";

  #
  # Linux / Podman backend
  #

  options.programs.agentSandbox.targetSystem =
    lib.mkOption {
      type = lib.types.str;
      default = "aarch64-linux";
    };

  options.programs.agentSandbox.memory =
    lib.mkOption {
      type = lib.types.str;
      default = "10g";
    };

  options.programs.agentSandbox.machine.name =
    lib.mkOption {
      type = lib.types.str;
      default = "podman-machine-default";
    };

  options.programs.agentSandbox.machine.cpus =
    lib.mkOption {
      type = lib.types.ints.positive;
      default = 6;
    };

  options.programs.agentSandbox.machine.memory =
    lib.mkOption {
      type = lib.types.ints.positive;
      default = 12288;
    };

  options.programs.agentSandbox.machine.diskSize =
    lib.mkOption {
      type = lib.types.ints.positive;
      default = 100;
    };

  options.programs.agentSandbox.stopMachineOnExit =
    lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

  options.programs.agentSandbox.extraTools =
    lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };

  options.programs.agentSandbox.dns =
    lib.mkOption {
      type = lib.types.listOf lib.types.str;

      default = [
        "1.1.1.1"
      ];
    };

  options.programs.agentSandbox.builderImage =
    lib.mkOption {
      type = lib.types.str;
      default = "docker.io/nixos/nix:latest";
    };

  options.programs.agentSandbox.substituters =
    lib.mkOption {
      type =
        lib.types.nullOr
          (lib.types.listOf lib.types.str);

      default = [
        "https://cache.nixos.org"
      ];
    };

  #
  # Native macOS backend
  #

  options.programs.agentSandbox.darwin.enable =
    lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

  options.programs.agentSandbox.darwin.targetSystem =
    lib.mkOption {
      type = lib.types.str;
      default = "aarch64-darwin";
    };

  options.programs.agentSandbox.darwin.hostUser =
    lib.mkOption {
      type = lib.types.str;
      default = "chris";
    };

  options.programs.agentSandbox.darwin.user =
    lib.mkOption {
      type = lib.types.str;
      default = "agent";
    };

  options.programs.agentSandbox.darwin.uid =
    lib.mkOption {
      type = lib.types.ints.positive;
      default = 599;
    };

  options.programs.agentSandbox.darwin.group =
    lib.mkOption {
      type = lib.types.str;
      default = "agent-sandbox";
    };

  options.programs.agentSandbox.darwin.gid =
    lib.mkOption {
      type = lib.types.ints.positive;
      default = 599;
    };

  options.programs.agentSandbox.darwin.projectRoot =
    lib.mkOption {
      type = lib.types.str;
      default = "/Users/chris/Projects";
    };

  options.programs.agentSandbox.darwin.developerDir =
    lib.mkOption {
      type =
        lib.types.nullOr
          lib.types.str;

      default = null;

      description = ''
        Optional Xcode Developer directory.

        null means use the system-wide xcode-select setting.

        Example:

          /Applications/Xcode-beta.app/Contents/Developer
      '';
    };

  options.programs.agentSandbox.darwin.derivedDataRoot =
    lib.mkOption {
      type = lib.types.str;

      default =
        "${agentHome}/Library/Caches/agent-sandbox/DerivedData";

      description = ''
        Root directory for native macOS agent Xcode DerivedData.

        Each project receives a private subdirectory derived from its
        project name and absolute path.
      '';
    };

  #
  # Kept temporarily for compatibility with older macos.nix configs.
  # It is no longer used because DerivedData is private per user.
  #
  options.programs.agentSandbox.darwin.sharedBuildDirs =
    lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];

      description = ''
        Deprecated compatibility option.

        Native macOS build artifacts are no longer shared between the
        host and agent users.
      '';
    };

  config =
    lib.mkIf cfg.enable {
      #
      # Both users belong to the Git-sharing group.
      #
      users.knownGroups =
        lib.mkAfter [
          cfg.darwin.group
        ];

      users.groups.${cfg.darwin.group} = {
        gid = cfg.darwin.gid;

        members = [
          cfg.darwin.hostUser
          cfg.darwin.user
        ];
      };

      #
      # Hidden, non-admin native macOS agent account.
      #
      users.knownUsers =
        lib.mkAfter [
          cfg.darwin.user
        ];

      users.users.${cfg.darwin.user} = {
        uid = cfg.darwin.uid;
        gid = cfg.darwin.gid;

        description =
          "OpenCode Agent";

        home =
          agentHome;

        createHome = true;
        isHidden = true;

        shell = "/bin/zsh";
      };

      #
      # The normal user may invoke only this immutable privileged helper
      # without a password.
      #
      security.sudo.extraConfig =
        lib.mkAfter ''
          ${cfg.darwin.hostUser} ALL=(root) NOPASSWD: ${darwinRootHelper}/bin/agent-sandbox-darwin-root
        '';

      environment.systemPackages = [
        pkgs.podman
        pkgs.opencode
        launcher
      ];
    };
}
