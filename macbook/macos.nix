{ pkgs, ... }:

{
  imports = [
    ./agent-sandbox.nix
  ];

  nixpkgs.hostPlatform = "aarch64-darwin";

  system.primaryUser = "chris";

  # Set display to sleep when docked to 5 minutes, computer sleep to 30
  # Remove network and battery icons
  system.activationScripts.postActivation.text = ''
    echo "Applying macOS user preferences..."
  
    # Hide network/Wi-Fi status item from menu bar.
    sudo -u chris /usr/bin/defaults \
      -currentHost write com.apple.controlcenter WiFi -int 24
  
    # Hide battery status item from menu bar.
    sudo -u chris /usr/bin/defaults \
      -currentHost write com.apple.controlcenter Battery -int 8
  
    # Apply AC power sleep settings.
    /usr/bin/pmset -c displaysleep 5 sleep 30
  '';

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = with pkgs; [
    git
    vim
    wget
    curl
    ripgrep
    fd
    jq
    direnv
    nix-direnv
  ];
  
  nix-homebrew = {
    enable = true;
    user = "chris";
  
    # Persistently trust the OpenAI tap before brew bundle runs.
    trust = {
      taps = [
        "openai/tools"
      ];
    };
  };
  
  homebrew = {
    enable = true;
  
    casks = [
      "ghostty"
      "discord"
      "1password"
      "moonlight"
      "mos"
      "thaw"
      "sanesidebuttons"
      "betterdisplay"
      "tailscale-app"
      "parallels"
      "crossover"
      "steam"
    ];
  
    onActivation = {
      autoUpdate = true;
      upgrade = true;
      cleanup = "zap";
    };
  };

  # So nix commands are available
  environment.systemPath = [
    "/run/current-system/sw/bin"
  ];

  programs.zsh = {
    enable = true;

    interactiveShellInit = ''
      export DIRENV_LOG_FORMAT=
      eval "$(direnv hook zsh)"
    '';
  };
  environment.etc."direnv/direnvrc".text = ''
    source ${pkgs.nix-direnv}/share/nix-direnv/direnvrc
  '';

  # -- Nix Sandbox -- #
  programs.agentSandbox = {
    enable = true;
  
    #
    # Linux projects
    #
    targetSystem = "aarch64-linux";
  
    machine = {
      cpus = 6;
      memory = 12288;
      diskSize = 100;
    };
  
    memory = "10g";
  
    #
    # Native macOS projects
    #
    darwin = {
      enable = true;
  
      targetSystem = "aarch64-darwin";
  
      hostUser = "chris";
  
      user = "agent";
      uid = 599;
  
      group = "agent-sandbox";
      gid = 599;
  
      projectRoot = "/Users/chris/Projects";

      sharedBuildDirs = [
        ".derivedData"
        ".build"
      ];
  
      # null = use whatever `xcode-select -p` selects.
      # Since you've selected Xcode-beta system-wide, that should work.
      developerDir = null;
    };
  };

  # Don't change this after initial installation without reading
  # the nix-darwin release notes.
  system.stateVersion = 6;
}
