# Adopted from suderman/nixos modules/nixos/default/options/honcho.nix.
# Source repository does not currently declare a license; keep this attribution
# with any derived versions of this module.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.honcho;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    optionalAttrs
    types
    ;

  honchoPkg = import ./honcho-pkg.nix { inherit pkgs; };

  llmTransports = [
    "openai"
    "anthropic"
    "gemini"
  ];
  embeddingTransports = [
    "openai"
    "gemini"
  ];

  thinkingEnvironment =
    if cfg.llm.transport == "openai" then
      {
        DERIVER_MODEL_CONFIG__THINKING_EFFORT = "minimal";
        SUMMARY_MODEL_CONFIG__THINKING_EFFORT = "minimal";
        DREAM_DEDUCTION_MODEL_CONFIG__THINKING_EFFORT = "minimal";
        DREAM_INDUCTION_MODEL_CONFIG__THINKING_EFFORT = "minimal";
        DIALECTIC_LEVELS__minimal__MODEL_CONFIG__THINKING_EFFORT = "minimal";
        DIALECTIC_LEVELS__low__MODEL_CONFIG__THINKING_EFFORT = "minimal";
        DIALECTIC_LEVELS__medium__MODEL_CONFIG__THINKING_EFFORT = "minimal";
        DIALECTIC_LEVELS__high__MODEL_CONFIG__THINKING_EFFORT = "minimal";
        DIALECTIC_LEVELS__max__MODEL_CONFIG__THINKING_EFFORT = "minimal";
      }
    else
      {
        DERIVER_MODEL_CONFIG__THINKING_BUDGET_TOKENS = "0";
        SUMMARY_MODEL_CONFIG__THINKING_BUDGET_TOKENS = "0";
        DREAM_DEDUCTION_MODEL_CONFIG__THINKING_BUDGET_TOKENS = "0";
        DREAM_INDUCTION_MODEL_CONFIG__THINKING_BUDGET_TOKENS = "0";
        DIALECTIC_LEVELS__minimal__MODEL_CONFIG__THINKING_BUDGET_TOKENS = "0";
        DIALECTIC_LEVELS__low__MODEL_CONFIG__THINKING_BUDGET_TOKENS = "0";
        DIALECTIC_LEVELS__medium__MODEL_CONFIG__THINKING_BUDGET_TOKENS = "0";
        DIALECTIC_LEVELS__high__MODEL_CONFIG__THINKING_BUDGET_TOKENS = "0";
        DIALECTIC_LEVELS__max__MODEL_CONFIG__THINKING_BUDGET_TOKENS = "0";
      };

  managedDatabaseUri = "postgresql+psycopg://${cfg.postgres.user}@${cfg.postgres.host}:${toString cfg.postgres.port}/${cfg.postgres.database}";
  effectiveDatabaseUri = if cfg.postgres.enable then managedDatabaseUri else cfg.databaseUri;

  managedCacheUrl = "redis://${cfg.redis.host}:${toString cfg.redis.port}/0?suppress=true";
  effectiveCacheUrl = if cfg.redis.enable then managedCacheUrl else cfg.cache.url;

  serviceEnvironment = {
    # Python / uv
    PYTHONUNBUFFERED = "1";
    PYTHON_DOTENV_DISABLED = "1";
    UV_CACHE_DIR = "${cfg.cacheDir}/uv";
    UV_PROJECT_ENVIRONMENT = "${cfg.dataDir}/.venv";
    UV_PYTHON = lib.getExe cfg.pythonPackage;
    UV_PYTHON_DOWNLOADS = "never";
    UV_LINK_MODE = "copy";
    LD_LIBRARY_PATH = lib.makeLibraryPath cfg.runtimeLibraries;

    # App
    HOME = cfg.dataDir;
    NAMESPACE = cfg.namespace;
    LOG_LEVEL = cfg.logLevel;
    AUTH_USE_AUTH = lib.boolToString cfg.authUseAuth;
    METRICS_ENABLED = lib.boolToString cfg.metrics.enable;

    # PostgreSQL database with pgvector support. The psycopg prefix is
    # required by SQLAlchemy.
    DB_CONNECTION_URI = effectiveDatabaseUri;
    VECTOR_STORE_TYPE = "pgvector";

    # Redis cache
    CACHE_ENABLED = lib.boolToString cfg.cache.enable;
    CACHE_URL = effectiveCacheUrl;

    # Embedding
    EMBED_MESSAGES = lib.boolToString cfg.embeddings.enable;
    EMBEDDING_MODEL_CONFIG__TRANSPORT = cfg.embeddings.transport;
    EMBEDDING_MODEL_CONFIG__MODEL = cfg.embeddings.model;
    EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL = cfg.embeddings.baseUrl;
    EMBEDDING_MODEL_CONFIG__OVERRIDES__API_KEY_ENV = cfg.embeddings.apiKeyEnv;

    # Deriver (background worker)
    DERIVER_ENABLED = lib.boolToString cfg.deriver.enable;
    DERIVER_WORKERS = toString cfg.deriver.workers;
    DERIVER_FLUSH_ENABLED = lib.boolToString cfg.deriver.flush.enable;
    DERIVER_MODEL_CONFIG__TRANSPORT = cfg.llm.transport;
    DERIVER_MODEL_CONFIG__MODEL = cfg.llm.model;
    DERIVER_MODEL_CONFIG__OVERRIDES__BASE_URL = cfg.llm.baseUrl;
    DERIVER_MODEL_CONFIG__OVERRIDES__API_KEY_ENV = cfg.llm.apiKeyEnv;

    # Peer Card
    PEER_CARD_ENABLED = lib.boolToString cfg.peerCard.enable;

    # Summary
    SUMMARY_ENABLED = lib.boolToString cfg.summary.enable;
    SUMMARY_MODEL_CONFIG__TRANSPORT = cfg.llm.transport;
    SUMMARY_MODEL_CONFIG__MODEL = cfg.llm.model;
    SUMMARY_MODEL_CONFIG__OVERRIDES__BASE_URL = cfg.llm.baseUrl;
    SUMMARY_MODEL_CONFIG__OVERRIDES__API_KEY_ENV = cfg.llm.apiKeyEnv;

    # Dream
    DREAM_ENABLED = lib.boolToString cfg.dream.enable;
    DREAM_SURPRISAL__ENABLED = lib.boolToString cfg.dream.surprisal.enable;
    DREAM_IDLE_TIMEOUT_MINUTES = toString cfg.dream.idleTimeoutMinutes;
    DREAM_MIN_HOURS_BETWEEN_DREAMS = toString cfg.dream.minHoursBetweenDreams;

    DREAM_DEDUCTION_MODEL_CONFIG__TRANSPORT = cfg.llm.transport;
    DREAM_DEDUCTION_MODEL_CONFIG__MODEL = cfg.llm.model;
    DREAM_DEDUCTION_MODEL_CONFIG__OVERRIDES__BASE_URL = cfg.llm.baseUrl;
    DREAM_DEDUCTION_MODEL_CONFIG__OVERRIDES__API_KEY_ENV = cfg.llm.apiKeyEnv;

    DREAM_INDUCTION_MODEL_CONFIG__TRANSPORT = cfg.llm.transport;
    DREAM_INDUCTION_MODEL_CONFIG__MODEL = cfg.llm.model;
    DREAM_INDUCTION_MODEL_CONFIG__OVERRIDES__BASE_URL = cfg.llm.baseUrl;
    DREAM_INDUCTION_MODEL_CONFIG__OVERRIDES__API_KEY_ENV = cfg.llm.apiKeyEnv;

    # Dialectic levels
    DIALECTIC_LEVELS__minimal__MODEL_CONFIG__TRANSPORT = cfg.llm.transport;
    DIALECTIC_LEVELS__minimal__MODEL_CONFIG__MODEL = cfg.llm.model;
    DIALECTIC_LEVELS__minimal__MODEL_CONFIG__OVERRIDES__BASE_URL = cfg.llm.baseUrl;
    DIALECTIC_LEVELS__minimal__MODEL_CONFIG__OVERRIDES__API_KEY_ENV = cfg.llm.apiKeyEnv;
    DIALECTIC_LEVELS__low__MODEL_CONFIG__TRANSPORT = cfg.llm.transport;
    DIALECTIC_LEVELS__low__MODEL_CONFIG__MODEL = cfg.llm.model;
    DIALECTIC_LEVELS__low__MODEL_CONFIG__OVERRIDES__BASE_URL = cfg.llm.baseUrl;
    DIALECTIC_LEVELS__low__MODEL_CONFIG__OVERRIDES__API_KEY_ENV = cfg.llm.apiKeyEnv;
    DIALECTIC_LEVELS__medium__MODEL_CONFIG__TRANSPORT = cfg.llm.transport;
    DIALECTIC_LEVELS__medium__MODEL_CONFIG__MODEL = cfg.llm.model;
    DIALECTIC_LEVELS__medium__MODEL_CONFIG__OVERRIDES__BASE_URL = cfg.llm.baseUrl;
    DIALECTIC_LEVELS__medium__MODEL_CONFIG__OVERRIDES__API_KEY_ENV = cfg.llm.apiKeyEnv;
    DIALECTIC_LEVELS__high__MODEL_CONFIG__TRANSPORT = cfg.llm.transport;
    DIALECTIC_LEVELS__high__MODEL_CONFIG__MODEL = cfg.llm.model;
    DIALECTIC_LEVELS__high__MODEL_CONFIG__OVERRIDES__BASE_URL = cfg.llm.baseUrl;
    DIALECTIC_LEVELS__high__MODEL_CONFIG__OVERRIDES__API_KEY_ENV = cfg.llm.apiKeyEnv;
    DIALECTIC_LEVELS__max__MODEL_CONFIG__TRANSPORT = cfg.llm.transport;
    DIALECTIC_LEVELS__max__MODEL_CONFIG__MODEL = cfg.llm.model;
    DIALECTIC_LEVELS__max__MODEL_CONFIG__OVERRIDES__BASE_URL = cfg.llm.baseUrl;
    DIALECTIC_LEVELS__max__MODEL_CONFIG__OVERRIDES__API_KEY_ENV = cfg.llm.apiKeyEnv;
  }
  // thinkingEnvironment
  // cfg.environment;

  environmentList = lib.mapAttrsToList (name: value: "${name}=${value}") serviceEnvironment;

  postgresPackage = cfg.postgres.package.withPackages (ps: [ ps.pgvector ]);
  postgresDataDir = "${cfg.dataDir}/postgres";
  postgresRunDir = "${cfg.dataDir}/run/postgres";
  postgresBin = name: lib.getExe' postgresPackage name;
  redisDataDir = "${cfg.dataDir}/redis";

  managedServices =
    lib.optional cfg.postgres.enable "honcho-postgres.service"
    ++ lib.optional cfg.redis.enable "honcho-redis.service";

  mkService =
    extraService:
    {
      Type = "simple";
      WorkingDirectory = cfg.source;
      Environment = environmentList;
      UMask = "0077";
    }
    // optionalAttrs (cfg.environmentFiles != [ ]) { EnvironmentFile = cfg.environmentFiles; }
    // extraService;

  setupDeps = cfg.setup.after ++ managedServices;
  runtimeDeps = managedServices ++ lib.optional cfg.setup.enable "honcho-setup.service";
  uv = lib.getExe pkgs.uv;
