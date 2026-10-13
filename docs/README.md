# Asenaizer web interface

This directory is a static site that can be deployed to GitHub Pages. Models and user text
are never uploaded to Pages. The local helper under `app/` downloads the model, runs it on
the user's GPU, and serves a loopback API to the paired page only.

## Local development

1. Start the helper with `cd app && go run . --no-browser --idle-exit 0`.
   Packaged builds include the model runtime. When running from source, you may need
   `--engine cuda=/path/to/llama-server`.
2. Serve `docs/` from a local static server. The bridge accepts
   `https://kaanalper.github.io` by default, so start the helper with
   `--web-origin http://127.0.0.1:5500` for local testing.
3. Open the site, enter the helper port (default: 47615), and select **Connect device**.
   Approve access in the local pairing window to see the model status.

To deploy, connect this checkout to your `KaanAlper/Asenaizer` repository and set the
GitHub Pages source to **GitHub Actions**. `.github/workflows/pages.yml` deploys `docs/`.
The current `origin` points to the upstream project; do not push the fork there.

## Security boundary

- The bridge listens only on `127.0.0.1` and allows a single configured web origin.
- The user explicitly approves access in the local pairing window. A random pairing key
  changes on every helper launch and stays in the tab's session storage.
- The browser may ask for local network access. The browser controls that permission.
- Encrypting a model file stored on the user's computer cannot prevent a determined local
  user from extracting weights. The open upstream model remains available separately.
