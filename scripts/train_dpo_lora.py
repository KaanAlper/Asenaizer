#!/usr/bin/env python3
"""Train a DPO LoRA adapter after validating the reviewed preference data."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

from academic_pipeline import ROOT
from humanizer.promptfmt import INSTR, SEP, fingerprint


def inspect_data(path: Path) -> dict:
    if not path.is_file():
        raise ValueError(f"Training data missing: {path}")
    rows = []
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"Invalid JSON on line {line_no}: {exc}") from exc
        if not isinstance(row, dict) or any(not isinstance(row.get(k), str) or not row[k].strip()
                                              for k in ("prompt", "chosen", "rejected")):
            raise ValueError(f"Line {line_no}: prompt, chosen, rejected must be nonempty strings")
        if row["chosen"] == row["rejected"]:
            raise ValueError(f"Line {line_no}: identical completions")
        if not row["prompt"].startswith(INSTR + "\n\n") or not row["prompt"].endswith(SEP):
            raise ValueError(f"Line {line_no}: prompt format differs from the model format")
        rows.append(row)
    if not rows:
        raise ValueError("Training data is empty")
    return {"pairs": len(rows), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "prompt_fingerprint": fingerprint()}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="jialinyyzz/humanizer")
    parser.add_argument("--data", type=Path, default=ROOT / "eval/dpo_dataset/train.jsonl")
    parser.add_argument("--output", type=Path, default=ROOT / "output/asenaizer_lora")
    parser.add_argument("--min-pairs", type=int, default=100)
    parser.add_argument("--epochs", type=float, default=1)
    parser.add_argument("--learning-rate", type=float, default=5e-6)
    parser.add_argument("--beta", type=float, default=0.1)
    parser.add_argument("--max-length", type=int, default=2048)
    parser.add_argument("--preflight", action="store_true", help="Validate data without loading the model")
    args = parser.parse_args(argv)
    try:
        info = inspect_data(args.data)
        if args.preflight:
            print(json.dumps({**info, "ready_for_training": info["pairs"] >= args.min_pairs}, indent=2))
            return 0
        if info["pairs"] < args.min_pairs:
            raise ValueError(f"Only {info['pairs']} pairs; require at least {args.min_pairs}")
        if args.output.exists() and any(args.output.iterdir()):
            raise ValueError(f"Output directory is not empty: {args.output}")

        import torch
        from datasets import load_dataset
        from peft import LoraConfig, prepare_model_for_kbit_training
        from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
        from trl import DPOConfig, DPOTrainer

        if not torch.cuda.is_available():
            raise ValueError("CUDA GPU unavailable; refusing CPU training")
        tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=False)
        if tokenizer.pad_token is None:
            tokenizer.pad_token = tokenizer.eos_token
        quant = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                                   bnb_4bit_compute_dtype=torch.bfloat16,
                                   bnb_4bit_use_double_quant=True)
        model = AutoModelForCausalLM.from_pretrained(args.model, quantization_config=quant,
                                                     dtype=torch.bfloat16, device_map="auto",
                                                     trust_remote_code=False)
        model = prepare_model_for_kbit_training(model)
        peft_config = LoraConfig(r=32, lora_alpha=64, lora_dropout=0.05, bias="none",
                                 task_type="CAUSAL_LM", target_modules=[
                                     "q_proj", "k_proj", "v_proj", "o_proj",
                                     "gate_proj", "up_proj", "down_proj"])
        config = DPOConfig(output_dir=str(args.output), num_train_epochs=args.epochs,
                           per_device_train_batch_size=1, gradient_accumulation_steps=8,
                           learning_rate=args.learning_rate, lr_scheduler_type="cosine",
                           warmup_ratio=0.1, logging_steps=5, save_strategy="epoch",
                           bf16=True, report_to="none", beta=args.beta,
                           max_length=args.max_length, truncation_mode="keep_start",
                           seed=42)
        dataset = load_dataset("json", data_files=str(args.data), split="train")
        trainer = DPOTrainer(model=model, ref_model=None, args=config,
                             train_dataset=dataset, processing_class=tokenizer,
                             peft_config=peft_config)
        trainer.train()
        trainer.save_model(str(args.output))
        tokenizer.save_pretrained(str(args.output))
        (args.output / "asenaizer_run.json").write_text(json.dumps({
            **info, "base_model": args.model, "epochs": args.epochs,
            "learning_rate": args.learning_rate, "beta": args.beta}, indent=2) + "\n")
        print(json.dumps({"adapter": str(args.output), **info}))
        return 0
    except (OSError, ValueError, ImportError) as exc:
        print(f"Training not started/completed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
