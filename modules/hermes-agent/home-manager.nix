{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    literalExpression
    mapAttrsToList
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optional
    optionalAttrs
    optionalString
    types
    ;

  cfg = config.programs.hermes-agent;

  effectivePackage =
    if cfg.package == null then
      null
    else if cfg.extraPythonPackages == [ ] && cfg.extraDependencyGroups == [ ] then
      cfg.package
    else
      cfg.package.override {
        inherit (cfg) extraPythonPackages extraDependencyGroups;
      };

  effectiveExecutable =
    if cfg.executable != null then
      cfg.executable
    else if effectivePackage != null then
      lib.getExe' effectivePackage "hermes"
    else
      null;

  configMergeScript = pkgs.callPackage ./configMergeScript.nix { };

  deepConfigType = types.mkOptionType {
    name = "hermes-config-attrs";
    description = "Hermes config attrset, deep-merged with lib.recursiveUpdate";
    check = builtins.isAttrs;
    merge = _loc: defs: lib.foldl' lib.recursiveUpdate { } (map (def: def.value) defs);
  };

  generatedEdgeTtsWrapper = pkgs.writeTextFile {
    name = "hermes-edge-tts-command.py";
    executable = true;
    text = ''
      #!/usr/bin/env python3
      from __future__ import annotations

      import asyncio
      import sys
      from pathlib import Path

      import edge_tts

      async def main() -> int:
          if len(sys.argv) < 3:
              print("usage: edge_tts_command.py INPUT_TEXT_PATH OUTPUT_AUDIO_PATH [VOICE]", file=sys.stderr)
              return 2

          input_path = Path(sys.argv[1]).expanduser()
          output_path = Path(sys.argv[2]).expanduser()
          voice = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else "en-US-AriaNeural"

          text = input_path.read_text(encoding="utf-8").strip()
          if not text:
              print("input text is empty", file=sys.stderr)
              return 2

          output_path.parent.mkdir(parents=True, exist_ok=True)
          communicate = edge_tts.Communicate(text, voice=voice)
          await communicate.save(str(output_path))

          if not output_path.exists() or output_path.stat().st_size <= 0:
              print(f"no output written to {output_path}", file=sys.stderr)
              return 1
          return 0

      if __name__ == "__main__":
          raise SystemExit(asyncio.run(main()))
    '';
  };

  edgeTtsCommand =
    if cfg.voice.edgeTts.command != null then
      cfg.voice.edgeTts.command
    else if cfg.voice.edgeTts.python != null then
      lib.concatStringsSep " " [
        (shellQuote cfg.voice.edgeTts.python)
        (shellQuote generatedEdgeTtsWrapper)
        "{input_path}"
        "{output_path}"
        (shellQuote cfg.voice.edgeTts.voice)
      ]
    else
      null;

  voiceSettings =
    optionalAttrs (cfg.voice.autoTts != null) {
      voice.auto_tts = cfg.voice.autoTts;
    }
    // optionalAttrs cfg.voice.edgeTts.enable {
      tts = {
        provider = cfg.voice.edgeTts.providerName;
        providers.${cfg.voice.edgeTts.providerName} = {
          type = "command";
          command = edgeTtsCommand;
          output_format = cfg.voice.edgeTts.outputFormat;
          voice_compatible = true;
        };
      };
    };

  mcpServerSettings = lib.mapAttrs (
    _name: srv:
    optionalAttrs (srv.command != null) { inherit (srv) command args; }
    // optionalAttrs (srv.env != { }) { inherit (srv) env; }
    // optionalAttrs (srv.url != null) { inherit (srv) url; }
    // optionalAttrs (srv.headers != { }) { inherit (srv) headers; }
    // optionalAttrs (srv.auth != null) { inherit (srv) auth; }
    // {
      inherit (srv) enabled;
    }
    // optionalAttrs (srv.timeout != null) { inherit (srv) timeout; }
    // optionalAttrs (srv.connectTimeout != null) { connect_timeout = srv.connectTimeout; }
    // optionalAttrs (srv.tools != null) {
      tools = lib.filterAttrs (_: value: value != [ ]) {
        inherit (srv.tools) include exclude;
      };
    }
    // optionalAttrs (srv.sampling != null) {
      sampling = lib.filterAttrs (_: value: value != null && value != [ ]) {
        inherit (srv.sampling)
          enabled
          model
          timeout
          ;
        max_tokens_cap = srv.sampling.maxTokensCap;
        max_rpm = srv.sampling.maxRpm;
        max_tool_rounds = srv.sampling.maxToolRounds;
        allowed_models = srv.sampling.allowedModels;
        log_level = srv.sampling.logLevel;
      };
    }
  ) cfg.mcpServers;

  renderedSettings = lib.recursiveUpdate (lib.recursiveUpdate cfg.settings (
    optionalAttrs (cfg.mcpServers != { }) {
      mcp_servers = mcpServerSettings;
    }
  )) voiceSettings;
  generatedConfigFile = pkgs.writeText "hermes-config.json" (builtins.toJSON renderedSettings);
  effectiveConfigFile = if cfg.configFile != null then cfg.configFile else generatedConfigFile;
  shouldManageConfig = cfg.manageConfig && (cfg.configFile != null || renderedSettings != { });

  generatedEnvFile = pkgs.writeText "hermes-env" (
    lib.concatStringsSep "\n" (mapAttrsToList (name: value: "${name}=${value}") cfg.environment)
    + optionalString (cfg.environment != { }) "\n"
  );

  voiceModesFile = pkgs.writeText "hermes-gateway-voice-mode.json" (
    builtins.toJSON cfg.gateway.voiceModes
  );

  shellQuote = lib.escapeShellArg;

  gatewayArgs = [
    "gateway"
    "run"
  ]
  ++ optional cfg.gateway.replace "--replace"
  ++ cfg.gateway.extraArgs;

  gatewayCommand = lib.concatStringsSep " " (
    [ (shellQuote effectiveExecutable) ] ++ map shellQuote gatewayArgs
  );

  servicePath = lib.makeBinPath (
    (optional (effectivePackage != null) effectivePackage)
    ++ [
      pkgs.bash
      pkgs.coreutils
      pkgs.git
    ]
    ++ cfg.extraPackages
  );

  serviceEnvironment = [
    "HOME=${config.home.homeDirectory}"
    "HERMES_HOME=${cfg.hermesHome}"
    "HERMES_MANAGED=true"
    "MESSAGING_CWD=${cfg.workingDirectory}"
    "PATH=${servicePath}"
  ]
  ++ mapAttrsToList (name: value: "${name}=${value}") cfg.service.environment;

  validDocumentPath =
    name:
    let
      components = lib.splitString "/" name;
    in
    name != ""
    && !(lib.hasPrefix "/" name)
    && !(lib.hasSuffix "/" name)
    && !(lib.hasInfix "\n" name)
    && lib.all (component: component != "" && component != "." && component != "..") components;

  validMcpServerTransport =
    srv:
    let
      hasCommand = srv.command != null;
      hasUrl = srv.url != null;
    in
    (hasCommand != hasUrl)
    && (hasCommand || (srv.args == [ ] && srv.env == { }))
    && (hasUrl || (srv.headers == { } && srv.auth == null));

