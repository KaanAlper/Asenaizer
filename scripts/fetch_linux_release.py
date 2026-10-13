#!/usr/bin/env python3
"""Find, download and verify the newest Asenaizer Linux release.

Usage: fetch_linux_release.py OUT_DIR [--status STATUS_JSON] [--cancel CANCEL_FILE]

Releases are tagged v<semver>. The fixed "setup" release that carries the setup programs is
the repository's "latest", so /releases/latest is never used; every page of releases is read
and the highest non-draft, non-prerelease version with exactly one Linux archive and its
.sha256 wins (the same rule as the Windows install.ps1, installer/PROTOCOL.md).

With --status the progress is written there as the installer protocol's status.json (phases
release, download, verify, extract); otherwise a progress bar is drawn on stderr.

Exit codes: 0 installed into OUT_DIR, 2 cancelled, 3 no release published (the caller may
build from source), 1 any other failure.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = "KaanAlper/Asenaizer"
RELEASES = f"https://api.github.com/repos/{REPO}/releases?per_page=100&page={{page}}"
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
USER_AGENT = "Asenaizer-Install"
TRIES = 5
CHUNK = 1 << 17


class Cancelled(Exception):
    pass


class Reporter:
    """Writes status.json atomically, or draws a console bar when there is no driver."""

    def __init__(self, status: Path | None, cancel: Path | None) -> None:
        self.status, self.cancel, self.last = status, cancel, 0.0
        self.version = ""

    def check_cancel(self) -> None:
        if self.cancel and self.cancel.exists():
            raise Cancelled()

    def report(self, phase: str, **fields: object) -> None:
        self.check_cancel()
        if self.status:
            data = {"phase": phase, "version": self.version, **fields}
            tmp = self.status.with_suffix(".tmp")
            tmp.write_text(json.dumps(data), encoding="utf-8")
            os.replace(tmp, self.status)
        elif phase != "download":
            print({"release": "Finding the newest release…", "verify": "Checking SHA-256…",
                   "extract": "Unpacking…"}.get(phase, phase), file=sys.stderr, flush=True)

    def download(self, done: int, total: int, speed: float) -> None:
        now = time.monotonic()
        if now - self.last < 0.1 and done < total:
            return
        self.last = now
        percent = int(done * 100 / total) if total else 0
        if self.status:
            self.report("download", percent=percent, done=done, total=total, speed=int(speed))
            return
        self.check_cancel()
        # one line redrawn in place: narrower than the terminal, or each redraw wraps onto a new line
        width = max(5, min(30, shutil.get_terminal_size((80, 24)).columns - 50))
        filled = width * percent // 100
        print(f"\r  [{'█' * filled}{'░' * (width - filled)}] {percent:3d}%  "
              f"{done / 1e6:7.1f} / {total / 1e6:.1f} MB  {speed / 1e6:5.1f} MB/s",
              end="", file=sys.stderr, flush=True)
        if done >= total:
            print(file=sys.stderr)


def open_url(url: str, offset: int = 0):
    headers = {"User-Agent": USER_AGENT}
    if offset:
        headers["Range"] = f"bytes={offset}-"
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60)


def newest_release() -> tuple[str, dict[str, str]] | None:
    """Returns (version, {asset name: url}) for the highest complete v<semver> release."""
    best: tuple[tuple[int, int, int], str, dict[str, str]] | None = None
    for page in range(1, 20):
        with open_url(RELEASES.format(page=page)) as response:
            releases = json.load(response)
        if not releases:
            break
        for release in releases:
            match = TAG_RE.match(release.get("tag_name", ""))
            if not match or release.get("draft") or release.get("prerelease"):
                continue
            version = ".".join(match.groups())
            assets = {a["name"]: a["browser_download_url"] for a in release.get("assets", [])}
            name = f"Asenaizer-{version}-linux-x64.tar.gz"
            if name not in assets or name + ".sha256" not in assets:
                continue
            key = tuple(int(part) for part in match.groups())
            if best is None or key > best[0]:
                best = (key, version, {name: assets[name], name + ".sha256": assets[name + ".sha256"]})
    return None if best is None else (best[1], best[2])


def download(url: str, target: Path, reporter: Reporter) -> None:
    """Downloads with HTTP range resume and retries."""
    part = target.with_suffix(target.suffix + ".part")
    for attempt in range(1, TRIES + 1):
        offset = part.stat().st_size if part.exists() else 0
        try:
            with open_url(url, offset) as response:
                if offset and response.status != 206:
                    offset = 0  # the server ignored the range; start over
                total = offset + int(response.headers.get("Content-Length") or 0)
                start, done = time.monotonic(), offset
                with part.open("ab" if offset else "wb") as out:
                    while block := response.read(CHUNK):
                        out.write(block)
                        done += len(block)
                        elapsed = max(time.monotonic() - start, 1e-3)
                        reporter.download(done, total, (done - offset) / elapsed)
            part.replace(target)
            return
        except urllib.error.HTTPError as error:
            if error.code == 416:
                part.unlink(missing_ok=True)
            elif error.code in (403, 404, 410):
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            pass
        if attempt == TRIES:
            raise RuntimeError("Download failed after several tries")
        time.sleep(2 * attempt)


def fetch(out: Path, reporter: Reporter) -> int:
    reporter.report("release")
    found = newest_release()
    if found is None:
        print("No published Linux release yet.", file=sys.stderr)
        return 3
    version, assets = found
    reporter.version = version
    name = f"Asenaizer-{version}-linux-x64.tar.gz"
    with open_url(assets[name + ".sha256"]) as response:
        checksum = response.read(1024).decode("ascii").strip().split()
    if not checksum or not re.fullmatch(r"[a-f0-9]{64}", checksum[0]):
        raise RuntimeError("Malformed release checksum")
    archive = out.parent / name
    download(assets[name], archive, reporter)
    reporter.report("verify")
    digest = hashlib.sha256()
    with archive.open("rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            digest.update(block)
    if digest.hexdigest() != checksum[0]:
        archive.unlink(missing_ok=True)
        raise RuntimeError("Release archive SHA-256 mismatch")
    reporter.report("extract")
    with tarfile.open(archive) as source:
        try:
            source.extractall(out, filter="data")
        except TypeError:  # Python < 3.12; the verified archive is built by our workflow
            source.extractall(out)
    archive.unlink(missing_ok=True)
    if not (out / "Humanizer").is_file() or not (out / "asenaizer-tray").is_file():
        raise RuntimeError("Release archive is incomplete")
    (out / "VERSION").write_text(version + "\n", encoding="utf-8")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("out", type=Path)
    parser.add_argument("--status", type=Path)
    parser.add_argument("--cancel", type=Path)
    args = parser.parse_args()
    reporter = Reporter(args.status, args.cancel)
    try:
        return fetch(args.out, reporter)
    except Cancelled:
        return 2
    except Exception as error:  # reported to the user by the installer
        print(f"Release installation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
