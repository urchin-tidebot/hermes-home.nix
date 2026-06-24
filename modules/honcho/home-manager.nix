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

  postgresPackage = cfg.postgres.package.withPackages (ps: [ ps.pgvector ]);
  postgresBin = name: lib.getExe' postgresPackage name;
  postgresDataDir = "${cfg.dataDir}/postgres";
  postgresRunDir = "${cfg.dataDir}/run/postgres";
  redisDataDir = "${cfg.dataDir}/redis";

  managedDatabaseUri = "postgresql+psycopg://${cfg.postgres.user}@${cfg.postgres.host}:${toString cfg.postgres.port}/${cfg.postgres.database}";
  databaseUri = if cfg.postgres.enable then managedDatabaseUri else cfg.databaseUri;
  managedCacheUrl = "redis://${cfg.redis.host}:${toString cfg.redis.port}/0?suppress=true";
  cacheUrl = if cfg.redis.enable then managedCacheUrl else cfg.cache.url;

  generatedSettings = {
    app = {
      LOG_LEVEL = cfg.logLevel;
      NAMESPACE = cfg.namespace;
      EMBED_MESSAGES = cfg.embedMessages;
    };

    db.CONNECTION_URI = databaseUri;

    auth.USE_AUTH = cfg.authUseAuth;

    cache = {
      ENABLED = cfg.cache.enable;
      URL = cacheUrl;
    };

    vector_store = {
      TYPE = "pgvector";
      NAMESPACE = cfg.namespace;
    };

    deriver = {
      ENABLED = cfg.deriver.enable;
      WORKERS = cfg.deriver.workers;
      FLUSH_ENABLED = cfg.deriver.flush.enable;
    };
  };

  renderedSettings = lib.recursiveUpdate generatedSettings cfg.settings;
  generatedConfig = toml.generate "honcho-config.toml" renderedSettings;
  configDir = builtins.dirOf cfg.configPath;

  uv = lib.getExe pkgs.uv;
  python = lib.getExe cfg.pythonPackage;
  runtimeEnvironment = {
    HOME = cfg.dataDir;
    PYTHONUNBUFFERED = "1";
    PYTHON_DOTENV_DISABLED = "1";
    UV_CACHE_DIR = "${cfg.cacheDir}/uv";
    UV_PROJECT_ENVIRONMENT = "${cfg.dataDir}/.venv";
    UV_PYTHON = python;
    UV_PYTHON_DOWNLOADS = "never";
    UV_LINK_MODE = "copy";
    LD_LIBRARY_PATH = lib.makeLibraryPath cfg.runtimeLibraries;
  }
  // cfg.environment;
  environmentList = lib.mapAttrsToList (name: value: "${name}=${toString value}") runtimeEnvironment;

  managedServiceUnits =
    lib.optional cfg.postgres.enable "honcho-postgres.service"
    ++ lib.optional cfg.redis.enable "honcho-redis.service";
  setupDeps = cfg.setup.after ++ managedServiceUnits;
  appDeps = managedServiceUnits ++ lib.optional cfg.setup.enable "honcho-setup.service";

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

    namespace = mkOption {
      type = types.str;
      default = "honcho";
      description = "Namespace written to Honcho app/vector-store configuration.";
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

    settings = mkOption {
      type = toml.type;
      default = { };
      description = ''
        Additional Honcho config.toml settings, recursively merged over module
        defaults. Values are rendered into the Nix store, so use
        environmentFiles for provider API keys and other secrets.
      '';
      example = literalExpression ''
        {
          app.LOG_LEVEL = "DEBUG";
          dialectic.MAX_OUTPUT_TOKENS = 4096;
          deriver.model_config = {
            transport = "openai";
            model = "gpt-5.4-mini";
          };
        }
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

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Extra non-secret environment variables for Honcho services. These are
        rendered through Nix and are not secret-safe.
      '';
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

    databaseUri = mkOption {
      type = types.str;
      default = "postgresql+psycopg://postgres:postgres@localhost:5432/postgres";
      description = ''
        SQLAlchemy PostgreSQL URI used when services.honcho.postgres.enable is
        false. Managed PostgreSQL derives a URI from postgres.* options.
      '';
    };

    postgres = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Run a per-user PostgreSQL service with pgvector available.";
      };

      package = mkOption {
        type = types.package;
        default = pkgs.postgresql;
        defaultText = literalExpression "pkgs.postgresql";
        description = "PostgreSQL package; pgvector is added with withPackages.";
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "PostgreSQL listen address for the managed service.";
      };

      port = mkOption {
        type = types.port;
        default = 55432;
        description = "PostgreSQL listen port for the managed service.";
      };

      database = mkOption {
        type = types.str;
        default = "honcho";
        description = "Database created by honcho-setup for managed PostgreSQL.";
      };

      user = mkOption {
        type = types.str;
        default = "honcho";
        description = "Database role created by honcho-setup for managed PostgreSQL.";
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional arguments passed to postgres.";
      };
    };

    redis = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Run a per-user Redis service for Honcho cache support.";
      };

      package = mkOption {
        type = types.package;
        default = pkgs.redis;
        defaultText = literalExpression "pkgs.redis";
        description = "Redis package used by the managed service.";
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Redis bind address for the managed service.";
      };

      port = mkOption {
        type = types.port;
        default = 6380;
        description = "Redis listen port for the managed service.";
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional arguments passed to redis-server.";
      };
    };

    pythonPackage = mkOption {
      type = types.package;
      default = pkgs.python313;
      defaultText = literalExpression "pkgs.python313";
      description = "Python interpreter supplied to uv through UV_PYTHON.";
    };

    runtimeLibraries = mkOption {
      type = types.listOf types.package;
      default = [ pkgs.stdenv.cc.cc ];
      defaultText = literalExpression "[ pkgs.stdenv.cc.cc ]";
      description = "Libraries added to LD_LIBRARY_PATH for Honcho runtime.";
    };

    logLevel = mkOption {
      type = types.str;
      default = "INFO";
      description = "Honcho app.LOG_LEVEL value.";
    };

    authUseAuth = mkOption {
      type = types.bool;
      default = false;
      description = "Honcho auth.USE_AUTH value.";
    };

    embedMessages = mkOption {
      type = types.bool;
      default = true;
      description = "Honcho app.EMBED_MESSAGES value.";
    };

    setup = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Run a one-shot service to sync the uv environment and provision the database.";
      };

      after = mkOption {
        type = types.listOf types.str;
        default = [ "network-online.target" ];
        description = "Additional units ordered before honcho-setup.";
      };
    };

    cache = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Honcho cache.ENABLED value.";
      };

      url = mkOption {
        type = types.str;
        default = "redis://127.0.0.1:6380/0?suppress=true";
        description = "Honcho cache.URL value when the managed Redis service is disabled.";
      };
    };

    deriver = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Honcho deriver.ENABLED value and honcho-deriver unit toggle.";
      };

      workers = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Honcho deriver.WORKERS value.";
      };

      flush.enable = mkOption {
        type = types.bool;
        default = true;
        description = "Honcho deriver.FLUSH_ENABLED value.";
      };
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
      ${optionalString cfg.postgres.enable ''
        $DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg postgresDataDir}
        $DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg postgresRunDir}
      ''}
      ${optionalString cfg.redis.enable ''
        $DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg redisDataDir}
      ''}
    '';

    systemd.user.services = {
      honcho-postgres = mkIf cfg.postgres.enable {
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
              printf '%s\n' ${lib.escapeShellArg "host all all ${cfg.postgres.host}/32 trust"} >> ${lib.escapeShellArg postgresDataDir}/pg_hba.conf
            fi
          '';
          ExecStart = lib.escapeShellArgs (
            [
              (postgresBin "postgres")
              "-D"
              postgresDataDir
              "-k"
              postgresRunDir
              "-h"
              cfg.postgres.host
              "-p"
              (toString cfg.postgres.port)
            ]
            ++ cfg.postgres.extraArgs
          );
          Restart = "on-failure";
          RestartSec = "5s";
        };
        Install.WantedBy = [ "default.target" ];
      };

      honcho-redis = mkIf cfg.redis.enable {
        Unit.Description = "Honcho Redis cache";
        Service = {
          Type = "simple";
          ExecStartPre = pkgs.writeShellScript "honcho-redis-prepare" ''
            set -euo pipefail
            install -d -m 700 ${lib.escapeShellArg redisDataDir}
          '';
          ExecStart = lib.escapeShellArgs (
            [
              (lib.getExe' cfg.redis.package "redis-server")
              "--bind"
              cfg.redis.host
              "--port"
              (toString cfg.redis.port)
              "--dir"
              redisDataDir
              "--daemonize"
              "no"
              "--protected-mode"
              "yes"
              "--save"
              ""
            ]
            ++ cfg.redis.extraArgs
          );
          Restart = "on-failure";
          RestartSec = "5s";
        };
        Install.WantedBy = [ "default.target" ];
      };

      honcho-setup = mkIf cfg.setup.enable (mkHonchoService {
        Unit = {
          Description = "Prepare Honcho virtualenv and database";
          After = setupDeps;
          Requires = managedServiceUnits;
        };
        Service = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "honcho-setup" ''
            set -euo pipefail
            ${optionalString cfg.postgres.enable ''
              export PGHOST=${lib.escapeShellArg postgresRunDir}
              export PGPORT=${toString cfg.postgres.port}
              until ${postgresBin "pg_isready"} -q -d postgres; do
                sleep 1
              done
              if ! ${postgresBin "psql"} -d postgres -tAc ${lib.escapeShellArg "SELECT 1 FROM pg_roles WHERE rolname='${cfg.postgres.user}'"} | grep -qx 1; then
                ${postgresBin "createuser"} ${lib.escapeShellArg cfg.postgres.user}
              fi
              if ! ${postgresBin "psql"} -d postgres -tAc ${lib.escapeShellArg "SELECT 1 FROM pg_database WHERE datname='${cfg.postgres.database}'"} | grep -qx 1; then
                ${postgresBin "createdb"} --owner=${lib.escapeShellArg cfg.postgres.user} ${lib.escapeShellArg cfg.postgres.database}
              fi
              ${postgresBin "psql"} -d ${lib.escapeShellArg cfg.postgres.database} -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS vector;'
            ''}
            ${uv} run --project ${lib.escapeShellArg cfg.source} --frozen --no-group dev python ${lib.escapeShellArg cfg.source}/scripts/provision_db.py
          '';
        };
      });

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

      honcho-deriver = mkIf cfg.deriver.enable (mkHonchoService {
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
      });
    };
  };
}
