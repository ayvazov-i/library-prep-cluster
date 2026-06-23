set -uo pipefail

OUTPUT_DIR="${1:-$HOME/enamine_outputs}"
CHUNK_DIR="$HOME/enamine_chunks"
N_CONFORMERS=1
mkdir -p "$OUTPUT_DIR/logs"

PREP_FLAGS="--skip-conformers --skip-tautomers --no-canon-tautomer \
--max-unspecified-stereo 1 --min-ph 7.4 --max-ph 7.4 --pains-backend cpu --save-intermediates"


declare -A SERVER_CHUNK=(
  ["leviathan.bch.ed.ac.uk"]="chunk_02"
  ["executor.bch.ed.ac.uk"]="chunk_03"
  ["behemoth.bch.ed.ac.uk"]="chunk_04"
  ["atlas.bch.ed.ac.uk"]="chunk_05"
  ["cerberus.bch.ed.ac.uk"]="chunk_06"
)
REMOTE_CSIZE=100000
APOLLO_CSIZE=200000   

echo "Distributed prep+conformers | 6 nodes | single-state pH 7.4 | 1 conf/mol"

# --- Apollo (local, chunk_01) ---
(
  LOG="$OUTPUT_DIR/logs/chunk_01.log"
  echo "[apollo] chunk_01 (log: $LOG)"
  {
    echo "=== START | apollo | $(date) ==="
    source "$HOME/miniconda3/etc/profile.d/conda.sh"; conda activate chem
    python -c "from nvmolkit.embedMolecules import EmbedMolecules" || { echo "[FATAL] nvMolKit import failed"; exit 3; }
    python ~/library_pipeline.py --input "$CHUNK_DIR/chunk_01.smi" --output "$OUTPUT_DIR/chunk_01.sdf" $PREP_FLAGS || { echo "[FATAL] prep"; exit 4; }
    python ~/run_conformers_chunked.py --input "$OUTPUT_DIR/chunk_01_final.smi" --output "$OUTPUT_DIR/chunk_01.sdf" --n-conformers $N_CONFORMERS --chunk-size $APOLLO_CSIZE || { echo "[FATAL] conformers"; exit 5; }
    echo "=== DONE | apollo ==="
  } > "$LOG" 2>&1
) &

# --- Remotes ---
for SERVER in "${!SERVER_CHUNK[@]}"; do
  CHUNK="${SERVER_CHUNK[$SERVER]}"
  LOG="$OUTPUT_DIR/logs/${CHUNK}.log"
  echo "[$SERVER] $CHUNK (log: $LOG)"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SERVER" bash > "$LOG" 2>&1 <<REMOTE &
    set -uo pipefail
    echo "=== START | \$(hostname) | \$(date) | $CHUNK ==="
    source \$HOME/miniconda3/etc/profile.d/conda.sh; conda activate chem
    python -c "from nvmolkit.embedMolecules import EmbedMolecules" || { echo "[FATAL] nvMolKit import failed"; exit 3; }
    python \$HOME/library_pipeline.py --input \$HOME/${CHUNK}.smi --output \$HOME/enamine_outputs/${CHUNK}.sdf $PREP_FLAGS || { echo "[FATAL] prep"; exit 4; }
    python \$HOME/run_conformers_chunked.py --input \$HOME/enamine_outputs/${CHUNK}_final.smi --output \$HOME/enamine_outputs/${CHUNK}.sdf --n-conformers $N_CONFORMERS --chunk-size $REMOTE_CSIZE || { echo "[FATAL] conformers"; exit 5; }
    echo "=== DONE | \$(hostname) ==="
REMOTE
done

wait

echo ""
echo "Summary:"
for f in "$OUTPUT_DIR"/logs/chunk_0[1-6].log; do
  [ -e "$f" ] || continue
  stem=$(basename "$f" .log)
  if grep -q "=== DONE" "$f"; then echo "  [OK]   $stem"
  else echo "  [FAIL] $stem"; tail -6 "$f" | sed 's/^/         /'; fi
done
echo "Verify each chunk_NN.sdf conformer count is non-zero, then ./02_gather_merge.sh"