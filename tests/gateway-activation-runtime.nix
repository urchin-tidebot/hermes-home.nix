{
  pkgs,
  home-manager,
  hermesModule,
}:

let
  python = pkgs.python3.withPackages (ps: [ ps.openai ]);
  source = pkgs.runCommand "hermes-preflight-source-fixture" { } ''
    mkdir -p "$out/agent"
    printf 'from openai import OpenAI\n' > "$out/agent/process_bootstrap.py"
  '';
  mkWrapper =
    name: body:
    pkgs.writeShellScriptBin name ''
      set -eu
      export HERMES_PYTHON='${python}/bin/python3'
      export HERMES_PYTHON_SRC_ROOT='${source}'
      ${body}
    '';
  workingWrapper = mkWrapper "hermes" ''
    test "$1" = --version
    test -z "''${PYTHONPATH:-}"
    test -z "''${PYTHONHOME:-}"
    printf 'version\n' >> "$PREFLIGHT_LOG"
  '';
  brokenWrapper = mkWrapper "hermes-broken" ''
    exit 42
  '';
  missingSourceWrapper = pkgs.writeShellScriptBin "hermes-missing-source" ''
    export HERMES_PYTHON='${python}/bin/python3'
    export HERMES_PYTHON_SRC_ROOT='${pkgs.emptyDirectory}'
    exit 0
  '';
  fallbackWrapper = pkgs.writeShellScriptBin "hermes-fallback" ''
    set -eu
    test "$1" = --version
    printf 'fallback\n' >> "$PREFLIGHT_LOG"
  '';
  activation =
    executable:
    let
      home = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          hermesModule
          {
            home.username = "hermes-preflight";
            home.homeDirectory = "/build/hermes-preflight";
            home.stateVersion = "24.11";
            programs.hermes-agent = {
              enable = true;
              addToPackages = false;
              inherit executable;
              gateway.enable = true;
            };
          }
        ];
      };
    in
    pkgs.writeShellScript "run-hermes-preflight" home.config.home.activation.hermesGatewayActivationCheck.data;
in
pkgs.runCommand "hermes-gateway-activation-runtime-check" { } ''
  export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
  export PREFLIGHT_LOG="$PWD/preflight.log"
  # Exercise the generated activation entry, not just its source strings.
  if ${activation "${brokenWrapper}/bin/hermes-broken"}; then
    echo 'preflight accepted a broken CLI whose Python imports still work' >&2
    exit 1
  fi

  if ${activation "${missingSourceWrapper}/bin/hermes-missing-source"} 2>missing-source.log; then
    echo 'preflight accepted a wrapper with missing Python source' >&2
    exit 1
  fi
  grep -F "No module named 'agent'" missing-source.log

  PYTHONPATH=/invalid/pythonpath PYTHONHOME=/invalid/pythonhome \
    ${activation "${workingWrapper}/bin/hermes"}
  grep -Fx version "$PREFLIGHT_LOG"
  ${activation "${fallbackWrapper}/bin/hermes-fallback"}
  grep -Fx fallback "$PREFLIGHT_LOG"
  touch "$out"
''
