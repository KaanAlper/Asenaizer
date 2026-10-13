#!/usr/bin/env bash
# Prints the next release version, with the same rules as Logical Lunge's
# tools/release-version.ps1:
#   MAJOR when a commit since the last release is breaking ("type!:" in the subject, or a
#   "BREAKING CHANGE: <text>" footer line), MINOR when one adds a feature ("feat:"), PATCH
#   otherwise. A bump argument (patch|minor|major) forces the level. Without an earlier
#   v<semver> tag, VERSION is released as it is; a higher VERSION wins over the computed one.
#   Versions any tag already used are never reused.
#   tools/release-version.sh [auto|patch|minor|major]
set -euo pipefail
bump="${1:-auto}"
base="$(tr -d '[:space:]' < VERSION)"
[[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VERSION: $base" >&2; exit 2; }
[[ "$bump" =~ ^(auto|patch|minor|major)$ ]] || { echo "Invalid bump: $bump" >&2; exit 2; }

mapfile -t used < <(git tag --list 'v*' | sed -nE 's/^v([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | sort -V)
if ((${#used[@]} == 0)); then
  echo "$base"
  exit 0
fi
last="${used[-1]}"

level="$bump"
if [[ "$level" == auto ]]; then
  level=patch
  # %x1e separates commits so a body line is never read as a subject.
  while IFS= read -r -d $'\x1e' commit; do
    commit="${commit#$'\n'}"
    subject="${commit%%$'\n'*}"
    if [[ "$subject" =~ ^[A-Za-z]+(\([^\)]*\))?\!: ]] || grep -qE '^BREAKING[ -]CHANGE: [^[:space:]]' <<<"$commit"; then
      level=major
      break
    fi
    [[ "$subject" =~ ^feat(\([^\)]*\))?: ]] && level=minor
  done < <(git log --format='%s%n%b%x1e' "v$last"..HEAD)
fi

step() {
  local IFS=. v
  read -r -a v <<<"$1"
  case "$2" in
    major) echo "$((v[0] + 1)).0.0" ;;
    minor) echo "${v[0]}.$((v[1] + 1)).0" ;;
    *) echo "${v[0]}.${v[1]}.$((v[2] + 1))" ;;
  esac
}

next="$(step "$last" "$level")"
if [[ "$(printf '%s\n%s\n' "$base" "$next" | sort -V | tail -1)" == "$base" && "$base" != "$next" ]]; then
  next="$base"
fi
while printf '%s\n' "${used[@]}" | grep -qxF "$next"; do
  next="$(step "$next" patch)"
done
echo "$next"
