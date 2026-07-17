{ pkgs, ... }:

{
  home.username = "hermes-service-config-unset-test";
  home.homeDirectory = "/tmp/hermes-service-config-unset-test";
  home.stateVersion = "24.11";

  programs.hermes-agent = {
    enable = true;
    package = pkgs.writeShellScriptBin "hermes" ''
      echo "fake hermes $@"
    '';
    gateway = {
      enable = true;
      serviceConfig.UnsetEnvironment = [ "CUSTOM_LEGACY_VAR" ];
    };
  };
}
