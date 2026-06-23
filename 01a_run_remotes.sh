#!/usr/bin/env bash
# WAVE 1: launch the 6 REMOTE nodes only. Apollo's GPU is left alone so the
# in-progress benchmark is not disturbed. Run Apollo's own chunk afterwards
# with 01b_run_apollo.sh once its GPU is free.
set -uo pipefail

OUTPUT_DIR="${1:-$HOME/enamine_outputs}"
N_CONFORMERS=1
MIN_PH=6.4
MAX_PH=8.4
mkdir -p "$OUTPUT_DIR/logs"

PREP_FLAGS="--skip-conformers --skip-tautomers --no-canon-tautomer \
--max-unspecified-stereo 1 --min-ph $MIN_PH --max-ph $MAX_PH \
--pains-backend cpu --save-intermediates"

declare -A SERVER_CHUNK=(
  ["leviathan.bch.ed.ac.uk"]="chunk_02"
  ["executor.bch.ed.ac.uk"]="chunk_03"
  ["behemoth.bch.ed.ac.uk"]="chunk_04"
  ["atlas.bch.ed.ac.uk"]="chunk_05"
  ["colossus.bch.ed.ac.uk"]="chunk_06"
  ["cerberus.bch.ed.ac.uk"]="chunk_07"
)
declare -A SERVER_CHUNKSIZE=(
  ["leviathan.bch.ed.ac.uk"]="100000"
  ["executor.bch.ed.ac.uk"]="100000"
  ["behemoth.bch.ed.ac.uk"]="100000"
  ["atlas.bch.ed.ac.uk"]="100000"
  ["colossus.bch.ed.ac.uk"]="200000"
  ["cerberus.bch.ed.ac.uk"]="100000"
)
# Colossus CUDA workaround goes here. If left as-is and Colossus's nvMolKit
# import fails, that node exits loudly (exit 3) and chunk_06 simply won't
# appear — you then rerun chunk_06 on Apollo via 01b in wave 2.
declare -A SERVER_SETUP=(
  ["colossus.bch.ed.ac.uk"]=": # TODO Colossus nvMolKit CUDA workaround"
)

echo "WAVE 1: 6 remote nodes (Apollo GPU left untouched)"

for SERVER in "${!SERVER_CHUNK[@]}"; do
  CHUNK="${SERVER_CHUNK[$SERVER]}"
  CSIZE="${SERVER_CHUNKSIZE[$SERVER]}"
  SETUP="${SERVER_SETUP[$SERVER]:-}"
  LOG="$OUTPUT_DIR/logs/${CHUNK}.log"
  echo "[$SERVER] starting $CHUNK (chunk-size=$CSIZE, log: $LOG)"

  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SERVER" bash > "$LOG" 2>&1 <<REMOTE &
    set -uo pipefail
    echo "=== START | \$(hostname) | \$(date) | $CHUNK ==="
    source \$HOME/miniconda3/etc/profile.d/conda.sh; conda activate chem
    $SETUP
    python -c "from nvmolkit.embedMolecules import EmbedMolecules" \
      || { echo "[FATAL] nvMolKit import failed on \$(hostname)"; exit 3; }
    nvidia-smi --query-gpu=name --format=csv,noheader
    mkdir -p \$HOME/enamine_outputs
    START=\$(date +%s)
    python \$HOME/library_pipeline.py --input \$HOME/${CHUNK}.smi \
        --output \$HOME/enamine_outputs/${CHUNK}.sdf $PREP_FLAGS \
      || { echo "[FATAL] prep failed ($CHUNK)"; exit 4; }
    python \$HOME/run_conformers_chunked.py --input \$HOME/enamine_outputs/${CHUNK}_final.smi \
        --output \$HOME/enamine_outputs/${CHUNK}.sdf --n-conformers $N_CONFORMERS --chunk-size $CSIZE \
      || { echo "[FATAL] conformers failed ($CHUNK)"; exit 5; }
    END=\$(date +%s)
    echo "=== DONE | \$(hostname) | \$((END-START))s ==="
REMOTE
done

wait

echo ""
echo "WAVE 1 summary:"
for f in "$OUTPUT_DIR"/logs/chunk_0[2-7].log; do
  [ -e "$f" ] || continue
  stem=$(basename "$f" .log)
  if grep -q "=== DONE" "$f"; then
    secs=$(grep "=== DONE" "$f" | grep -oP '\d+(?=s ===)')
    echo "  [OK]   $stem — ${secs}s"
  else
    echo "  [FAIL] $stem — tail:"; tail -8 "$f" | sed 's/^/         /'
  fi
done
echo "Run 01b_run_apollo.sh once Apollo's GPU is free."