{ pkgs, ... }:

{
  home.username = "hermes-unsafe-pythonpath-test";
  home.homeDirectory = "/tmp/hermes-unsafe-pythonpath-test";
  home.stateVersion = "24.11";

  programs.hermes-agent = {
    enable = true;
    package = pkgs.writeShellScriptBin "hermes" ''
      echo "fake hermes $*"
    '';
    gateway.enable = true;
    service.environment.PYTHONPATH = "/tmp/cpython-313-dependencies";
  };
}
