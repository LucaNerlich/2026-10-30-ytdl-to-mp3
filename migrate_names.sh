#!/usr/bin/env bash
# migrate_names.sh: one-off helper that renames kanazhan-style mp3 files
# from "<id>.mp3" to "<slugified-title>.mp3", using the same slug rule as
# channel2mp3.sh. Run AFTER updating the script, BEFORE the next full run.
# Usage:  ./migrate_names.sh [BASE_DIR]      (default: karazhan)
set -euo pipefail

BASE_DIR="${1:-karazhan}"
MP3_DIR="$BASE_DIR/mp3"
META_DIR="$BASE_DIR/meta"

[[ -d "$META_DIR" ]] || { echo "no metadata dir: $META_DIR" >&2; exit 1; }
[[ -d "$MP3_DIR" ]] || { echo "no mp3 dir: $MP3_DIR" >&2; exit 1; }

slug_of() {  # $1=title $2=id
  local s
  s="$(jq -rn --arg t "$1" '
    $t | ascii_downcase | gsub("[^a-z0-9]+"; "-")
    | gsub("(^-+|-+$)"; "")
    | (if .[0:80] != . then .[0:80] else . end)
    | gsub("(^-+|-+$)"; "")')"
  [[ -z "$s" ]] && s="$2"
  printf '%s' "$s"
}

declare -A TAKEN=()
moved=0
for info in "$META_DIR"/*.info.json; do
  id="$(jq -r '.id' "$info")"
  [[ -z "$id" || "$id" == "null" ]] && continue
  title="$(jq -r '.title // ""' "$info")"
  s="$(slug_of "$title" "$id")"
  while [[ -n "${TAKEN[$s]:-}" ]]; do s="$s-$id"; done
  TAKEN[$s]="$id"

  old="$MP3_DIR/$id.mp3"
  new="$MP3_DIR/$s.mp3"
  if [[ "$s" == "$id" ]]; then continue; fi                 # already slug == id
  if [[ -e "$new" ]]; then                                   # target exists
    if [[ -s "$old" ]]; then
      echo "leave $old: target $new already exists" >&2
    fi
    continue
  fi
  if [[ -s "$old" ]]; then
    mv -n "$old" "$new"
    echo "mv $id.mp3 -> $s.mp3"
    moved=$((moved + 1))
  fi
done
echo "migrated $moved file(s); $(find "$MP3_DIR" -name '*.mp3' | wc -l) mp3s in $MP3_DIR"
