{ pkgs, ... }:

{
  home.username = "hermes-unset-test";
  home.homeDirectory = "/tmp/hermes-unset-test";
  home.stateVersion = "24.11";

  programs.hermes-agent = {
    enable = true;
    package = pkgs.writeShellScriptBin "hermes" ''
      echo "fake hermes $@"
    '';
    gateway = {
      enable = true;
      unsetEnvironment = [
        "CUSTOM_LEGACY_VAR"
        "PYTHONPATH"
        "PYTHONHOME"
        "PYTHONPATH"
      ];
    };
  };
}
