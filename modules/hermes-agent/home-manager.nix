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
      "${cfg.voice.edgeTts.python} ${generatedEdgeTtsWrapper} {input_path} {output_path} ${cfg.voice.edgeTts.voice}"
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

  renderedSettings = lib.recursiveUpdate cfg.settings voiceSettings;
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
    [ (shellQuote (lib.getExe cfg.package)) ] ++ map shellQuote gatewayArgs
  );

  serviceEnvironment = [
    "HERMES_HOME=${cfg.hermesHome}"
    "MESSAGING_CWD=${cfg.workingDirectory}"
  ]
  ++ mapAttrsToList (name: value: "${name}=${value}") cfg.service.environment;

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

    addToPackages = mkOption {
      type = types.bool;
      default = true;
      description = "Install the Hermes package into home.packages when package is non-null.";
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
          assertion = cfg.package != null || (!cfg.addToPackages && !cfg.gateway.enable);
          message = "programs.hermes-agent.package must be set when installing Hermes or enabling the gateway service.";
        }
        {
          assertion = !cfg.voice.edgeTts.enable || edgeTtsCommand != null;
          message = "programs.hermes-agent.voice.edgeTts requires either voice.edgeTts.command or voice.edgeTts.python.";
        }
      ];

      home.packages = mkIf (cfg.addToPackages && cfg.package != null) [ cfg.package ];

      home.activation.hermesAgent = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        ''
          set -eu
          hermes_home=${shellQuote cfg.hermesHome}
          install -d -m 700 "$hermes_home"
          install -d -m 700 "$hermes_home/audio_cache" "$hermes_home/scripts" "$hermes_home/memories"
        ''
        + optionalString shouldManageConfig ''
          install -m 600 ${shellQuote effectiveConfigFile} "$hermes_home/config.yaml"
        ''
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
              echo "warning: Hermes environment file not found: ${path}" >&2
            fi
          '') cfg.environmentFiles
          + ''
            install -m 600 "$tmp_env" "$hermes_home/.env"
          ''
        )
        + optionalString (cfg.gateway.voiceModes != { }) ''
          install -m 600 ${shellQuote voiceModesFile} "$hermes_home/gateway_voice_mode.json"
        ''
        + lib.concatStringsSep "" (
          mapAttrsToList (
            name: value:
            let
              source =
                if builtins.isPath value || lib.isStorePath value then
                  value
                else
                  pkgs.writeText "hermes-document-${baseNameOf name}" value;
            in
            ''
              install -D -m 600 ${shellQuote source} "$hermes_home/${name}"
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
          Restart = "on-failure";
          RestartSec = "5s";
        };

        Install = {
          WantedBy = [ "default.target" ];
        };
      };
    })
  ]);
}
