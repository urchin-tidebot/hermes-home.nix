{ pkgs, ... }:

{
  home.username = "hermes-test";
  home.homeDirectory = "/tmp/hermes-home-test";
  home.stateVersion = "24.11";

  programs.hermes-agent = {
    enable = true;
    package = pkgs.writeShellScriptBin "hermes" ''
      echo "fake hermes $@"
    '';
    gateway.enable = false;
    settings.model = "test/model";
  };
}
