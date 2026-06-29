# Pinned Plastic Labs Honcho source.
#
# This file is intentionally small and data-only so scripts/update-package-pins.py
# and CI can update the pinned tag/hash without touching service module logic.
{ pkgs }:

rec {
  owner = "plastic-labs";
  repo = "honcho";
  version = "3.0.11";
  rev = "v${version}";
  hash = "sha256-FI9JO436dJD83tmyLTYSWNLSUkeErgGwId3ewI9j9ig=";

  src = pkgs.fetchFromGitHub {
    inherit
      owner
      repo
      rev
      hash
      ;
  };
}
