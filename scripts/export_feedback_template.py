#!/usr/bin/env python3
"""Combine model runs into a review form without inventing external scores."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def export(paths: list[Path]) -> list[dict]:
    rows: dict[str, dict] = {}
    for path in paths:
        run = json.loads(path.read_text(encoding="utf-8"))
        if run.get("schema_version") != 1 or not isinstance(run.get("items"), list):
            raise ValueError(f"Unsupported run: {path}")
        for item in run["items"]:
            key = item["draft_sha256"]
            row = rows.setdefault(key, {"id": item["id"], "draft": item["draft"], "candidates": []})
            if row["draft"] != item["draft"] or row["id"] != item["id"]:
                raise ValueError(f"Conflicting draft identity in {path}")
            if item["rewrite"] not in [c["text"] for c in row["candidates"]]:
                row["candidates"].append({"text": item["rewrite"], "external_score": None,
                                          "facts_verified": False,
                                          "source_run": str(path.parent)})
    return list(rows.values())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", type=Path, nargs="+", help="results.json paths")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.output.exists():
            raise ValueError(f"Output exists: {args.output}")
        rows = export(args.runs)
        if not rows:
            raise ValueError("No candidates found")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"output": str(args.output), "drafts": len(rows),
                          "candidates": sum(len(x["candidates"]) for x in rows)}))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Feedback export failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
