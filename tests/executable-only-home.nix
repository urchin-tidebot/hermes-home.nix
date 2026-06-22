{ ... }:

{
  home.username = "hermes-test";
  home.homeDirectory = "/tmp/hermes-home-test";
  home.stateVersion = "24.11";

  programs.hermes-agent = {
    enable = true;
    package = null;
    addToPackages = false;
    executable = "/custom/bin/hermes";
    gateway.enable = true;
  };
}
