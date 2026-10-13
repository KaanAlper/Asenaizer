#!/usr/bin/env python3
"""Fetch and verify the latest published Asenaizer Linux release.

Exit 3 means no release is published, so the installer may build from source.
Other errors mean a release exists but could not be verified or installed.
"""

import hashlib
import json
import re
import shutil
import sys
import tarfile
import urllib.error
import urllib.request
from pathlib import Path


API = "https://api.github.com/repos/KaanAlper/Asenaizer/releases/latest"


def open_url(url):
    return urllib.request.urlopen(
        urllib.request.Request(url, headers={"User-Agent": "asenaizer-installer/0.1"}),
        timeout=120,
    )


def main(out):
    try:
        with open_url(API) as response:
            release = json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            print("No published Linux release yet; building from source.")
            return 3
        raise
    assets = {asset["name"]: asset["browser_download_url"] for asset in release["assets"]}
    names = [name for name in assets if re.fullmatch(r"Asenaizer-[\w.\-]+-linux-x64\.tar\.gz", name)]
    if len(names) != 1 or names[0] + ".sha256" not in assets:
        raise RuntimeError("The release is missing one Linux archive or checksum file")
    name = names[0]
    with open_url(assets[name + ".sha256"]) as response:
        checksum = response.read(1024).decode("ascii").strip()
    match = re.fullmatch(r"([a-f0-9]{64})\s+" + re.escape(name), checksum)
    if not match:
        raise RuntimeError("Malformed release checksum")
    archive = out.parent / name
    print(f"Downloading {name}…", flush=True)
    with open_url(assets[name]) as response, archive.open("wb") as target:
        shutil.copyfileobj(response, target, 1 << 20)
    digest = hashlib.sha256()
    with archive.open("rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            digest.update(block)
    if digest.hexdigest() != match.group(1):
        raise RuntimeError("Release archive SHA-256 mismatch")
    print("Release SHA-256 verified.", flush=True)
    with tarfile.open(archive) as source:
        try:
            source.extractall(out, filter="data")
        except TypeError:  # Python < 3.12; the verified archive is built by our workflow
            source.extractall(out)
    if not (out / "Humanizer").is_file() or not (out / "asenaizer-tray").is_file():
        raise RuntimeError("Release archive is incomplete")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(Path(sys.argv[1])))
    except Exception as error:
        print(f"Release installation failed: {error}", file=sys.stderr)
        sys.exit(1)
