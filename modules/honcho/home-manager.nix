{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.honcho;
  toml = pkgs.formats.toml { };
  honchoPkg = import ./honcho-pkg.nix { inherit pkgs; };

  inherit (lib)
    literalExpression
    mkEnableOption
    mkIf
    mkOption
    optionalAttrs
    optionalString
    types
    ;

  postgresPackage = pkgs.postgresql.withPackages (ps: [ ps.pgvector ]);
  postgresBin = name: lib.getExe' postgresPackage name;
  postgresHost = "127.0.0.1";
  postgresPort = 55432;
  postgresUser = "honcho";
  postgresDatabase = "honcho";
  postgresDataDir = "${cfg.dataDir}/postgres";
  postgresRunDir = "${cfg.dataDir}/run/postgres";

  redisHost = "127.0.0.1";
  redisPort = 6380;
  redisDataDir = "${cfg.dataDir}/redis";

  localPostgres = cfg.localServices.postgres;
  localRedis = cfg.localServices.redis;
  databaseUri =
    if localPostgres then
      "postgresql+psycopg://${postgresUser}@${postgresHost}:${toString postgresPort}/${postgresDatabase}"
    else
      "postgresql+psycopg://postgres:postgres@localhost:5432/postgres";
  cacheUrl =
    if localRedis then
      "redis://${redisHost}:${toString redisPort}/0?suppress=true"
    else
      "redis://localhost:6379/0?suppress=true";

  moduleSettings = {
    app = {
      LOG_LEVEL = "INFO";
      NAMESPACE = "honcho";
      EMBED_MESSAGES = true;
    };

    db.CONNECTION_URI = databaseUri;
    auth.USE_AUTH = false;

    cache = {
      ENABLED = localRedis;
      URL = cacheUrl;
    };

    deriver = {
      ENABLED = true;
      WORKERS = 1;
      FLUSH_ENABLED = true;
    };

    vector_store = {
      TYPE = "pgvector";
      NAMESPACE = "honcho";
    };
  };

  renderedSettings = lib.recursiveUpdate moduleSettings cfg.settings;
  generatedConfig = toml.generate "honcho-config.toml" renderedSettings;
  configDir = builtins.dirOf cfg.configPath;

  uv = lib.getExe cfg.uvPackage;
  python = lib.getExe cfg.pythonPackage;
  runtimeEnvironment = {
    HOME = cfg.dataDir;
    PYTHONUNBUFFERED = "1";
    PYTHON_DOTENV_DISABLED = "1";
    PYTHONPATH = cfg.source;
    UV_CACHE_DIR = "${cfg.cacheDir}/uv";
    UV_PROJECT_ENVIRONMENT = "${cfg.dataDir}/.venv";
    UV_PYTHON = python;
    UV_PYTHON_DOWNLOADS = "never";
    UV_LINK_MODE = "copy";
    LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.stdenv.cc.cc ];
  };
  environmentList = lib.mapAttrsToList (name: value: "${name}=${toString value}") runtimeEnvironment;

  managedServiceUnits =
    lib.optional localPostgres "honcho-postgres.service"
    ++ lib.optional localRedis "honcho-redis.service";
  appDeps = managedServiceUnits ++ [ "honcho-setup.service" ];

  mkHonchoService = extra: {
    Unit = extra.Unit or { };
    Service = {
      Type = "simple";
      WorkingDirectory = configDir;
      Environment = environmentList;
      UMask = "0077";
    }
    // optionalAttrs (cfg.environmentFiles != [ ]) { EnvironmentFile = cfg.environmentFiles; }
    // (extra.Service or { });
    Install = extra.Install or { WantedBy = [ "default.target" ]; };
  };
