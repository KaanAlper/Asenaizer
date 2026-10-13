"""Regression tests for the academic CLI's data and server boundaries."""
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from academic_pipeline import benchmark, review, save_benchmark, server_info, validate_drafts
from export_feedback_template import export
from prepare_dpo_dataset import build_dataset
from train_dpo_lora import inspect_data
from humanizer.promptfmt import build_prompt


class Handler(BaseHTTPRequestHandler):
    calls = []
    def log_message(self, *_args):
        pass
    def do_GET(self):
        body = {"status": "ok"} if self.path == "/health" else {"model_path": "fixture.gguf"}
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.calls.append(payload)
        body = {"content": "The result was 34.2% across 4096 tokens.", "stopped_eos": True,
                "stopped_limit": False, "tokens_predicted": 20}
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())


class AcademicPipelineTests(unittest.TestCase):
    def test_guard_catches_percent_citation_and_new_number(self):
        r = review("Srnicek (2017) reported 34.2%.", "Someone (2017) reported 34.2 and 99 cases.")
        self.assertIn("missing_percentages", r["issues"])
        self.assertIn("missing_citations", r["issues"])
        self.assertIn("added_numbers", r["issues"])

    def test_benchmark_contract_and_export(self):
        Handler.calls = []
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}"
            rows = validate_drafts([{"id": "X1", "title": "Test", "genre": "Method",
                                     "draft": "The result was 34.2% across 4096 tokens."}])
            data = benchmark(rows, url, attempts=2)
            self.assertEqual(data["items"][0]["chosen_attempt"], 1)
            self.assertEqual(Handler.calls[0]["top_k"], 0)
            self.assertNotIn("stop", Handler.calls[0])
            with tempfile.TemporaryDirectory() as tmp:
                path = save_benchmark(data, Path(tmp), "run1")
                feedback = export([path / "results.json"])
                self.assertIsNone(feedback[0]["candidates"][0]["external_score"])
                self.assertFalse(feedback[0]["candidates"][0]["facts_verified"])
        finally:
            server.shutdown()
            server.server_close()

    def test_bad_feedback_never_becomes_chosen(self):
        rows = [{"id": "X", "draft": "The result was 34.2% across 4096 tokens.",
                 "candidates": [
                     {"text": "The result was 34.2 across 4096 tokens.",
                      "external_score": 1, "facts_verified": True},
                     {"text": "Across 4096 tokens, the result was 34.2%.",
                      "external_score": 5, "facts_verified": True}]}]
        pairs, report = build_dataset(rows)
        self.assertEqual(pairs[0]["chosen"], rows[0]["candidates"][1]["text"])
        self.assertEqual(report["accepted"], 1)

    def test_no_unreviewed_pair_and_training_preflight(self):
        rows = [{"id": "X", "draft": "42 days", "candidates": [
            {"text": "42 days, according to the study", "external_score": 2, "facts_verified": False},
            {"text": "43 days", "external_score": 80, "facts_verified": False}]}]
        pairs, report = build_dataset(rows)
        self.assertEqual(pairs, [])
        self.assertEqual(report["rejected"], 1)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "train.jsonl"
            path.write_text(json.dumps({"prompt": build_prompt("A draft"),
                                        "chosen": "a", "rejected": "b"}) + "\n")
            self.assertEqual(inspect_data(path)["pairs"], 1)


if __name__ == "__main__":
    unittest.main()
