# agent-sandbox.nix
#
# Containerized coding-agent sandbox, synthesized per project from the
# project's own flake devShell. No per-project flake changes required:
# any project with a `devShells.<system>.default` works.
#
# Import it and enable (synth.nix must sit next to this file):
#
#   imports = [ ./agent-sandbox.nix ];
#   programs.agentSandbox.enable = true;
#
# Usage:
#   agent-sandbox                    # run the default agent (pi) in this flake project
#   agent-sandbox opencode           # run OpenCode instead, same project sandbox
#   agent-sandbox claude             # run Claude Code instead, same project sandbox
#   agent-sandbox --update           # upgrade the default agent (npm agents only)
#   agent-sandbox opencode --update  # (no-op for nixpkgs-provided agents; see note)
#   agent-sandbox --gc               # remove volumes/images for projects that no longer exist
#
# The first positional arg, if it names a defined agent, selects that agent and
# is shifted off; otherwise the default agent is used. Everything else (--update,
# --gc) is unchanged. Agents are defined in `programs.agentSandbox.agents`; three
# are built in (pi, opencode, claude) and you can add or override more.
#
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.agentSandbox;

  # Built-in agents. pi installs from npm at runtime (it isn't in nixpkgs);
  # opencode and claude are pulled from nixpkgs and baked into the image, because
  # their upstream distributions ship prebuilt binaries that need an FHS loader
  # the nix image lacks (opencode's npm build, and Claude Code's npm package which
  # now installs a native binary rather than running under node).
  #
  # Both nixpkgs-provided built-ins set useHostNixpkgs = true, so the agent comes
  # from the host's nixpkgs pin rather than each project's — one consistent agent
  # version everywhere, and no failure on projects pinned to a nixpkgs too old to
  # contain the agent. The devShell + extraTools still come from the project.
  #
  # mounts:     host<->container bind mounts giving the agent its real identity
  #             /config/sessions; host paths may use $HOME, expanded at run time.
  # sessionEnv: optional per-project session-isolation env var; `value` may use
  #             $KEY (the per-project key), expanded at run time.
  builtinAgents = {
    pi = {
      command = cfg.agentCommand;
      npmPackage = cfg.agentPackage;
      nixPackage = "";
      useHostNixpkgs = false;
      # Mounted + run at a fixed /work, as before. Pi isolates sessions via the
      # explicit per-project session dir below, so the uniform path is fine.
      workdir = "/work";
      mounts = [
        # Your real ~/.pi (login, sessions, plugins, models.json), read-write.
        { host = "$HOME/.pi"; container = "/root/.pi"; readOnly = false; }
        # Your ~/.agents (pi-subagents user agent definitions), read-only.
        { host = "$HOME/.agents"; container = "/root/.agents"; readOnly = true; }
      ];
      sessionEnv = {
        name = "PI_CODING_AGENT_SESSION_DIR";
        value = "/root/.pi/sessions/$KEY";
      };
    };
    opencode = {
      command = "opencode";
      npmPackage = "";
      nixPackage = "opencode";
      # Resolve opencode from the host's nixpkgs, not the project's, so its
      # version is consistent across every project sandbox.
      useHostNixpkgs = true;
      # OpenCode derives a project's identity from its git root-commit hash (or
      # normalized origin URL), falling back to the directory path for non-git
      # folders, and stores sessions under ~/.local/share/opencode/storage keyed
      # by that ID. Mounting the project at its REAL host path (not /work) makes
      # OpenCode compute exactly the identity and paths it would on the host:
      # git repos isolate per repo (and share history with any host OpenCode run
      # on the same repo), non-git folders isolate by their real path, and the
      # working directory the model sees matches the host. So no per-project
      # session env is needed — the shared data dir behaves like a normal host.
      workdir = "$PROJECT";
      mounts = [
        # Global config: opencode.json, tui.json, plugins/, agents/, commands/.
        { host = "$HOME/.config/opencode"; container = "/root/.config/opencode"; readOnly = false; }
        # Data dir: auth.json (your provider logins) plus session/state storage.
        { host = "$HOME/.local/share/opencode"; container = "/root/.local/share/opencode"; readOnly = false; }
      ];
      sessionEnv = null;
    };
    claude = {
      command = "claude";
      npmPackage = "";
      # Claude Code's npm package now ships a prebuilt native binary (it no longer
      # runs under node), so — like opencode — it can't run in the pure nix image;
      # use the patched nixpkgs build instead. (Swap in "claude-code-bin" for the
      # autoPatchelf'd native-binary variant, which tracks upstream releases more
      # closely; also unfree.)
      nixPackage = "claude-code";
      # Resolve claude-code from the host's nixpkgs, not the project's. Besides
      # version consistency, this sidesteps the unfree eval on the project side —
      # the host import enables allowUnfree. (The launcher still passes
      # NIXPKGS_ALLOW_UNFREE=1 for the project-nixpkgs path, in case you flip this
      # off or a project's devShell pulls unfree tools of its own.)
      useHostNixpkgs = true;
      # Claude Code keys project identity and stores session transcripts by the
      # working directory's absolute path (~/.claude/projects/<abs-path>/*.jsonl
      # plus the `projects` map in ~/.claude.json). Mount the project at its REAL
      # host path (like opencode) so the sandbox computes the same identity and
      # shares/continues sessions with any host `claude` run on the same repo.
      workdir = "$PROJECT";
      mounts = [
        # Your real ~/.claude: auth (.credentials.json), settings.json, session
        # transcripts (projects/), todos, skills/agents/commands — read-write.
        # A DIRECTORY mount (not a single-file mount): Claude Code rewrites its
        # config atomically (temp file + rename), and renaming over a bind-
        # mounted *file* fails with "device or resource busy". Keeping the mount
        # at the directory keeps those renames inside one mount. With
        # CLAUDE_CONFIG_DIR below, ~/.claude.json (and its .backup) also land
        # inside this directory, so they persist and stay safe from the rename
        # trap too.
        { host = "$HOME/.claude"; container = "/root/.claude"; readOnly = false; }
      ];
      # Point Claude Code's whole config surface at the mounted dir: with
      # CLAUDE_CONFIG_DIR set, .claude.json / .claude.json.backup / .credentials
      # / projects / todos all live under /root/.claude (= host ~/.claude),
      # instead of .claude.json sitting loose in the sandbox home. Identity still
      # comes from the real project path (workdir), like opencode.
      #
      # Note: this makes .claude.json live at ~/.claude/.claude.json, which is a
      # DIFFERENT file from host Claude Code's ~/.claude.json sibling (host CC
      # doesn't set CLAUDE_CONFIG_DIR). Auth and sessions are shared with the
      # host; .claude.json (user MCP servers, per-project trust/onboarding) is
      # effectively sandbox-scoped but persistent. Set host CLAUDE_CONFIG_DIR to
      # the same dir if you want that file shared with the host too.
      sessionEnv = {
        name = "CLAUDE_CONFIG_DIR";
        value = "/root/.claude";
      };
    };
  };

  # User-defined agents win over the built-ins on name collision.
  allAgents = builtinAgents // cfg.agents;
  agentNamesList = lib.attrNames allAgents;

  extraToolsNix =
    "[ " + lib.concatMapStringsSep " " (n: "\"" + n + "\"") cfg.extraTools + " ]";

  dnsFlags = lib.concatMapStringsSep " " (s: "--dns=" + s) cfg.dns;

  # `pi|opencode|claude` pattern for the agent-selection case, and a bash array
  # of the same names for --gc to sweep per-agent images.
  agentSelectPattern = lib.concatStringsSep "|" agentNamesList;
  agentNamesArr = lib.concatMapStringsSep " " (n: "\"" + n + "\"") agentNamesList;

  # Per-agent shell case: set the package/command, build the bind-mount array,
  # and build the session-env array. Runs after KEY is known (sessionEnv uses it).
  #
  # AGENTNIXPKGS is the nixpkgs source the agent is resolved from: empty (=>
  # the project's nixpkgs, inside synth.nix) unless useHostNixpkgs is set, in
  # which case it's the host nixpkgs source path (pkgs.path) baked in here.
  agentDefineCase = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: a:
    let
      mounts = a.mounts or [ ];
      hostDirs = lib.concatMapStringsSep " " (m: "\"" + m.host + "\"") mounts;
      mountFlags = lib.concatMapStringsSep " "
        (m: "-v \"" + m.host + ":" + m.container
            + (lib.optionalString (m.readOnly or false) ":ro") + "\"")
        mounts;
      sess = a.sessionEnv or null;
      sessionFlag =
        if sess == null then ""
        else "-e \"" + sess.name + "=" + sess.value + "\"";
      agentNixpkgs = lib.optionalString (a.useHostNixpkgs or false) "${pkgs.path}";
    in ''
      ${name})
        AGENTCMD="${a.command}"
        AGENTNPM="${a.npmPackage or ""}"
        AGENTNIX="${a.nixPackage or ""}"
        AGENTNIXPKGS="${agentNixpkgs}"
        WORKDIR="${a.workdir or "/work"}"
        ${lib.optionalString (mounts != [ ]) "mkdir -p ${hostDirs}"}
        AGENT_MOUNTS=( ${mountFlags} )
        SESSION_ENV=( ${sessionFlag} )
        ;;''
  ) allAgents);

  # Scope the per-project image build to an explicit substituter list, so a
  # flaky/unrelated system substituter isn't queried on every build. Empty
  # string => inherit the system substituters.
  substFlag =
    if cfg.substituters == null then ""
    else "--substituters " + lib.escapeShellArg (lib.concatStringsSep " " cfg.substituters);

  # The sandbox home (/root) holds the disposable durable state: the agent
  # install (~/.npm-global) and caches (~/.cargo, ~/.cache). Bind it to a real
  # host directory so it survives `podman volume prune` and is directly visible
  # / backup-able. Each agent's real config/identity is bind-mounted on top
  # separately (see builtinAgents above).
  # null => default under the state dir; otherwise the literal path given.
  homeMountLine =
    if cfg.homePath == null
    then ''HOME_MOUNT="$STATE_DIR/home"''
    else ''HOME_MOUNT="${cfg.homePath}"'';

  launcher = pkgs.writeShellScriptBin "agent-sandbox" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.podman pkgs.nix pkgs.gawk pkgs.gnused pkgs.slirp4netns ]}:$PATH

    SYNTH="${./synth.nix}"
    SYSTEM="${pkgs.stdenv.hostPlatform.system}"
    EXTRATOOLS='${extraToolsNix}'
    DEFAULT_AGENT="${cfg.defaultAgent}"
    AGENT_NAMES=( ${agentNamesArr} )

    DISKWARN_ENABLE="${lib.optionalString cfg.diskWarn.enable "1"}"
    DISKWARN_INTERVAL_HOURS="${toString cfg.diskWarn.checkIntervalHours}"
    DISKWARN_MIN_FREE_GIB="${toString cfg.diskWarn.minFreeGiB}"
    DISKWARN_VOLUME_GIB="${toString cfg.diskWarn.volumeWarnGiB}"

    PRUNE_ENABLE="${lib.optionalString cfg.prune.enable "1"}"
    PRUNE_ABOVE_GIB="${toString cfg.prune.aboveGiB}"

    STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/agent-sandbox"
    mkdir -p "$STATE_DIR/projects"
    ${homeMountLine}

    # --- agent selection ----------------------------------------------------
    # First positional arg selects the agent if it names one; else default.
    AGENT="$DEFAULT_AGENT"
    case "''${1:-}" in
      ${agentSelectPattern})
        AGENT="$1"; shift ;;
    esac

    # --- garbage collection -------------------------------------------------
    # Remove per-project volumes + images for projects whose directory is gone,
    # then prune dangling images left behind by flake changes. Images are now
    # per-agent (agent-sandbox:<key>-<agent>), so sweep every known agent plus
    # the legacy un-suffixed ref.
    if [ "''${1:-}" = "--gc" ]; then
      removed=0
      for f in "$STATE_DIR"/projects/*; do
        [ -e "$f" ] || continue
        k="$(basename "$f")"
        p="$(cat "$f")"
        if [ ! -d "$p" ] || [ ! -f "$p/flake.nix" ]; then
          echo "agent-sandbox: removing orphan $k ($p)" >&2
          for a in "''${AGENT_NAMES[@]}"; do
            podman rmi -f "agent-sandbox:$k-$a" >/dev/null 2>&1 || true
            rm -f "$STATE_DIR/img-$k-$a" "$STATE_DIR/fp-$k-$a" "$STATE_DIR/diskcheck-$k-$a"
            for v in target venv node; do
              podman volume rm "agentsb-$v-$k-$a" >/dev/null 2>&1 || true
            done
          done
          podman rmi -f "agent-sandbox:$k" >/dev/null 2>&1 || true   # legacy image
          for v in target venv node; do                              # legacy volumes
            podman volume rm "agentsb-$v-$k" >/dev/null 2>&1 || true
          done
          # Drop the key->path record and any legacy sentinels/fingerprints.
          rm -f "$f" "$STATE_DIR/img-$k" "$STATE_DIR/fp-$k"
          removed=$((removed + 1))
        fi
      done
      podman image prune -f >/dev/null 2>&1 || true
      echo "agent-sandbox: removed $removed orphaned project(s). Run 'podman system df' to check reclaimed space." >&2
      exit 0
    fi

    # --- normal run (optionally upgrading the agent first) ------------------
    UPDATE_ENV=()
    if [ "''${1:-}" = "--update" ]; then
      UPDATE_ENV=(-e AGENT_SANDBOX_UPDATE=1)
    fi

    PROJECT="$(realpath "$PWD")"
    if [ ! -f "$PROJECT/flake.nix" ]; then
      echo "agent-sandbox: no flake.nix in $PROJECT" >&2
      echo "  this mode needs a flake exposing devShells.$SYSTEM.default" >&2
      exit 1
    fi

    # Readable per-project key: sanitized basename + short hash of the full path.
    # The hash keeps it unique even when two projects share a basename.
    BASE="$(basename "$PROJECT" | tr -c 'a-zA-Z0-9_.-' '-' | sed 's/^[.-]*//' | cut -c1-40)"
    [ -n "$BASE" ] || BASE=proj
    HASH="$(printf '%s' "$PROJECT" | sha256sum | cut -c1-10)"
    KEY="$BASE-$HASH"

    # Record key -> path so --gc can find orphans later. (Project-scoped: shadow
    # build volumes and the orphan record are shared across agents.)
    printf '%s' "$PROJECT" > "$STATE_DIR/projects/$KEY"

    # Resolve the selected agent: sets AGENTCMD / AGENTNPM / AGENTNIX /
    # AGENTNIXPKGS / WORKDIR, builds the AGENT_MOUNTS array, and builds
    # SESSION_ENV (may reference $KEY).
    case "$AGENT" in
      ${agentDefineCase}
      *)
        echo "agent-sandbox: unknown agent '$AGENT'" >&2
        exit 1 ;;
    esac

    # Image + state files are per-(project,agent), so switching agents in the
    # same project doesn't force a rebuild and the two never clobber each other.
    IMGKEY="$KEY-$AGENT"
    REF="agent-sandbox:$IMGKEY"
    SENTINEL="$STATE_DIR/img-$IMGKEY"
    FP_FILE="$STATE_DIR/fp-$IMGKEY"

    # The image is a function of the devShell definition + its lock, the synth
    # logic, and the agent/tool set — NOT the project source, which is
    # bind-mounted into /work at run time. So fingerprint just those inputs and
    # skip the (slow) nix evaluation whenever none of them changed and the
    # image is already loaded. This turns a warm relaunch from a ~30s re-eval
    # into a near-instant podman run.
    #
    # AGENTNIXPKGS is in the fingerprint too: for a host-sourced agent it's the
    # host nixpkgs store path, so bumping the host pin changes it and forces the
    # agent image to rebuild against the new version.
    FP="$( ( cat "$PROJECT/flake.nix" "$PROJECT/flake.lock" "$SYNTH" 2>/dev/null || true ) \
           | sha256sum | cut -c1-32 )|$AGENTCMD|$AGENTNPM|$AGENTNIX|$AGENTNIXPKGS|$EXTRATOOLS"

    if [ -f "$FP_FILE" ] && [ "$(cat "$FP_FILE")" = "$FP" ] && podman image exists "$REF"; then
      echo "agent-sandbox: image up to date, skipping build" >&2
    else
      echo "agent-sandbox: building $AGENT image from project devShell ..." >&2
      EXPR="import $SYNTH { projectPath = \"$PROJECT\"; system = \"$SYSTEM\"; agentCommand = \"$AGENTCMD\"; agentNpmPackage = \"$AGENTNPM\"; agentNixPackage = \"$AGENTNIX\"; agentNixpkgs = \"$AGENTNIXPKGS\"; extraTools = $EXTRATOOLS; }"
      # claude-code (the built-in `claude` agent) is unfree in nixpkgs. When it's
      # host-sourced, synth.nix's alternate import already enables allowUnfree;
      # this covers the project-nixpkgs path too (and any unfree devShell tools).
      IMG="$(NIXPKGS_ALLOW_UNFREE=1 nix build --impure --fallback ${substFlag} --no-link --print-out-paths --expr "$EXPR")"

      # Retag to a per-(project,agent) ref so nothing clobbers anything else, and
      # only reload when the resolved store path actually changed.
      if [ ! -f "$SENTINEL" ] || [ "$(cat "$SENTINEL")" != "$IMG" ] || ! podman image exists "$REF"; then
        echo "agent-sandbox: loading image into podman ..." >&2
        LOADED="$(podman load -i "$IMG" | awk -F': ' '/Loaded image/{print $NF}' | tail -n1)"
        podman tag "$LOADED" "$REF"
        printf '%s' "$IMG" > "$SENTINEL"
      fi

      # Record the inputs we just built against, so the next launch can skip
      # the eval. Written last, so a failed build doesn't poison the cache.
      printf '%s' "$FP" > "$FP_FILE"

      # Drop the transient image output from the nix store. podman now holds its
      # own copy (loaded/tagged above), and the warm-relaunch fast path keys off
      # the FP cache + `podman image exists`, never re-reading $IMG — so this
      # store path is unrooted garbage the moment it's loaded. Deleting it here
      # reclaims the multi-GB blob immediately instead of leaving it for the
      # weekly GC. Only this leaf is removed; the devShell closure it depends on
      # stays (still referenced), and superseded closures from older flake locks
      # are a separate cleanup left to `nix.gc`. `nix store delete` refuses if the
      # path is somehow still referenced, and `|| true` keeps a failure here from
      # blocking the launch.
      nix store delete "$IMG" >/dev/null 2>&1 || true
    fi

    # --- disk-pressure warning (throttled, per project+agent) ---------------
    # Surfaces two things the tool can silently pile up: (a) low free space on
    # the filesystem(s) holding the nix store / podman storage, and (b) this
    # project's build-cache shadow volumes (Rust target/ etc.), which grow
    # unboundedly and no GC touches. Measuring the volumes needs a `du`, so the
    # whole check is throttled to once per checkIntervalHours per (project,agent)
    # — keeping warm relaunches instant — with the last-run time stamped under
    # the state dir. Set checkIntervalHours = 0 to check on every launch.
    #
    # The prune option piggybacks on the same throttled measurement: when the
    # Rust target volume alone exceeds prune.aboveGiB, its contents are cleared
    # (the volume itself stays; next build is cold). Only target — venv and
    # node_modules regrow to a bounded size and don't accumulate the same way.
    if [ "$DISKWARN_ENABLE" = "1" ] || [ "$PRUNE_ENABLE" = "1" ]; then
      CHECK_STAMP="$STATE_DIR/diskcheck-$IMGKEY"
      NOW="$(date +%s)"
      LAST=0; [ -f "$CHECK_STAMP" ] && LAST="$(cat "$CHECK_STAMP" 2>/dev/null || echo 0)"
      INTERVAL=$(( DISKWARN_INTERVAL_HOURS * 3600 ))
      if [ "$INTERVAL" -le 0 ] || [ $(( NOW - LAST )) -ge "$INTERVAL" ]; then
        seen_devs=""
        warn_fs() {
          # $1 = a path on the filesystem to check, $2 = human label. df is O(1),
          # so this stays instant. Dedup by backing device so store+podman on one
          # disk warn once.
          local path="$1" label="$2" line dev rest avail_kib pct avail_gib
          line="$(df -Pk "$path" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $1" "$4" "$5}')" || true
          [ -n "$line" ] || return 0
          dev="''${line%% *}"; rest="''${line#* }"
          avail_kib="''${rest%% *}"; pct="''${rest##* }"
          case " $seen_devs " in *" $dev "*) return 0 ;; esac
          seen_devs="$seen_devs $dev"
          avail_gib=$(( avail_kib / 1024 / 1024 ))
          if [ "$avail_gib" -lt "$DISKWARN_MIN_FREE_GIB" ]; then
            echo "agent-sandbox: WARNING: ''${avail_gib}GiB free on the filesystem holding $label (''${pct}% used)." >&2
            echo "  reclaim: nix-collect-garbage --delete-older-than 7d ; podman system prune -f" >&2
          fi
        }
        if [ "$DISKWARN_ENABLE" = "1" ]; then
          warn_fs /nix/store "the nix store"
          PODMAN_ROOT="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)"
          [ -n "$PODMAN_ROOT" ] && warn_fs "$PODMAN_ROOT" "podman storage"
        fi

        # This project's build-cache volumes (target / .venv / node_modules).
        # target's size and mountpoint are kept separately for the prune below.
        vol_bytes=0; target_gib=0; target_mp=""
        for v in target venv node; do
          mp="$(podman volume inspect "agentsb-$v-$IMGKEY" --format '{{.Mountpoint}}' 2>/dev/null || true)"
          [ -n "$mp" ] && [ -d "$mp" ] || continue
          b="$(du -sx -B1 "$mp" 2>/dev/null | awk '{print $1}' || true)"
          if [ -n "$b" ]; then
            vol_bytes=$(( vol_bytes + b ))
            if [ "$v" = target ]; then
              target_gib=$(( b / 1024 / 1024 / 1024 ))
              target_mp="$mp"
            fi
          fi
        done
        vol_gib=$(( vol_bytes / 1024 / 1024 / 1024 ))
        if [ "$DISKWARN_ENABLE" = "1" ] && [ "$vol_gib" -ge "$DISKWARN_VOLUME_GIB" ]; then
          echo "agent-sandbox: WARNING: build-cache volumes for this project total ''${vol_gib}GiB (agentsb-*-$IMGKEY)." >&2
          echo "  reset (rebuilds cold next run): podman volume rm agentsb-{target,venv,node}-$IMGKEY" >&2
        fi

        # Auto-clear the Rust target volume when it alone crosses the prune
        # threshold. Contents only — the volume stays in place, so there's no
        # re-create race and the container mounts it as usual next launch.
        # cargo treats the empty dir as a cold cache and rebuilds everything.
        if [ "$PRUNE_ENABLE" = "1" ] && [ "$target_gib" -ge "$PRUNE_ABOVE_GIB" ] \
           && [ -n "$target_mp" ] && [ -d "$target_mp" ]; then
          echo "agent-sandbox: clearing agentsb-target-$IMGKEY (''${target_gib}GiB >= ''${PRUNE_ABOVE_GIB}GiB); next build is cold" >&2
          find "$target_mp" -mindepth 1 -xdev -delete 2>/dev/null || true
        fi

        printf '%s' "$NOW" > "$CHECK_STAMP"
      fi
    fi

    mkdir -p "$HOME_MOUNT"

    # Shadow only the build-output dirs the project actually uses, so we don't
    # create spurious empty mountpoints (node_modules in a Python project, etc.)
    # in the real tree. Each shadow is a named volume over <workdir>/<dir>.
    # Keyed per-(project,agent): agents may mount the project at different paths
    # (e.g. /work vs the real host path), and build caches like Cargo's target
    # bake in absolute source paths, so sharing one cache across agents would
    # thrash. Different agents therefore keep independent build caches.
    SHADOW_MOUNTS=()
    if [ -f "$PROJECT/Cargo.toml" ]; then
      SHADOW_MOUNTS+=(-v "agentsb-target-$IMGKEY:$WORKDIR/target")
    fi
    if [ -f "$PROJECT/pyproject.toml" ] || [ -f "$PROJECT/setup.py" ] \
       || [ -f "$PROJECT/requirements.txt" ] || [ -f "$PROJECT/uv.lock" ]; then
      SHADOW_MOUNTS+=(-v "agentsb-venv-$IMGKEY:$WORKDIR/.venv")
    fi
    if [ -f "$PROJECT/package.json" ]; then
      SHADOW_MOUNTS+=(-v "agentsb-node-$IMGKEY:$WORKDIR/node_modules")
    fi

    exec podman run --rm -it \
      --name "agentsb-$IMGKEY" --replace \
      --cap-drop=ALL \
      --security-opt=no-new-privileges \
      --network=slirp4netns \
      ${dnsFlags} \
      --pids-limit=1024 \
      --memory="''${AGENT_SANDBOX_MEM:-${cfg.memory}}" \
      -v "$PROJECT:$WORKDIR:rw" -w "$WORKDIR" \
      --tmpfs /tmp:rw,size=2g,mode=1777 \
      -v "$HOME_MOUNT:/root" \
      "''${SESSION_ENV[@]}" \
      "''${SHADOW_MOUNTS[@]}" \
      "''${AGENT_MOUNTS[@]}" \
      "''${UPDATE_ENV[@]}" \
      "$REF"
  '';
