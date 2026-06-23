#!/usr/bin/env bash
# WAVE 2: run ONE chunk on Apollo locally. Use after the benchmark frees
# Apollo's GPU. Defaults to chunk_01; pass another chunk name to rerun it here
# (e.g. chunk_06 if Colossus failed in wave 1).
#   ./01b_run_apollo.sh                 -> chunk_01 (size 200000)
#   ./01b_run_apollo.sh chunk_06        -> chunk_06 (size 200000)
#   ./01b_run_apollo.sh chunk_07 100000 -> chunk_07 (size 100000)
set -uo pipefail

CHUNK="${1:-chunk_01}"
CSIZE="${2:-200000}"
OUTPUT_DIR="$HOME/enamine_outputs"
CHUNK_DIR="$HOME/enamine_chunks"
N_CONFORMERS=1
MIN_PH=6.4
MAX_PH=8.4
mkdir -p "$OUTPUT_DIR/logs"
LOG="$OUTPUT_DIR/logs/${CHUNK}.log"

PREP_FLAGS="--skip-conformers --skip-tautomers --no-canon-tautomer \
--max-unspecified-stereo 1 --min-ph $MIN_PH --max-ph $MAX_PH \
--pains-backend cpu --save-intermediates"

echo "[apollo] running $CHUNK (chunk-size=$CSIZE, log: $LOG)"
# Safety check: refuse to start if the GPU is still busy.
if nvidia-smi --query-compute-apps=pid --format=csv,noheader | grep -q .; then
  echo "[ABORT] Apollo GPU still has a running process. Wait for the benchmark to finish."
  nvidia-smi --query-compute-apps=pid,used_memory,process_name --format=csv
  exit 1
fi

{
  echo "=== START | apollo (local) | $(date) | $CHUNK ==="
  source "$HOME/miniconda3/etc/profile.d/conda.sh"; conda activate chem
  python -c "from nvmolkit.embedMolecules import EmbedMolecules" \
    || { echo "[FATAL] nvMolKit import failed on apollo"; exit 3; }
  nvidia-smi --query-gpu=name --format=csv,noheader
  START=$(date +%s)
  python ~/library_pipeline.py --input "$CHUNK_DIR/${CHUNK}.smi" \
      --output "$OUTPUT_DIR/${CHUNK}.sdf" $PREP_FLAGS \
    || { echo "[FATAL] prep failed ($CHUNK)"; exit 4; }
  python ~/run_conformers_chunked.py --input "$OUTPUT_DIR/${CHUNK}_final.smi" \
      --output "$OUTPUT_DIR/${CHUNK}.sdf" --n-conformers $N_CONFORMERS --chunk-size $CSIZE \
    || { echo "[FATAL] conformers failed ($CHUNK)"; exit 5; }
  END=$(date +%s)
  echo "=== DONE | apollo | $((END-START))s ==="
} 2>&1 | tee "$LOG"