in
{
  options.services.honcho = {
    enable = mkEnableOption "Plastic Labs Honcho user services";

    source = mkOption {
      type = types.path;
      default = honchoPkg.src;
      defaultText = literalExpression "(import ./honcho-pkg.nix { inherit pkgs; }).src";
      description = "Pinned Honcho source tree used as the uv project.";
    };

    configPath = mkOption {
      type = types.str;
      default = "${config.xdg.configHome}/honcho/config.toml";
      defaultText = literalExpression ''"''${config.xdg.configHome}/honcho/config.toml"'';
      description = ''
        Runtime Honcho TOML config path. The module writes this file at
        activation time and starts Honcho from its containing directory because
        Honcho loads config.toml from the current working directory.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "${config.xdg.dataHome}/honcho";
      defaultText = literalExpression ''"''${config.xdg.dataHome}/honcho"'';
      description = "Persistent Honcho state directory.";
    };

    cacheDir = mkOption {
      type = types.str;
      default = "${config.xdg.cacheHome}/honcho";
      defaultText = literalExpression ''"''${config.xdg.cacheHome}/honcho"'';
      description = "Honcho cache directory, including uv cache.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address for the Honcho API service.";
    };

    port = mkOption {
      type = types.port;
      default = 24880;
      description = "Port for the Honcho API service.";
    };

    environmentFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "/run/secrets/honcho.env" ];
      description = ''
        Runtime environment files passed to Honcho services. Use these for API
        keys and other secrets; paths are strings consumed by systemd at runtime.
      '';
    };

    uvPackage = mkOption {
      type = types.package;
      default = pkgs.uv;
      internal = true;
      visible = false;
      description = "uv package used by tests to inject a deterministic runner.";
    };

    pythonPackage = mkOption {
      type = types.package;
      default = pkgs.python313;
      internal = true;
      visible = false;
      description = "Python package used by tests to inject a deterministic runtime.";
    };

    localServices = {
      postgres = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Run a local per-user PostgreSQL service with pgvector and point Honcho
          at it. The service listens on 127.0.0.1:${toString postgresPort} and
          stores state under services.honcho.dataDir.
        '';
      };

      redis = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Run a local per-user Redis service and enable Honcho cache support.
          The service listens on 127.0.0.1:${toString redisPort} and stores
          state under services.honcho.dataDir.
        '';
      };
    };

    settings = mkOption {
      type = toml.type;
      default = { };
      description = ''
        Additional Honcho config.toml settings, recursively merged over the
        module's opinionated defaults. Values are rendered into the Nix store,
        so use environmentFiles for provider API keys and other secrets.
      '';
      example = literalExpression ''
        {
          llm.ANTHROPIC_BASE_URL = "https://api.example.invalid/anthropic";
          dialectic.MAX_OUTPUT_TOKENS = 4096;
          embedding.model_config.overrides.base_url = "https://embedding.example.invalid/v1";
        }
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.isLinux;
        message = "services.honcho currently requires Linux/systemd user services.";
      }
      {
        assertion = lib.hasSuffix "/config.toml" cfg.configPath;
        message = "services.honcho.configPath must end with /config.toml because Honcho loads config.toml from its working directory.";
      }
    ];

    home.activation.honchoRuntime = config.lib.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg cfg.dataDir}
      $DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg cfg.cacheDir}
      $DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg configDir}
      $DRY_RUN_CMD install -m 600 ${lib.escapeShellArg generatedConfig} ${lib.escapeShellArg cfg.configPath}
      ${optionalString localPostgres ''
        $DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg postgresDataDir}
        $DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg postgresRunDir}
      ''}
      ${optionalString localRedis ''
        $DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg redisDataDir}
      ''}
    '';

    systemd.user.services = {
      honcho-postgres = mkIf localPostgres {
        Unit.Description = "Honcho PostgreSQL database";
        Service = {
          Type = "simple";
          Environment = [ "PGHOST=${postgresRunDir}" ];
          ExecStartPre = pkgs.writeShellScript "honcho-postgres-prepare" ''
            set -euo pipefail
            install -d -m 700 ${lib.escapeShellArg postgresDataDir}
            install -d -m 700 ${lib.escapeShellArg postgresRunDir}
            if [ ! -e ${lib.escapeShellArg postgresDataDir}/PG_VERSION ]; then
              ${postgresBin "initdb"} -D ${lib.escapeShellArg postgresDataDir} --auth=trust --no-locale --encoding=UTF8
              printf '%s\n' ${lib.escapeShellArg "host all all ${postgresHost}/32 trust"} >> ${lib.escapeShellArg postgresDataDir}/pg_hba.conf
            fi
          '';
          ExecStart = lib.escapeShellArgs [
            (postgresBin "postgres")
            "-D"
            postgresDataDir
            "-k"
            postgresRunDir
            "-h"
            postgresHost
            "-p"
            (toString postgresPort)
          ];
          Restart = "on-failure";
          RestartSec = "5s";
        };
        Install.WantedBy = [ "default.target" ];
      };

      honcho-redis = mkIf localRedis {
        Unit.Description = "Honcho Redis cache";
        Service = {
          Type = "simple";
          ExecStartPre = pkgs.writeShellScript "honcho-redis-prepare" ''
            set -euo pipefail
            install -d -m 700 ${lib.escapeShellArg redisDataDir}
          '';
          ExecStart = lib.escapeShellArgs [
            (lib.getExe' pkgs.redis "redis-server")
            "--bind"
            redisHost
            "--port"
            (toString redisPort)
            "--dir"
            redisDataDir
            "--daemonize"
            "no"
            "--protected-mode"
            "yes"
            "--save"
            ""
          ];
          Restart = "on-failure";
          RestartSec = "5s";
        };
        Install.WantedBy = [ "default.target" ];
      };

      honcho-setup = mkHonchoService {
        Unit = {
          Description = "Prepare Honcho virtualenv and database";
          After = managedServiceUnits;
          Requires = managedServiceUnits;
        };
        Service = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "honcho-setup" ''
            set -euo pipefail
            ${optionalString localPostgres ''
              export PGHOST=${lib.escapeShellArg postgresRunDir}
              export PGPORT=${toString postgresPort}
              until ${postgresBin "pg_isready"} -q -d postgres; do
                sleep 1
              done
              if ! ${postgresBin "psql"} -d postgres -tAc ${lib.escapeShellArg "SELECT 1 FROM pg_roles WHERE rolname='${postgresUser}'"} | grep -qx 1; then
                ${postgresBin "createuser"} ${lib.escapeShellArg postgresUser}
              fi
              if ! ${postgresBin "psql"} -d postgres -tAc ${lib.escapeShellArg "SELECT 1 FROM pg_database WHERE datname='${postgresDatabase}'"} | grep -qx 1; then
                ${postgresBin "createdb"} --owner=${lib.escapeShellArg postgresUser} ${lib.escapeShellArg postgresDatabase}
              fi
              ${postgresBin "psql"} -d ${lib.escapeShellArg postgresDatabase} -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS vector;'
            ''}
            ${uv} run --project ${lib.escapeShellArg cfg.source} --frozen --no-group dev python ${lib.escapeShellArg cfg.source}/scripts/provision_db.py
          '';
        };
      };

      honcho-api = mkHonchoService {
        Unit = {
          Description = "Honcho API";
          After = appDeps;
          Requires = appDeps;
        };
        Service = {
          Restart = "on-failure";
          RestartSec = "5s";
          ExecStart = pkgs.writeShellScript "honcho-api" ''
            exec ${uv} run --project ${lib.escapeShellArg cfg.source} --frozen --no-sync --no-group dev fastapi run --host ${lib.escapeShellArg cfg.host} --port ${toString cfg.port} ${lib.escapeShellArg cfg.source}/src/main.py
          '';
        };
      };

      honcho-deriver = mkHonchoService {
        Unit = {
          Description = "Honcho background deriver";
          After = appDeps;
          Requires = appDeps;
        };
        Service = {
          Restart = "on-failure";
          RestartSec = "5s";
          ExecStart = pkgs.writeShellScript "honcho-deriver" ''
            exec ${uv} run --project ${lib.escapeShellArg cfg.source} --frozen --no-sync --no-group dev python -m src.deriver
          '';
        };
      };
    };
  };
}