in
{
  options.services.honcho = {
    enable = mkEnableOption "Plastic Labs Honcho user services";

    source = mkOption {
      type = types.path;
      default = honchoPkg.src;
      defaultText = lib.literalExpression "(import ./honcho-pkg.nix { inherit pkgs; }).src";
      description = "Pinned Honcho source tree.";
    };

    namespace = mkOption {
      type = types.str;
      default = "honcho";
      description = "Honcho namespace.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "${config.xdg.dataHome}/honcho";
      defaultText = lib.literalExpression ''"${config.xdg.dataHome}/honcho"'';
      description = "Persistent Honcho state directory.";
    };

    cacheDir = mkOption {
      type = types.str;
      default = "${config.xdg.cacheHome}/honcho";
      defaultText = lib.literalExpression ''"${config.xdg.cacheHome}/honcho"'';
      description = "Honcho cache directory, including uv cache.";
    };

    port = mkOption {
      type = types.port;
      default = 24880;
      description = "TCP port for the Honcho API listener.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Host address for the Honcho API listener.";
    };

    environmentFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "/run/secrets/honcho.env" ];
      description = ''
        Runtime environment files passed to Honcho user services. Use this for
        provider API keys such as MINIMAX_API_KEY and OPENROUTER_API_KEY. These
        are plain strings read by systemd at service start, so /run/secrets paths
        do not enter the Nix store unless you explicitly interpolate store paths.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra non-secret environment variables for Honcho services.";
    };

    databaseUri = mkOption {
      type = types.str;
      default = "postgresql+psycopg://honcho@127.0.0.1:5432/honcho";
      description = ''
        SQLAlchemy-compatible PostgreSQL connection URI. Used when
        `services.honcho.postgres.enable` is false; when the user-level
        PostgreSQL service is enabled, Honcho derives this URI from the
        PostgreSQL service options.
      '';
    };

    postgres = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to run a Home Manager-managed PostgreSQL user service for
          Honcho. The service stores data under `services.honcho.dataDir` and
          is intended for single-user local deployments.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.postgresql;
        defaultText = lib.literalExpression "pkgs.postgresql";
        description = ''
          PostgreSQL package used for the user service. The module applies
          `withPackages (ps: [ ps.pgvector ])` so Honcho can create the vector
          extension.
        '';
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Host address for the PostgreSQL listener.";
      };

      port = mkOption {
        type = types.port;
        default = 55432;
        description = "TCP port for the PostgreSQL listener.";
      };

      database = mkOption {
        type = types.str;
        default = "honcho";
        description = "Database name created for Honcho.";
      };

      user = mkOption {
        type = types.str;
        default = "honcho";
        description = "Database role created for Honcho.";
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "-c log_min_messages=notice" ];
        description = "Additional arguments passed to the PostgreSQL server.";
      };
    };

    redis = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to run a Home Manager-managed Redis user service for Honcho.
          The service binds to localhost by default and stores data under
          `services.honcho.dataDir`.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.redis;
        defaultText = lib.literalExpression "pkgs.redis";
        description = "Redis package used for the user service.";
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Host address for the Redis listener.";
      };

      port = mkOption {
        type = types.port;
        default = 6380;
        description = "TCP port for the Redis listener.";
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
      defaultText = lib.literalExpression "pkgs.python313";
      description = "Python interpreter used by uv for Honcho.";
    };

    runtimeLibraries = mkOption {
      type = types.listOf types.package;
      default = [ pkgs.stdenv.cc.cc ];
      defaultText = lib.literalExpression "[ pkgs.stdenv.cc.cc ]";
      description = "Runtime libraries included in LD_LIBRARY_PATH for Honcho.";
    };

    logLevel = mkOption {
      type = types.str;
      default = "INFO";
      description = "Honcho log level.";
    };

    authUseAuth = mkOption {
      type = types.bool;
      default = false;
      description = "Whether Honcho should enable AUTH_USE_AUTH.";
    };

    setup = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to enable a one-shot user service that runs `uv sync` and
          `scripts/provision_db.py` before Honcho runtime services start.
        '';
      };

      after = mkOption {
        type = types.listOf types.str;
        default = [ "network-online.target" ];
        description = "User/systemd units that honcho-setup should start after.";
      };
    };

    metrics.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Whether Honcho metrics are enabled.";
    };

    cache = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether Honcho Redis cache support is enabled.";
      };

      url = mkOption {
        type = types.str;
        default = "redis://127.0.0.1:6380/0?suppress=true";
        description = ''
          Redis cache URL. Used when `services.honcho.redis.enable` is false;
          when the user-level Redis service is enabled, Honcho derives this URL
          from the Redis service options.
        '';
      };
    };

    llm = {
      transport = mkOption {
        type = types.enum llmTransports;
        default =
          if lib.hasSuffix "/anthropic" cfg.llm.baseUrl then
            "anthropic"
          else if lib.hasSuffix "/api/v1" cfg.llm.baseUrl then
            "openai"
          else
            "gemini";
        description = "LLM API transport for Honcho background tasks.";
      };

      baseUrl = mkOption {
        type = types.str;
        default = "https://api.minimax.io/anthropic";
        description = "Base URL for the LLM provider.";
      };

      model = mkOption {
        type = types.str;
        default = "MiniMax-M2.7";
        description = "LLM model name.";
      };

      apiKeyEnv = mkOption {
        type = types.str;
        default = "MINIMAX_API_KEY";
        description = "Environment variable name containing the LLM API key.";
      };
    };

    embeddings = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether Honcho should embed messages.";
      };

      transport = mkOption {
        type = types.enum embeddingTransports;
        default = if lib.hasSuffix "/api/v1" cfg.embeddings.baseUrl then "openai" else "gemini";
        description = "Embedding API transport.";
      };

      baseUrl = mkOption {
        type = types.str;
        default = "https://openrouter.ai/api/v1";
        description = "Base URL for the embedding provider.";
      };

      model = mkOption {
        type = types.str;
        default = "openai/text-embedding-3-small";
        description = "Embedding model name.";
      };

      apiKeyEnv = mkOption {
        type = types.str;
        default = "OPENROUTER_API_KEY";
        description = "Environment variable name containing the embedding API key.";
      };
    };

    deriver = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to enable Honcho's background deriver.";
      };

      workers = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Number of Honcho deriver workers.";
      };

      flush.enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether deriver flushing is enabled.";
      };
    };

    peerCard.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether peer card generation is enabled.";
    };

    summary.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether summary generation is enabled.";
    };

    dream = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether dream generation is enabled.";
      };

      surprisal.enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether dream surprisal is enabled.";
      };

      idleTimeoutMinutes = mkOption {
        type = types.ints.positive;
        default = 30;
        description = "Idle timeout before dream work, in minutes.";
      };

      minHoursBetweenDreams = mkOption {
        type = types.ints.positive;
        default = 4;
        description = "Minimum hours between dream runs.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.isLinux;
        message = "services.honcho currently requires Linux/systemd user services.";
      }
    ];

    home.activation.honchoDirectories = config.lib.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg cfg.dataDir}
      $DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg cfg.cacheDir}
      $DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg postgresRunDir}
      ${lib.optionalString cfg.postgres.enable "$DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg postgresDataDir}"}
      ${lib.optionalString cfg.redis.enable "$DRY_RUN_CMD install -d -m 700 ${lib.escapeShellArg redisDataDir}"}
    '';

    systemd.user.services = {
      honcho-postgres = mkIf cfg.postgres.enable {
        Unit = {
          Description = "Honcho PostgreSQL database";
        };
        Service = {
          Type = "simple";
          Environment = [ "PGHOST=${postgresRunDir}" ];
          ExecStartPre = pkgs.writeShellScript "honcho-postgres-initdb" ''
                        set -euo pipefail
                        install -d -m 700 ${lib.escapeShellArg postgresDataDir}
                        install -d -m 700 ${lib.escapeShellArg postgresRunDir}
                        if [ ! -e ${lib.escapeShellArg postgresDataDir}/PG_VERSION ]; then
                          ${postgresBin "initdb"} -D ${lib.escapeShellArg postgresDataDir} --auth=trust --no-locale --encoding=UTF8
                          cat >> ${lib.escapeShellArg postgresDataDir}/pg_hba.conf <<'EOF'
            host all all ${cfg.postgres.host}/32 trust
            EOF
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
        Unit = {
          Description = "Honcho Redis cache";
        };
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

      honcho-setup = mkIf cfg.setup.enable {
        Unit = {
          Description = "Prepare Honcho virtualenv and database";
          After = setupDeps;
        };
        Service = mkService {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "honcho-setup" ''
            set -euo pipefail
            ${lib.optionalString cfg.postgres.enable ''
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
            ${uv} sync --frozen --no-group dev
            ${uv} run --frozen --no-sync --no-group dev python scripts/provision_db.py
          '';
        };
        Install.WantedBy = [ "default.target" ];
      };

      honcho-api = {
        Unit = {
          Description = "Honcho API";
          After = runtimeDeps;
          Requires = runtimeDeps;
        };
        Service = mkService {
          Restart = "on-failure";
          RestartSec = "5s";
          ExecStart = pkgs.writeShellScript "honcho-api" ''
            exec ${uv} run --frozen --no-sync --no-group dev fastapi run --host ${lib.escapeShellArg cfg.host} --port ${toString cfg.port} src/main.py
          '';
        };
        Install.WantedBy = [ "default.target" ];
      };

      honcho-deriver = mkIf cfg.deriver.enable {
        Unit = {
          Description = "Honcho background deriver";
          After = runtimeDeps;
          Requires = runtimeDeps;
        };
        Service = mkService {
          Restart = "on-failure";
          RestartSec = "5s";
          ExecStart = pkgs.writeShellScript "honcho-deriver" ''
            exec ${uv} run --frozen --no-sync --no-group dev python -m src.deriver
          '';
        };
        Install.WantedBy = [ "default.target" ];
      };
    };
  };
}
