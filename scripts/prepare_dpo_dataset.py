#!/usr/bin/env python3
"""Validate reviewed candidates and write DPO JSONL plus an audit report.

Candidate scores and factual approval must come from a separate review. The
automatic checks are useful guards, not proof that a claim stayed correct.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

from academic_pipeline import ROOT, review
from humanizer.promptfmt import build_prompt


def score(value: object) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 100:
        raise ValueError("external_score must be a number from 0 to 100")
    return float(value)


def choose(row: dict, max_score: float, min_gap: float) -> tuple[dict | None, dict]:
    item_id = row.get("id")
    draft = row.get("draft")
    candidates = row.get("candidates")
    if not isinstance(item_id, str) or not item_id or not isinstance(draft, str) or not draft.strip():
        raise ValueError("Each row requires id and draft")
    if not isinstance(candidates, list) or len(candidates) < 2:
        raise ValueError(f"{item_id}: at least two candidates are required")
    assessed = []
    for index, candidate in enumerate(candidates):
        if not isinstance(candidate, dict) or not isinstance(candidate.get("text"), str) or not candidate["text"].strip():
            raise ValueError(f"{item_id}: candidate {index} has no text")
        s = score(candidate.get("external_score"))
        checks = review(draft, candidate["text"])
        verified = candidate.get("facts_verified") is True
        assessed.append({"index": index, "score": s, "review": checks,
                         "facts_verified": verified, "text": candidate["text"].strip(),
                         "eligible": verified and not checks["issues"] and s <= max_score})
    valid = sorted((x for x in assessed if x["eligible"]), key=lambda x: x["score"])
    audit = {"id": item_id, "draft_sha256": hashlib.sha256(draft.encode()).hexdigest(),
             "candidates": [{k: v for k, v in x.items() if k != "text"} for x in assessed]}
    if not valid:
        audit["reason"] = "no_fact_verified_candidate_below_score_limit"
        return None, audit
    chosen = valid[0]
    alternatives = [x for x in assessed if x["index"] != chosen["index"] and x["text"] != chosen["text"]
                    and (not x["facts_verified"] or x["review"]["issues"] or x["score"] - chosen["score"] >= min_gap)]
    if not alternatives:
        audit["reason"] = "no_distinct_rejected_candidate_with_quality_gap"
        return None, audit
    rejected = max(alternatives, key=lambda x: (not x["facts_verified"], len(x["review"]["issues"]), x["score"]))
    audit.update({"chosen_index": chosen["index"], "rejected_index": rejected["index"], "reason": "accepted"})
    return {"prompt": build_prompt(draft), "chosen": chosen["text"], "rejected": rejected["text"]}, audit


def build_dataset(rows: object, max_score: float = 10, min_gap: float = 20) -> tuple[list[dict], dict]:
    if not isinstance(rows, list) or not rows:
        raise ValueError("Feedback must be a nonempty JSON array")
    pairs, audit, seen = [], [], set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("Every feedback row must be an object")
        if row.get("example_only"):
            raise ValueError("Example feedback cannot be used for training")
        pair, detail = choose(row, max_score, min_gap)
        if detail["id"] in seen or detail["draft_sha256"] in seen:
            raise ValueError(f"Repeated id or draft: {detail['id']}")
        seen.update((detail["id"], detail["draft_sha256"]))
        audit.append(detail)
        if pair:
            pairs.append(pair)
    return pairs, {"schema_version": 1, "rows": len(rows), "accepted": len(pairs),
                   "rejected": len(rows) - len(pairs), "items": audit}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="Reviewed feedback JSON")
    parser.add_argument("--output", type=Path, default=ROOT / "eval/dpo_dataset/train.jsonl")
    parser.add_argument("--report", type=Path, default=ROOT / "eval/dpo_dataset/build_report.json")
    parser.add_argument("--max-score", type=float, default=10)
    parser.add_argument("--min-gap", type=float, default=20)
    parser.add_argument("--force", action="store_true", help="Replace previous generated files")
    args = parser.parse_args(argv)
    if not 0 <= args.max_score <= 100 or not 0 <= args.min_gap <= 100:
        parser.error("Score limits must be between 0 and 100")
    try:
        if not args.force and (args.output.exists() or args.report.exists()):
            raise ValueError("Output exists; use --force to replace generated files")
        rows = json.loads(args.input.read_text(encoding="utf-8"))
        pairs, report = build_dataset(rows, args.max_score, args.min_gap)
        if not pairs:
            raise ValueError("No eligible preference pairs; inspect feedback and quality checks")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text("".join(json.dumps(p, ensure_ascii=False) + "\n" for p in pairs), encoding="utf-8")
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"train": str(args.output), "report": str(args.report),
                          "accepted": report["accepted"], "rejected": report["rejected"]}))
        return 0
    except (OSError, ValueError, TypeError) as exc:
        print(f"Dataset build failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
