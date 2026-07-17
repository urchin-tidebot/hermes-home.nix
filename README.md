# hermes-home.nix

A Home Manager module for declaratively managing [Hermes Agent](https://github.com/NousResearch/hermes-agent) as a user-level Nix/Home Manager setup.

This project exists because upstream Hermes currently ships a NixOS module, while our active setup runs Hermes from a user account with `~/.hermes`, a Home Manager-owned `systemd --user` gateway, Telegram voice mode, and Nix-managed helper scripts. The goal is to make that setup reproducible before we switch to it.

## Status

Early design/prototype. The module evaluates and has a basic Home Manager check, but it is not yet applied to our live Hermes profile.

## Features

- `programs.hermes-agent` Home Manager module.
- Optional package installation via `home.packages`.
- Declarative `HERMES_HOME` directory creation.
- Declarative `config.yaml` from a Nix attrset, deep-merged into existing config by default.
- `.env` assembly from non-secret Nix attrs plus activation-time secret files.
- Optional auth seed file for `auth.json`.
- Optional `systemd.user.services.hermes-gateway` service.
- Gateway service `PATH` composition with Hermes plus `extraPackages`.
- Switch-time gateway activation check: validates the Hermes executable before
  systemd reloads it, including Pydantic's native module and local OpenAI client
  construction for compatible Nix wrappers.
- Gateway `unitConfig`/`serviceConfig` passthroughs for preserving existing
  stateful `systemd --user` lifecycle semantics during migration.
- Declarative `mcpServers`, rendered into Hermes `settings.mcp_servers`.
- Declarative `extraPlugins`, symlinked into `HERMES_HOME/plugins` as `nix-managed-*`.
- Declarative `gateway_voice_mode.json` for voice replies by platform target.
- Optional Edge TTS command-provider helper for Nix/PEP 668 environments where Hermes' lazy dependency check is not ideal.
- Declarative Hermes documents under `HERMES_HOME`, such as `SOUL.md` and memory files.
- `services.honcho` Home Manager module for Plastic Labs Honcho, with a standalone auto-updatable Honcho source pin.

## Usage

Add the flake input:

```nix
{
  inputs.hermes-home.url = "github:urchin-tidebot/hermes-home.nix";
}
```

Import the module in your Home Manager modules list:

```nix
{
  imports = [ inputs.hermes-home.homeManagerModules.default ];

  programs.hermes-agent = {
    enable = true;
    package = pkgs.llm-agents.hermes-agent;

    settings = {
      model = "openai/gpt-5";
      terminal.backend = "local";
    };

    environmentFiles = [ "/run/secrets/hermes.env" ];

    gateway = {
      enable = true;
      voiceModes = {
        "telegram:-1001234567890" = true;
        "telegram:-1001234567890:42" = true;
      };
      serviceConfig = {
        Restart = "always";
        KillMode = "mixed";
        ExecReload = "${pkgs.coreutils}/bin/kill -USR1 $MAINPID";
        TimeoutStopSec = "210s";
      };
    };
  };
}
```

### Edge TTS command provider

If you have a Python interpreter with `edge_tts` importable, this module can generate the Hermes command-provider config:

```nix
programs.hermes-agent = {
  voice = {
    autoTts = true;
    edgeTts = {
      enable = true;
      python = "/nix/store/...-python3-env/bin/python3";
      voice = "en-US-AriaNeural";
    };
  };
};
```

Or provide the exact command yourself:

```nix
programs.hermes-agent.voice.edgeTts = {
  enable = true;
  command = "/path/to/python /path/to/edge_tts_command.py {input_path} {output_path} en-US-AriaNeural";
};
```

### Honcho Home Manager module

The flake also exposes `homeManagerModules.honcho`, a user-level Home Manager module that renders Honcho `config.toml` settings and manages `systemd.user` services. It can either point Honcho at externally managed PostgreSQL/Redis services or run local per-user PostgreSQL+pgvector and Redis services for single-user deployments.

```nix
{
  imports = [ inputs.hermes-home.homeManagerModules.honcho ];

  services.honcho = {
    enable = true;
    environmentFiles = [ "/run/secrets/honcho.env" ];

    # Optional user-level backing services. Leave these disabled when pointing
    # Honcho at services managed elsewhere.
    localServices.postgres = true;
    localServices.redis = true;

    # Arbitrary Honcho config.toml settings can be layered over the module's
    # runtime defaults. Do not put secrets here; use environmentFiles instead.
    settings = {
      llm.ANTHROPIC_BASE_URL = "https://api.example.invalid/anthropic";
      dialectic.MAX_OUTPUT_TOKENS = 4096;
    };
  };
}
```

The Honcho source pin lives in `modules/honcho/honcho-pkg.nix`. It is intentionally separate from the service module so the generalized package-pin updater (`scripts/update-package-pins.py` and `.github/workflows/update-package-pins.yml`) can update the upstream tag/hash in a weekly automated PR.

## Design notes

- The module intentionally defaults `hermesHome` to `~/.hermes` because that matches the current Hermes CLI/gateway user-level layout and makes migration easier.
- `settings` are rendered as JSON in the Nix store and deep-merged into `config.yaml` by default; generated Nix keys win while user/runtime keys are preserved. Set `mergeConfig = false` or provide `configFile` when you want replacement semantics.
- Do not put secrets in `settings`, `environment`, `service.environment`, `mcpServers.env`, `mcpServers.headers`, `documents`, or any Nix path values. Nix-rendered values are generally world-readable through the Nix store or generated units.
- `environmentFiles`, `configFile`, and `authFile` are plain string paths read at activation time, so `/run/secrets/...`-style inputs do not enter the Nix store unless you explicitly interpolate a store path.
- Removal semantics are opt-in for potentially user-owned runtime files: set `removeConfigWhenEmpty`, `manageEnvironment`, `manageGatewayVoiceModes`, or `managePlugins` when you want Home Manager to remove stale `config.yaml`, `.env`, `gateway_voice_mode.json`, or `nix-managed-*` plugin links after the corresponding declarations become empty.
- For stateful migrations, keep one owner for `hermes-gateway.service`: remove
  any hand-written `systemd.user.services.hermes-gateway` declaration and carry
  required lifecycle knobs through `programs.hermes-agent.gateway.unitConfig`,
  `programs.hermes-agent.gateway.serviceConfig`, and
  `programs.hermes-agent.service.environment`.
- `service.environment.PYTHONPATH` and `PYTHONHOME` are rejected, and the
  gateway unit explicitly unsets ambient values inherited by the systemd user
  manager. Injecting a mutable Python tree can shadow Nix-packaged native
  extensions with the wrong CPython ABI. Use `extraPythonPackages`,
  `extraDependencyGroups`, or a package override so Hermes and its Python
  dependencies are built together.
- `gateway.activationCheck.enable` defaults to true. It runs after Home Manager's
  write boundary but before `reloadSystemd`; set it to false only for a custom
  executable that cannot support even the fallback `hermes --version` probe.
- `mcpServers`, `extraPackages`, `extraPlugins`, `authFile`, and config merging intentionally mirror the relevant user-level pieces of upstream `services.hermes-agent`.
- The Home Manager module is user-level only. For a system-level `/var/lib/hermes` deployment, prefer upstream's NixOS module.
- `services.honcho.localServices.postgres` and `services.honcho.localServices.redis` run local user-level backing services for convenience; they are intentionally bound to localhost and store state under XDG/Honcho data directories rather than managing system users, firewall, or `/var/lib` state.
- `gateway.enable` currently requires Linux/systemd. Darwin users can still use non-gateway package/config/document options; launchd support would be a future addition.

## References and licenses

This project borrows design ideas from the following public modules/configurations. The implementation here is original and intentionally small, but the option shape and activation/service patterns were informed by these references:

- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) — MIT license. Upstream Hermes Agent and its official NixOS module (`services.hermes-agent`).
- [yzx9/nix-config](https://github.com/yzx9/nix-config) — Apache-2.0 license. Home Manager `programs.hermes-agent` pattern, deep-merged settings, user service, env/doc handling.
- [edmundmiller/dotfiles](https://github.com/edmundmiller/dotfiles) — MIT license. Richer Hermes Home Manager integration ideas: repo-managed Hermes config, auth/config synchronization, skins/hooks/secrets.
- [yuanw/nix-home](https://github.com/yuanw/nix-home) — no repository license detected at the time of writing. Referenced only for high-level package/environment/gateway-service module shape; no code is copied.
- [suderman/nixos](https://github.com/suderman/nixos) — no repository license detected at the time of writing. Consulted only to understand deployment requirements; the Honcho module implementation is written around Honcho's own configuration surface and user-level Home Manager services.
- [plastic-labs/honcho](https://github.com/plastic-labs/honcho) — AGPL-3.0 license. This repository pins/fetches Honcho source but does not vendor it.

## Post-migration TODOs

These are intentionally tracked in this in-flight migration PR so the first
Home Manager switch can stay conservative without losing follow-up work:

- TODO: After the module-owned gateway has run successfully for a few days,
  promote selected stable `~/.hermes/config.yaml` keys into
  `programs.hermes-agent.settings` and leave provider credentials/runtime state
  in runtime files or secret paths.
- TODO: Decide whether `gateway_voice_mode.json` should be fully declarative
  via `programs.hermes-agent.gateway.voiceModes`; before enabling it, confirm
  the current Telegram target list is complete.
- TODO: Move non-secret, stable `.env` values into
  `programs.hermes-agent.environment` and keep secrets in activation-time
  `environmentFiles` only.
- TODO: Audit runtime plugin usage and convert stable plugins to
  `extraPlugins`; only enable `managePlugins` once all `nix-managed-*` links are
  known to be declarative.
- TODO: Once the canary migration is complete, remove any leftover manual
  `hermes-gateway.service` backups and document the rollback procedure for the
  module-owned service.

## Development

```sh
nix flake check
nix fmt
```

Evaluate the basic Home Manager activation package:

```sh
nix build .#checks.x86_64-linux.basic
```

## License

MIT. See [LICENSE](./LICENSE).
