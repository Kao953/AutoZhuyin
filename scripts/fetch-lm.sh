#!/bin/bash
# Downloads the CKIP gpt2-tiny-chinese language model (GPL-3.0,
# https://huggingface.co/ckiplab/gpt2-tiny-chinese) and converts it to build/lm/:
#   lm.bin     float16 weights (custom format, see training/lm/export_lm.py)
#   lm-vocab.txt
# build.sh bundles them into the app when present ("AI 選字"). Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=build/models/ckip-gpt2-tiny
BASE="https://huggingface.co/ckiplab/gpt2-tiny-chinese/resolve/refs%2Fpr%2F1"
mkdir -p "$SRC" build/lm
for f in model.safetensors vocab.txt config.json; do
    [ -s "$SRC/$f" ] || curl -sfL -o "$SRC/$f" "$BASE/$f"
done
python3 -I training/lm/export_lm.py "$SRC" build/lm/lm.bin
cp "$SRC/vocab.txt" build/lm/lm-vocab.txt
ls -lh build/lm
