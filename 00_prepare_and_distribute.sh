#!/usr/bin/env bash
# Stage 0: convert the remaining collections to SMILES, combine all five,
# weighted-split into 7 chunks, and distribute the PATCHED pipeline + chunks
# to every node. Run on Apollo AFTER the dimorphite patch is applied locally.
set -uo pipefail

WORK="$HOME"                       # where the zips / sdfs / *.smi live
CHUNK_DIR="$HOME/enamine_chunks"
SCRIPTS=(library_pipeline.py run_conformers_chunked.py sdf2smi.py)
mkdir -p "$CHUNK_DIR"

cd "$WORK"
source "$HOME/miniconda3/etc/profile.d/conda.sh"
conda activate chem

# host -> input chunk (chunk_01 stays local for Apollo). Cerberus (4090) gets the
# smaller chunk_07; the six 5090s (Apollo + 5 remotes) get equal chunks 01-06.
declare -A SERVER_CHUNK=(
  ["leviathan.bch.ed.ac.uk"]="chunk_02"
  ["executor.bch.ed.ac.uk"]="chunk_03"
  ["behemoth.bch.ed.ac.uk"]="chunk_04"
  ["atlas.bch.ed.ac.uk"]="chunk_05"
  ["colossus.bch.ed.ac.uk"]="chunk_06"
  ["cerberus.bch.ed.ac.uk"]="chunk_07"
)

# ── 1. Convert the three not-yet-converted collections ───────────────────────
#     (functional.smi and hts.smi already exist from your pilots)
for NAME in premium advanced legacy; do
  if [ -f "${NAME}.smi" ]; then
    echo "[convert] ${NAME}.smi already present, skipping"
    continue
  fi
  ZIP=$(ls Enamine_${NAME}_collection_sdf_*.zip 2>/dev/null | head -1)
  [ -n "$ZIP" ] && unzip -o "$ZIP"
  SDF=$(ls Enamine_${NAME}_collection_*.sdf 2>/dev/null | head -1)
  if [ -z "$SDF" ]; then echo "[FATAL] no SDF found for $NAME"; exit 1; fi
  echo "[convert] $SDF -> ${NAME}.smi"
  python sdf2smi.py "$SDF" "${NAME}.smi"
done

# ── 2. Concatenate all five collections ──────────────────────────────────────
#     Plain cat is correct for SMILES *inputs*. (The byte-stream-not-canonical
#     rule applies only to merging multi-record SDF *outputs*, in stage 2.)
for f in functional hts premium advanced legacy; do
  [ -f "${f}.smi" ] || { echo "[FATAL] missing ${f}.smi"; exit 1; }
done
echo "[combine] building all_screening.smi"
cat functional.smi hts.smi premium.smi advanced.smi legacy.smi > all_screening.smi
N=$(wc -l < all_screening.smi)
echo "[combine] total molecules: $N"

# ── 3. Weighted split: 6 equal 5090 chunks + 1 smaller Cerberus chunk ────────
#     5090:4090 throughput ~ 1 : 0.55  ->  6*1 + 0.55 = 6.55 weight units.
PER=$(awk "BEGIN{printf \"%d\", $N/6.55}")
echo "[split] $PER lines per 5090 chunk; remainder (~0.55x) -> Cerberus chunk_07"
awk -v n="$PER" -v d="$CHUNK_DIR" '
  NR <= 6*n { f=sprintf("%s/chunk_%02d.smi", d, int((NR-1)/n)+1); print > f; next }
  { print > (d "/chunk_07.smi") }
' all_screening.smi
wc -l "$CHUNK_DIR"/chunk_*.smi

# ── 4. Distribute patched scripts + each node's chunk ────────────────────────
for SERVER in "${!SERVER_CHUNK[@]}"; do
  CHUNK="${SERVER_CHUNK[$SERVER]}"
  echo "[scp] $SERVER <- ${SCRIPTS[*]} + ${CHUNK}.smi"
  scp -o StrictHostKeyChecking=accept-new "${SCRIPTS[@]}" "$SERVER:~/" || { echo "[FATAL] scp scripts -> $SERVER"; exit 2; }
  scp "$CHUNK_DIR/${CHUNK}.smi" "$SERVER:~/${CHUNK}.smi"               || { echo "[FATAL] scp chunk -> $SERVER";   exit 2; }
  ssh "$SERVER" "mkdir -p ~/enamine_outputs"
done
echo "[local] chunk_01 stays in $CHUNK_DIR for Apollo"

# ── 5. Preflight: confirm the chem env is sane on every node ──────────────────
#     Catches version drift / missing deps BEFORE the long run. The patched
#     pipeline handles dimorphite 1.x and 2.x, but not its absence.
echo "[preflight] env check (rdkit | nvmolkit | dimorphite versions)"
python -c "import rdkit,nvmolkit,dimorphite_dl as d; print('apollo', rdkit.__version__, getattr(d,'__version__','?'))" \
  || echo "[WARN] apollo env check failed"
for SERVER in "${!SERVER_CHUNK[@]}"; do
  ssh "$SERVER" 'source ~/miniconda3/etc/profile.d/conda.sh; conda activate chem; \
    python -c "import rdkit,nvmolkit,dimorphite_dl as d; print(\"'"$SERVER"'\", rdkit.__version__, getattr(d,\"__version__\",\"?\"))"' \
    || echo "[WARN] env check failed on $SERVER (nvmolkit import on Colossus may need its CUDA workaround)"
done
echo "[done] stage 0 complete — run 01_run_distributed.sh next"