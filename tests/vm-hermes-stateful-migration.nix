{
  pkgs,
  home-manager,
  hermesModule,
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
      printf 'TIRITH_BIN=%s\n' "''${TIRITH_BIN:-}"
      printf 'PYTHONPATH=%s\n' "''${PYTHONPATH:-}"
    } > "$HERMES_HOME/instrumentation/gateway.log"

    if [ "$#" -ge 2 ] && [ "$1" = gateway ] && [ "$2" = run ]; then
      while true; do
        sleep 3600
      done
    fi
  '';

  authSeed = pkgs.writeText "hermes-migration-auth.json" ''
    {"provider":"new-seed-should-not-overwrite"}
  '';

  pythonWithYaml = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
in
pkgs.testers.runNixOSTest {
  name = "hermes-stateful-home-manager-migration";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ home-manager.nixosModules.home-manager ];

      users.users.hermes-state = {
        isNormalUser = true;
        group = "users";
        home = "/home/hermes-state";
        createHome = true;
      };

      system.activationScripts.seedHermesState = lib.stringAfter [ "users" ] ''
        set -euo pipefail
        hermes_home=/home/hermes-state/.hermes
        install -d -o hermes-state -g users -m 700 "$hermes_home" "$hermes_home/plugins"
        install -d -o hermes-state -g users -m 700 "$hermes_home/memories"
        cat > "$hermes_home/config.yaml" <<'EOF'
        model: old/runtime-model
        runtime_only: preserved
        terminal:
          backend: old-runtime-backend
          preserve_me: yes
        nested:
          keep: true
          override: old
        EOF
        cat > "$hermes_home/.env" <<'EOF'
        EXISTING_SECRET=keep-me
        EOF
        cat > "$hermes_home/auth.json" <<'EOF'
        {"provider":"existing-runtime-auth"}
        EOF
        cat > "$hermes_home/gateway_voice_mode.json" <<'EOF'
        {"telegram:existing":true}
        EOF
        ln -sfn /tmp "$hermes_home/plugins/runtime-plugin"
        ln -sfn /tmp "$hermes_home/plugins/nix-managed-stale"
        chown -R hermes-state:users "$hermes_home"
        chmod 600 "$hermes_home/config.yaml" "$hermes_home/.env" "$hermes_home/auth.json" "$hermes_home/gateway_voice_mode.json"
      '';

      environment.etc."hermes-state/auth.json".source = authSeed;
      environment.systemPackages = [ pythonWithYaml ];

      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.hermes-state = {
        imports = [ hermesModule ];

        home.username = "hermes-state";
        home.homeDirectory = "/home/hermes-state";
        home.stateVersion = "26.05";
        systemd.user.startServices = "sd-switch";

        programs.hermes-agent = {
          enable = true;
          package = fakeHermes;
          authFile = "/etc/hermes-state/auth.json";
          workingDirectory = "/home/hermes-state/.hermes";

          settings = {
            model = "nix/migrated-model";
            terminal.backend = "local";
            nested.override = "nix";
          };

          service.environment = {
            TIRITH_BIN = "/run/current-system/sw/bin/tirith";
            PYTHONPATH = "/home/hermes-state/.hermes/python-deps/honcho-ai";
          };

          gateway = {
            enable = true;
            restart = "always";
            unitConfig.StartLimitIntervalSec = 0;
            serviceConfig = {
              KillMode = "mixed";
              KillSignal = "SIGTERM";
              ExecReload = "${pkgs.coreutils}/bin/kill -USR1 $MAINPID";
              TimeoutStopSec = "210s";
              RestartForceExitStatus = 75;
              RestartSteps = 5;
              RestartMaxDelaySec = "300s";
            };
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
    machine.wait_until_succeeds("test \"$(systemctl show home-manager-hermes-state.service -P Result)\" = success")

    uid = machine.succeed("id -u hermes-state").strip()
    machine.succeed(f"systemctl start user@{uid}.service")
    machine.wait_for_unit(f"user@{uid}.service")
    user_systemctl = f"runuser -u hermes-state -- env XDG_RUNTIME_DIR=/run/user/{uid} systemctl --user"
    machine.succeed(f"{user_systemctl} daemon-reload")

    machine.succeed("test \"$(stat -c %a /home/hermes-state/.hermes)\" = 700")
    machine.succeed("test \"$(stat -c %a /home/hermes-state/.hermes/config.yaml)\" = 600")
    machine.succeed("test \"$(stat -c %a /home/hermes-state/.hermes/.env)\" = 600")
    machine.succeed("test \"$(stat -c %a /home/hermes-state/.hermes/auth.json)\" = 600")
    machine.succeed("test \"$(stat -c %a /home/hermes-state/.hermes/gateway_voice_mode.json)\" = 600")

    machine.succeed("grep -F 'EXISTING_SECRET=keep-me' /home/hermes-state/.hermes/.env")
    machine.succeed("grep -F 'existing-runtime-auth' /home/hermes-state/.hermes/auth.json")
    machine.fail("grep -F 'new-seed-should-not-overwrite' /home/hermes-state/.hermes/auth.json")
    machine.succeed("grep -F 'telegram:existing' /home/hermes-state/.hermes/gateway_voice_mode.json")
    machine.succeed("test -L /home/hermes-state/.hermes/plugins/runtime-plugin")
    machine.succeed("test -L /home/hermes-state/.hermes/plugins/nix-managed-stale")

    machine.succeed("python3 - <<'PY'\nfrom pathlib import Path\nimport yaml\nconfig = yaml.safe_load(Path('/home/hermes-state/.hermes/config.yaml').read_text())\nassert config['model'] == 'nix/migrated-model'\nassert config['runtime_only'] == 'preserved'\nassert config['terminal']['backend'] == 'local'\nassert config['terminal']['preserve_me'] is True\nassert config['nested']['keep'] is True\nassert config['nested']['override'] == 'nix'\nPY")

    machine.succeed(f"{user_systemctl} cat hermes-gateway.service | grep -F 'WorkingDirectory=/home/hermes-state/.hermes'")
    machine.succeed(f"{user_systemctl} cat hermes-gateway.service | grep -F 'Restart=always'")
    machine.succeed(f"{user_systemctl} cat hermes-gateway.service | grep -F 'KillMode=mixed'")
    machine.succeed(f"{user_systemctl} cat hermes-gateway.service | grep -F 'KillSignal=SIGTERM'")
    machine.succeed(f"{user_systemctl} cat hermes-gateway.service | grep -F 'ExecReload=${pkgs.coreutils}/bin/kill -USR1'")
    machine.succeed(f"{user_systemctl} cat hermes-gateway.service | grep -F 'TimeoutStopSec=210s'")
    machine.succeed(f"{user_systemctl} cat hermes-gateway.service | grep -F 'RestartForceExitStatus=75'")
    machine.succeed(f"{user_systemctl} cat hermes-gateway.service | grep -F 'StartLimitIntervalSec=0'")

    machine.succeed(f"{user_systemctl} start hermes-gateway.service")
    machine.wait_until_succeeds(f"{user_systemctl} is-active --quiet hermes-gateway.service")
    machine.wait_until_succeeds("grep -F 'args=gateway run --replace' /home/hermes-state/.hermes/instrumentation/gateway.log")
    machine.succeed("grep -F 'MESSAGING_CWD=/home/hermes-state/.hermes' /home/hermes-state/.hermes/instrumentation/gateway.log")
    machine.succeed("grep -F 'TIRITH_BIN=/run/current-system/sw/bin/tirith' /home/hermes-state/.hermes/instrumentation/gateway.log")
    machine.succeed("grep -F 'PYTHONPATH=/home/hermes-state/.hermes/python-deps/honcho-ai' /home/hermes-state/.hermes/instrumentation/gateway.log")
  '';
}
