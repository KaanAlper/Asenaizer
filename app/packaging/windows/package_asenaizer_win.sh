#!/usr/bin/env bash
# Builds the Asenaizer Windows package (installer/PROTOCOL.md): service + tray + engines, plus
# the shared setup scripts, zipped with a .sha256. install.ps1 / the setup exe install it.
# Runs in Git Bash on the GitHub windows runner, from app/:
#   python packaging/fetch_engine.py --target windows --out dist/engine
#   bash packaging/windows/package_asenaizer_win.sh 0.1.0
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION="${1:?version}"
for d in cpu vulkan cuda; do
  [ -f "dist/engine/$d/llama-server.exe" ] || { echo "dist/engine/$d is missing; run fetch_engine.py first" >&2; exit 1; }
done

PKG=dist/pkg
rm -rf "$PKG" && mkdir -p "$PKG/app" "$PKG/installer"

# Icon and version resources for the service (.syso is picked up by go build).
go run github.com/tc-hib/go-winres@v0.3.3 simply --icon packaging/icon/asenaizer-1024.png --manifest gui \
  --product-name Asenaizer --file-description "Asenaizer local service" \
  --product-version "$VERSION" --file-version "$VERSION" --original-filename Humanizer.exe
# -H=windowsgui: no console window when the tray starts the service.
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w -H=windowsgui -X main.version=$VERSION" -o "$PKG/app/Humanizer.exe" .
rm -f rsrc_windows_*.syso

cargo build --locked --release --manifest-path tray/Cargo.toml
cp tray/target/release/asenaizer-tray.exe "$PKG/app/asenaizer-tray.exe"
cp -R dist/engine "$PKG/app/engine"
# the website, served to other computers on the network when the user allows it (lan.go)
mkdir -p "$PKG/app/site" && cp ../docs/{index.html,app.js,style.css,theme.js,favicon.svg,apple-touch-icon.png} "$PKG/app/site/"
cp packaging/icon/asenaizer.ico "$PKG/app/asenaizer.ico"
cp ../LICENSE "$PKG/app/LICENSE.txt"
cp ../NOTICE "$PKG/app/NOTICE.txt"
cp ../installer/setup.ps1 ../installer/uninstall.ps1 "$PKG/installer/"
printf '%s\n' "$VERSION" > "$PKG/VERSION"

ZIP="Asenaizer-windows-x64-$VERSION.zip"
(cd "$PKG" && 7z a -tzip -mx=7 "../$ZIP" . >/dev/null)
(cd dist && sha256sum "$ZIP" > "$ZIP.sha256")
ls -lh "dist/$ZIP" "dist/$ZIP.sha256"
