#!/usr/bin/env bash
# Builds the Asenaizer Windows installer: Go service + Rust tray + engines -> Inno Setup.
# Runs in Git Bash on the GitHub windows runner, from app/:
#   python packaging/fetch_engine.py --target windows --out dist/engine
#   bash packaging/windows/build_asenaizer_win.sh 0.1.0
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION="${1:-0.0.0-dev}"
for d in cpu vulkan cuda; do
  [ -f "dist/engine/$d/llama-server.exe" ] || { echo "dist/engine/$d is missing; run fetch_engine.py first" >&2; exit 1; }
done

OUT=dist/asenaizer-win
rm -rf "$OUT" && mkdir -p "$OUT"

# Icon and version resources for the service (.syso is picked up by go build).
go run github.com/tc-hib/go-winres@v0.3.3 simply --icon packaging/icon/asenaizer-1024.png --manifest gui \
  --product-name Asenaizer --file-description "Asenaizer local service" \
  --product-version "$VERSION" --file-version "$VERSION" --original-filename Humanizer.exe
# -H=windowsgui: no console window when the tray starts the service.
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w -H=windowsgui -X main.version=$VERSION" -o "$OUT/Humanizer.exe" .
rm -f rsrc_windows_*.syso

cargo build --locked --release --manifest-path tray/Cargo.toml
cp tray/target/release/asenaizer-tray.exe "$OUT/asenaizer-tray.exe"
cp -R dist/engine "$OUT/engine"
cp packaging/icon/asenaizer.ico "$OUT/asenaizer.ico"
cp ../LICENSE "$OUT/LICENSE.txt"
cp ../NOTICE "$OUT/NOTICE.txt"

ISCC="${ISCC:-/c/Program Files (x86)/Inno Setup 6/ISCC.exe}"
if [ ! -x "$ISCC" ]; then
  choco install innosetup -y --no-progress >/dev/null
fi
# Git Bash would rewrite /DAppVersion=... as a path; turn argument conversion off.
MSYS2_ARG_CONV_EXCL="*" MSYS_NO_PATHCONV=1 "$ISCC" "/DAppVersion=$VERSION" packaging/windows/asenaizer.iss

(cd dist && sha256sum Asenaizer-windows-x64-setup.exe > Asenaizer-windows-x64-setup.exe.sha256)
ls -lh dist/Asenaizer-windows-x64-setup.exe*