in
{
  options.programs.agentSandbox = {
    enable = lib.mkEnableOption
      "coding-agent sandbox synthesized from each project's flake devShell";

    defaultAgent = lib.mkOption {
      type = lib.types.str;
      default = "pi";
      description = ''
        Agent launched when no agent name is given as the first argument.
        Must name one of the defined agents (built-in: "pi", "opencode", "claude").
      '';
    };

    agentPackage = lib.mkOption {
      type = lib.types.str;
      default = "@earendil-works/pi-coding-agent";
      description = "npm package for the built-in `pi` agent.";
    };

    agentCommand = lib.mkOption {
      type = lib.types.str;
      default = "pi";
      description = "Executable for the built-in `pi` agent.";
    };

    agents = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          command = lib.mkOption {
            type = lib.types.str;
            description = "Executable run inside the sandbox for this agent.";
          };
          npmPackage = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = ''
              npm package installed into ~/.npm-global on first run. Leave empty
              if the agent is provided via nixpkgs (`nixPackage`) instead.
            '';
          };
          nixPackage = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = ''
              nixpkgs attribute baked into the image, so the command is already
              on PATH. Use this for agents whose upstream distribution ships a
              prebuilt binary that won't run in the nix image (e.g. opencode, or
              claude-code whose npm package now installs a native binary). Leave
              empty for npm agents.

              Resolved against the project's nixpkgs by default, or the host's
              when `useHostNixpkgs` is set. If the attribute is unfree (e.g.
              claude-code / claude-code-bin), the per-project image build runs
              with NIXPKGS_ALLOW_UNFREE=1 (and the host import enables allowUnfree
              directly), so the eval doesn't refuse it.
            '';
          };
          useHostNixpkgs = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Resolve `nixPackage` against the host's nixpkgs (the pin this module
              is evaluated with, via pkgs.path) instead of the project's. This
              keeps the agent version consistent across every project sandbox and
              avoids `attribute '<agent>' missing` on projects pinned to a nixpkgs
              too old to contain it. The devShell and `extraTools` still come from
              the project's nixpkgs; only the agent package is re-sourced.

              The host import enables allowUnfree, so unfree agents evaluate
              cleanly. Note this pins the agent to host state rather than the
              project's lock, and may add a modestly larger closure if the host
              and project pins diverge enough not to dedup. No effect on npm
              agents. Bumping the host pin re-fingerprints and rebuilds the agent
              image on next launch.
            '';
          };
          workdir = lib.mkOption {
            type = lib.types.str;
            default = "/work";
            example = "$PROJECT";
            description = ''
              Path inside the sandbox to mount the project at and use as the
              working directory. Evaluated by the shell at run time, so it may
              reference $PROJECT (the project's real host path). Use "$PROJECT"
              to mirror a normal host, so an agent that derives project identity
              or stores state by path (e.g. opencode, claude) sees the same paths
              it would outside the sandbox. Defaults to "/work".

              Build-cache shadow volumes are keyed per-(project,agent), so two
              agents with different workdirs don't share absolute-path-sensitive
              caches.
            '';
          };
          mounts = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                host = lib.mkOption {
                  type = lib.types.str;
                  description = "Host path (may use $HOME), expanded at run time.";
                };
                container = lib.mkOption {
                  type = lib.types.str;
                  description = "Mount point inside the sandbox.";
                };
                readOnly = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Mount read-only.";
                };
              };
            });
            default = [ ];
            description = ''
              Bind mounts giving the agent its real identity/config/sessions from
              the host. Created with `mkdir -p` before mounting. Prefer mounting
              a directory over a single file: apps that rewrite a config file
              atomically (temp file + rename) fail against a bind-mounted file
              with "device or resource busy".
            '';
          };
          sessionEnv = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                name = lib.mkOption { type = lib.types.str; };
                value = lib.mkOption {
                  type = lib.types.str;
                  description = "Value; may use $KEY (the per-project key).";
                };
              };
            });
            default = null;
            description = ''
              Optional per-project session-isolation env var. For an agent that
              keys sessions by the worktree path (always /work in the sandbox)
              you can instead point a per-project data dir here. null to omit.
            '';
          };
        };
      });
      default = { };
      description = ''
        Agents merged over the built-ins (`pi`, `opencode`, `claude`); entries
        here win on name collision, so you can add new agents or override the
        built-ins. Launch one with `agent-sandbox <name>`.

        OpenCode session isolation: the built-in `opencode` agent mounts the
        project at its real host path (workdir = "$PROJECT") rather than /work,
        so OpenCode computes the same git-derived project identity and stores
        sessions exactly as it would on the host — isolated per project, and
        shared with any host OpenCode you run on the same repo. Set its workdir
        back to "/work" if you'd prefer the project to appear under a uniform
        mountpoint instead.

        Claude Code session isolation: the built-in `claude` agent likewise
        mounts the project at its real host path, because Claude Code keys
        project identity and session transcripts by the working directory's
        absolute path (~/.claude/projects/<abs-path>/ and the `projects` map in
        .claude.json). Its ~/.claude (auth, settings, transcripts) is bind-
        mounted from the host as a directory, so sessions are shared with any
        host `claude` run on the same repo. It also sets CLAUDE_CONFIG_DIR to
        that mounted dir, so .claude.json (and its .backup) live inside it rather
        than loose in the sandbox home — persistent and safe from the single-
        file bind-mount rename trap. That makes .claude.json a different file
        from host CC's ~/.claude.json sibling (host CC doesn't set the env var),
        so user MCP servers / onboarding are sandbox-scoped but persistent;
        auth and sessions remain shared. Point host CLAUDE_CONFIG_DIR at the
        same dir to share .claude.json with the host too.

        Both nixpkgs-provided built-ins set useHostNixpkgs = true, so the agent
        tracks the host nixpkgs pin instead of each project's. Override an agent
        here with useHostNixpkgs = false to pin it to the project instead.
      '';
    };

    extraTools = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ripgrep" "jq" "fd" ];
      description = ''
        Extra nixpkgs attribute names added to every sandbox, resolved against
        the project's own nixpkgs. Strings (not packages), since they cross into
        a separate `nix build --expr` evaluation.
      '';
    };

    dns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "1.1.1.1" ];
      description = ''
        DNS servers for the container. Rootless podman often can't use the
        host's systemd-resolved stub (127.0.0.53), which breaks name lookups
        for the model API and npm. Add "100.100.100.100" first if you want
        Tailscale MagicDNS names to resolve inside the sandbox too.
      '';
    };

    memory = lib.mkOption {
      type = lib.types.str;
      default = "12g";
      description = "Container memory limit (override per-run with $AGENT_SANDBOX_MEM).";
    };

    substituters = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = [ "https://cache.nixos.org" ];
      description = ''
        Substituters used for the per-project image build, passed via
        `nix build --substituters` to override the system list for this build
        only. Defaults to just the official cache, so an unrelated or flaky
        system substituter (e.g. a down CachyOS cache that only hosts
        kernel/proton artifacts) isn't queried on every sandbox build. Your
        system substituters are untouched for everything else.

        Add a project's cachix URL here if its devShell pulls paths from one
        (e.g. "https://fenix.cachix.org" for fenix Rust toolchains). Two
        conditions for a non-official cache to actually be used: its public
        key must be in the system's trusted-public-keys, and the cache must be
        in trusted-substituters (or you must be a trusted user) — otherwise
        the daemon ignores it for non-trusted users and the path builds from
        source. Set to null to inherit the system substituters unchanged.
      '';
    };

    homePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/mnt/tank/agent-sandbox/home";
      description = ''
        Host directory bind-mounted as the sandbox's home (/root): the
        disposable durable state — the agent install (~/.npm-global) and
        caches (~/.cargo, ~/.cache). Being a real directory on your
        filesystem, it survives `podman volume prune` and is directly visible
        and backup-able, unlike a podman named volume.

        Note: each agent's real config/identity (e.g. ~/.pi for pi, or
        ~/.config/opencode + ~/.local/share/opencode for opencode, or ~/.claude
        for claude) is bind-mounted on top separately and is NOT stored here, so
        the sandbox shares your existing agent identity and config.

        When null, defaults to "$XDG_STATE_HOME/agent-sandbox/home"
        (typically ~/.local/state/agent-sandbox/home). Set an absolute path to
        place it on a specific disk or mount. Files are owned by your user
        (rootless podman maps the container's uid 0 to you).
      '';
    };

    diskWarn = lib.mkOption {
      default = { };
      description = ''
        Throttled disk-pressure warnings printed to stderr before the sandbox
        launches. Warns when free space on the filesystem(s) holding the nix
        store or podman storage runs low, and when this project's build-cache
        shadow volumes (Rust target/, .venv, node_modules — which grow
        unboundedly and no GC touches) exceed a size. The volume size needs a
        `du`, so the check is throttled per (project,agent) to keep warm
        relaunches instant. Warnings only; nothing is deleted (automatic
        clearing of the Rust target volume is the separate `prune` option,
        which shares this check's throttle).
      '';
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Print disk-pressure warnings before launch.";
          };
          checkIntervalHours = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 6;
            description = ''
              Minimum hours between checks for a given (project,agent). The last
              run is stamped under the state dir. 0 checks on every launch (adds
              a `du` of the build-cache volumes each time).
            '';
          };
          minFreeGiB = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 20;
            description = ''
              Warn when free space on the filesystem holding the nix store or
              podman storage drops below this many GiB.
            '';
          };
          volumeWarnGiB = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 25;
            description = ''
              Warn when this project's build-cache shadow volumes
              (agentsb-{target,venv,node}-<key>-<agent>) total at least this
              many GiB. Reset them with `podman volume rm` (they rebuild cold).
            '';
          };
        };
      };
    };

    prune = lib.mkOption {
      default = { };
      description = ''
        Automatically clear a project's Rust target shadow volume
        (agentsb-target-<key>-<agent>) when it grows past a threshold. Cargo
        never garbage-collects target/, so old dependency versions, dead
        incremental caches, and pre-toolchain-bump artifacts accumulate
        unboundedly; clearing resets that at the cost of one cold rebuild.
        Contents are removed but the volume itself is kept. Runs inside the
        diskWarn check's throttle (same stamp file and checkIntervalHours),
        but is independent of diskWarn.enable. Only the target volume is
        pruned — venv and node_modules regrow to a bounded size.
      '';
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Clear the Rust target volume when it exceeds aboveGiB.";
          };
          aboveGiB = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 40;
            description = ''
              Clear this project's target volume when it alone reaches this many
              GiB. Every trigger costs a full cold rebuild next launch, so keep
              this comfortably above the project's fresh-build target size.
            '';
          };
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.defaultAgent allAgents;
        message = "programs.agentSandbox.defaultAgent (\"${cfg.defaultAgent}\") "
          + "is not a defined agent. Defined: ${lib.concatStringsSep ", " agentNamesList}.";
      }
    ];
    virtualisation.podman.enable = lib.mkDefault true;
    environment.systemPackages = [ launcher ];
  };
}

