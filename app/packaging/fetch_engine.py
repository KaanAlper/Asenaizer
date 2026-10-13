#!/usr/bin/env python3
"""Download checksum-pinned official llama.cpp binaries into launcher directories:

  macos   → <out>/metal/{llama-server, *.dylib, LICENSE}
  windows → <out>/cpu/    {llama-server.exe, *.dll, LICENSE}
            <out>/vulkan/ {...}
            <out>/cuda/   {... + cudart/cublas runtime libraries}

Keep llama-server and its dynamic libraries; omit unrelated tools.
Usage: python3 packaging/fetch_engine.py --target linux --out dist/engine
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
LAYOUT = {
    "macos": [("metal", ["macos-arm64"])],
    "linux": [
        ("cpu", ["ubuntu-x64"]),
        ("vulkan", ["ubuntu-vulkan-x64"]),
        ("cuda", ["ubuntu-cuda-12.8-x64", "ubuntu-cudart-12.8-x64"]),
    ],
    "windows": [
        ("cpu", ["win-cpu-x64"]),
        ("vulkan", ["win-vulkan-x64"]),
        ("cuda", ["win-cuda-12.4-x64", "win-cudart-12.4-x64"]),
    ],
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(lock, key, cache):
    a = lock["assets"][key]
    dst = os.path.join(cache, a["file"])
    if os.path.exists(dst) and sha256(dst) == a["sha256"]:
        print(f"  Cached {a['file']}")
        return dst
    url = f"{lock['base_url']}/{a['file']}"
    print(f"  Downloading {url}")
    tmp = dst + ".tmp"
    try:
        with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
            total = int(r.headers.get("Content-Length") or 0)
            done, last_percent = 0, -1
            while chunk := r.read(1 << 20):
                f.write(chunk)
                done += len(chunk)
                if total:
                    percent = min(100, done * 100 // total)
                    if percent // 10 != last_percent // 10:
                        print(f"    {percent}% · {done / (1 << 20):.0f} / {total / (1 << 20):.0f} MiB", flush=True)
                        last_percent = percent
    except Exception:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise
    print("    Verifying SHA-256…", flush=True)
    got = sha256(tmp)
    if got != a["sha256"]:
        os.remove(tmp)
        sys.exit(f"SHA-256 mismatch: {a['file']}\n  expected {a['sha256']}\n  actual   {got}")
    os.replace(tmp, dst)
    return dst


def extract(archive, into):
    if archive.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            z.extractall(into)
    else:
        with tarfile.open(archive) as t:
            try:
                t.extractall(into, filter="data")  # Python ≥3.12
            except TypeError:
                t.extractall(into)


def wanted(name):
    low = name.lower()
    if low in ("llama-server", "llama-server.exe") or low.startswith("license"):
        return True
    return low.endswith((".dylib", ".dll", ".so")) or ".so." in low


def collect(src_root, dest):
    os.makedirs(dest, exist_ok=True)
    n = 0
    for root, _, files in os.walk(src_root):
        for fn in files:
            if not wanted(fn):
                continue
            s, d = os.path.join(root, fn), os.path.join(dest, fn)
            if os.path.lexists(d):
                os.remove(d)
            if os.path.islink(s):  # Preserve links such as libggml.dylib -> libggml.0.dylib.
                os.symlink(os.readlink(s), d)
            else:
                shutil.copy2(s, d)
            n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", choices=sorted(LAYOUT), required=True)
    ap.add_argument("--backend", action="append", help="Only fetch these backends (repeatable)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--cache", default=os.path.join(HERE, "..", "dist", "engine-cache"))
    args = ap.parse_args()
    with open(os.path.join(HERE, "llama-cpp.lock.json"), encoding="utf-8") as f:
        lock = json.load(f)
    os.makedirs(args.cache, exist_ok=True)
    print(f"llama.cpp {lock['tag']} ({lock['commit']}) -> {args.out}")
    for name, keys in LAYOUT[args.target]:
        if args.backend and name not in args.backend:
            continue
        dest = os.path.join(args.out, name)
        shutil.rmtree(dest, ignore_errors=True)
        total = 0
        for key in keys:
            arc = fetch(lock, key, args.cache)
            with tempfile.TemporaryDirectory() as tmp:
                extract(arc, tmp)
                total += collect(tmp, dest)
        server = os.path.join(dest, "llama-server.exe" if args.target == "windows" else "llama-server")
        if not os.path.exists(server):
            sys.exit(f"{name}: archive does not contain llama-server")
        with open(os.path.join(dest, "ENGINE_VERSION.txt"), "w") as f:
            f.write(f"llama.cpp {lock['tag']} {lock['commit']} ({', '.join(keys)})\n")
        print(f"  {name}: {total} files")


if __name__ == "__main__":
    main()
