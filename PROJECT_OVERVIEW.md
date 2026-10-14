# Asenaizer project overview

Updated: 2026-10-13

## Goal

Asenaizer is a web interface for rewriting drafts with a model that runs on each user's
own computer. The public website is static and can be hosted on GitHub Pages. A local
helper downloads and runs the model on the user's hardware. The browser pairs with that
helper through a loopback bridge. The model and draft do not pass through GitHub Pages.

The academic evaluation work aims to improve rewriting quality and factual fidelity.
AI detector scores are measurements, never guaranteed outcomes. A rewrite still needs
human review of numbers, dates, names, citations, and the direction of claims.

## Architecture

| Part | Current implementation | Responsibility |
| --- | --- | --- |
| Website | `docs/` | Connection screen, full-height Draft / Result workspace, model selection, word diff, result checks |
| Local service | `app/` (Go) | Model download and SHA-256 verification, llama.cpp engine, loopback API |
| Tray | `app/tray/` (Rust/Wry) | Starts the local service and opens a small native device settings window |
| Device settings | `app/web/tray.html` | Model download, selection, deletion, progress and pause controls |
| Academic pipeline | `scripts/academic_pipeline.py` | Reproducible local benchmark runs with prompt and output checks |
| Training tools | `scripts/prepare_dpo_dataset.py`, `scripts/train_dpo_lora.py` | Review gated data export and DPO preflight |

The layout follows [Logical Lunge](https://github.com/KaanAlper/logical-lunge): a
shared core, separate interfaces, and a reviewable installation path. The runtime
is `llama.cpp`; Rust replaces Python for the desktop helper, while Go retains the
existing download and engine management code. There is no need to build or train
another general purpose Llama model merely to run the existing Humanizer weights.

## Current status

- The site, pairing bridge, model management controls, tray, and Linux installer are
  implemented locally. The installer fetches checksum-pinned llama.cpp binaries and installs
  per user. Windows/macOS tray packaging has not yet been integrated into releases.
- The bridge checks the exact configured origin and requires user approval and a random
  session key. It listens on loopback. Browser local network permission still depends
  on the user's browser. When the user turns on "Other computers" in the tray, a second
  listener serves the website itself on port 47630 of every interface, with only the paired
  `/bridge/*` routes behind it (`app/internal/launcher/lan.go`); `/app/*` and `/api/*` stay
  on loopback. That traffic is plain HTTP on the local network.
- The tray checks GitHub releases (`v<semver>`) and installs an update with the package's own
  installer (`installer/setup.ps1 -KeepChoices`, `install-linux.sh` with `ASZ_KEEP_CHOICES=1`),
  run by a copy of the service from the data folder (`update_asenaizer.go`).
- Q8, Q6, Q4, Q3 and 2-bit GGUF hashes are configured. Q6 downloaded and passed SHA-256
  verification on an RTX 5080 Laptop GPU. The installed CUDA llama.cpp runtime reached
  ready state and produced a 29-token rewrite in 2.13 seconds in one local smoke test.
- The academic benchmark and training scripts have tests. They do not constitute a
  trained Asenaizer model or a verified Turnitin result. Existing mock baseline results
  must not be presented as measurements.
- The site and installer are not published. The current Git remote points to the
  upstream Humanizer repository. Deployment requires a dedicated Asenaizer repository.

## Model handling and intellectual property

The upstream Humanizer model is open under Apache 2.0 and remains obtainable outside
this app. Packaging model weights with a decrypting local application can deter casual
copying, but cannot reliably prevent extraction by a user who controls that computer.
This project prioritizes the user's local GPU and does not claim effective DRM.

## Evaluation gates

1. Run the real model with the exact completion prompt and sampling settings. Record
   speed, memory use, and output quality on the target GPU and smaller devices.
2. Establish an academic baseline on held out texts. Keep detector name, version,
   date, input and output, and repository setting with each result. Do not infer a
   Turnitin result from a different detector.
3. Review factual fidelity and citations before accepting any training pair. Train
   only after enough reviewed pairs exist, with separate held out evaluation data.
4. Package and smoke test Linux, Windows, and macOS releases. Test install, update,
   cancellation, uninstall, and rollback on clean devices.
5. Publish the site and installer after release artifacts and URLs are confirmed.

## Constraints

The exact prompt format is defined by `prompt_format.json` and tested by its fingerprint.
The model is a text completion model; requests use `/completion`, with temperature 1.0,
top-p 0.95, top-k 0, min-p 0, repetition penalty 1.0, and no stop strings.
