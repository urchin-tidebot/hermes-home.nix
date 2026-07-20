# Pinned Plastic Labs Honcho source.
#
# This file is intentionally small and data-only so scripts/update-package-pins.py
# and CI can update the pinned tag/hash without touching service module logic.
{ pkgs }:

rec {
  owner = "plastic-labs";
  repo = "honcho";
  version = "3.0.12";
  rev = "v${version}";
  hash = "sha256-BekiGw5l1eTGbCtGrOcPeJHk/ckJ9pmBJ7r8YXNIMGM=";

  src = pkgs.fetchFromGitHub {
    inherit
      owner
      repo
      rev
      hash
      ;
  };
}