in
{
  options.programs.hermes-agent = {
    enable = mkEnableOption "Hermes Agent user-level configuration";

    package = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = ''
        Hermes Agent package. Set this to the package from llm-agents.nix,
        the upstream Hermes flake, or another overlay-provided package.
      '';
      example = literalExpression "pkgs.llm-agents.hermes-agent";
    };

    executable = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Hermes CLI executable used by the gateway service. Defaults to the
        `hermes` binary from package when package is set.
      '';
      example = literalExpression ''"${pkgs.llm-agents.hermes-agent}/bin/hermes"'';
    };

    addToPackages = mkOption {
      type = types.bool;
      default = true;
      description = "Install the Hermes package into home.packages when package is non-null.";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Extra packages available to Hermes, the gateway service PATH, and the
        user's Home Manager profile. Useful for terminal tools, skills, and cron jobs.
      '';
    };

    extraPythonPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Python packages passed to package.override when the Hermes package supports
        extraPythonPackages, matching the upstream NixOS module.
      '';
    };

    extraDependencyGroups = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Optional dependency groups passed to package.override when supported by the
        Hermes package, such as "voice" or other groups declared upstream.
      '';
    };

    extraPlugins = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Directory-based Hermes plugin packages to symlink into
        $HERMES_HOME/plugins as nix-managed-* entries. Each package should
        contain plugin.yaml at its root.
      '';
    };

    hermesHome = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.hermes";
      defaultText = literalExpression ''"''${config.home.homeDirectory}/.hermes"'';
      description = "Directory used as HERMES_HOME.";
    };

    workingDirectory = mkOption {
      type = types.str;
      default = config.home.homeDirectory;
      defaultText = literalExpression "config.home.homeDirectory";
      description = "Default working directory exposed to Hermes as MESSAGING_CWD.";
    };

    settings = mkOption {
      type = deepConfigType;
      default = { };
      description = ''
        Declarative Hermes config attrset. This is rendered as JSON, which is
        valid YAML, and written to $HERMES_HOME/config.yaml when manageConfig is true.
        Multiple module definitions are merged deeply.
      '';
      example = literalExpression ''
        {
          model = "openai/gpt-5";
          timezone = "America/Toronto";
          terminal.backend = "local";
        }
      '';
    };

    configFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Existing config file to install as $HERMES_HOME/config.yaml. When set,
        this takes precedence over generated settings.
      '';
    };

    manageConfig = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether Home Manager should own $HERMES_HOME/config.yaml. Disable this
        during migration if you only want packages/services/environment managed.
      '';
    };

    mergeConfig = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Deep-merge generated settings into an existing config.yaml, preserving
        user/runtime keys while Nix-declared keys win. Ignored when configFile is set.
      '';
    };

    authFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to an auth.json seed file. Copied to $HERMES_HOME/auth.json only
        when missing unless authFileForceOverwrite is true.
      '';
    };

    authFileForceOverwrite = mkOption {
      type = types.bool;
      default = false;
      description = "Always overwrite auth.json from authFile on activation.";
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Non-secret environment variables merged into $HERMES_HOME/.env.
        Use environmentFiles for secrets.
      '';
      example = literalExpression ''
        {
          OPENAI_BASE_URL = "https://api.openai.com/v1";
        }
      '';
    };

    environmentFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Secret environment files concatenated into $HERMES_HOME/.env at
        activation time. Paths are read at activation, not copied into the Nix store.
      '';
    };

    documents = mkOption {
      type = types.attrsOf (types.either types.lines types.path);
      default = { };
      description = ''
        Files installed under HERMES_HOME. Keys are relative paths such as
        "SOUL.md", "memories/USER.md", or "skills/example/SKILL.md".
      '';
      example = literalExpression ''
        {
          "SOUL.md" = "You are a helpful AI assistant.";
          "memories/USER.md" = ./USER.md;
        }
      '';
    };

    mcpServers = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            command = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "MCP server command for stdio transport.";
            };
            args = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "MCP stdio command arguments.";
            };
            env = mkOption {
              type = types.attrsOf types.str;
              default = { };
              description = "Environment variables for stdio MCP server process.";
            };
            url = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "MCP server URL for HTTP/Streamable HTTP transport.";
            };
            headers = mkOption {
              type = types.attrsOf types.str;
              default = { };
              description = "HTTP headers for remote MCP servers.";
            };
            auth = mkOption {
              type = types.nullOr (types.enum [ "oauth" ]);
              default = null;
              description = "Authentication method for remote MCP servers.";
            };
            enabled = mkOption {
              type = types.bool;
              default = true;
              description = "Enable or disable this MCP server.";
            };
            timeout = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "Tool call timeout in seconds.";
            };
            connectTimeout = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "Initial connection timeout in seconds.";
            };
            tools = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    include = mkOption {
                      type = types.listOf types.str;
                      default = [ ];
                      description = "Tool allowlist for this server.";
                    };
                    exclude = mkOption {
                      type = types.listOf types.str;
                      default = [ ];
                      description = "Tool blocklist for this server.";
                    };
                  };
                }
              );
              default = null;
              description = "Filter which MCP tools are exposed.";
            };
            sampling = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    enabled = mkOption {
                      type = types.bool;
                      default = true;
                      description = "Enable sampling.";
                    };
                    model = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = "Sampling model override.";
                    };
                    maxTokensCap = mkOption {
                      type = types.nullOr types.int;
                      default = null;
                      description = "Max tokens per sampling request.";
                    };
                    timeout = mkOption {
                      type = types.nullOr types.int;
                      default = null;
                      description = "Sampling timeout in seconds.";
                    };
                    maxRpm = mkOption {
                      type = types.nullOr types.int;
                      default = null;
                      description = "Max sampling requests per minute.";
                    };
                    maxToolRounds = mkOption {
                      type = types.nullOr types.int;
                      default = null;
                      description = "Max tool-use rounds per sampling request.";
                    };
                    allowedModels = mkOption {
                      type = types.listOf types.str;
                      default = [ ];
                      description = "Models the server may request.";
                    };
                    logLevel = mkOption {
                      type = types.nullOr (
                        types.enum [
                          "debug"
                          "info"
                          "warning"
                        ]
                      );
                      default = null;
                      description = "Audit log level for sampling requests.";
                    };
                  };
                }
              );
              default = null;
              description = "Sampling configuration for server-initiated LLM requests.";
            };
          };
        }
      );
      default = { };
      description = ''
        MCP server configurations merged into settings.mcp_servers. Each server
        uses either stdio (command/args) or HTTP (url) transport.
      '';
    };

    gateway = {
      enable = mkEnableOption "Hermes gateway user service";

      replace = mkOption {
        type = types.bool;
        default = true;
        description = "Pass --replace to `hermes gateway run`.";
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional arguments appended to `hermes gateway run`.";
      };

      restart = mkOption {
        type = types.str;
        default = "on-failure";
        description = "systemd Restart= policy for the gateway user service.";
      };

      restartSec = mkOption {
        type = types.str;
        default = "5s";
        description = "systemd RestartSec= value for the gateway user service.";
      };

      voiceModes = mkOption {
        type = types.attrsOf types.bool;
        default = { };
        description = ''
          Declarative content for $HERMES_HOME/gateway_voice_mode.json.
          Keys are platform target IDs, values enable or disable voice replies.
        '';
        example = literalExpression ''
          {
            "telegram:-1001234567890" = true;
            "telegram:-1001234567890:42" = true;
          }
        '';
      };
    };

    service.environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra environment variables for the systemd user service only.";
    };

    voice = {
      autoTts = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "When set, writes voice.auto_tts in Hermes config.";
      };

      edgeTts = {
        enable = mkEnableOption "Edge TTS command provider helper";

        providerName = mkOption {
          type = types.str;
          default = "edge-command";
          description = "Hermes TTS provider name for the generated Edge TTS command provider.";
        };

        voice = mkOption {
          type = types.str;
          default = "en-US-AriaNeural";
          description = "Microsoft Edge TTS voice passed to edge_tts.Communicate.";
        };

        outputFormat = mkOption {
          type = types.enum [
            "mp3"
            "ogg"
            "wav"
          ];
          default = "mp3";
          description = "Output format reported to Hermes for the command provider.";
        };

        python = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Python interpreter with the edge_tts module importable. If command is
            null and this is set, the module generates a command using its bundled
            wrapper script.
          '';
          example = literalExpression ''"/nix/store/...-python3-env/bin/python3"'';
        };

        command = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Complete Hermes command-provider command. Supports Hermes placeholders
            {input_path} and {output_path}. Overrides python/wrapper generation.
          '';
        };
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.gateway.enable || pkgs.stdenv.isLinux;
          message = "programs.hermes-agent.gateway.enable currently requires Linux/systemd.";
        }
        {
          assertion = cfg.package != null || !cfg.addToPackages;
          message = "programs.hermes-agent.package must be set when installing Hermes with addToPackages.";
        }
        {
          assertion = !cfg.gateway.enable || effectiveExecutable != null;
          message = "programs.hermes-agent.package or executable must be set when enabling the gateway service.";
        }
        {
          assertion = !cfg.voice.edgeTts.enable || edgeTtsCommand != null;
          message = "programs.hermes-agent.voice.edgeTts requires either voice.edgeTts.command or voice.edgeTts.python.";
        }
        {
          assertion =
            let
              names = map lib.getName cfg.extraPlugins;
            in
            (lib.length names) == (lib.length (lib.unique names));
          message = "programs.hermes-agent.extraPlugins contains duplicate plugin names.";
        }
        {
          assertion = lib.all validDocumentPath (lib.attrNames cfg.documents);
          message = "programs.hermes-agent.documents keys must be safe relative paths without empty, '.', '..', absolute, trailing-slash, or newline components.";
        }
        {
          assertion = lib.all validMcpServerTransport (lib.attrValues cfg.mcpServers);
          message = "Each programs.hermes-agent.mcpServers entry must set exactly one of command or url, use stdio-only args/env only with command, and use HTTP-only headers/auth only with url.";
        }
      ];

      home.packages =
        (optional (cfg.addToPackages && effectivePackage != null) effectivePackage) ++ cfg.extraPackages;

      home.activation.hermesAgent = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        ''
          set -eu
          hermes_home=${shellQuote cfg.hermesHome}
          install -d -m 700 "$hermes_home"
          install -d -m 700 "$hermes_home/audio_cache" "$hermes_home/scripts" "$hermes_home/memories"
          install -d -m 700 "$hermes_home/cron" "$hermes_home/sessions" "$hermes_home/logs" "$hermes_home/plugins"
        ''
        + optionalString shouldManageConfig (
          if cfg.configFile != null || !cfg.mergeConfig then
            ''
              install -m 600 ${shellQuote effectiveConfigFile} "$hermes_home/config.yaml"
            ''
          else
            ''
              ${configMergeScript} ${shellQuote generatedConfigFile} "$hermes_home/config.yaml"
              chmod 600 "$hermes_home/config.yaml"
            ''
        )
        + optionalString (cfg.environment != { } || cfg.environmentFiles != [ ]) (
          ''
            tmp_env="$(${pkgs.coreutils}/bin/mktemp)"
            cleanup_env() { rm -f "$tmp_env"; }
            trap cleanup_env EXIT
          ''
          + optionalString (cfg.environment != { }) ''
            cat ${shellQuote generatedEnvFile} >> "$tmp_env"
          ''
          + lib.concatMapStringsSep "\n" (path: ''
            if [ -f ${shellQuote path} ]; then
              cat ${shellQuote path} >> "$tmp_env"
              printf '\n' >> "$tmp_env"
            else
              printf '%s\n' ${shellQuote "warning: Hermes environment file not found: ${path}"} >&2
            fi
          '') cfg.environmentFiles
          + ''
            install -m 600 "$tmp_env" "$hermes_home/.env"
          ''
        )
        + optionalString (cfg.authFile != null) (
          if cfg.authFileForceOverwrite then
            ''
              install -m 600 ${shellQuote cfg.authFile} "$hermes_home/auth.json"
            ''
          else
            ''
              if [ ! -f "$hermes_home/auth.json" ]; then
                install -m 600 ${shellQuote cfg.authFile} "$hermes_home/auth.json"
              fi
            ''
        )
        + optionalString (cfg.gateway.voiceModes != { }) ''
          install -m 600 ${shellQuote voiceModesFile} "$hermes_home/gateway_voice_mode.json"
        ''
        + optionalString (cfg.extraPlugins != [ ]) ''
          find "$hermes_home/plugins" -maxdepth 1 -type l -name 'nix-managed-*' -delete 2>/dev/null || true
        ''
        + lib.concatStringsSep "" (
          map (
            plugin:
            let
              name = lib.getName plugin;
            in
            ''
              if [ ! -f ${shellQuote plugin}/plugin.yaml ]; then
                echo "ERROR: extraPlugins entry '${plugin}' has no plugin.yaml" >&2
                exit 1
              fi
              ln -sfn ${shellQuote plugin} "$hermes_home/plugins/nix-managed-${name}"
            ''
          ) cfg.extraPlugins
        )
        + lib.concatStringsSep "" (
          mapAttrsToList (
            name: value:
            let
              source =
                if builtins.isPath value || lib.isStorePath value then
                  value
                else
                  pkgs.writeText "hermes-document-${baseNameOf name}" value;
              destination = "${cfg.hermesHome}/${name}";
            in
            ''
              install -D -m 600 ${shellQuote source} ${shellQuote destination}
            ''
          ) cfg.documents
        )
      );
    }

    (mkIf cfg.gateway.enable {
      systemd.user.services.hermes-gateway = {
        Unit = {
          Description = "Hermes Agent gateway";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };

        Service = {
          Type = "simple";
          WorkingDirectory = cfg.workingDirectory;
          Environment = serviceEnvironment;
          ExecStart = gatewayCommand;
          Restart = cfg.gateway.restart;
          RestartSec = cfg.gateway.restartSec;
          UMask = "0077";
        };

        Install = {
          WantedBy = [ "default.target" ];
        };
      };
    })
  ]);
}
