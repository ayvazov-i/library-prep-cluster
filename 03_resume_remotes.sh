#!/usr/bin/env bash
# RESUME wave (remotes): re-ionise each node from its banked intermediate_05 at
# single-state pH 7.4, then conformers. The five working 4090 nodes do both;
# Colossus does re-ionise ONLY (its GPU can't run nvMolKit), and its conformers
# are run on Apollo by 03b_resume_apollo.sh.
set -uo pipefail

OUTPUT_DIR="${1:-$HOME/enamine_outputs}"
PH=7.4
CSIZE=100000          # every working remote here is a 4090
mkdir -p "$OUTPUT_DIR/logs"

declare -A WORK_CHUNK=(
  ["leviathan.bch.ed.ac.uk"]="chunk_02"
  ["executor.bch.ed.ac.uk"]="chunk_03"
  ["behemoth.bch.ed.ac.uk"]="chunk_04"
  ["atlas.bch.ed.ac.uk"]="chunk_05"
  ["cerberus.bch.ed.ac.uk"]="chunk_07"
)

echo "RESUME: 5 working remotes (re-ionise + conformers) + Colossus (re-ionise only)"

for SERVER in "${!WORK_CHUNK[@]}"; do
  CHUNK="${WORK_CHUNK[$SERVER]}"
  LOG="$OUTPUT_DIR/logs/${CHUNK}_resume.log"
  echo "[$SERVER] $CHUNK re-ionise + conformers (log: $LOG)"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SERVER" bash > "$LOG" 2>&1 <<REMOTE &
    set -uo pipefail
    echo "=== START | \$(hostname) | \$(date) | $CHUNK resume ==="
    source \$HOME/miniconda3/etc/profile.d/conda.sh; conda activate chem
    test -f \$HOME/intermediate_05_deduplicated.csv || { echo "[FATAL] no intermediate_05 on \$(hostname)"; exit 2; }
    python -c "from nvmolkit.embedMolecules import EmbedMolecules" || { echo "[FATAL] nvMolKit import failed"; exit 3; }
    START=\$(date +%s)
    python \$HOME/resume_ionise.py \$HOME/intermediate_05_deduplicated.csv \
        \$HOME/enamine_outputs/${CHUNK}_final.smi $PH \
      || { echo "[FATAL] re-ionise failed ($CHUNK)"; exit 4; }
    python \$HOME/run_conformers_chunked.py --input \$HOME/enamine_outputs/${CHUNK}_final.smi \
        --output \$HOME/enamine_outputs/${CHUNK}.sdf --n-conformers 1 --chunk-size $CSIZE \
      || { echo "[FATAL] conformers failed ($CHUNK)"; exit 5; }
    END=\$(date +%s)
    echo "=== DONE | \$(hostname) | \$((END-START))s ==="
REMOTE
done

# Colossus: re-ionise only (CPU). chunk_06 conformers happen on Apollo.
COL="colossus.bch.ed.ac.uk"
CLOG="$OUTPUT_DIR/logs/chunk_06_resume.log"
echo "[$COL] chunk_06 re-ionise ONLY (conformers -> Apollo) (log: $CLOG)"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$COL" bash > "$CLOG" 2>&1 <<'REMOTE' &
  set -uo pipefail
  echo "=== START | $(hostname) | $(date) | chunk_06 re-ionise only ==="
  source $HOME/miniconda3/etc/profile.d/conda.sh; conda activate chem
  test -f $HOME/intermediate_05_deduplicated.csv || { echo "[FATAL] no intermediate_05 on colossus"; exit 2; }
  START=$(date +%s)
  python $HOME/resume_ionise.py $HOME/intermediate_05_deduplicated.csv \
      $HOME/enamine_outputs/chunk_06_final.smi 7.4 \
    || { echo "[FATAL] re-ionise failed (chunk_06)"; exit 4; }
  END=$(date +%s)
  echo "=== DONE (reionise only) | $(hostname) | $((END-START))s ==="
REMOTE

wait

echo ""
echo "RESUME-remotes summary:"
for f in "$OUTPUT_DIR"/logs/chunk_0[2-7]_resume.log; do
  [ -e "$f" ] || continue
  stem=$(basename "$f" .log)
  if grep -q "=== DONE" "$f"; then echo "  [OK]   $stem"
  else echo "  [FAIL] $stem"; tail -6 "$f" | sed 's/^/         /'; fi
done
echo "Next: ./03b_resume_apollo.sh   (chunk_01 + chunk_06 on Apollo)"