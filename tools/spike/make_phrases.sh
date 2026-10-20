#!/bin/bash
# Makes the spike's test audio on the Mac: the phrases in Spike/Phrases/phrases.json spoken by macOS `say` voices, 16 kHz mono
# 16-bit WAV, written to Spike/Audio (gitignored: audio is never committed). Usage: tools/spike/make_phrases.sh [voice ...]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$root/Spike/Audio"
mkdir -p "$out"
voices=("$@")
[ ${#voices[@]} -gt 0 ] || voices=(Samantha Daniel Karen)
for voice in "${voices[@]}"; do
  python3 - "$root/Spike/Phrases/phrases.json" <<'PY' | while IFS=$'\t' read -r id text; do
import json, sys
data = json.load(open(sys.argv[1]))
for p in data["phrases"] + [data["long"]]:
    print(p["id"] + "\t" + p["text"])
PY
    # the long passage is only spoken by the first voice
    if [ "$id" = long ] && [ "$voice" != "${voices[0]}" ]; then continue; fi
    say -v "$voice" -o "$out/$voice-$id.wav" --file-format=WAVE --data-format=LEI16@16000 "$text"
  done
done
find "$out" -name "*.wav" | wc -l | xargs echo "clips written to $out:"
