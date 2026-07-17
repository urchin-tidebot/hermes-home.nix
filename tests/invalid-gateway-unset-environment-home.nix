{ pkgs, ... }:

{
  home.username = "hermes-invalid-unset-test";
  home.homeDirectory = "/tmp/hermes-invalid-unset-test";
  home.stateVersion = "24.11";

  programs.hermes-agent = {
    enable = true;
    package = pkgs.writeShellScriptBin "hermes" ''
      echo "fake hermes $@"
    '';
    gateway = {
      enable = true;
      unsetEnvironment = [ true ];
    };
  };
}
