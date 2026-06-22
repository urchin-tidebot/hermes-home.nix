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
    configFile = "/run/secrets/hermes/config.yaml";
    authFile = "/run/secrets/hermes/auth.json";
    environmentFiles = [ "/run/secrets/hermes/env" ];
  };
}
