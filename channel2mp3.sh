#!/usr/bin/env bash
# channel2mp3.sh
#
# Downloads the audio of all videos of a YouTube channel with yt-dlp,
# converts them to mono MP3 with ffmpeg, and writes a markdown log
# (LOG.md) mapping every file to its original video title, URL and
# cover image. Cover art is also embedded into the MP3 itself.
#
# Usage:
#   ./channel2mp3.sh
#   CHANNEL_URL="https://www.youtube.com/@somechannel/videos" ./channel2mp3.sh
#   BITRATE=128k ./channel2mp3.sh
#   LIMIT=3 ./channel2mp3.sh       # test run: first 3 videos only
#   COOKIES_FILE=cookies.txt ./channel2mp3.sh      # for members-only/age-restricted
#
# Re-running is safe: yt-dlp's download archive skips videos already
# fetched, and failed conversions get repaired on the next run.
#
# Requirements: yt-dlp, ffmpeg (with libmp3lame), jq
#
# Result layout (inside BASE_DIR):
#   LOG.md               the markdown log
#   downloaded.txt       yt-dlp archive of processed video ids
#   mp3/<slug>.mp3       final mono MP3 files (slugified video title)
#   thumbs/<id>.jpg      cover images
#   meta/<id>.info.json  raw yt-dlp metadata used to build the log
#   raw/                 transient dir (emptied on success)
set -euo pipefail

CHANNEL_URL="${CHANNEL_URL:-https://www.youtube.com/@TheKarazhanLibrary/videos}"
CHANNEL_NAME="${CHANNEL_NAME:-The Karazhan Library}"
BITRATE="${BITRATE:-192k}"            # mono; 128k is usually transparent, 96k fine for speech
BASE_DIR="${BASE_DIR:-karazhan}"
MP3_DIR="$BASE_DIR/mp3"
THUMB_DIR="$BASE_DIR/thumbs"
META_DIR="$BASE_DIR/meta"
RAW_DIR="$BASE_DIR/raw"
LOG_FILE="$BASE_DIR/LOG.md"
ARCHIVE="$BASE_DIR/downloaded.txt"

for cmd in yt-dlp ffmpeg jq; do
  command -v "$cmd" >/dev/null || { echo "error: '$cmd' not found in PATH" >&2; exit 1; }
done
ffmpeg_encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"
[[ "$ffmpeg_encoders" == *libmp3lame* ]] || {
  echo "error: ffmpeg without libmp3lame" >&2; exit 1;
}

mkdir -p "$MP3_DIR" "$THUMB_DIR" "$META_DIR" "$RAW_DIR"
shopt -s nullglob

ytdlp_opts=()
if [[ -n "${COOKIES_FILE:-}" ]]; then
  ytdlp_opts+=(--cookies "$COOKIES_FILE")
fi
# main download only (repair pass fetches single URLs where this would break)
download_opts=("${ytdlp_opts[@]}")
if [[ -n "${LIMIT:-}" ]]; then
  download_opts+=("--playlist-items" "1:$LIMIT")
fi

# find_cover <id> -> prints first existing cover file path, if any
find_cover() {
  local d id ext
  local -a dirs=("$RAW_DIR" "$THUMB_DIR")
  for d in "${dirs[@]}"; do
    for ext in jpg jpeg png webp; do
      id="$d/$1.$ext"
      [[ -f "$id" ]] && { echo "$id"; return 0; }
    done
  done
  return 1
}

# make_slug <title> <id>: slugified title (lowercase, [a-z0-9]-), max 80 chars;
# falls back to the video id when the title slugifies away entirely
make_slug() {
  local slug
  slug="$(jq -rn --arg t "$1" '
    $t | ascii_downcase | gsub("[^a-z0-9]+"; "-")
    | gsub("(^-+|-+$)"; "")
    | (if .[0:80] != . then .[0:80] else . end)
    | gsub("(^-+|-+$)"; "")')"
  [[ -z "$slug" ]] && slug="$2"
  printf '%s' "$slug"
}

