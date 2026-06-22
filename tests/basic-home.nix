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
    settings = {
      model = "test/model";
      terminal.backend = "local";
    };
    environment = {
      HERMES_TEST = "1";
    };
    documents."SOUL.md" = "You are a test Hermes.";
    gateway = {
      enable = true;
      voiceModes."telegram:-1001234567890" = true;
    };
  };
}
