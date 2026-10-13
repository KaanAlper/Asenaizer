#!/usr/bin/env bash
# Asenaizer - Linux uninstaller (installed as ~/.local/share/asenaizer/uninstall.sh; run it with asenaizer-uninstall)
# Stops Asenaizer's own processes (an executable under the install dir, never a name alone), then removes the install
# dir, the asenaizer / asenaizer-uninstall commands, the app menu, desktop and autostart entries. The service data
# (~/.local/share/Humanizer: models of several GB, settings, pairings) is kept unless you say otherwise.
# Usage: uninstall.sh [--remove-data | --keep-data] [--quiet]
#   --remove-data / --keep-data   answer the data question without asking
#   --quiet                       no questions (the data is kept unless --remove-data), less output
# ASZ_PREVIEW=1: only print what would be removed.

set -uo pipefail

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
PREFIX="$DATA_HOME/asenaizer"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$DATA_HOME/applications"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
SERVICE_DATA="$DATA_HOME/Humanizer"

REMOVE_DATA=""   # "", 1, 0
QUIET=0
PREVIEW=""

T_STOPPING="Stopping Asenaizer"; T_REMOVING="Removing Asenaizer"
T_Q_DATA="Also delete the models and settings? (%s, %s)"; T_YES="y"
T_DATA_KEPT="The models and settings were kept: %s"; T_DATA_REMOVED="The models and settings were deleted."
T_DATA_ELSEWHERE="The models are in another folder, which was left alone: %s"
T_DONE="Asenaizer was removed."; T_NOTHING="Asenaizer does not seem to be installed for this account."
T_NOT_OURS="%s does not look like an Asenaizer install; it was not deleted."
T_STILL_RUNNING="Some Asenaizer processes could not be stopped:"
T_PREVIEW="Preview: this would be removed"

say() { ((QUIET)) || printf '  %s\n' "$*"; }

# The install dir this script belongs to (uninstall.sh inside it), else the default one.
own_prefix() {
  local self dir
  self="${BASH_SOURCE[0]:-}"
  [[ -n "$self" && -f "$self" ]] || return 0
  dir="$(cd "$(dirname "$self")" && pwd)"
  if [[ -x "$dir/asenaizer-tray" && -f "$dir/VERSION" ]]; then PREFIX="$dir"; fi
}

# Only a directory that holds an Asenaizer install is ever deleted.
looks_like_install() {
  [[ -d "$1" && "$(basename "$1")" == asenaizer ]] || return 1
  [[ -e "$1/asenaizer-tray" || -e "$1/Humanizer" || -e "$1/VERSION" ]]
}

asz_pids() {
  local dir exe name
  while read -r dir exe; do
    exe="${exe% (deleted)}"
    [[ "$exe" == "$PREFIX"/* ]] || continue
    name="${exe##*/}"
    case "$name" in asenaizer-tray | Humanizer | llama-server) printf '%s\n' "${dir#/proc/}" ;; esac
  done < <(find /proc -mindepth 2 -maxdepth 2 -name exe -lname "$PREFIX/*" -printf '%h %l\n' 2>/dev/null)
}

