#!/usr/bin/env bash
# Asenaizer Linux installer. Fetches checksum-pinned runtimes and installs per user.
set -euo pipefail

SOURCE_DIR=""
while (($#)); do
  case "$1" in
    --source) SOURCE_DIR="${2:?--source needs a directory}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$(uname -s)" == Linux ]] || { echo "This installer is for Linux." >&2; exit 2; }
command -v python3 >/dev/null || { echo "Python 3 is required." >&2; exit 2; }

PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/asenaizer"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
mkdir -p "$(dirname "$PREFIX")" "$BIN_DIR" "$APP_DIR" "$AUTOSTART_DIR"
WORK="$(mktemp -d "$(dirname "$PREFIX")/.asenaizer-install.XXXXXX")"
BACKUP="$(dirname "$PREFIX")/.asenaizer-previous-$$"
INSTALLED=0
cleanup() {
  code=$?
  if ((code != 0)); then
    if ((INSTALLED)) || [[ -e "$BACKUP" ]]; then rm -rf "$PREFIX"; fi
    if [[ -e "$BACKUP" ]]; then
      mv "$BACKUP" "$PREFIX"
      echo "Previous installation restored." >&2
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

STAGE="$WORK/new"
mkdir -p "$STAGE"
RELEASE=0
if [[ -z "$SOURCE_DIR" ]]; then
  command -v curl >/dev/null || { echo "curl is required for the remote installer." >&2; exit 2; }
  curl -fsSL https://raw.githubusercontent.com/KaanAlper/Asenaizer/main/scripts/fetch_linux_release.py -o "$WORK/fetch_linux_release.py"
  if python3 "$WORK/fetch_linux_release.py" "$STAGE"; then
    RELEASE=1
  else
    code=$?
    if ((code != 3)); then exit "$code"; fi
  fi
fi

if ((RELEASE == 0)); then
  for cmd in git go cargo pkg-config; do
    command -v "$cmd" >/dev/null || { echo "Missing build tool: $cmd" >&2; exit 2; }
  done
  pkg-config --exists gtk+-3.0 webkit2gtk-4.1 dbus-1 || {
    echo "Missing GTK3/WebKitGTK/D-Bus development files (Arch: gtk3 webkit2gtk-4.1 dbus; Debian: libgtk-3-dev libwebkit2gtk-4.1-dev libdbus-1-dev)." >&2
    exit 2
  }
  if [[ -z "$SOURCE_DIR" ]]; then
    echo "Fetching Asenaizer source…"
    git clone --depth 1 https://github.com/KaanAlper/Asenaizer.git "$WORK/source"
    SOURCE_DIR="$WORK/source"
  fi
  SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
  [[ -f "$SOURCE_DIR/app/go.mod" && -f "$SOURCE_DIR/app/tray/Cargo.toml" ]] || {
    echo "The source directory is not an Asenaizer checkout." >&2; exit 2;
  }
  mkdir -p "$STAGE/engine"
  echo "Building local service…"
  (cd "$SOURCE_DIR/app" && go build -trimpath -o "$STAGE/Humanizer" .)
  echo "Building Linux tray…"
  (cd "$SOURCE_DIR/app/tray" && CARGO_TARGET_DIR="$WORK/cargo-target" cargo build --release --locked)
  install -m 755 "$WORK/cargo-target/release/asenaizer-tray" "$STAGE/asenaizer-tray"

  echo "Fetching verified llama.cpp runtimes…"
  ENGINE_ARGS=(--target linux --out "$STAGE/engine" --backend cpu)
  if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
    ENGINE_ARGS+=(--backend cuda)
  elif command -v ldconfig >/dev/null && ldconfig -p 2>/dev/null | grep -q 'libvulkan.so'; then
    ENGINE_ARGS+=(--backend vulkan)
  fi
  python3 "$SOURCE_DIR/app/packaging/fetch_engine.py" "${ENGINE_ARGS[@]}"
fi
[[ -x "$STAGE/engine/cpu/llama-server" ]] || { echo "CPU runtime is missing." >&2; exit 1; }
# Installs the tray's GTK3, WebKitGTK and D-Bus runtime with the distribution's package manager.
install_runtime_libs() {
  local sudo=""
  ((EUID == 0)) || sudo="sudo"
  if command -v apt-get >/dev/null; then
    $sudo apt-get install -y libgtk-3-0 libwebkit2gtk-4.1-0 libdbus-1-3
  elif command -v pacman >/dev/null; then
    $sudo pacman -S --needed --noconfirm gtk3 webkit2gtk-4.1 dbus
  elif command -v dnf >/dev/null; then
    $sudo dnf install -y gtk3 webkit2gtk4.1 dbus-libs
  elif command -v zypper >/dev/null; then
    $sudo zypper --non-interactive install libgtk-3-0 libwebkit2gtk-4_1-0 libdbus-1-3
  else
    return 1
  fi
}
if ldd "$STAGE/asenaizer-tray" | grep -q 'not found'; then
  echo "Installing tray runtime libraries (GTK3, WebKitGTK 4.1, D-Bus)…"
  install_runtime_libs || true
fi
if ldd "$STAGE/asenaizer-tray" | grep -q 'not found'; then
  echo "Missing tray runtime libraries. Install GTK3, WebKitGTK 4.1 and D-Bus, then retry." >&2
  ldd "$STAGE/asenaizer-tray" | grep 'not found' >&2
  exit 1
fi

echo "Installing…"
if [[ -e "$PREFIX" ]]; then mv "$PREFIX" "$BACKUP"; fi
mv "$STAGE" "$PREFIX"
INSTALLED=1
cat > "$BIN_DIR/asenaizer" <<EOF
#!/usr/bin/env bash
exec "$PREFIX/asenaizer-tray" "\$@"
EOF
chmod 755 "$BIN_DIR/asenaizer"
cat > "$APP_DIR/asenaizer.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Asenaizer
Comment=Local GPU helper for the Asenaizer website
Exec=$BIN_DIR/asenaizer
Terminal=false
Categories=Utility;
EOF
cp "$APP_DIR/asenaizer.desktop" "$AUTOSTART_DIR/asenaizer.desktop"
rm -rf "$BACKUP"
echo "Installed. Launch: $BIN_DIR/asenaizer"
echo "The model is downloaded only when you choose one in the site or device settings."

# Open the device window right away when a desktop session is available.
if pgrep -x asenaizer-tray >/dev/null; then
  echo "Asenaizer is already running. Quit it from the tray and start it again to use this version."
elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  nohup "$PREFIX/asenaizer-tray" --settings >/dev/null 2>&1 &
  disown
  echo "Asenaizer is running in your tray."
fi
