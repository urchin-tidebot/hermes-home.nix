{ pkgs }:

let
  mergeScript = pkgs.callPackage ../modules/hermes-agent/configMergeScript.nix { };
in
pkgs.runCommand "hermes-config-merge-test" { } ''
  set -eu

  work="$TMPDIR/hermes-config-merge"
  mkdir -p "$work"

  cat > "$work/generated.json" <<'JSON'
  {
    "model": "nix/model",
    "terminal": {
      "backend": "local"
    },
    "nested": {
      "keep": "from-nix"
    }
  }
  JSON

  cat > "$work/config.yaml" <<'YAML'
  model: old/model
  provider: openrouter
  terminal:
    timeout: 120
  nested:
    keep: from-existing
    preserve: true
  YAML

  ${mergeScript} "$work/generated.json" "$work/config.yaml"

  ${pkgs.python3.withPackages (ps: [ ps.pyyaml ])}/bin/python3 - <<'PY' "$work/config.yaml"
  import stat
  import sys
  from pathlib import Path
  import yaml

  path = Path(sys.argv[1])
  data = yaml.safe_load(path.read_text())
  assert data["model"] == "nix/model"
  assert data["provider"] == "openrouter"
  assert data["terminal"] == {"timeout": 120, "backend": "local"}
  assert data["nested"] == {"keep": "from-nix", "preserve": True}
  assert stat.S_IMODE(path.stat().st_mode) == 0o600
  PY

  cat > "$work/bad.yaml" <<'YAML'
  - not
  - a
  - mapping
  YAML

  if ${mergeScript} "$work/generated.json" "$work/bad.yaml" 2> "$work/bad.err"; then
    echo "expected merge to fail for non-mapping YAML" >&2
    exit 1
  fi
  grep -q "must contain a YAML mapping" "$work/bad.err"

  touch "$out"
''