stop_processes() {
  local -a pids
  local i
  mapfile -t pids < <(asz_pids)
  ((${#pids[@]})) || return 0
  say "$T_STOPPING"
  kill -TERM "${pids[@]}" 2>/dev/null
  for ((i = 0; i < 150; i++)); do
    [[ -n "$(asz_pids)" ]] || return 0
    ((i == 100)) && kill -KILL "${pids[@]}" 2>/dev/null
    sleep 0.1
  done
  [[ -z "$(asz_pids)" ]] && return 0
  printf '  %s %s\n' "$T_STILL_RUNNING" "$(asz_pids | tr '\n' ' ')" >&2
  return 1
}

desktop_dir() {
  local d=""
  command -v xdg-user-dir >/dev/null && d="$(xdg-user-dir DESKTOP 2>/dev/null)"
  [[ -z "$d" || "$d" == "$HOME" ]] && d="$HOME/Desktop"
  printf '%s' "$d"
}

# A file we wrote: removed only when it points at Asenaizer.
remove_ours() {
  local f="$1"
  [[ -e "$f" || -L "$f" ]] || return 0
  grep -qF "asenaizer" "$f" 2>/dev/null || return 0
  if [[ -n "$PREVIEW" ]]; then printf '    %s\n' "$f"; else rm -f -- "$f"; fi
}

# Where the service keeps its models: location.json in the default folder may point to another one.
custom_data_dir() {
  [[ -f "$SERVICE_DATA/location.json" ]] && command -v python3 >/dev/null || return 0
  python3 -I -c 'import json,sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8")).get("data_dir") or ""
except Exception:
    d = ""
print(d)' "$SERVICE_DATA/location.json" 2>/dev/null
}

ask_remove_data() {
  local size a
  [[ -d "$SERVICE_DATA" ]] || { REMOVE_DATA=0; return; }
  [[ -n "$REMOVE_DATA" ]] && return
  if ((QUIET)) || ! (: </dev/tty) 2>/dev/null; then REMOVE_DATA=0; return; fi
  size="$(du -sh "$SERVICE_DATA" 2>/dev/null | awk '{print $1}')"
  # shellcheck disable=SC2059
  read -r -p "  $(printf "$T_Q_DATA" "$SERVICE_DATA" "${size:-?}") [$T_YES/N] " a </dev/tty || a=""
  a="${a,,}"
  if [[ "$a" == "$T_YES"* || "$a" == y* ]]; then REMOVE_DATA=1; else REMOVE_DATA=0; fi
}

main() {
  local found=0 other desk
  while (($#)); do
    case "$1" in
      --remove-data) REMOVE_DATA=1 ;;
      --keep-data) REMOVE_DATA=0 ;;
      --quiet | -q) QUIET=1 ;;
      -h | --help) sed -n '2,10p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//'; return 0 ;;
      *) echo "Unknown argument: $1" >&2; return 2 ;;
    esac
    shift
  done
  [[ -n "${HOME:-}" ]] || { echo "HOME is not set." >&2; return 2; }
  [[ -n "${ASZ_PREVIEW:-}" && "${ASZ_PREVIEW}" != 0 ]] && PREVIEW=1
  own_prefix
  desk="$(desktop_dir)/asenaizer.desktop"

  [[ -e "$PREFIX" || -e "$BIN_DIR/asenaizer" || -e "$APP_DIR/asenaizer.desktop" || -e "$AUTOSTART_DIR/asenaizer.desktop" ]] && found=1
  if ((!found)); then say "$T_NOTHING"; fi

  ask_remove_data
  if [[ -n "$PREVIEW" ]]; then
    printf '  %s:\n' "$T_PREVIEW"
    looks_like_install "$PREFIX" && printf '    %s/\n' "$PREFIX"
    for f in "$BIN_DIR/asenaizer" "$BIN_DIR/asenaizer-uninstall" "$APP_DIR/asenaizer.desktop" "$AUTOSTART_DIR/asenaizer.desktop" "$desk"; do
      remove_ours "$f"
    done
    ((REMOVE_DATA)) && printf '    %s/\n' "$SERVICE_DATA"
    return 0
  fi

  ((found)) && { stop_processes || true; }
  ((found)) && say "$T_REMOVING"
  for f in "$AUTOSTART_DIR/asenaizer.desktop" "$APP_DIR/asenaizer.desktop" "$desk" "$BIN_DIR/asenaizer" "$BIN_DIR/asenaizer-uninstall"; do
    remove_ours "$f"
  done
  command -v update-desktop-database >/dev/null && update-desktop-database "$APP_DIR" >/dev/null 2>&1
  if [[ -e "$PREFIX" ]]; then
    if looks_like_install "$PREFIX"; then
      rm -rf -- "$PREFIX"
    else
      # shellcheck disable=SC2059
      printf "  $T_NOT_OURS\n" "$PREFIX" >&2
    fi
  fi

  if [[ -d "$SERVICE_DATA" ]]; then
    other="$(custom_data_dir)"
    if ((REMOVE_DATA)); then
      rm -rf -- "$SERVICE_DATA"
      say "$T_DATA_REMOVED"
      # shellcheck disable=SC2059
      [[ -n "$other" && "$other" != "$SERVICE_DATA" && -d "$other" ]] && say "$(printf "$T_DATA_ELSEWHERE" "$other")"
    else
      # shellcheck disable=SC2059
      say "$(printf "$T_DATA_KEPT" "$SERVICE_DATA")"
    fi
  fi
  ((found)) && say "$T_DONE"
  return 0
}

main "$@"
