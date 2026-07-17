{
  description = "Home Manager module for declarative Hermes Agent configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      eachSystem = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
    in
    {
      homeManagerModules = {
        default = self.homeManagerModules.hermes-agent;
        hermes-agent = import ./modules/hermes-agent/home-manager.nix;
        honcho = import ./modules/honcho/home-manager.nix;
      };

      checks = eachSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;
          basicConfig = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeManagerModules.default
              ./tests/basic-home.nix
            ];
          };
          executableOnlyConfig = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeManagerModules.default
              ./tests/executable-only-home.nix
            ];
          };
          nonGatewayConfig = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeManagerModules.default
              ./tests/non-gateway-home.nix
            ];
          };
          activationPathsConfig = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeManagerModules.default
              ./tests/activation-paths-home.nix
            ];
          };
          managedCleanupConfig = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeManagerModules.default
              ./tests/managed-cleanup-home.nix
            ];
          };
          unsafePythonPathConfig = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeManagerModules.default
              ./tests/unsafe-pythonpath-home.nix
            ];
          };
          unsafePythonPathEvaluation = builtins.tryEval unsafePythonPathConfig.activationPackage.drvPath;
          honchoConfig = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeManagerModules.honcho
              ./tests/honcho-home.nix
            ];
          };
          honchoApiExecStart = builtins.elemAt honchoConfig.config.systemd.user.services.honcho-api.Service.ExecStart 0;
          honchoSetupExecStart = builtins.elemAt honchoConfig.config.systemd.user.services.honcho-setup.Service.ExecStart 0;
          honchoPostgresExecStart =
            honchoConfig.config.systemd.user.services.honcho-postgres.Service.ExecStart;
          honchoRedisExecStart = honchoConfig.config.systemd.user.services.honcho-redis.Service.ExecStart;
          honchoApiEnvironment = builtins.toJSON honchoConfig.config.systemd.user.services.honcho-api.Service.Environment;
          honchoApiAfter = builtins.toJSON honchoConfig.config.systemd.user.services.honcho-api.Unit.After;
          honchoEnvironmentFile = builtins.toJSON honchoConfig.config.systemd.user.services.honcho-api.Service.EnvironmentFile;
          basicExecStart = builtins.toJSON basicConfig.config.systemd.user.services.hermes-gateway.Service.ExecStart;
          basicUnsetEnvironment = builtins.toJSON (
            basicConfig.config.systemd.user.services.hermes-gateway.Service.UnsetEnvironment or [ ]
          );
          hermesAgentVmTest = import ./tests/vm-hermes-agent.nix {
            inherit pkgs home-manager;
            hermesModule = self.homeManagerModules.default;
            honchoModule = self.homeManagerModules.honcho;
          };
          hermesStatefulMigrationVmTest = import ./tests/vm-hermes-stateful-migration.nix {
            inherit pkgs home-manager;
            hermesModule = self.homeManagerModules.default;
          };
          honchoE2eVmTest = import ./tests/vm-honcho-e2e.nix {
            inherit pkgs home-manager;
            honchoModule = self.homeManagerModules.honcho;
          };
        in
        {
          config-merge = import ./tests/config-merge.nix { inherit pkgs; };
          activation-paths = activationPathsConfig.activationPackage;
          managed-cleanup = pkgs.runCommand "hermes-managed-cleanup-check" { } ''
            activate=${managedCleanupConfig.activationPackage}/activate
            grep -F -- 'rm -f "$hermes_home/config.yaml"' "$activate"
            grep -F -- 'rm -f "$hermes_home/.env"' "$activate"
            grep -F -- 'rm -f "$hermes_home/gateway_voice_mode.json"' "$activate"
            grep -F -- 'nix-managed-*' "$activate"
            touch "$out"
          '';
          unsafe-pythonpath-rejected = pkgs.runCommand "hermes-unsafe-pythonpath-rejected-check" { } ''
            ${
              if unsafePythonPathEvaluation.success then
                ''
                  echo "expected service.environment.PYTHONPATH evaluation to fail" >&2
                  exit 1
                ''
              else
                ''
                  touch "$out"
                ''
            }
          '';
        }
        // lib.optionalAttrs pkgs.stdenv.isLinux {
          honcho-home = honchoConfig.activationPackage;
          honcho-api-execstart = pkgs.runCommand "honcho-api-execstart-check" { } ''
            grep -F -- 'uv run --project' ${lib.escapeShellArg honchoApiExecStart}
            grep -F -- '--frozen --no-sync --no-group dev fastapi run --host 127.0.0.1 --port 24880' ${lib.escapeShellArg honchoApiExecStart}
            grep -F -- '/src/main.py' ${lib.escapeShellArg honchoApiExecStart}
            case ${lib.escapeShellArg honchoPostgresExecStart} in
              *"postgres"*"-p 55432"*) ;;
              *)
                echo "unexpected postgres ExecStart: ${lib.escapeShellArg honchoPostgresExecStart}" >&2
                exit 1
                ;;
            esac
            case ${lib.escapeShellArg honchoRedisExecStart} in
              *"redis-server"*"--port 6380"*) ;;
              *)
                echo "unexpected redis ExecStart: ${lib.escapeShellArg honchoRedisExecStart}" >&2
                exit 1
                ;;
            esac
            grep -F -- 'CREATE EXTENSION IF NOT EXISTS vector' ${lib.escapeShellArg honchoSetupExecStart}
            grep -F -- 'scripts/provision_db.py' ${lib.escapeShellArg honchoSetupExecStart}
            case ${lib.escapeShellArg honchoApiAfter} in
              *"honcho-postgres.service"*"honcho-redis.service"*) ;;
              *)
                echo "unexpected honcho-api After: ${lib.escapeShellArg honchoApiAfter}" >&2
                exit 1
                ;;
            esac
            case ${lib.escapeShellArg honchoApiEnvironment} in
              *"PYTHON_DOTENV_DISABLED=1"*"UV_PROJECT_ENVIRONMENT=/tmp/honcho-home-test/.local/share/honcho/.venv"*) ;;
              *)
                echo "unexpected honcho runtime env: ${lib.escapeShellArg honchoApiEnvironment}" >&2
                exit 1
                ;;
            esac
            case ${lib.escapeShellArg honchoEnvironmentFile} in
              *"/run/secrets/honcho.env"*) touch "$out" ;;
              *)
                echo "unexpected EnvironmentFile: ${lib.escapeShellArg honchoEnvironmentFile}" >&2
                exit 1
                ;;
            esac
          '';
          basic = basicConfig.activationPackage;
          executable-only = executableOnlyConfig.activationPackage;
          gateway-execstart = pkgs.runCommand "hermes-gateway-execstart-check" { } ''
            case ${lib.escapeShellArg basicExecStart} in
              *"/bin/hermes gateway run --replace"*) touch "$out" ;;
              *)
                echo "unexpected ExecStart: ${lib.escapeShellArg basicExecStart}" >&2
                exit 1
                ;;
            esac
          '';
          gateway-python-environment-sanitized =
            pkgs.runCommand "hermes-gateway-python-environment-sanitized-check" { }
              ''
                case ${lib.escapeShellArg basicUnsetEnvironment} in
                  *"PYTHONPATH"*"PYTHONHOME"*) touch "$out" ;;
                  *)
                    echo "gateway must unset ambient PYTHONPATH and PYTHONHOME: ${lib.escapeShellArg basicUnsetEnvironment}" >&2
                    exit 1
                    ;;
                esac
              '';
          document-path-quoting = pkgs.runCommand "hermes-document-path-quoting-check" { } ''
            grep -F -- ${lib.escapeShellArg "'/tmp/hermes-home-test/.hermes/notes/shell $(safe).md'"} ${basicConfig.activationPackage}/activate
            touch "$out"
          '';
          gateway-activation-preflight = pkgs.runCommand "hermes-gateway-activation-preflight-check" { } ''
            activate=${basicConfig.activationPackage}/activate
            check_script="$(${pkgs.gnugrep}/bin/grep -o '/nix/store/[^ ]*-hermes-gateway-activation-check' "$activate")"
            test -x "$check_script"
            grep -F -- 'HERMES_PYTHON_SRC_ROOT' "$check_script"
            grep -F -- 'pydantic_core._pydantic_core' "$check_script"
            grep -F -- 'from run_agent import OpenAI' "$check_script"
            grep -F -- 'hermes-home-activation-check' "$check_script"
            touch "$out"
          '';
          vm-hermes-agent = hermesAgentVmTest;
          vm-hermes-stateful-migration = hermesStatefulMigrationVmTest;
          vm-honcho-e2e = honchoE2eVmTest;
        }
        // lib.optionalAttrs (!pkgs.stdenv.isLinux) {
          non-gateway = nonGatewayConfig.activationPackage;
        }
      );

      formatter = eachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
