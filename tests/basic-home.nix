{ pkgs, ... }:

{
  home.username = "hermes-test";
  home.homeDirectory = "/tmp/hermes-home-test";
  home.stateVersion = "24.11";

  programs.hermes-agent = {
    enable = true;
    package = pkgs.runCommand "hermes-agent" { } ''
      mkdir -p $out/bin
      cat > $out/bin/hermes <<'EOF'
      #!${pkgs.runtimeShell}
      echo "fake hermes $@"
      EOF
      chmod +x $out/bin/hermes
    '';
    extraPackages = [ pkgs.git ];

    settings = {
      model = "test/model";
      terminal.backend = "local";
    };

    mcpServers.filesystem = {
      command = "mcp-server-filesystem";
      args = [ "/tmp" ];
      tools.include = [ "read_file" ];
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
