#!/usr/bin/env bash
# Asenaizer - Linux installer
#   curl -fsSL https://raw.githubusercontent.com/KaanAlper/Asenaizer/main/scripts/install-linux.sh | bash
# Installs the newest Asenaizer release for the current user (~/.local/share/asenaizer). Only the system
# libraries the tray needs (GTK3, WebKitGTK 4.1, D-Bus) may ask for sudo, once, in the terminal. Every change is
# recorded; on an error or a cancel everything is put back the way it was. Contract: installer/PROTOCOL.md.
#
# Modes
#   bootstrap (default)  installs missing system libraries, then, with a desktop session, opens the setup window
#                        (Asenaizer-Setup-linux-x64 from the "setup" release, checked against its .sha256), which
#                        runs this script in driver mode. Without a display, or if the window cannot start, the
#                        console mode runs instead.
#   driver               ASZ_DRIVER=<dir>, run by the setup window: no questions, phases in <dir>/status.json,
#                        the steps in <dir>/progress.json, <dir>/cancel stops and rolls back.
#   console              questions with gum 2.0.2 (or simple prompts), progress drawn in the terminal; builds
#                        from source when no release has been published yet.
# Options (environment)
#   ASZ_NO_GUI=1      no setup window             ASZ_DEFAULTS=1   no questions in the console
#   ASZ_NO_STARTUP=1  do not start at sign-in     ASZ_DESKTOP=1    add a desktop shortcut
#   ASZ_NO_LAUNCH=1   do not open when done       ASZ_PLAIN=1      simple prompts instead of gum
#   ASZ_SOURCE=<dir>  install an unpacked Linux package (Humanizer, asenaizer-tray, engine/, VERSION)
#   ASZ_KEEP_CHOICES=1  keep the current sign-in start and desktop shortcut (the app updating itself)
#   ASZ_PREVIEW=1     walk through everything, change nothing (=fail: a failed install, =warn: an optional part
#                     that failed)
# Arguments
#   --source <dir>    build from an Asenaizer source checkout (console)
#   --console         skip the setup window
# Exit codes: 0 installed, 1 error, 2 cancelled (or a bad argument).
# Everything below is functions; the last line runs main, so `curl | bash` has read the whole script first.

set -uo pipefail

REPO="KaanAlper/Asenaizer"
RAW="https://raw.githubusercontent.com/$REPO/main"
SETUP_BASE="https://github.com/$REPO/releases/download/setup"
SETUP_ASSET="Asenaizer-Setup-linux-x64"
GUM_VER="2.0.2"
UA="Asenaizer-Install"
STEP_IDS=(check runtimes stop files shortcuts startup register)
TOTAL_STEPS=${#STEP_IDS[@]}
TRAY_LIBS=(libgtk-3.so.0 libwebkit2gtk-4.1.so.0 libjavascriptcoregtk-4.1.so.0 libdbus-1.so.3)

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
PREFIX="$DATA_HOME/asenaizer"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$DATA_HOME/applications"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
BACKUP="$(dirname "$PREFIX")/.asenaizer-previous-$$"
LOG="${TMPDIR:-/tmp}/asenaizer-install.log"

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# ---------------------------------------------------------------- state
DRIVER=""            # driver mode: the setup window's work dir
PREVIEW=""           # "", ok, fail, warn
CHECKOUT=""          # --source: a source checkout to build
FORCE_CONSOLE=0
WORK=""              # this run's own temp dir (staging, gum, rollback copies)
STAGE=""             # the new install, before it is put in place
PROGRESS=""          # driver: progress.json
VERSION_STR=""
CANCEL=0
INTERACTIVE=0
GUM=""
OPT_STARTUP=1 OPT_DESKTOP=0 OPT_LAUNCH=1
JOURNAL=()           # what the steps changed, undone in reverse order on rollback
WARN=()              # optional parts that failed (ids)
NOTES=()             # extra lines for the result
STEP_N=0 STEP_ID="" STEP_PCT=0 STEP_FILE="" STEP_ERR=""
STEPS_STARTED=0 COMMITTED=0 STOPPED_TRAY=0 OTHER_TRAY=0 LAUNCHED=0

# ---------------------------------------------------------------- texts (all visible text is English)
load_texts() {
  T_TAGLINE="Asenaizer: rewrites AI drafts so they read like a person wrote them, on your own computer"
  T_PREPARING="Getting ready"; T_RELEASE="Looking for the latest release"
  T_NO_RELEASE="No Linux release of Asenaizer has been published yet."
  T_NO_RELEASE_HINT="To build it from source, run this in a terminal:"
  T_SOURCE_BUILD="No published release yet; building Asenaizer from source."
  T_WELCOME="Welcome to Asenaizer"
  T_WELCOME_BODY=$'A few quick questions, then we take care of the rest. Asenaizer installs for your account only (~/.local/share/asenaizer).\nEvery change is backed up; if something goes wrong or you cancel, everything goes back to how it was.'
  T_VERSION="Version"
  T_Q_OPTIONS="Options (Space to toggle, Enter to confirm)"
  T_O_STARTUP="Start Asenaizer when I sign in"; T_O_DESKTOP="Add a desktop shortcut"; T_O_LAUNCH="Open Asenaizer when the install is done"
  T_SUMMARY="Summary"; T_ON="yes"; T_OFF="no"; T_MENU_ALWAYS="It is always added to the app menu."
  T_Q_GO="Ready to install?"; T_GO="Install"; T_CANCEL="Cancel"
  T_DOWNLOADING="Downloading Asenaizer"; T_VERIFYING="Verifying the package"; T_EXTRACTING="Unpacking"
  T_INSTALLING="Installing Asenaizer"; T_CTRLC="Ctrl+C: cancel"; T_ROLLING_BACK="Putting everything back..."
  T_BUILD_SERVICE="Building the local service"; T_BUILD_TRAY="Building the tray app"; T_FETCH_SOURCE="Fetching the source"
  T_BUILD_ENGINES="Fetching verified llama.cpp runtimes"
  T_MISSING_TOOLS="Building from source needs:"
  T_S_check="Checking the system"; T_S_runtimes="Required components"; T_S_stop="Stopping Asenaizer"
  T_S_files="Copying files"; T_S_shortcuts="Creating shortcuts"; T_S_startup="Setting up start at sign-in"
  T_S_register="Adding the uninstaller"
  T_DONE_TITLE="All set! Asenaizer is installed"
  T_DONE_BODY=$'Asenaizer runs in your system tray; its window opens in a moment.\n\n  App menu       Asenaizer\n  Command        asenaizer\n  To remove it   asenaizer-uninstall'
  T_DONE_BODY_QUIET=$'Open Asenaizer from the app menu or with the asenaizer command. While it runs, it sits in your system tray.\n\n  App menu       Asenaizer\n  Command        asenaizer\n  To remove it   asenaizer-uninstall'
  T_MODEL_NOTE="The model is downloaded only when you choose one on the site or in the device settings."
  T_OTHER_TRAY="Asenaizer is already running from another location; quit it from the tray and start it again to use this version."
  T_NO_PATH="~/.local/bin is not on your PATH; run the commands with their full path (~/.local/bin/asenaizer)."
  T_ERR_TITLE="That didn't work, but don't worry"
  T_ERR_BODY="The install got stuck at '%s'. Nothing was left half-done: the changes were undone and the previous Asenaizer (if there was one) was started again."
  T_ERR_DETAIL="Details"; T_ERR_LOG="Log"
  T_ERR_RETRY=$'You can try again by running the same command. If it keeps happening, please share the log with us:\nhttps://github.com/'"$REPO"'/issues'
  T_DL_FAILED="The newest release could not be downloaded or verified. Nothing on your computer was changed."
  T_CANCEL_TITLE="Install cancelled"; T_CANCEL_BODY="Everything is back to how it was; nothing on your computer was changed."
  T_NOT_X64="The Asenaizer Linux package needs 64-bit x86 (x86_64); this computer is %s."
  T_BAD_PKG="The package looks incomplete"
  T_LIBS_MISSING="System libraries Asenaizer needs are missing (GTK3, WebKitGTK 4.1, D-Bus):"
  T_LIBS_HINT="Install them with your package manager and try again."
  T_LIBS_INSTALL="Installing the system libraries the Asenaizer window needs (GTK3, WebKitGTK 4.1, D-Bus); sudo may ask for your password."
  T_LIBS_PREVIEW="Preview: these libraries would be installed:"
  T_STOP_FAILED="Asenaizer's processes could not be stopped"
  T_NO_UNINSTALLER="The uninstaller script could not be fetched"
  T_PLAIN_YES="y"
  T_WARN_TITLE="An optional part couldn't be installed"
  T_WARN_BODY="Asenaizer works; only this is missing. Run the same command again later to complete it."
  T_X_icon="App icon (the menu entry shows a generic icon)"
  T_X_desktop="Desktop shortcut"
  T_GUI_FALLBACK="The setup window could not open (%s); continuing in the terminal."
  T_GUI_OPENING="Opening the setup window..."
}

step_label() { local v="T_S_$1"; printf '%s' "${!v:-$1}"; }
warn_label() { local v="T_X_$1"; printf '%s' "${!v:-$1}"; }

# ---------------------------------------------------------------- console drawing
setup_drawing() {
  local charmap=""
  charmap="$(locale charmap 2>/dev/null || true)"
  if [[ "$charmap" == UTF-8 || "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" =~ [Uu][Tt][Ff]-?8 ]]; then
    G_OK="✓"; G_FAIL="✗"; G_WAIT="◌"; G_DOT="·"; G_FILL="━"; G_HEAD="╸"; G_TRACK="─"; G_BULLET="•"
    G_TL="╭"; G_TR="╮"; G_BL="╰"; G_BR="╯"; G_H="─"; G_V="│"
  else
    G_OK="+"; G_FAIL="x"; G_WAIT="o"; G_DOT="."; G_FILL="="; G_HEAD=">"; G_TRACK="-"; G_BULLET="*"
    G_TL="+"; G_TR="+"; G_BL="+"; G_BR="+"; G_H="-"; G_V="|"
  fi
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_ACCENT="$(fg '#a48bff')"; C_TEXT="$(fg '#e6e0e9')"; C_DIM="$(fg '#938f99')"; C_OK="$(fg '#a8dab5')"
    C_ERR="$(fg '#f2b8b5')"; C_WARN="$(fg '#ffb77c')"; C_TRACK="$(fg '#49454f')"; C_PEND="$(fg '#6f6a75')"
    C_BOLD=$'\e[1m'; RST=$'\e[0m'; EL=$'\e[K'
  else
    C_ACCENT=""; C_TEXT=""; C_DIM=""; C_OK=""; C_ERR=""; C_WARN=""; C_TRACK=""; C_PEND=""; C_BOLD=""; RST=""; EL=""
  fi
  update_cols
  trap update_cols WINCH
}

# The terminal width, kept current when the window is resized.
TERM_COLS=80
update_cols() {
  local c
  c="$(tput cols 2>/dev/null)" || c=""
  [[ "$c" =~ ^[0-9]+$ ]] || c="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
  [[ "$c" =~ ^[0-9]+$ ]] && ((c > 0)) && TERM_COLS="$c"
  return 0
}

fg() { local h="${1#\#}"; printf '\e[38;2;%d;%d;%dm' "$((16#${h:0:2}))" "$((16#${h:2:2}))" "$((16#${h:4:2}))"; }
rep() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }
box_width() {
  local cols="$TERM_COLS"
  cols=$((cols - 4)); ((cols > 76)) && cols=76; ((cols < 40)) && cols=40
  printf '%d' "$cols"
}

