{
  pkgs,
  home-manager,
  hermesModule,
  honchoModule,
}:

let
  fakeHermes = pkgs.writeShellScriptBin "hermes" ''
    set -eu
    mkdir -p "$HERMES_HOME/instrumentation"
    {
      printf 'args=%s\n' "$*"
      printf 'HOME=%s\n' "$HOME"
      printf 'HERMES_HOME=%s\n' "$HERMES_HOME"
      printf 'HERMES_MANAGED=%s\n' "$HERMES_MANAGED"
      printf 'MESSAGING_CWD=%s\n' "$MESSAGING_CWD"
      printf 'PATH=%s\n' "$PATH"
    } > "$HERMES_HOME/instrumentation/gateway.log"

    if [ "$#" -ge 2 ] && [ "$1" = gateway ] && [ "$2" = run ]; then
      while true; do
        sleep 3600
      done
    fi
  '';

  samplePlugin = pkgs.runCommand "sample-plugin" { } ''
    mkdir -p "$out"
    cat > "$out/plugin.yaml" <<'EOF'
    name: sample-plugin
    version: 1.0.0
    EOF
  '';

  secretEnv = pkgs.writeText "hermes-vm-secret.env" ''
    HERMES_SECRET_SOURCE=activation-time
  '';

  authSeed = pkgs.writeText "hermes-vm-auth.json" ''
    {"provider":"vm-test"}
  '';

  honchoEnv = pkgs.writeText "honcho-vm.env" ''
    MINIMAX_API_KEY=vm-minimax-key
    OPENROUTER_API_KEY=vm-openrouter-key
  '';
