#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
import hashlib
import json
import re
import subprocess
import sys
import tarfile
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
FORMULAE = ("openssl@3", "opus", "json-c", "miniupnpc", "libevent")
SUBMODULES = ("curl", "gf-complete", "jerasure", "nanopb")
METADATA_PATCH = "scripts/remoteplay/patches/0002-chiaki-video-metadata.patch"


def output(*args):
    return subprocess.check_output(args, text=True, cwd=ROOT).strip()


def export(repo, destination, *paths):
    tree = output("git", "-C", repo, "ls-tree", "-rz", "--name-only", "HEAD", "--", *paths)
    if any(Path(name).name.lower() in {"agents.md", "claude.md"} for name in tree.split("\0")):
        raise SystemExit(f"Private instruction file in {repo}")
    destination.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory() as tmp:
        archive = Path(tmp) / "tree.tar"
        subprocess.run(["git", "-C", repo, "archive", "-o", archive, "HEAD", *paths], check=True)
        subprocess.run(["tar", "-xf", archive, "-C", destination], check=True)
    return output("git", "-C", repo, "rev-parse", "HEAD")


def download(url, digest, destination):
    if not url.startswith("https://") or not re.fullmatch(r"[a-f0-9]{64}", digest or ""):
        raise SystemExit(f"No checksummed HTTPS source for {destination.name}")
    subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location", "--retry", "3",
                    "--connect-timeout", "15", "--max-time", "180", "--output", destination, url], check=True)
    if hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
        raise SystemExit(f"Checksum mismatch for {destination.name}")


def export_formula(name, destination):
    formula = json.loads(output("brew", "info", "--json=v2", "--formula", name))["formulae"][0]
    version = formula["versions"]["stable"]
    revision = formula["revision"]
    expected = f"{version}_{revision}" if revision else version
    installed = Path(output("brew", "--prefix", name)).resolve().name
    if installed != expected:
        raise SystemExit(f"{name}: installed {installed}, source recipe is for {expected}")
    destination.mkdir()
    source = formula["urls"]["stable"]
    filename = Path(urlsplit(source["url"]).path).name
    download(source["url"], source["checksum"], destination / filename)
    recipe = formula["ruby_source_path"]
    tap_head = formula["tap_git_head"]
    url = f"https://raw.githubusercontent.com/Homebrew/homebrew-core/{tap_head}/{recipe}"
    download(url, formula["ruby_source_checksum"]["sha256"], destination / Path(recipe).name)
    return f"{expected}  {source['url']}"


def main(version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit("Usage: scripts/release_source.py MAJOR.MINOR.PATCH")
    name = f"Framelift-{version}-source"
    with TemporaryDirectory(prefix="framelift-source-") as tmp:
        staging = Path(tmp) / name
        revisions = [f"Framelift  {export(ROOT, staging)}"]
        vendor = ROOT / "third_party"
        sources = staging / "third_party"
        revisions.append(f"chiaki-ng  {export(vendor / 'chiaki-ng', sources / 'chiaki-ng')}")
        for submodule in SUBMODULES:
            path = Path("chiaki-ng/third-party") / submodule
            revisions.append(f"{submodule}  {export(vendor / path, sources / path)}")
        revisions.append(f"Veyra  {export(vendor / 'veyra', sources / 'veyra', METADATA_PATCH)}")
        brew_sources = sources / "homebrew"
        brew_sources.mkdir()
        for formula in FORMULAE:
            revisions.append(f"{formula}  {export_formula(formula, brew_sources / formula)}")
        (staging / "SOURCE_REVISIONS.txt").write_text("\n".join(revisions) + "\n")
        dist = ROOT / "dist"
        dist.mkdir(exist_ok=True)
        with tarfile.open(dist / f"{name}.tar.gz", "w:gz") as archive:
            archive.add(staging, arcname=name)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: scripts/release_source.py MAJOR.MINOR.PATCH")
    main(sys.argv[1])
