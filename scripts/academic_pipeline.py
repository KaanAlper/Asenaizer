"""Shared, standard-library evaluation core for CLI and a future web API."""
from __future__ import annotations

import hashlib
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from humanizer import hz_text, promptfmt

PERCENT = re.compile(r"(?<!\w)\d+(?:[.,]\d+)?\s?%")
CITATION = re.compile(r"\b[A-Z][A-Za-z'’\-]+\s*\(\s*(?:19|20)\d{2}[a-z]?\s*\)")


def review(draft: str, rewrite: str, truncated: bool = False) -> dict:
    check = hz_text.check(draft, rewrite, truncated=truncated)
    missing_percent = sorted(set(PERCENT.findall(draft)) - set(PERCENT.findall(rewrite)))
    added_percent = sorted(set(PERCENT.findall(rewrite)) - set(PERCENT.findall(draft)))
    missing_citations = sorted(set(CITATION.findall(draft)) - set(CITATION.findall(rewrite)))
    issues = list(check.issues)
    for name, value in (("missing_percentages", missing_percent),
                        ("added_percentages", added_percent), ("missing_citations", missing_citations)):
        if value:
            issues.append(name)
    return {"issues": issues, "missing_numbers": check.missing_numbers,
            "added_numbers": check.added_numbers, "missing_urls": check.missing_urls,
            "missing_percentages": missing_percent, "added_percentages": added_percent,
            "missing_citations": missing_citations, "copy_rate": check.copy,
            "manual_review_required": True}


def request_json(url: str, data: dict | None = None, timeout: int = 30) -> dict:
    payload = json.dumps(data).encode() if data is not None else None
    request = urllib.request.Request(url, data=payload,
                                     headers={"Content-Type": "application/json"} if payload else {})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        value = json.load(response)
    if not isinstance(value, dict):
        raise ValueError(f"Expected JSON object from {url}")
    return value


def server_info(base_url: str) -> dict:
    base = base_url.rstrip("/")
    try:
        health = request_json(base + "/health", timeout=5)
    except (ValueError, urllib.error.URLError) as exc:
        raise ValueError(f"No llama-server at {base}: {exc}") from exc
    if health.get("status") != "ok":
        raise ValueError("Endpoint is not a ready llama-server model")
    try:
        props = request_json(base + "/props", timeout=5)
    except (ValueError, urllib.error.URLError) as exc:
        raise ValueError(f"Model properties unavailable at {base}: {exc}") from exc
    return {"health": health, "props": props}


def completion(draft: str, base_url: str, timeout: int = 600) -> tuple[str, bool, dict]:
    body = {"prompt": promptfmt.build_prompt(draft), "temperature": 1.0,
            "top_p": 0.95, "top_k": 0, "min_p": 0, "repeat_penalty": 1.0,
            "n_predict": 2048}
    response = request_json(base_url.rstrip("/") + "/completion", body, timeout)
    output = response.get("content")
    if not isinstance(output, str) or not output.strip():
        raise ValueError("Completion response contains no text")
    meta = {key: response.get(key) for key in ("tokens_predicted", "stopped_eos", "stopped_limit")}
    return output.strip(), bool(response.get("stopped_limit")), meta


def validate_drafts(rows: object) -> list[dict]:
    if not isinstance(rows, list) or not rows:
        raise ValueError("Input must be a nonempty JSON array")
    ids = set()
    for row in rows:
        if not isinstance(row, dict) or any(not isinstance(row.get(k), str) or not row[k].strip()
                                              for k in ("id", "title", "genre", "draft")):
            raise ValueError("Each item needs nonempty id, title, genre, draft")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", row["id"]) or row["id"] in ids:
            raise ValueError(f"Duplicate or unsafe ID: {row['id']}")
        ids.add(row["id"])
    return rows


def benchmark(rows: list[dict], base_url: str, attempts: int = 2, timeout: int = 600) -> dict:
    info = server_info(base_url)
    items = []
    for row in rows:
        samples = []
        for _ in range(attempts):
            output, truncated, meta = completion(row["draft"], base_url, timeout)
            quality = review(row["draft"], output, truncated)
            samples.append({"text": output, "review": quality, "model_response": meta})
            if not quality["issues"]:
                break
        chosen = min(range(len(samples)), key=lambda i: (
            len(samples[i]["review"]["issues"]), samples[i]["review"]["copy_rate"]))
        items.append({**row, "draft_sha256": hashlib.sha256(row["draft"].encode()).hexdigest(),
                      "rewrite": samples[chosen]["text"], "review": samples[chosen]["review"],
                      "chosen_attempt": chosen + 1, "attempts": samples,
                      "external_score": None})
    return {"schema_version": 1, "created_at": datetime.now(timezone.utc).isoformat(),
            "server_url": base_url, "server": info,
            "prompt_fingerprint": promptfmt.fingerprint(), "sampling": {
                "temperature": 1.0, "top_p": 0.95, "top_k": 0, "min_p": 0,
                "repeat_penalty": 1.0, "n_predict": 2048}, "items": items}


def save_benchmark(data: dict, output_root: Path, run_id: str | None = None) -> Path:
    stamp = run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    run_dir = output_root / stamp
    run_dir.mkdir(parents=True, exist_ok=False)
    (run_dir / "results.json").write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for item in data["items"]:
        (run_dir / (item["id"] + ".txt")).write_text(item["rewrite"] + "\n", encoding="utf-8")
    return run_dir
