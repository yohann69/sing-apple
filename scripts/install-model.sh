#!/bin/zsh
# Converts the on-device models (Demucs separation, CREPE pitch, ECAPA voices) to Core ML and installs them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${SING_ML_DIR:-$HOME/Developer/sing-ml}"
mkdir -p "$WORK"
cp "$HERE"/convert_*.py "$WORK/"
cd "$WORK"
[ -d .venv ] || uv venv --python 3.12 .venv
uv pip install --python .venv "torch==2.7.*" "torchaudio==2.7.*" demucs coremltools numpy soundfile torchcrepe speechbrain
.venv/bin/python convert_htdemucs.py htdemucs
.venv/bin/python convert_crepe.py full
.venv/bin/python convert_ecapa.py
DEST="$HOME/Library/Application Support/Sing/Models"
mkdir -p "$DEST"
for m in htdemucs crepe_full ecapa; do xcrun coremlcompiler compile "$m.mlpackage" "$DEST/"; done
echo "Installed models in $DEST"
