{
  pkgs,
  home-manager,
  honchoModule,
}:

let
  o200kBase = pkgs.fetchurl {
    url = "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken";
    sha256 = "0b8szc68pgx5b7zgzb72jmjc6mwzn047q38j2qsqwd3crcw9asj4";
  };

  honchoEnv = pkgs.writeText "honcho-e2e.env" ''
    MINIMAX_API_KEY=vm-minimax-key
    OPENROUTER_API_KEY=vm-openrouter-key
    TIKTOKEN_CACHE_DIR=/etc/honcho-e2e/tiktoken
  '';

  pythonEnv = pkgs.python313.withPackages (ps: [
    ps.alembic
    ps.anthropic
    ps.cashews
    ps.cloudevents
    ps.email-validator
    ps.fastapi
    ps.fastapi-pagination
    ps.google-genai
    ps.greenlet
    ps.httpx
    ps.json-repair
    ps.lancedb
    ps.langfuse
    ps.nanoid
    ps.openai
    ps.pdfplumber
    ps.pgvector
    ps.prometheus-client
    ps.psycopg
    ps.pyarrow
    ps.pydantic
    ps.pydantic-settings
    ps.pyjwt
    ps.python-multipart
    ps.redis
    ps.rich
    ps.scikit-learn
    ps.sentry-sdk
    ps.sqlalchemy
    ps.tenacity
    ps.tiktoken
    ps.typing-extensions
    ps.uvicorn
  ]);

  fakeUv = pkgs.writeShellScriptBin "uv" ''
    set -euo pipefail

    args=("$@")
    start=0
    for ((i = 0; i < ''${#args[@]}; i++)); do
      case "''${args[$i]}" in
        python|fastapi)
          start="$i"
          break
          ;;
      esac
    done
    passthrough=("''${args[@]:$start}")

    case "''${passthrough[0]:-}" in
      python)
        if [ "''${passthrough[1]:-}" != "-m" ] && [[ "''${passthrough[1]:-}" == */scripts/provision_db.py ]]; then
          script="''${passthrough[1]}"
          project="$(dirname "$(dirname "$script")")"
          run_dir="$HOME/e2e-honcho-provision"
          rm -rf "$run_dir"
          mkdir -p "$run_dir"
          cp config.toml "$run_dir/config.toml"
          ln -s "$project/alembic.ini" "$run_dir/alembic.ini"
          ln -s "$project/migrations" "$run_dir/migrations"
          cd "$run_dir"
        fi
        exec ${pythonEnv}/bin/python "''${passthrough[@]:1}"
        ;;
      fastapi)
        host=127.0.0.1
        port=8000
        for ((j = 1; j < ''${#passthrough[@]}; j++)); do
          case "''${passthrough[$j]}" in
            --host)
              host="''${passthrough[$((j + 1))]}"
              ;;
            --port)
              port="''${passthrough[$((j + 1))]}"
              ;;
          esac
        done
        exec ${pythonEnv}/bin/python -m uvicorn src.main:app --host "$host" --port "$port"
        ;;
    esac

    echo "fake uv did not understand: $*" >&2
    exit 64
  '';

in
pkgs.testers.runNixOSTest {
  name = "honcho-real-e2e";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ home-manager.nixosModules.home-manager ];

      virtualisation.memorySize = 4096;
      virtualisation.diskSize = 8192;

      users.users.honcho-e2e = {
        isNormalUser = true;
        home = "/home/honcho-e2e";
        createHome = true;
      };

      environment.systemPackages = [ pkgs.curl ];
      environment.etc = {
        "honcho-e2e/honcho.env".source = honchoEnv;
        "honcho-e2e/tiktoken/fb374d419588a4632f3f557e76b4b70aebbca790".source = o200kBase;
      };

      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.honcho-e2e = {
        imports = [ honchoModule ];

        home.username = "honcho-e2e";
        home.homeDirectory = "/home/honcho-e2e";
        home.stateVersion = "26.05";

        services.honcho = {
          enable = true;
          environmentFiles = [ "/etc/honcho-e2e/honcho.env" ];
          localServices.postgres = true;
          localServices.redis = true;
          uvPackage = fakeUv;
          pythonPackage = pythonEnv;
          settings = {
            app.EMBED_MESSAGES = false;
            deriver.ENABLED = false;
          };
        };
      };

      documentation.enable = lib.mkDefault false;
      documentation.nixos.enable = lib.mkDefault false;
      programs.command-not-found.enable = lib.mkDefault false;
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")

    uid = machine.succeed("id -u honcho-e2e").strip()
    machine.succeed(f"systemctl start user@{uid}.service")
    machine.wait_for_unit(f"user@{uid}.service")

    user_systemctl = f"runuser -u honcho-e2e -- env XDG_RUNTIME_DIR=/run/user/{uid} systemctl --user"

    machine.succeed(f"{user_systemctl} daemon-reload")
    machine.succeed(f"{user_systemctl} start honcho-postgres.service honcho-redis.service")
    machine.wait_until_succeeds(f"{user_systemctl} is-active --quiet honcho-postgres.service")
    machine.wait_until_succeeds(f"{user_systemctl} is-active --quiet honcho-redis.service")
    machine.wait_until_succeeds("${pkgs.redis}/bin/redis-cli -h 127.0.0.1 -p 6380 PING | grep -Fx PONG")

    machine.succeed(f"{user_systemctl} start honcho-setup.service")
    machine.wait_until_succeeds(f"test \"$({user_systemctl} show honcho-setup.service -P Result)\" = success")

    machine.succeed(f"{user_systemctl} start honcho-api.service")
    machine.wait_until_succeeds(f"{user_systemctl} is-active --quiet honcho-api.service", timeout=120)
    machine.wait_until_succeeds("${pkgs.curl}/bin/curl -fsS http://127.0.0.1:24880/health | grep -F '\"ok\"'", timeout=120)

    machine.succeed("""${pkgs.curl}/bin/curl -fsS -X POST http://127.0.0.1:24880/v3/workspaces -H 'Content-Type: application/json' -d '{"id":"vm-e2e"}' | grep -F 'vm-e2e' """)
    machine.succeed("""${pkgs.curl}/bin/curl -fsS -X POST http://127.0.0.1:24880/v3/workspaces/vm-e2e/sessions -H 'Content-Type: application/json' -d '{"id":"smoke"}' | grep -F 'smoke' """)
    machine.succeed("""${pkgs.curl}/bin/curl -fsS -X POST http://127.0.0.1:24880/v3/workspaces/vm-e2e/sessions/smoke/messages -H 'Content-Type: application/json' -d '{"messages":[{"peer_id":"user","content":"hello from nixos vm"}]}' | grep -F 'hello from nixos vm' """)
    machine.succeed("""${pkgs.curl}/bin/curl -fsS -X POST http://127.0.0.1:24880/v3/workspaces/vm-e2e/sessions/smoke/messages/list -H 'Content-Type: application/json' -d '{}' | grep -F 'hello from nixos vm' """)

    machine.succeed(f"{user_systemctl} restart honcho-api.service")
    machine.wait_until_succeeds(f"{user_systemctl} is-active --quiet honcho-api.service", timeout=120)
    machine.wait_until_succeeds("${pkgs.curl}/bin/curl -fsS http://127.0.0.1:24880/docs | grep -F 'Honcho API'", timeout=120)

    machine.succeed(f"{user_systemctl} stop honcho-api.service honcho-postgres.service honcho-redis.service")
  '';
}