# Filenames: mp3 files are named <slug>.mp3. Slugs are kept unique across
# all known videos (meta/ + raw/) by suffixing "-<id>" on collisions;
# the registry is deterministic so names are stable across runs.
declare -A NAME_OF NAME_OF_REVERSE   # id -> mp3 basename / slug -> owner id
slug_registry_build() {
  NAME_OF=()
  NAME_OF_REVERSE=()
  local f id title s
  for f in "$META_DIR"/*.info.json "$RAW_DIR"/*.info.json; do
    id="$(jq -r '.id' "$f" 2>/dev/null)"
    [[ -z "$id" || "$id" == "null" ]] && continue
    [[ -n "${NAME_OF[$id]:-}" ]] && continue   # same id in meta/ and raw/
    title="$(jq -r '.title // ""' "$f" 2>/dev/null)"
    s="$(make_slug "$title" "$id")"
    while [[ -n "${NAME_OF_REVERSE[$s]:-}" ]]; do s="$s-$id"; done
    NAME_OF[$id]="$s"
    NAME_OF_REVERSE[$s]="$id"
  done
}
# name_for <id> <title?> -> mp3 basename for this video
name_for() {
  local n="${NAME_OF[$1]:-}"
  if [[ -z "$n" ]]; then
    n="$(make_slug "$2" "$1")"
    while [[ -n "${NAME_OF_REVERSE[$n]:-}" && "${NAME_OF_REVERSE[$n]}" != "$1" ]]; do
      n="$n-$1"
    done
    NAME_OF[$1]="$n"
    NAME_OF_REVERSE[$n]="$1"
  fi
  printf '%s' "$n"
}

echo "== Step 1/3: downloading source audio + thumbnails (yt-dlp)"
# --ignore-errors: skip failed videos and continue with the rest of the channel.
# --download-archive: re-runs only fetch new uploads.
yt-dlp \
  --ignore-errors \
  --download-archive "$ARCHIVE" \
  --no-write-playlist-metafiles \
  -f "bestaudio/best" \
  --write-info-json \
  --write-thumbnail --convert-thumbnails jpg \
  -o "$RAW_DIR/%(id)s.%(ext)s" \
  "${download_opts[@]}" \
  "$CHANNEL_URL" \
  || echo "   (yt-dlp reported errors; continuing with what was downloaded)"

# build id -> mp3-name mapping so repair/convert/log agree on filenames
slug_registry_build

echo "== Step 1b/3: repairing conversions that failed in an earlier run"
for info in "$META_DIR"/*.info.json; do
  id="$(jq -r '.id' "$info")"
  [[ -z "$id" || "$id" == "null" ]] && continue
  n="$(name_for "$id" "$(jq -r '.title // ""' "$info")")"
  # mp3 already fine under either naming? then nothing to repair
  [[ -s "$MP3_DIR/$n.mp3" || -s "$MP3_DIR/$id.mp3" ]] && continue
  # source still sitting in raw/ from an interrupted run? no re-download needed
  have_src=0
  for ext in webm m4a opus oga ogg aac mp3 flac wav; do
    [[ -f "$RAW_DIR/$id.$ext" ]] && have_src=1
  done
  if [[ "$have_src" == 1 ]]; then
    echo "   $id: source present in raw/, will just re-convert"
    continue
  fi
  url="$(jq -r '.webpage_url // ("https://www.youtube.com/watch?v=" + .id)' "$info")"
  echo "   re-downloading $id (mp3 missing)"
  yt-dlp --ignore-errors --no-download-archive \
    -f "bestaudio/best" --write-info-json \
    --write-thumbnail --convert-thumbnails jpg \
    -o "$RAW_DIR/%(id)s.%(ext)s" "${ytdlp_opts[@]}" "$url" \
    || echo "   WARNING: re-download of $id failed" >&2
done

echo "== Step 2/3: converting to mono MP3 ($BITRATE) with ffmpeg"
for info in "$RAW_DIR"/*.info.json; do
  id="$(jq -r '.id' "$info")"
  [[ -z "$id" || "$id" == "null" ]] && continue
  title="$(jq -r '.title // .id' "$info")"
  n="$(name_for "$id" "$title")"
  mp3="$MP3_DIR/$n.mp3"
  [[ -s "$mp3" ]] && continue   # already converted (previous run)
  # migrate legacy id-named files produced by older script versions
  if [[ "$n" != "$id" && -s "$MP3_DIR/$id.mp3" ]]; then
    mv "$MP3_DIR/$id.mp3" "$mp3"
    echo "   renamed mp3/$id.mp3 -> mp3/$n.mp3"
    continue
  fi

  # find the downloaded source audio for this id
  src=""
  for ext in webm m4a opus oga ogg aac mp3 flac wav; do
    [[ -f "$RAW_DIR/$id.$ext" ]] && { src="$RAW_DIR/$id.$ext"; break; }
  done
  if [[ -z "$src" ]]; then
    echo "   skip $id: no source audio in raw/" >&2
    continue
  fi

  cover="$(find_cover "$id")"

  title="$(jq -r '.title // .id' "$info")"
  url="$(jq -r '.webpage_url // ("https://www.youtube.com/watch?v=" + .id)' "$info")"
  upload="$(jq -r '.upload_date // ""' "$info")"
  uploader="$(jq -r '.uploader // .channel // ""' "$info")"

  echo "   $(basename "$src") -> mp3/$n.mp3"
  codec_args=(-c:a libmp3lame -b:a "$BITRATE" -ac 1)
  map_args=(-map 0:a:0)
  if [[ -n "$cover" ]]; then
    map_args+=(-map "1:v:0")
    if [[ "$cover" == *.jpg || "$cover" == *.jpeg ]]; then
      codec_args+=(-c:v copy)
    else
      codec_args+=(-c:v mjpeg -frames:v 1)   # rare non-jpg cover
    fi
    codec_args+=(-disposition:v attached_pic
                 -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)")
  fi
  date_args=()
  [[ -n "$upload" ]] && date_args=(-metadata date="${upload:0:4}-${upload:4:2}-${upload:6:2}")

  if ffmpeg -hide_banner -loglevel error -nostdin -y \
      -i "$src" ${cover:+-i "$cover"} \
      "${map_args[@]}" "${codec_args[@]}" "${date_args[@]}" \
      -metadata title="$title" \
      -metadata artist="${uploader:-$CHANNEL_NAME}" \
      -metadata album="${uploader:-$CHANNEL_NAME} (YouTube)" \
      -metadata comment="$url" \
      -id3v2_version 3 -f mp3 \
      "$mp3.part"; then
    mv "$mp3.part" "$mp3"
    rm -f "$src"   # success -> drop the intermediate source
    # record in the download archive so re-runs don't re-fetch this video
    # (single-video repair downloads would otherwise never get archived)
    extractor="$(jq -r '.extractor // "youtube"' "$info")"
    grep -qxF "$extractor $id" "$ARCHIVE" 2>/dev/null || printf '%s %s\n' "$extractor" "$id" >> "$ARCHIVE"
  else
    rm -f "$mp3.part"
    echo "   WARNING: ffmpeg failed for $id ($src)" >&2
  fi
done

echo "== Step 3/3: tidying up + writing log"

# move thumbnails and metadata out of raw/
mv "$RAW_DIR"/*.jpg "$RAW_DIR"/*.jpeg "$RAW_DIR"/*.png "$RAW_DIR"/*.webp "$THUMB_DIR"/ 2>/dev/null || true
mv "$RAW_DIR"/*.info.json "$META_DIR"/ 2>/dev/null || true
rmdir "$RAW_DIR" 2>/dev/null || {
  echo "   note: raw/ not empty, leftover files:" >&2
  ls "$RAW_DIR" >&2
}

# Build LOG.md from the stored metadata (covers everything downloaded so far)
entries_file="$BASE_DIR/.log_entries.tmp"
jq -s -c 'sort_by(.upload_date // "9999", .id) | .[]' "$META_DIR"/*.info.json > "$entries_file"

{
  echo "# $CHANNEL_NAME: audio extracts"
  echo
  echo "- Source: <$CHANNEL_URL>"
  echo "- Generated: $(date -u +%F) by channel2mp3.sh"
  echo "- Audio: mono MP3, ${BITRATE}, cover art embedded (files in \`mp3/\`)"
  echo "- Cover images also stored separately in \`thumbs/\`"
  n="$(find "$MP3_DIR" -name '*.mp3' | wc -l)"
  echo "- Files: $n mp3(s), $(du -sh "$MP3_DIR" | cut -f1) total"
  echo
  i=0
  while IFS= read -r entry; do
    i=$((i + 1))
    id="$(jq -r '.id' <<<"$entry")"
    [[ -z "$id" || "$id" == "null" ]] && continue
    title="$(jq -r '(.title // .id) | gsub("\\\\n"; " ")' <<<"$entry")"
    url="$(jq -r '.webpage_url // ("https://www.youtube.com/watch?v=" + .id)' <<<"$entry")"
    upload="$(jq -r '.upload_date // ""' <<<"$entry")"
    dur="$(jq -r '.duration_string // ""' <<<"$entry")"

    n="$(name_for "$id" "$title")"   # mp3 basename (slug-based)
    # the file may sit under any earlier naming scheme; prefer the current one
    file_name=""
    for cand in "$n.mp3" "$id.mp3"; do
      [[ -s "$MP3_DIR/$cand" ]] && { file_name="$cand"; break; }
    done

    cover=""
    for ext in jpg jpeg png webp; do
      [[ -f "$THUMB_DIR/$id.$ext" ]] && { cover="$id.$ext"; break; }
    done

    # link text: escape markdown-breaking characters
    title_esc="$(printf '%s' "$title" | sed -e 's/\\/\\\\/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g' -e 's/|/\\|/g')"

    echo "## $i. $title"
    echo
    [[ -n "$upload" ]] && echo "- Uploaded: ${upload:0:4}-${upload:4:2}-${upload:6:2}"
    [[ -n "$dur" ]] && echo "- Duration: $dur"
    echo "- File: \`mp3/${file_name:-$n.mp3}\`"
    if [[ -z "$file_name" ]]; then
      echo "- :warning: mp3 missing (download or conversion failed; re-run the script)"
    fi
    echo "- URL: <$url>"
    if [[ -n "$cover" ]]; then
      echo "- Cover:"
      echo
      echo "  <img src=\"thumbs/$cover\" width=\"240\">"
    fi
    echo
  done < "$entries_file"
} > "$LOG_FILE"
rm -f "$entries_file"

echo
echo "Done: $LOG_FILE"
echo
find "$MP3_DIR" -name '*.mp3' | wc -l | xargs echo "mp3 files:"
du -sh "$MP3_DIR" | cut -f1 | xargs echo "total size:"
du -sh "$THUMB_DIR" | cut -f1 | xargs echo "covers:"
