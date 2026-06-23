#!/usr/bin/env bash
# RESUME wave (Apollo): chunk_01 re-ionise + conformers, then chunk_06 conformers
# (Colossus already re-ionised chunk_06; only its GPU stage needs a working card).
# Run after 03_resume_remotes.sh and once Apollo's GPU is free.
set -uo pipefail

OUTPUT_DIR="$HOME/enamine_outputs"
PH=7.4
mkdir -p "$OUTPUT_DIR/logs"
LOG="$OUTPUT_DIR/logs/apollo_resume.log"

# Apollo is a 5090 -> chunk-size 200000
if nvidia-smi --query-compute-apps=pid --format=csv,noheader | grep -q .; then
  echo "[ABORT] Apollo GPU still busy. Wait for the current job to exit."
  nvidia-smi --query-compute-apps=pid,used_memory,process_name --format=csv
  exit 1
fi

{
  echo "=== START | apollo resume | $(date) ==="
  source "$HOME/miniconda3/etc/profile.d/conda.sh"; conda activate chem
  python -c "from nvmolkit.embedMolecules import EmbedMolecules" \
    || { echo "[FATAL] nvMolKit import failed on apollo"; exit 3; }

  # chunk_01: re-ionise + conformers
  test -f "$HOME/intermediate_05_deduplicated.csv" \
    || { echo "[FATAL] no intermediate_05 on apollo"; exit 2; }
  echo "--- chunk_01 re-ionise ---"
  python ~/resume_ionise.py ~/intermediate_05_deduplicated.csv \
      "$OUTPUT_DIR/chunk_01_final.smi" $PH || { echo "[FATAL] re-ionise chunk_01"; exit 4; }
  echo "--- chunk_01 conformers ---"
  python ~/run_conformers_chunked.py --input "$OUTPUT_DIR/chunk_01_final.smi" \
      --output "$OUTPUT_DIR/chunk_01.sdf" --n-conformers 1 --chunk-size 200000 \
    || { echo "[FATAL] conformers chunk_01"; exit 5; }

  # chunk_06: pull Colossus's re-ionised SMILES, run conformers here
  echo "--- fetching chunk_06_final.smi from Colossus ---"
  scp colossus.bch.ed.ac.uk:~/enamine_outputs/chunk_06_final.smi "$OUTPUT_DIR/" \
    || { echo "[FATAL] could not fetch chunk_06_final.smi"; exit 6; }
  echo "--- chunk_06 conformers ---"
  python ~/run_conformers_chunked.py --input "$OUTPUT_DIR/chunk_06_final.smi" \
      --output "$OUTPUT_DIR/chunk_06.sdf" --n-conformers 1 --chunk-size 200000 \
    || { echo "[FATAL] conformers chunk_06"; exit 7; }

  echo "=== DONE | apollo | chunk_01 + chunk_06 complete ==="
} 2>&1 | tee "$LOG"