# Word-wrapped lines for a box of inner width $2; a word longer than the box (a path) is cut into pieces.
wrap_lines() {
  local w="$2" para line word
  local -a words
  while IFS= read -r para || [[ -n "$para" ]]; do
    if ((${#para} <= w)); then printf '%s\n' "$para"; continue; fi
    line=""
    read -ra words <<<"$para"
    for word in "${words[@]}"; do
      while ((${#word} > w)); do
        [[ -n "$line" ]] && { printf '%s\n' "$line"; line=""; }
        printf '%s\n' "${word:0:w}"; word="${word:w}"
      done
      if [[ -z "$line" ]]; then line="$word"
      elif ((${#line} + 1 + ${#word} <= w)); then line+=" $word"
      else printf '%s\n' "$line"; line="$word"; fi
    done
    printf '%s\n' "$line"
  done <<<"$1"
}

# Rounded box: the title in the border colour, the body wrapped.
box() {
  local c="$1" title="$2" body="$3" w in line
  w="$(box_width)"; in=$((w - 4))
  printf '\n  %s%s%s%s%s\n' "$c" "$G_TL" "$(rep "$G_H" $((w - 2)))" "$G_TR" "$RST"
  if [[ -n "$title" ]]; then
    printf '  %s%s%s %s%s%s%s%*s %s%s%s\n' "$c" "$G_V" "$RST" "$C_BOLD" "$c" "$title" "$RST" $((in - ${#title})) '' "$c" "$G_V" "$RST"
    printf '  %s%s%s %*s %s%s%s\n' "$c" "$G_V" "$RST" "$in" '' "$c" "$G_V" "$RST"
  fi
  while IFS= read -r line; do
    printf '  %s%s%s %s%s%s%*s %s%s%s\n' "$c" "$G_V" "$RST" "$C_TEXT" "$line" "$RST" $((in - ${#line})) '' "$c" "$G_V" "$RST"
  done < <(wrap_lines "$body" "$in")
  printf '  %s%s%s%s%s\n' "$c" "$G_BL" "$(rep "$G_H" $((w - 2)))" "$G_BR" "$RST"
}

banner() {
  [[ -t 1 ]] && printf '\e[H\e[2J'
  local -a art=('╔═╗┌─┐┌─┐┌┐┌┌─┐┬┌─┐┌─┐┬─┐' '╠═╣└─┐├┤ │││├─┤│┌─┘├┤ ├┬┘' '╩ ╩└─┘└─┘┘└┘┴ ┴┴└─┘└─┘┴└─')
  local -a shade=('#c9b8ff' '#a48bff' '#8466f0')
  local i
  printf '\n'
  if [[ "$G_OK" == "✓" ]]; then
    for i in 0 1 2; do
      if [[ -n "$RST" ]]; then printf '  %s%s%s\n' "$(fg "${shade[$i]}")" "${art[$i]}" "$RST"; else printf '  %s\n' "${art[$i]}"; fi
    done
  else
    printf '  %sAsenaizer%s\n' "$C_BOLD$C_ACCENT" "$RST"
  fi
  printf '  %s%s%s\n\n' "$C_DIM" "$T_TAGLINE" "$RST"
}

say() { printf '  %s%s%s %s%s%s\n' "$1" "$2" "$RST" "$C_TEXT" "$3" "$RST"; }

bar() {
  local pct="$1" width="$2" fill
  ((pct < 0)) && pct=0; ((pct > 100)) && pct=100
  fill=$((pct * width / 100))
  if ((fill >= width)); then printf '%s%s%s' "$C_ACCENT" "$(rep "$G_FILL" "$width")" "$RST"; return; fi
  printf '%s%s%s%s%s%s' "$C_ACCENT" "$(rep "$G_FILL" "$fill")" "$G_HEAD" "$C_TRACK" "$(rep "$G_TRACK" $((width - fill - 1)))" "$RST"
}

# A short console task: "◌ label" while it runs, then ✓ / ✗ in place.
spin_start() { [[ -n "$DRIVER" ]] || printf '  %s%s%s %s' "$C_ACCENT" "$G_WAIT" "$RST" "$1"; }
spin_end() {
  [[ -n "$DRIVER" ]] && return 0
  if (($1 == 0)); then printf '\r  %s%s%s %s%s\n' "$C_OK" "$G_OK" "$RST" "$2" "$EL"
  else printf '\r  %s%s%s %s%s\n' "$C_ERR" "$G_FAIL" "$RST" "$2" "$EL"; fi
}
with_spinner() { local label="$1" rc; shift; spin_start "$label"; "$@"; rc=$?; spin_end "$rc" "$label"; return "$rc"; }

# ---------------------------------------------------------------- JSON (status.json, progress.json)
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  s="${s//$'\e'/}"
  printf '"%s"' "$s"
}
json_arr() { local out="" x; for x in "$@"; do out+="${out:+,}$(json_str "$x")"; done; printf '[%s]' "$out"; }
kv() { printf '"%s":%s' "$1" "$(json_str "$2")"; }
clean_line() { printf '%s' "$1" | tr -d '\000-\010\013-\037' | tail -c 600; }

# status.json for the setup window, written whole (status.tmp, then renamed). Extra args are "key":value pairs.
status() {
  [[ -n "$DRIVER" ]] || return 0
  local phase="$1" extra="" pair; shift
  for pair in "$@"; do extra+=",$pair"; done
  printf '{"phase":%s,"version":%s%s}' "$(json_str "$phase")" "$(json_str "$VERSION_STR")" "$extra" >"$DRIVER/status.tmp" \
    && mv -f "$DRIVER/status.tmp" "$DRIVER/status.json"
}

# progress.json: {state, step, n, total, percent, file, warn, error}; percent stays at most 99 until done.
progress() {
  local state="$1"
  [[ -n "$PROGRESS" ]] || return 0
  local pct="$STEP_PCT"
  [[ "$state" != done ]] && ((pct > 99)) && pct=99
  printf '{"state":%s,"step":%s,"n":%d,"total":%d,"percent":%d,"file":%s,"warn":%s,"error":%s}' \
    "$(json_str "$state")" "$(json_str "$STEP_ID")" "$STEP_N" "$TOTAL_STEPS" "$pct" "$(json_str "$STEP_FILE")" \
    "$(json_arr ${WARN[@]+"${WARN[@]}"})" "$(json_str "$STEP_ERR")" >"$PROGRESS.tmp" && mv -f "$PROGRESS.tmp" "$PROGRESS"
}

# Per-step progress: the file and the console line (the console draws a bar only while files are copied).
step_progress() {
  local pct="$1" file="${2:-}"
  ((pct > STEP_PCT)) && STEP_PCT="$pct"
  STEP_FILE="$file"
  progress running
  if [[ -z "$DRIVER" && -n "$file" ]]; then
    # one line, redrawn in place: it must never be wider than the terminal, or every redraw wraps onto a new line
    local label name="$file" room width
    label="$(step_label "$STEP_ID")"
    room=$((TERM_COLS - 1 - 2 - 2 - ${#label} - 2 - 1 - 4 - 2))
    width=$((room / 2)); ((width > 20)) && width=20
    if ((width < 6)); then width=0; fi
    room=$((room - width))
    if ((room < 8)); then name=""
    elif ((${#name} > room)); then name="...${name: -$((room - 3))}"; fi
    printf '\r  %s%s%s %s  %s %s%3d%%%s  %s%s%s%s' "$C_ACCENT" "$G_WAIT" "$RST" "$label" "$( ((width)) && bar "$STEP_PCT" "$width")" \
      "$C_TEXT" "$STEP_PCT" "$RST" "$C_DIM" "$name" "$RST" "$EL"
  fi
}

cancel_requested() { ((CANCEL)) || [[ -n "$DRIVER" && -e "$DRIVER/cancel" ]]; }

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }

# ---------------------------------------------------------------- helpers
has_display() { [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; }

# A helper file: next to this script (the setup window writes them there), in the checkout, or from GitHub.
get_asset() {
  local rel="$1" dest="$2" base c
  base="$(basename "$rel")"
  for c in "${SCRIPT_DIR:+$SCRIPT_DIR/$base}" "${SCRIPT_DIR:+$SCRIPT_DIR/../$rel}" "${CHECKOUT:+$CHECKOUT/$rel}"; do
    if [[ -n "$c" && -f "$c" ]]; then cp -- "$c" "$dest" && return 0; fi
  done
  command -v curl >/dev/null || return 1
  curl -fsSL --retry 3 --connect-timeout 20 -A "$UA" -o "$dest" "$RAW/$rel" >>"$LOG" 2>&1
}

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# Libraries the tray (and the setup window) load, by soname, from the linker cache.
missing_system_libs() {
  local cache lib
  cache="$(PATH="$PATH:/sbin:/usr/sbin" ldconfig -p 2>/dev/null)" || return 0
  [[ -n "$cache" ]] || return 0
  for lib in "${TRAY_LIBS[@]}"; do grep -qF "$lib (" <<<"$cache" || printf '%s\n' "$lib"; done
}
ldd_missing() { ldd "$1" 2>/dev/null | awk '/not found/ {print $1}'; }

# GTK3, WebKitGTK 4.1 and D-Bus with the distribution's package manager. $1 = interactive (sudo may ask).
install_runtime_libs() {
  local sudo=()
  if ((EUID != 0)); then
    command -v sudo >/dev/null || return 1
    if [[ "${1:-0}" == 1 ]]; then sudo=(sudo); else sudo=(sudo -n); fi
  fi
  if command -v apt-get >/dev/null; then
    "${sudo[@]}" apt-get install -y libgtk-3-0 libwebkit2gtk-4.1-0 libdbus-1-3
  elif command -v pacman >/dev/null; then
    "${sudo[@]}" pacman -S --needed --noconfirm gtk3 webkit2gtk-4.1 dbus
  elif command -v dnf >/dev/null; then
    "${sudo[@]}" dnf install -y gtk3 webkit2gtk4.1 dbus-libs
  elif command -v zypper >/dev/null; then
    "${sudo[@]}" zypper --non-interactive install libgtk-3-0 libwebkit2gtk-4_1-0 libdbus-1-3
  else
    return 1
  fi
}

# Bootstrap and console: the libraries are installed here, in the terminal, where sudo can ask.
ensure_runtime_libs() {
  local missing
  missing="$(missing_system_libs)"
  [[ -n "$missing" ]] || return 0
  if [[ -n "$PREVIEW" ]]; then say "$C_ACCENT" "$G_WAIT" "$T_LIBS_PREVIEW $(tr '\n' ' ' <<<"$missing")"; return 0; fi
  say "$C_ACCENT" "$G_WAIT" "$T_LIBS_INSTALL"
  log "installing runtime libraries: $(tr '\n' ' ' <<<"$missing")"
  install_runtime_libs 1 </dev/tty 2>&1 | tee -a "$LOG" | sed 's/^/    /'
  [[ -z "$(missing_system_libs)" ]]
}

# Asenaizer's own processes: an executable under the install dir (never a name alone). Prints "pid name".
asz_pids() {
  local dir exe name
  # one find for every process (no readlink per pid); a replaced binary reads "<path> (deleted)"
  while read -r dir exe; do
    exe="${exe% (deleted)}"
    [[ "$exe" == "$PREFIX"/* ]] || continue
    name="${exe##*/}"
    case "$name" in asenaizer-tray | Humanizer | llama-server) printf '%s %s\n' "${dir#/proc/}" "$name" ;; esac
  done < <(find /proc -mindepth 2 -maxdepth 2 -name exe -lname "$PREFIX/*" -printf '%h %l\n' 2>/dev/null)
}
# A tray running from somewhere else (a source build, another prefix).
other_tray_running() {
  local d comm
  for d in /proc/[0-9]*; do
    { read -r comm <"$d/comm"; } 2>/dev/null || continue
    [[ "$comm" == asenaizer-tray ]] && return 0
  done
  return 1
}

start_tray() {
  has_display || return 1
  [[ -x "$PREFIX/asenaizer-tray" ]] || return 1
  if command -v setsid >/dev/null; then
    setsid -f "$PREFIX/asenaizer-tray" "$@" </dev/null >/dev/null 2>&1
  else
    nohup "$PREFIX/asenaizer-tray" "$@" </dev/null >/dev/null 2>&1 &
    disown
  fi
}

# ---------------------------------------------------------------- journal and rollback
# A file this run writes or removes: its earlier copy (or "-" when there was none) goes into the journal first.
record_file() {
  local path="$1" n="${#JOURNAL[@]}"
  if [[ -e "$path" || -L "$path" ]]; then
    mkdir -p "$WORK/rollback" && cp -a -- "$path" "$WORK/rollback/$n" || return 1
    JOURNAL+=("file|$path|$WORK/rollback/$n")
  else
    JOURNAL+=("file|$path|-")
  fi
}
write_file() { # path mode content
  local path="$1" mode="$2" content="$3"
  record_file "$path" || return 1
  mkdir -p "$(dirname "$path")" || return 1
  printf '%s' "$content" >"$path.asz-tmp" && chmod "$mode" "$path.asz-tmp" && mv -f "$path.asz-tmp" "$path"
}
remove_file() { [[ -e "$1" || -L "$1" ]] || return 0; record_file "$1" && rm -f -- "$1"; }

rollback() {
  local i entry kind path saved
  for ((i = ${#JOURNAL[@]} - 1; i >= 0; i--)); do
    entry="${JOURNAL[$i]}"
    kind="${entry%%|*}"
    case "$kind" in
      file)
        path="${entry#file|}"; saved="${path##*|}"; path="${path%|*}"
        if [[ "$saved" == - ]]; then rm -f -- "$path"; else rm -f -- "$path"; cp -a -- "$saved" "$path"; fi
        ;;
      prefix)
        rm -rf -- "$PREFIX"
        [[ -e "$BACKUP" ]] && mv -- "$BACKUP" "$PREFIX"
        ;;
    esac
  done
  JOURNAL=()
  log "rolled back"
  # the tray that was running before is started again
  if ((STOPPED_TRAY)); then start_tray || true; fi
}

# ---------------------------------------------------------------- the steps
desktop_entry() { # exec args, comment
  local icon=""
  [[ -f "$PREFIX/asenaizer.png" ]] && icon="Icon=$PREFIX/asenaizer.png"$'\n'
  printf '[Desktop Entry]\nType=Application\nVersion=1.0\nName=Asenaizer\nComment=Local GPU helper for the Asenaizer website\nExec="%s"%s\n%sTerminal=false\nCategories=Utility;\nStartupNotify=false\n%s' \
    "$PREFIX/asenaizer-tray" "$1" "$icon" "${2:-}"
}

desktop_dir() {
  local d=""
  command -v xdg-user-dir >/dev/null && d="$(xdg-user-dir DESKTOP 2>/dev/null)"
  [[ -z "$d" || "$d" == "$HOME" ]] && d="$HOME/Desktop"
  printf '%s' "$d"
}

step_check() {
  local need arch
  arch="$(uname -m)"
  if [[ -z "$CHECKOUT" && "$arch" != x86_64 ]]; then
    # shellcheck disable=SC2059
    STEP_ERR="$(printf "$T_NOT_X64" "$arch")"; return 1
  fi
  step_progress 30
  for need in Humanizer asenaizer-tray engine/cpu/llama-server VERSION; do
    [[ -e "$STAGE/$need" ]] || { STEP_ERR="$T_BAD_PKG: $need"; return 1; }
  done
  [[ -x "$STAGE/asenaizer-tray" && -x "$STAGE/Humanizer" ]] || { STEP_ERR="$T_BAD_PKG: chmod"; return 1; }
  step_progress 70
  mkdir -p "$(dirname "$PREFIX")" "$BIN_DIR" || { STEP_ERR="cannot create $(dirname "$PREFIX") or $BIN_DIR"; return 1; }
  [[ -w "$(dirname "$PREFIX")" && -w "$BIN_DIR" ]] || { STEP_ERR="not writable: $(dirname "$PREFIX") or $BIN_DIR"; return 1; }
  return 0
}

step_runtimes() {
  local missing
  missing="$(ldd_missing "$STAGE/asenaizer-tray")"
  [[ -n "$missing" ]] || return 0
  log "tray libraries missing: $(tr '\n' ' ' <<<"$missing")"
  step_progress 20
  if [[ -n "$DRIVER" ]]; then
    install_runtime_libs 0 </dev/null >>"$LOG" 2>&1 || true
  else
    printf '\n'
    say "$C_ACCENT" "$G_WAIT" "$T_LIBS_INSTALL"
    install_runtime_libs 1 </dev/tty 2>&1 | tee -a "$LOG" | sed 's/^/    /'
    spin_start "$(step_label runtimes)"
  fi
  step_progress 90
  missing="$(ldd_missing "$STAGE/asenaizer-tray")"
  [[ -z "$missing" ]] && return 0
  STEP_ERR="$T_LIBS_MISSING $(tr '\n' ' ' <<<"$missing")- $T_LIBS_HINT"
  return 1
}

step_stop() {
  local list pids=() pid name i
  list="$(asz_pids)"
  [[ -n "$list" ]] || return 0
  while read -r pid name; do
    pids+=("$pid")
    [[ "$name" == asenaizer-tray ]] && STOPPED_TRAY=1
  done <<<"$list"
  log "stopping: $(tr '\n' ' ' <<<"$list")"
  kill -TERM "${pids[@]}" 2>/dev/null
  for ((i = 0; i < 150; i++)); do
    [[ -n "$(asz_pids)" ]] || return 0
    ((i == 100)) && kill -KILL "${pids[@]}" 2>/dev/null
    step_progress $((i * 99 / 150))
    sleep 0.1
  done
  [[ -n "$(asz_pids)" ]] || return 0
  STEP_ERR="$T_STOP_FAILED: $(asz_pids | tr '\n' ' ')"
  return 1
}

step_files() {
  local entries total=0 done=0 size rel kind
  # the current install goes aside whole; it comes back on rollback
  if [[ -e "$PREFIX" ]]; then
    mv -- "$PREFIX" "$BACKUP" || { STEP_ERR="cannot move $PREFIX aside"; return 1; }
  fi
  JOURNAL+=("prefix")
  mkdir -p "$PREFIX" || { STEP_ERR="cannot create $PREFIX"; return 1; }
  entries="$(cd "$STAGE" && find . -mindepth 1 \( -type f -o -type l \) -printf '%y %s %P\n' | sort -k3)"
  while read -r kind size rel; do [[ "$size" =~ ^[0-9]+$ ]] && total=$((total + size)); done <<<"$entries"
  ((total > 0)) || total=1
  while read -r kind size rel; do
    [[ -n "$rel" && "$size" =~ ^[0-9]+$ ]] || continue
    cancel_requested && return 2
    mkdir -p "$PREFIX/$(dirname "$rel")" || { STEP_ERR="cannot create $PREFIX/$(dirname "$rel")"; return 1; }
    cp -P --preserve=mode,timestamps -- "$STAGE/$rel" "$PREFIX/$rel" 2>>"$LOG" || { STEP_ERR="cannot copy $rel"; return 1; }
    done=$((done + size))
    step_progress $((done * 95 / total)) "$rel"
  done <<<"$entries"
  if get_asset app/packaging/icon/asenaizer-256.png "$PREFIX/asenaizer.png"; then
    chmod 644 "$PREFIX/asenaizer.png"
  else
    rm -f "$PREFIX/asenaizer.png"; WARN+=(icon)
  fi
  step_progress 99 "asenaizer.png"
  return 0
}

step_shortcuts() {
  local desk
  write_file "$BIN_DIR/asenaizer" 755 "#!/usr/bin/env bash
exec \"$PREFIX/asenaizer-tray\" \"\$@\"
" || { STEP_ERR="cannot write $BIN_DIR/asenaizer"; return 1; }
  step_progress 30
  write_file "$APP_DIR/asenaizer.desktop" 644 "$(desktop_entry ' --settings')
" || { STEP_ERR="cannot write $APP_DIR/asenaizer.desktop"; return 1; }
  step_progress 60
  desk="$(desktop_dir)/asenaizer.desktop"
  if ((OPT_DESKTOP)); then
    # only into an existing desktop folder (a session without one gets no new ~/Desktop)
    if [[ -d "$(dirname "$desk")" ]] && write_file "$desk" 755 "$(desktop_entry ' --settings')
"; then
      command -v gio >/dev/null && gio set "$desk" metadata::trusted true >/dev/null 2>&1
    else
      WARN+=(desktop)
    fi
  elif [[ -f "$desk" ]] && grep -qF "$PREFIX/asenaizer-tray" "$desk"; then
    remove_file "$desk" || true
  fi
  command -v update-desktop-database >/dev/null && update-desktop-database "$APP_DIR" >/dev/null 2>&1
  return 0
}

step_startup() {
  local file="$AUTOSTART_DIR/asenaizer.desktop"
  if ((OPT_STARTUP)); then
    write_file "$file" 644 "$(desktop_entry '' 'X-GNOME-Autostart-enabled=true')
" || { STEP_ERR="cannot write $file"; return 1; }
  else
    remove_file "$file" || { STEP_ERR="cannot remove $file"; return 1; }
  fi
  return 0
}

step_register() {
  get_asset scripts/uninstall-linux.sh "$PREFIX/uninstall.sh" && chmod 755 "$PREFIX/uninstall.sh" \
    || { STEP_ERR="$T_NO_UNINSTALLER"; return 1; }
  step_progress 50
  write_file "$BIN_DIR/asenaizer-uninstall" 755 "#!/usr/bin/env bash
exec \"$PREFIX/uninstall.sh\" \"\$@\"
" || { STEP_ERR="cannot write $BIN_DIR/asenaizer-uninstall"; return 1; }
  return 0
}

# The steps of a preview: same progress file, same cancel file, nothing touched.
preview_step() {
  local id="$1" pc delay=0.03
  local -a files=(asenaizer-tray Humanizer engine/cpu/llama-server engine/cpu/libggml-cpu.so engine/cuda/libggml-cuda.so engine/cuda/libcublasLt.so.12)
  [[ "$id" == files ]] && delay=0.11
  for ((pc = 0; pc <= 99; pc += 3)); do
    cancel_requested && return 2
    if [[ "$PREVIEW" == fail && "$id" == files ]] && ((pc >= 50)); then STEP_ERR="Preview: simulated failure"; return 1; fi
    [[ "$PREVIEW" == warn && "$id" == runtimes && ${#WARN[@]} -eq 0 ]] && WARN+=(icon)
    if [[ "$id" == files ]]; then step_progress "$pc" "${files[$((pc / 17))]}"; else step_progress "$pc"; fi
    sleep "$delay"
  done
  return 0
}

# Runs the seven steps. 0 done, 1 error (rolled back), 2 cancelled (rolled back).
run_steps() {
  local id rc label
  STEPS_STARTED=1
  if [[ -z "$DRIVER" ]]; then
    printf '\n  %s%s%s%s   %s%s%s\n' "$C_BOLD" "$C_ACCENT" "$T_INSTALLING" "$RST" "$C_DIM" "$T_CTRLC" "$RST"
  fi
  for id in "${STEP_IDS[@]}"; do
    STEP_N=$((STEP_N + 1)); STEP_ID="$id"; STEP_PCT=0; STEP_FILE=""
    label="$(step_label "$id")"
    log "step $STEP_N/$TOTAL_STEPS $id"
    progress running
    spin_start "$label"
    if cancel_requested; then rc=2
    elif [[ -n "$PREVIEW" ]]; then preview_step "$id"; rc=$?
    else "step_$id"; rc=$?; fi
    ((rc == 1)) && cancel_requested && rc=2
    if ((rc != 0)); then
      spin_end 1 "$label"
      ((rc == 1)) && log "failed at $id: $STEP_ERR"
      STEP_FILE=""
      progress rollback
      [[ -z "$DRIVER" ]] && printf '  %s%s%s\n' "$C_WARN" "$T_ROLLING_BACK" "$RST"
      if [[ -n "$PREVIEW" ]]; then sleep 1.5; else rollback; fi
      if ((rc == 2)); then progress cancelled; else progress error; fi
      return "$rc"
    fi
    STEP_FILE=""
    spin_end 0 "$label"
  done
  # commit: the previous install is no longer needed
  COMMITTED=1
  [[ -z "$PREVIEW" ]] && rm -rf -- "$BACKUP"
  STEP_PCT=100
  progress done
  log "installed $VERSION_STR into $PREFIX"
  return 0
}

after_install() {
  [[ -n "$PREVIEW" ]] && return 0
  if other_tray_running; then OTHER_TRAY=1; NOTES+=("$T_OTHER_TRAY"); return 0; fi
  if ((OPT_LAUNCH)); then start_tray --settings && LAUNCHED=1
  elif ((STOPPED_TRAY)); then start_tray || true; fi
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) NOTES+=("$T_NO_PATH") ;; esac
  return 0
}

done_body() {
  local body note
  if ((LAUNCHED)) || { [[ -n "$PREVIEW" ]] && ((OPT_LAUNCH)); }; then body="$T_DONE_BODY"; else body="$T_DONE_BODY_QUIET"; fi
  body+=$'\n\n'"$T_MODEL_NOTE"
  for note in ${NOTES[@]+"${NOTES[@]}"}; do body+=$'\n\n'"$note"; done
  printf '%s' "$body"
}

# ---------------------------------------------------------------- getting the package
# Bytes as "12.5" MB without printf %f (a Turkish locale writes 12,5 and bash then rejects "12.5").
mb() { local t=$(($1 * 10 / 1048576)); printf '%d.%d' $((t / 10)) $((t % 10)); }

# Preview without touching the network: the download played with made-up numbers.
preview_download() {
  local total=$((180 * 1048576)) i done
  VERSION_STR="0.0.0"
  status release; sleep 0.6
  for ((i = 0; i <= 100; i += 2)); do
    cancel_requested && return 2
    done=$((total * i / 100))
    status download "\"percent\":$i" "\"done\":$done" "\"total\":$total"
    if [[ -z "$DRIVER" ]]; then
      local info width
      info="$(mb "$done") / $(mb "$total") MB"
      width=$((TERM_COLS - 1 - 4 - ${#T_DOWNLOADING} - 2 - 1 - 4 - 2 - ${#info}))
      ((width > 28)) && width=28
      ((width < 6)) && { width=0; info=""; }
      printf '\r  %s%s%s %s  %s %s%3d%%%s  %s%s%s%s' "$C_ACCENT" "$G_WAIT" "$RST" "$T_DOWNLOADING" "$( ((width)) && bar "$i" "$width")" \
        "$C_TEXT" "$i" "$RST" "$C_DIM" "$info" "$RST" "$EL"
    fi
    sleep 0.08
  done
  [[ -z "$DRIVER" ]] && printf '\r  %s%s%s %s  %s180.0 MB%s%s\n' "$C_OK" "$G_OK" "$RST" "$T_DOWNLOADING" "$C_DIM" "$RST" "$EL"
  status verify; with_spinner "$T_VERIFYING" sleep 0.5
  cancel_requested && return 2
  status extract; with_spinner "$T_EXTRACTING" sleep 0.5
  mkdir -p "$STAGE"
  return 0
}

# The newest release, with fetch_linux_release.py. 0 ok, 1 error ($FETCH_ERR), 2 cancelled, 3 no release.
FETCH_ERR=""
fetch_release() {
  local fetcher="$WORK/fetch_linux_release.py" rc
  command -v python3 >/dev/null || { FETCH_ERR="Python 3 is required."; return 1; }
  get_asset scripts/fetch_linux_release.py "$fetcher" || { FETCH_ERR="could not fetch $RAW/scripts/fetch_linux_release.py"; return 1; }
  mkdir -p "$STAGE"
  if [[ -n "$DRIVER" ]]; then
    python3 "$fetcher" "$STAGE" --status "$DRIVER/status.json" --cancel "$DRIVER/cancel" </dev/null 2>"$WORK/fetch.err"
    rc=$?
  else
    python3 "$fetcher" "$STAGE" </dev/null 2> >(tee "$WORK/fetch.err" >&2)
    rc=$?
    sleep 0.1 # tee flushes
  fi
  cat "$WORK/fetch.err" >>"$LOG" 2>/dev/null
  FETCH_ERR="$(clean_line "$(grep -v '^\s*$' "$WORK/fetch.err" 2>/dev/null | tail -n 1)")"
  ((rc == 0)) && VERSION_STR="$(tr -d '[:space:]' <"$STAGE/VERSION" 2>/dev/null)"
  ((CANCEL)) && rc=2
  return "$rc"
}

use_package_dir() {
  local src="$ASZ_SOURCE"
  [[ -d "$src" ]] || { FETCH_ERR="ASZ_SOURCE is not a folder: $src"; return 1; }
  status extract
  mkdir -p "$STAGE" && cp -a -- "$src"/. "$STAGE"/ || { FETCH_ERR="cannot copy $src"; return 1; }
  # a release package carries this script for the app's own updates; it does not go into the install dir
  rm -rf -- "$STAGE/installer"
  VERSION_STR="$(tr -d '[:space:]' <"$STAGE/VERSION" 2>/dev/null || true)"
  [[ -n "$VERSION_STR" ]] || VERSION_STR="?"
  return 0
}

# Console only: no release yet, so the tray and the service are built from a checkout.
build_from_source() {
  local cmd missing=() engine_args
  for cmd in git go cargo pkg-config python3; do command -v "$cmd" >/dev/null || missing+=("$cmd"); done
  if ((${#missing[@]})); then FETCH_ERR="$T_MISSING_TOOLS ${missing[*]}"; return 1; fi
  if ! pkg-config --exists gtk+-3.0 webkit2gtk-4.1 dbus-1; then
    FETCH_ERR="$T_MISSING_TOOLS GTK3/WebKitGTK/D-Bus development files (Arch: gtk3 webkit2gtk-4.1 dbus; Debian: libgtk-3-dev libwebkit2gtk-4.1-dev libdbus-1-dev)"
    return 1
  fi
  if [[ -z "$CHECKOUT" ]]; then
    with_spinner "$T_FETCH_SOURCE" git clone --depth 1 "https://github.com/$REPO.git" "$WORK/source" </dev/null >>"$LOG" 2>&1 \
      || { FETCH_ERR="git clone failed"; return 1; }
    CHECKOUT="$WORK/source"
  fi
  CHECKOUT="$(cd "$CHECKOUT" && pwd)"
  [[ -f "$CHECKOUT/app/go.mod" && -f "$CHECKOUT/app/tray/Cargo.toml" ]] || { FETCH_ERR="The source directory is not an Asenaizer checkout."; return 1; }
  mkdir -p "$STAGE/engine"
  cancel_requested && return 2
  with_spinner "$T_BUILD_SERVICE" bash -c 'cd "$1/app" && go build -trimpath -o "$2/Humanizer" .' _ "$CHECKOUT" "$STAGE" </dev/null >>"$LOG" 2>&1 \
    || { FETCH_ERR="go build failed"; return 1; }
  cancel_requested && return 2
  with_spinner "$T_BUILD_TRAY" bash -c 'cd "$1/app/tray" && CARGO_TARGET_DIR="$2" cargo build --release --locked --bin asenaizer-tray' _ "$CHECKOUT" "$WORK/cargo-target" </dev/null >>"$LOG" 2>&1 \
    || { FETCH_ERR="cargo build failed"; return 1; }
  install -m 755 "$WORK/cargo-target/release/asenaizer-tray" "$STAGE/asenaizer-tray" || { FETCH_ERR="tray binary missing"; return 1; }
  cancel_requested && return 2
  engine_args=(--target linux --out "$STAGE/engine" --backend cpu)
  if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
    engine_args+=(--backend cuda)
  elif PATH="$PATH:/sbin:/usr/sbin" ldconfig -p 2>/dev/null | grep -q 'libvulkan.so'; then
    engine_args+=(--backend vulkan)
  fi
  with_spinner "$T_BUILD_ENGINES" python3 "$CHECKOUT/app/packaging/fetch_engine.py" "${engine_args[@]}" </dev/null >>"$LOG" 2>&1 \
    || { FETCH_ERR="fetch_engine.py failed"; return 1; }
  [[ -x "$STAGE/engine/cpu/llama-server" ]] || { FETCH_ERR="CPU runtime is missing."; return 1; }
  VERSION_STR="$(tr -d '[:space:]' <"$CHECKOUT/VERSION" 2>/dev/null || true)"
  [[ -n "$VERSION_STR" ]] || VERSION_STR="0.0.0"
  printf '%s\n' "$VERSION_STR" >"$STAGE/VERSION"
  # the website, which the service serves to other computers on the network when asked to
  mkdir -p "$STAGE/site" && cp -- "$CHECKOUT"/docs/{index.html,app.js,style.css,theme.js,favicon.svg,apple-touch-icon.png} "$STAGE/site/" \
    || { FETCH_ERR="the website files are missing from the checkout"; return 1; }
  return 0
}

# ---------------------------------------------------------------- console prompts (gum, or simple prompts)
# gum: downloaded into the work dir (removed with it at the end), checked against the release's checksums.txt.
get_gum() {
  local arch name base want dir
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) return 1 ;;
  esac
  name="gum_${GUM_VER}_Linux_${arch}.tar.gz"
  base="https://github.com/charmbracelet/gum/releases/download/v$GUM_VER"
  dir="$WORK/gum"
  mkdir -p "$dir" || return 1
  curl -fsSL --retry 2 --connect-timeout 15 -A "$UA" -o "$dir/$name" "$base/$name" 2>>"$LOG" || return 1
  curl -fsSL --retry 2 --connect-timeout 15 -A "$UA" -o "$dir/checksums.txt" "$base/checksums.txt" 2>>"$LOG" || return 1
  want="$(awk -v n="$name" '$2 == n {print $1; exit}' "$dir/checksums.txt")"
  [[ "$want" =~ ^[0-9a-f]{64}$ && "$want" == "$(sha256_of "$dir/$name")" ]] || { log "gum checksum does not match"; return 1; }
  tar -xzf "$dir/$name" -C "$dir" 2>>"$LOG" || return 1
  GUM="$(find "$dir" -type f -name gum -perm -u+x | head -n 1)"
  [[ -n "$GUM" ]] && "$GUM" --version >/dev/null 2>&1
}

# The three options at once: OPT_STARTUP, OPT_DESKTOP, OPT_LAUNCH in and out. 130 = cancelled.
ask_options() {
  local -a labels=("$T_O_STARTUP" "$T_O_DESKTOP" "$T_O_LAUNCH") picked=()
  local sel="" i out rc a def hint
  local -a vals=("$OPT_STARTUP" "$OPT_DESKTOP" "$OPT_LAUNCH")
  if [[ -n "$GUM" ]]; then
    for i in 0 1 2; do ((vals[i])) && sel+="${sel:+,}${labels[$i]}"; done
    local -a args=(choose --no-limit --header "$T_Q_OPTIONS" --cursor '❯ ' --cursor.foreground '#a48bff' --header.foreground '#a48bff'
      --selected.foreground '#a48bff' --selected-prefix '◆ ' --unselected-prefix '◇ ' --cursor-prefix '◇ ')
    [[ -n "$sel" ]] && args+=(--selected "$sel")
    out="$("$GUM" "${args[@]}" "${labels[@]}" </dev/tty)"; rc=$?
    ((rc == 130)) && return 130
    if ((rc == 0)); then
      for i in 0 1 2; do
        if grep -qxF -- "${labels[$i]}" <<<"$out"; then picked[i]=1; else picked[i]=0; fi
      done
      OPT_STARTUP="${picked[0]}"; OPT_DESKTOP="${picked[1]}"; OPT_LAUNCH="${picked[2]}"
      return 0
    fi
    GUM="" # gum could not draw: this and every later question use the simple prompts
  fi
  printf '  %s%s%s\n' "$C_ACCENT" "${T_Q_OPTIONS%% (*}" "$RST"
  for i in 0 1 2; do
    def="${vals[$i]}"
    if ((def)); then hint="${T_PLAIN_YES^^}/n"; else hint="$T_PLAIN_YES/N"; fi
    read -r -p "    ${labels[$i]} [$hint] " a </dev/tty || return 130
    a="${a,,}"
    if [[ -z "$a" ]]; then picked[i]="$def"
    elif [[ "$a" == "$T_PLAIN_YES"* || "$a" == y* ]]; then picked[i]=1
    else picked[i]=0; fi
  done
  OPT_STARTUP="${picked[0]}"; OPT_DESKTOP="${picked[1]}"; OPT_LAUNCH="${picked[2]}"
  return 0
}

# 0 yes, 1 no
ask_confirm() {
  local a rc
  if [[ -n "$GUM" ]]; then
    "$GUM" confirm "$1" --affirmative "$T_GO" --negative "$T_CANCEL" --default=true --prompt.foreground '#a48bff' \
      --selected.background '#a48bff' --selected.foreground '#1a1033' </dev/tty
    rc=$?
    ((rc == 130)) && return 1
    ((rc <= 1)) && return "$rc"
    GUM=""
  fi
  read -r -p "  $1 [${T_PLAIN_YES^^}/n] " a </dev/tty || return 1
  a="${a,,}"
  [[ -z "$a" || "$a" == "$T_PLAIN_YES"* || "$a" == y* ]]
}

# ---------------------------------------------------------------- modes
new_work_dir() {
  if [[ -n "$PREVIEW" ]]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/asz-install-XXXXXXXX")" || return 1
  else
    mkdir -p "$(dirname "$PREFIX")" || return 1
    # next to the install dir: the package is large and /tmp is often memory
    WORK="$(mktemp -d "$(dirname "$PREFIX")/.asenaizer-install.XXXXXXXX")" || return 1
  fi
  STAGE="$WORK/stage"
}

cleanup() {
  local code=$?
  if ((STEPS_STARTED && !COMMITTED)) && ((${#JOURNAL[@]})); then rollback; fi
  [[ -n "$WORK" ]] && rm -rf -- "$WORK"
  [[ -t 1 && -z "$DRIVER" ]] && printf '\e[?25h'
  exit "$code"
}

open_log() {
  if [[ -L "$LOG" ]] || ! { : >>"$LOG"; } 2>/dev/null; then
    LOG="${XDG_CACHE_HOME:-$HOME/.cache}/asenaizer-install.log"
    mkdir -p "$(dirname "$LOG")" 2>/dev/null
  fi
  if [[ "${1:-}" == new ]]; then printf '== Asenaizer install %s ==\n' "$(date)" >"$LOG" 2>/dev/null
  else printf '\n== Asenaizer install %s (%s) ==\n' "$(date)" "${DRIVER:+driver}" >>"$LOG" 2>/dev/null; fi
}

# The setup window drives the install: no questions, the phases in status.json, the steps in progress.json.
driver_mode() {
  local rc detail
  [[ -d "$DRIVER" ]] || { echo "ASZ_DRIVER is not a folder: $DRIVER" >&2; return 1; }
  if [[ -n "${ASZ_LOG_KEEP:-}" ]]; then open_log; else open_log new; fi
  exec >>"$LOG" 2>&1 </dev/null
  PROGRESS="$DRIVER/progress.json"
  new_work_dir || { status error "$(kv title "$T_ERR_TITLE")" "$(kv message "$T_ERR_RETRY")" "$(kv detail "cannot create a work dir")" "$(kv log "$LOG")"; return 1; }
  status release
  if [[ -n "$PREVIEW" ]]; then preview_download; rc=$?
  elif [[ -n "${ASZ_SOURCE:-}" ]]; then use_package_dir; rc=$?
  else fetch_release; rc=$?; fi
  cancel_requested && ((rc != 0)) && rc=2
  case "$rc" in
    0) ;;
    2) status cancelled "$(kv title "$T_CANCEL_TITLE")" "$(kv message "$T_CANCEL_BODY")"; return 2 ;;
    3) status error "$(kv title "$T_ERR_TITLE")" "$(kv message "$T_NO_RELEASE $T_NO_RELEASE_HINT")" \
         "$(kv detail "curl -fsSL $RAW/scripts/install-linux.sh | ASZ_NO_GUI=1 bash")" "$(kv log "$LOG")"
       return 1 ;;
    *) status error "$(kv title "$T_ERR_TITLE")" "$(kv message "$T_DL_FAILED")" "$(kv detail "${FETCH_ERR:-exit $rc}")" "$(kv log "$LOG")"
       return 1 ;;
  esac
  local -a labels=()
  local id
  for id in "${STEP_IDS[@]}"; do labels+=("$(step_label "$id")"); done
  status setup "$(kv progress "$PROGRESS")" "\"steps\":$(json_arr "${labels[@]}")"
  run_steps; rc=$?
  case "$rc" in
    0)
      after_install
      local -a warn=()
      local w
      for w in ${WARN[@]+"${WARN[@]}"}; do warn+=("$(warn_label "$w")"); done
      status done "$(kv title "$T_DONE_TITLE")" "$(kv body "$(done_body)")" "$(kv warnTitle "$T_WARN_TITLE")" \
        "$(kv warnBody "$T_WARN_BODY")" "\"warn\":$(json_arr ${warn[@]+"${warn[@]}"})" "$(kv log "$LOG")"
      ;;
    2) status cancelled "$(kv title "$T_CANCEL_TITLE")" "$(kv message "$T_CANCEL_BODY")" ;;
    *)
      detail="${STEP_ERR:-exit $rc}"
      # shellcheck disable=SC2059
      status error "$(kv title "$T_ERR_TITLE")" "$(kv message "$(printf "$T_ERR_BODY" "$(step_label "$STEP_ID")")")" \
        "$(kv detail "$detail")" "$(kv log "$LOG")"
      ;;
  esac
  return "$rc"
}

console_mode() {
  local rc yn
  open_log "${1:-new}"
  INTERACTIVE=0
  if [[ -z "${ASZ_DEFAULTS:-}" && -t 1 ]] && (: </dev/tty) 2>/dev/null; then INTERACTIVE=1; fi
  trap 'CANCEL=1' INT
  banner
  new_work_dir || { box "$C_ERR" "$T_ERR_TITLE" "cannot create a work dir next to $PREFIX"; return 1; }
  if ((INTERACTIVE)) && [[ "${ASZ_PLAIN:-}" != 1 ]]; then
    with_spinner "$T_PREPARING" get_gum || GUM=""
  fi
  box "$C_ACCENT" "$T_WELCOME" "$T_WELCOME_BODY"
  printf '\n'
  if ((INTERACTIVE)); then
    ask_options; rc=$?
    if ((rc == 130)) || ((CANCEL)); then box "$C_WARN" "$T_CANCEL_TITLE" "$T_CANCEL_BODY"; return 2; fi
    yn() { if (($1)); then printf '%s' "$T_ON"; else printf '%s' "$T_OFF"; fi; }
    box "$C_ACCENT" "$T_SUMMARY" "$T_O_STARTUP: $(yn "$OPT_STARTUP")"$'\n'"$T_O_DESKTOP: $(yn "$OPT_DESKTOP")"$'\n'"$T_O_LAUNCH: $(yn "$OPT_LAUNCH")"$'\n\n'"$T_MENU_ALWAYS"
    printf '\n'
    if ! ask_confirm "$T_Q_GO" || ((CANCEL)); then box "$C_WARN" "$T_CANCEL_TITLE" "$T_CANCEL_BODY"; return 2; fi
    printf '\n'
  fi

  # ------------------------------------------------------------ the package
  if [[ -n "$PREVIEW" ]]; then preview_download; rc=$?
  elif [[ -n "$CHECKOUT" ]]; then say "$C_ACCENT" "$G_WAIT" "$T_SOURCE_BUILD"; build_from_source; rc=$?
  elif [[ -n "${ASZ_SOURCE:-}" ]]; then use_package_dir; rc=$?
  else
    fetch_release; rc=$?
    if ((rc == 3)); then
      say "$C_WARN" "$G_WAIT" "$T_SOURCE_BUILD"
      rm -rf -- "$STAGE"
      build_from_source; rc=$?
    fi
  fi
  ((CANCEL)) && rc=2
  case "$rc" in
    0) ;;
    2) box "$C_WARN" "$T_CANCEL_TITLE" "$T_CANCEL_BODY"; return 2 ;;
    *) box "$C_ERR" "$T_ERR_TITLE" "$T_DL_FAILED"$'\n\n'"$T_ERR_DETAIL: ${FETCH_ERR:-exit $rc}"$'\n'"$T_ERR_LOG: $LOG"$'\n\n'"$T_ERR_RETRY"; return 1 ;;
  esac
  [[ -n "$VERSION_STR" ]] && say "$C_DIM" "$G_DOT" "$T_VERSION: $VERSION_STR"

  [[ -t 1 ]] && printf '\e[?25l'
  run_steps; rc=$?
  [[ -t 1 ]] && printf '\e[?25h'
  case "$rc" in
    0)
      after_install
      box "$C_OK" "$T_DONE_TITLE" "$(done_body)"
      if ((${#WARN[@]})); then
        local list="" w
        for w in "${WARN[@]}"; do list+="${list:+$'\n'}$G_BULLET $(warn_label "$w")"; done
        box "$C_WARN" "$T_WARN_TITLE" "$list"$'\n\n'"$T_WARN_BODY"$'\n'"$T_ERR_LOG: $LOG"
      fi
      ;;
    2) box "$C_WARN" "$T_CANCEL_TITLE" "$T_CANCEL_BODY" ;;
    *)
      # shellcheck disable=SC2059
      box "$C_ERR" "$T_ERR_TITLE" "$(printf "$T_ERR_BODY" "$(step_label "$STEP_ID")")"$'\n\n'"$T_ERR_DETAIL: ${STEP_ERR:-exit $rc}"$'\n'"$T_ERR_LOG: $LOG"$'\n\n'"$T_ERR_RETRY"
      ;;
  esac
  printf '\n'
  return "$rc"
}

# Downloads the setup window into a temp dir, checks it and runs it. Prints why when it cannot (exit 200).
GUI_WHY=""
run_setup_window() {
  local tmp bin want rc missing
  [[ "$(uname -m)" == x86_64 ]] || { GUI_WHY="$(uname -m)"; return 200; }
  command -v curl >/dev/null || { GUI_WHY="curl"; return 200; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/asz-boot-XXXXXXXX")" || { GUI_WHY="mktemp"; return 200; }
  bin="$tmp/$SETUP_ASSET"
  if ! curl -fsSL --retry 3 --connect-timeout 20 -A "$UA" -o "$bin" "$SETUP_BASE/$SETUP_ASSET" 2>>"$LOG" \
    || ! curl -fsSL --retry 3 --connect-timeout 20 -A "$UA" -o "$bin.sha256" "$SETUP_BASE/$SETUP_ASSET.sha256" 2>>"$LOG"; then
    rm -rf -- "$tmp"; GUI_WHY="$SETUP_ASSET: download failed"; return 200
  fi
  want="$(awk '{print $1; exit}' "$bin.sha256")"
  if [[ ! "$want" =~ ^[0-9a-f]{64}$ || "$want" != "$(sha256_of "$bin")" ]]; then
    rm -rf -- "$tmp"; GUI_WHY="$SETUP_ASSET: SHA-256 mismatch"; return 200
  fi
  chmod 700 "$bin"
  missing="$(ldd_missing "$bin")"
  if [[ -n "$missing" ]]; then rm -rf -- "$tmp"; GUI_WHY="missing $(tr '\n' ' ' <<<"$missing")"; return 200; fi
  say "$C_ACCENT" "$G_WAIT" "$T_GUI_OPENING"
  log "running $SETUP_ASSET ($want)"
  ASZ_LOG_KEEP=1 "$bin" </dev/null
  rc=$?
  rm -rf -- "$tmp"
  log "$SETUP_ASSET exited with $rc"
  return "$rc"
}

bootstrap_mode() {
  local rc
  open_log new
  setup_drawing
  if ((FORCE_CONSOLE)) || [[ -n "${ASZ_NO_GUI:-}" ]] || ! has_display; then console_mode keep; return; fi
  ensure_runtime_libs || true
  run_setup_window; rc=$?
  # the window ran: its result is the answer (0 installed, 1 failed, 2 cancelled; 130 = Ctrl+C here)
  case "$rc" in
    0 | 1 | 2 | 130) return "$rc" ;;
  esac
  [[ "$rc" == 200 ]] || GUI_WHY="exit $rc"
  # shellcheck disable=SC2059
  say "$C_WARN" "$G_WAIT" "$(printf "$T_GUI_FALLBACK" "$GUI_WHY")"
  sleep 1
  console_mode keep
}

main() {
  while (($#)); do
    case "$1" in
      --source) CHECKOUT="${2:?--source needs a directory}"; shift 2 ;;
      --console) FORCE_CONSOLE=1; shift ;;
      -h | --help) sed -n '2,31p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//'; return 0 ;;
      *) echo "Unknown argument: $1" >&2; return 2 ;;
    esac
  done
  [[ "$(uname -s)" == Linux ]] || { echo "This installer is for Linux." >&2; return 2; }
  [[ -n "${HOME:-}" ]] || { echo "HOME is not set." >&2; return 2; }
  case "${ASZ_PREVIEW:-}" in
    "" | 0) PREVIEW="" ;;
    fail | warn) PREVIEW="$ASZ_PREVIEW" ;;
    *) PREVIEW=ok ;;
  esac
  [[ "${ASZ_NO_STARTUP:-}" == 1 ]] && OPT_STARTUP=0
  [[ "${ASZ_DESKTOP:-}" == 1 ]] && OPT_DESKTOP=1
  [[ "${ASZ_NO_LAUNCH:-}" == 1 ]] && OPT_LAUNCH=0
  if [[ "${ASZ_KEEP_CHOICES:-}" == 1 ]]; then
    # the app updates itself: it starts at sign-in and has a desktop shortcut only if it does now
    if [[ -f "$AUTOSTART_DIR/asenaizer.desktop" ]]; then OPT_STARTUP=1; else OPT_STARTUP=0; fi
    if grep -qsF "$PREFIX/asenaizer-tray" "$(desktop_dir)/asenaizer.desktop"; then OPT_DESKTOP=1; else OPT_DESKTOP=0; fi
  fi
  load_texts
  trap cleanup EXIT
  trap 'CANCEL=1' TERM
  if [[ -n "${ASZ_DRIVER:-}" ]]; then
    DRIVER="$ASZ_DRIVER"
    # Ctrl+C in the terminal that started the window reaches this script too: roll back, do not die half-way
    trap 'CANCEL=1' INT
    setup_drawing
    driver_mode
  elif [[ -n "$CHECKOUT" ]]; then
    setup_drawing
    console_mode new
  else
    bootstrap_mode
  fi
}

main "$@"
