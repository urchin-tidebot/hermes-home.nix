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
- Declarative `mcpServers`, rendered into Hermes `settings.mcp_servers`.
- Declarative `extraPlugins`, symlinked into `HERMES_HOME/plugins` as `nix-managed-*`.
- Declarative `gateway_voice_mode.json` for voice replies by platform target.
- Optional Edge TTS command-provider helper for Nix/PEP 668 environments where Hermes' lazy dependency check is not ideal.
- Declarative Hermes documents under `HERMES_HOME`, such as `SOUL.md` and memory files.

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

## Design notes

- The module intentionally defaults `hermesHome` to `~/.hermes` because that matches the current Hermes CLI/gateway user-level layout and makes migration easier.
- `settings` are rendered as JSON and deep-merged into `config.yaml` by default; generated Nix keys win while user/runtime keys are preserved. Set `mergeConfig = false` or provide `configFile` when you want replacement semantics.
- `environmentFiles` are read at activation time so secrets do not enter the Nix store.
- `mcpServers`, `extraPackages`, `extraPlugins`, `authFile`, and config merging intentionally mirror the relevant user-level pieces of upstream `services.hermes-agent`.
- The Home Manager module is user-level only. For a system-level `/var/lib/hermes` deployment, prefer upstream's NixOS module.

## References and licenses

This project borrows design ideas from the following public modules/configurations. The implementation here is original and intentionally small, but the option shape and activation/service patterns were informed by these references:

- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) — MIT license. Upstream Hermes Agent and its official NixOS module (`services.hermes-agent`).
- [yzx9/nix-config](https://github.com/yzx9/nix-config) — Apache-2.0 license. Home Manager `programs.hermes-agent` pattern, deep-merged settings, user service, env/doc handling.
- [edmundmiller/dotfiles](https://github.com/edmundmiller/dotfiles) — MIT license. Richer Hermes Home Manager integration ideas: repo-managed Hermes config, auth/config synchronization, skins/hooks/secrets.
- [yuanw/nix-home](https://github.com/yuanw/nix-home) — no repository license detected at the time of writing. Referenced only for high-level package/environment/gateway-service module shape; no code is copied.

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
