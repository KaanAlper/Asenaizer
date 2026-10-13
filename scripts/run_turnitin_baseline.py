#!/usr/bin/env python3
"""Run local model rewrites on a versioned evaluation set; never upload them."""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from academic_pipeline import ROOT, benchmark, save_benchmark, validate_drafts


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=ROOT / "eval/academic_drafts.json")
    parser.add_argument("--server", default="http://127.0.0.1:8081")
    parser.add_argument("--output-root", type=Path, default=ROOT / "eval/turnitin_benchmark/runs")
    parser.add_argument("--attempts", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    if not 1 <= args.attempts <= 3 or args.timeout < 1:
        parser.error("--attempts must be 1..3 and --timeout must be positive")
    try:
        rows = validate_drafts(json.loads(args.input.read_text(encoding="utf-8")))
        if args.dry_run:
            print(json.dumps({"items": len(rows), "ids": [x["id"] for x in rows],
                              "server": args.server}, indent=2))
            return 0
        start = time.monotonic()
        result = benchmark(rows, args.server, args.attempts, args.timeout)
        run_dir = save_benchmark(result, args.output_root)
        print(json.dumps({"run_dir": str(run_dir), "items": len(rows),
                          "flagged": sum(bool(x["review"]["issues"]) for x in result["items"]),
                          "seconds": round(time.monotonic() - start, 1)}))
        return 0
    except (OSError, ValueError, TypeError) as exc:
        print(f"Benchmark failed; no completed run was written: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
