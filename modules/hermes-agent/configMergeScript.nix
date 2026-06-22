# Deep-merge Nix settings into an existing Hermes config.yaml.
# Borrowed from the upstream NousResearch/hermes-agent NixOS module (MIT).
{ pkgs }:

pkgs.writeScript "hermes-config-merge" ''
  #!${pkgs.python3.withPackages (ps: [ ps.pyyaml ])}/bin/python3
  import json
  import os
  import sys
  import tempfile
  from pathlib import Path

  import yaml

  nix_json, config_path = sys.argv[1], Path(sys.argv[2])

  with open(nix_json) as f:
      nix = json.load(f)
  if not isinstance(nix, dict):
      raise SystemExit(f"{nix_json} must contain a JSON object at top level")

  existing = {}
  if config_path.exists():
      with open(config_path) as f:
          existing = yaml.safe_load(f) or {}
      if not isinstance(existing, dict):
          raise SystemExit(f"{config_path} must contain a YAML mapping at top level")

  def deep_merge(base, override):
      result = dict(base)
      for k, v in override.items():
          if k in result and isinstance(result[k], dict) and isinstance(v, dict):
              result[k] = deep_merge(result[k], v)
          else:
              result[k] = v
      return result

  merged = deep_merge(existing, nix)
  config_path.parent.mkdir(parents=True, exist_ok=True)
  fd, tmp_name = tempfile.mkstemp(
      prefix=f".{config_path.name}.",
      suffix=".tmp",
      dir=config_path.parent,
      text=True,
  )
  tmp_path = Path(tmp_name)
  try:
      with os.fdopen(fd, "w") as f:
          yaml.safe_dump(merged, f, default_flow_style=False, sort_keys=False)
      tmp_path.chmod(0o600)
      os.replace(tmp_path, config_path)
  except Exception:
      try:
          tmp_path.unlink()
      except FileNotFoundError:
          pass
      raise
''