in
pkgs.testers.runNixOSTest {
  name = "hermes-agent-home-manager-vm";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ home-manager.nixosModules.home-manager ];

      virtualisation.memorySize = 1024;
      virtualisation.diskSize = 2048;

      users.users.hermes-test = {
        isNormalUser = true;
        home = "/home/hermes-test";
        createHome = true;
        linger = true;
      };

      users.users.honcho-test = {
        isNormalUser = true;
        home = "/home/honcho-test";
        createHome = true;
      };

      environment.systemPackages = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ];

      environment.etc = {
        "hermes-vm/secret.env".source = secretEnv;
        "hermes-vm/auth.json".source = authSeed;
        "honcho-vm/honcho.env".source = honchoEnv;
      };

      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.hermes-test = {
        imports = [ hermesModule ];

        home.username = "hermes-test";
        home.homeDirectory = "/home/hermes-test";
        home.stateVersion = "24.11";
        systemd.user.startServices = "sd-switch";

        programs.hermes-agent = {
          enable = true;
          package = fakeHermes;
          extraPackages = [ pkgs.git ];
          extraPlugins = [ samplePlugin ];
          authFile = "/etc/hermes-vm/auth.json";

          settings = {
            model = "vm/test-model";
            terminal.backend = "local";
            providers.openai.base_url = "https://example.invalid/v1";
          };

          mcpServers = {
            filesystem = {
              command = "mcp-server-filesystem";
              args = [ "/tmp" ];
              tools.include = [ "read_file" ];
            };
            remote = {
              url = "https://mcp.example.invalid";
              headers."X-Test" = "enabled";
              connectTimeout = 5;
            };
          };

          environment = {
            HERMES_TEST = "vm";
          };
          environmentFiles = [ "/etc/hermes-vm/secret.env" ];

          documents = {
            "SOUL.md" = "You are VM-tested Hermes.";
            "skills/vm/SKILL.md" = "# VM skill\n";
          };

          gateway = {
            enable = true;
            voiceModes."telegram:-1001234567890:7" = true;
          };

          voice = {
            autoTts = true;
            edgeTts = {
              enable = true;
              command = "edge-tts {input_path} {output_path} en-US-AriaNeural";
              outputFormat = "ogg";
            };
          };
        };
      };

      home-manager.users.honcho-test = {
        imports = [ honchoModule ];

        home.username = "honcho-test";
        home.homeDirectory = "/home/honcho-test";
        home.stateVersion = "26.05";

        services.honcho = {
          enable = true;
          environmentFiles = [ "/etc/honcho-vm/honcho.env" ];
          localServices.postgres = true;
          localServices.redis = true;
        };
      };

      # Keep the VM focused on Home Manager/user-service behaviour.
      documentation.enable = lib.mkDefault false;
      documentation.nixos.enable = lib.mkDefault false;
      programs.command-not-found.enable = lib.mkDefault false;
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("test \"$(systemctl show home-manager-hermes-test.service -P Result)\" = success")
    machine.wait_until_succeeds("test \"$(systemctl show home-manager-honcho-test.service -P Result)\" = success")

    uid = machine.succeed("id -u hermes-test").strip()
    machine.succeed(f"systemctl start user@{uid}.service")
    machine.wait_for_unit(f"user@{uid}.service")

    user_systemctl = f"runuser -u hermes-test -- env XDG_RUNTIME_DIR=/run/user/{uid} systemctl --user"
    machine.succeed(f"{user_systemctl} daemon-reload")
    machine.succeed(f"{user_systemctl} start hermes-gateway.service")
    machine.wait_until_succeeds(f"{user_systemctl} is-active --quiet hermes-gateway.service")

    machine.succeed("test -d /home/hermes-test/.hermes")
    machine.succeed("test \"$(stat -c %a /home/hermes-test/.hermes)\" = 700")
    machine.succeed("test \"$(stat -c %a /home/hermes-test/.hermes/config.yaml)\" = 600")
    machine.succeed("test \"$(stat -c %a /home/hermes-test/.hermes/.env)\" = 600")
    machine.succeed("test \"$(stat -c %a /home/hermes-test/.hermes/auth.json)\" = 600")

    machine.succeed("grep -F 'HERMES_TEST=vm' /home/hermes-test/.hermes/.env")
    machine.succeed("grep -F 'HERMES_SECRET_SOURCE=activation-time' /home/hermes-test/.hermes/.env")
    machine.succeed("grep -F 'vm-test' /home/hermes-test/.hermes/auth.json")
    machine.succeed("grep -F 'You are VM-tested Hermes.' /home/hermes-test/.hermes/SOUL.md")
    machine.succeed("grep -F '# VM skill' /home/hermes-test/.hermes/skills/vm/SKILL.md")
    machine.succeed("test -L /home/hermes-test/.hermes/plugins/nix-managed-sample-plugin")

    machine.succeed("python3 - <<'PY'\nimport json\nfrom pathlib import Path\nimport yaml\nconfig = yaml.safe_load(Path('/home/hermes-test/.hermes/config.yaml').read_text())\nassert config['model'] == 'vm/test-model'\nassert config['terminal']['backend'] == 'local'\nassert config['mcp_servers']['filesystem']['command'] == 'mcp-server-filesystem'\nassert config['mcp_servers']['filesystem']['tools']['include'] == ['read_file']\nassert config['mcp_servers']['remote']['url'] == 'https://mcp.example.invalid'\nassert config['mcp_servers']['remote']['connect_timeout'] == 5\nassert config['voice']['auto_tts'] is True\nassert config['tts']['provider'] == 'edge-command'\nassert config['tts']['providers']['edge-command']['output_format'] == 'ogg'\nvoice_modes = json.loads(Path('/home/hermes-test/.hermes/gateway_voice_mode.json').read_text())\nassert voice_modes == {'telegram:-1001234567890:7': True}\nPY")

    machine.wait_until_succeeds("grep -F 'args=gateway run --replace' /home/hermes-test/.hermes/instrumentation/gateway.log")
    machine.succeed("grep -F 'HOME=/home/hermes-test' /home/hermes-test/.hermes/instrumentation/gateway.log")
    machine.succeed("grep -F 'HERMES_HOME=/home/hermes-test/.hermes' /home/hermes-test/.hermes/instrumentation/gateway.log")
    machine.succeed("grep -F 'HERMES_MANAGED=true' /home/hermes-test/.hermes/instrumentation/gateway.log")
    machine.succeed("grep -F 'MESSAGING_CWD=/home/hermes-test' /home/hermes-test/.hermes/instrumentation/gateway.log")
    machine.succeed("grep -F '${pkgs.git}' /home/hermes-test/.hermes/instrumentation/gateway.log")

    honcho_uid = machine.succeed("id -u honcho-test").strip()
    machine.succeed(f"systemctl start user@{honcho_uid}.service")
    machine.wait_for_unit(f"user@{honcho_uid}.service")

    honcho_systemctl = f"runuser -u honcho-test -- env XDG_RUNTIME_DIR=/run/user/{honcho_uid} systemctl --user"
    honcho_env = f"runuser -u honcho-test -- env XDG_RUNTIME_DIR=/run/user/{honcho_uid}"
    machine.succeed(f"{honcho_systemctl} daemon-reload")
    machine.succeed(f"{honcho_systemctl} start honcho-postgres.service honcho-redis.service")
    machine.wait_until_succeeds(f"{honcho_systemctl} is-active --quiet honcho-postgres.service")
    machine.wait_until_succeeds(f"{honcho_systemctl} is-active --quiet honcho-redis.service")

    machine.succeed("test -d /home/honcho-test/.local/share/honcho/postgres")
    machine.succeed("test -d /home/honcho-test/.local/share/honcho/redis")
    machine.succeed("test \"$(stat -c %a /home/honcho-test/.local/share/honcho)\" = 700")
    machine.succeed("test \"$(stat -c %a /home/honcho-test/.local/share/honcho/postgres)\" = 700")
    machine.succeed("test \"$(stat -c %a /home/honcho-test/.local/share/honcho/redis)\" = 700")

    machine.wait_until_succeeds(f"{honcho_env} ${
      pkgs.postgresql.withPackages (ps: [ ps.pgvector ])
    }/bin/pg_isready -h 127.0.0.1 -p 55432 -d postgres")
    machine.wait_until_succeeds("${pkgs.redis}/bin/redis-cli -h 127.0.0.1 -p 6380 PING | grep -Fx PONG")

    machine.succeed(f"{honcho_env} ${
      pkgs.postgresql.withPackages (ps: [ ps.pgvector ])
    }/bin/psql -h 127.0.0.1 -p 55432 -d postgres -tAc \"SELECT 1\"")
    machine.succeed(f"{honcho_env} ${
      pkgs.postgresql.withPackages (ps: [ ps.pgvector ])
    }/bin/psql -h 127.0.0.1 -p 55432 -d postgres -v ON_ERROR_STOP=1 -c \"CREATE ROLE honcho LOGIN\" || true")
    machine.succeed(f"{honcho_env} ${
      pkgs.postgresql.withPackages (ps: [ ps.pgvector ])
    }/bin/createdb -h 127.0.0.1 -p 55432 --owner=honcho honcho || true")
    machine.succeed(f"{honcho_env} ${
      pkgs.postgresql.withPackages (ps: [ ps.pgvector ])
    }/bin/psql -h 127.0.0.1 -p 55432 -d honcho -v ON_ERROR_STOP=1 -c \"CREATE EXTENSION IF NOT EXISTS vector\"")
    machine.succeed(f"{honcho_env} ${
      pkgs.postgresql.withPackages (ps: [ ps.pgvector ])
    }/bin/psql -h 127.0.0.1 -p 55432 -d honcho -tAc \"SELECT extname FROM pg_extension WHERE extname = 'vector'\" | grep -Fx vector")
    machine.succeed("grep -F 'CONNECTION_URI = \"postgresql+psycopg://honcho@127.0.0.1:55432/honcho\"' /home/honcho-test/.config/honcho/config.toml")
    machine.succeed("grep -F 'URL = \"redis://127.0.0.1:6380/0?suppress=true\"' /home/honcho-test/.config/honcho/config.toml")
    machine.succeed(f"{honcho_systemctl} cat honcho-api.service | grep -F 'EnvironmentFile=/etc/honcho-vm/honcho.env'")

    machine.succeed(f"{honcho_systemctl} stop honcho-postgres.service honcho-redis.service")
    machine.succeed(f"{user_systemctl} stop hermes-gateway.service")
  '';
}
