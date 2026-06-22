#!/usr/bin/env python3
"""Update vendored source pins for packages tracked by this repository."""

from __future__ import annotations

from dataclasses import dataclass
import json
import pathlib
import re
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class GitHubTagPin:
    name: str
    owner: str
    repo: str
    file: pathlib.Path
    version_pattern: str = r'version = "([^"]+)";'
    hash_pattern: str = r'hash = "sha256-[^"]+";'
    tag_regex: str = r"v(\d+(?:\.\d+)*)"
    tag_prefix: str = "v"

    @property
    def tags_url(self) -> str:
        return f"https://api.github.com/repos/{self.owner}/{self.repo}/tags?per_page=100"


PINS: tuple[GitHubTagPin, ...] = (
    GitHubTagPin(
        name="honcho",
        owner="plastic-labs",
        repo="honcho",
        file=ROOT / "modules" / "honcho" / "honcho-pkg.nix",
    ),
)


def latest_tag(pin: GitHubTagPin) -> str:
    request = urllib.request.Request(pin.tags_url, headers={"User-Agent": "hermes-home.nix-updater"})
    with urllib.request.urlopen(request, timeout=30) as response:
        tags = json.load(response)

    versions: list[tuple[tuple[int, ...], str]] = []
    for tag in tags:
        name = tag.get("name", "")
        match = re.fullmatch(pin.tag_regex, name)
        if match:
            versions.append((tuple(int(part) for part in match.group(1).split(".")), name))
    if not versions:
        raise SystemExit(f"no semver-like tags found for {pin.name}")
    return max(versions)[1]


def prefetch_hash(pin: GitHubTagPin, tag: str) -> str:
    result = subprocess.run(
        ["nix", "flake", "prefetch", f"github:{pin.owner}/{pin.repo}/{tag}", "--json"],
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return json.loads(result.stdout)["hash"]


def replace_unique(text: str, pattern: str, replacement: str, description: str) -> str:
    new_text, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"expected exactly one match for {description}, found {count}")
    return new_text


def update_pin(pin: GitHubTagPin) -> bool:
    tag = latest_tag(pin)
    version = tag.removeprefix(pin.tag_prefix)
    content = pin.file.read_text()
    current = re.search(pin.version_pattern, content)
    current_version = current.group(1) if current else None
    if current_version == version:
        print(f"{pin.name} already at {tag}")
        return False

    hash_value = prefetch_hash(pin, tag)
    content = replace_unique(content, pin.version_pattern, f'version = "{version}";', f"{pin.name} version")
    content = replace_unique(content, pin.hash_pattern, f'hash = "{hash_value}";', f"{pin.name} hash")
    pin.file.write_text(content)
    print(f"updated {pin.name} {current_version or 'unknown'} -> {version} ({hash_value})")
    return True


def main() -> int:
    changed = False
    for pin in PINS:
        changed = update_pin(pin) or changed
    if not changed:
        print("all package pins are current")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
