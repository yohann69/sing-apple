#!/bin/zsh
# Converts HTDemucs to Core ML and installs it where the Mac app looks for it.
set -euo pipefail
WORK="${SING_ML_DIR:-$HOME/Developer/sing-ml}"
mkdir -p "$WORK"
cp "$(dirname "$0")/convert_htdemucs.py" "$WORK/"
cd "$WORK"
[ -d .venv ] || uv venv --python 3.12 .venv
uv pip install --python .venv "torch==2.7.*" "torchaudio==2.7.*" demucs coremltools numpy soundfile
.venv/bin/python convert_htdemucs.py htdemucs
DEST="$HOME/Library/Application Support/Sing/Models"
mkdir -p "$DEST"
xcrun coremlcompiler compile htdemucs.mlpackage "$DEST/"
echo "Installed $DEST/htdemucs.mlmodelc"
