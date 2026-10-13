# Asenaizer delivery plan

Updated: 2026-10-13

## Implemented in this checkout

- Static English website under `docs/`, with local pairing and a focused rewrite editor.
- Go loopback bridge with exact origin and bearer pairing, plus inactive model deletion.
- Rust tray helper and a small local device settings page.
- Linux source installer with checksum-pinned llama.cpp release assets and rollback of a prior app
  directory if installation fails.
- Academic benchmark runner, feedback template export, reviewed DPO dataset builder,
  and training preflight. Existing mock result files are clearly separated from real runs.

## Before the first public release

1. Run a full Linux install on a clean machine. Confirm CUDA/CPU engine discovery,
   model download and checksum, pairing in supported browsers, inference, deletion,
   login startup, and uninstall behavior.
2. Integrate the Rust tray into Windows and macOS release packages. Add a narrow
   settings surface and test installation and rollback with the existing packagers.
3. Create a dedicated `KaanAlper/Asenaizer` repository. Update release identifiers,
   download links, and site origin there. Review the exact files before publication.
4. Add release artifact checksums and smoke tests to CI. Publish only after clean
   installer runs on each supported operating system.
5. Check accessibility, mobile layout, browser local network permissions, cancellation,
   and long document behavior. A 1,000 word request cap currently keeps the web path
   within the engine context; the long document path is still in the local app and `hz`.

## Research and model work

1. Benchmark the open Humanizer model on real held out academic drafts. Record elapsed
   time, GPU memory, copy rate, fact changes, citation preservation, and detector results
   only when an authorized detector measurement is actually available.
2. Compare related open source humanizer tools and published claims against their code,
   model cards, licenses, and reproducible evidence. Treat “guaranteed pass” claims as
   unverified until independent testing supports them.
3. Collect reviewed preferences, then run DPO only after the preflight threshold is met.
   Keep the base model, adapter, benchmark inputs, and evaluation outputs versioned.
4. Reevaluate on data excluded from training. Reject changes that improve one score
   while introducing unsupported facts or losing citations.

No exact Turnitin result or universal detector bypass is claimed by this plan.
