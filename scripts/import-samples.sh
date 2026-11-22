#!/bin/zsh
# Sets up the git-ignored sample library used by the tests and by SING_SAMPLES.
# Usage: scripts/import-samples.sh [folder with your MP3, FLAC or WAV files]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/../SongDataExample"
SRC="${1:-}"
mkdir -p "$DEST"
if [[ -n "$SRC" ]]; then
  find "$SRC" -type f \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.wav' -o -iname '*.m4a' -o -iname '*.aiff' \) -exec cp -n {} "$DEST/" \;
fi
count=$(find "$DEST" -type f | wc -l | tr -d ' ')
echo "$count files in $DEST"
echo "Run the Mac app with SING_SAMPLES=\"$DEST\" to import them on first launch, or drop the folder on the Library."
