set -uo pipefail

WORK="$HOME"
CHUNK_DIR="$HOME/enamine_chunks"
SCRIPTS=(library_pipeline.py run_conformers_chunked.py sdf2smi.py)
mkdir -p "$CHUNK_DIR"
cd "$WORK"
source "$HOME/miniconda3/etc/profile.d/conda.sh"; conda activate chem

declare -A SERVER_CHUNK=(
  ["leviathan.bch.ed.ac.uk"]="chunk_02"
  ["executor.bch.ed.ac.uk"]="chunk_03"
  ["behemoth.bch.ed.ac.uk"]="chunk_04"
  ["atlas.bch.ed.ac.uk"]="chunk_05"
  ["cerberus.bch.ed.ac.uk"]="chunk_06"
)

# 1. Convert each supplier collection to SMILES (edit this list for your inputs)
for NAME in functional hts premium advanced legacy; do
  if [ -f "${NAME}.smi" ]; then echo "[convert] ${NAME}.smi present, skipping"; continue; fi
  ZIP=$(ls Enamine_${NAME}_collection_sdf_*.zip 2>/dev/null | head -1)
  [ -n "$ZIP" ] && unzip -o "$ZIP"
  SDF=$(ls Enamine_${NAME}_collection_*.sdf 2>/dev/null | head -1)
  [ -z "$SDF" ] && { echo "[FATAL] no SDF found for $NAME"; exit 1; }
  echo "[convert] $SDF -> ${NAME}.smi"; python sdf2smi.py "$SDF" "${NAME}.smi"
done

# 2. Combine all collections
cat functional.smi hts.smi premium.smi advanced.smi legacy.smi > all_screening.smi
N=$(wc -l < all_screening.smi); echo "[combine] total molecules: $N"

# 3. Even 6-way split 
PER=$(( (N + 5) / 6 ))
awk -v n="$PER" -v d="$CHUNK_DIR" \
  '{ f=sprintf("%s/chunk_%02d.smi", d, int((NR-1)/n)+1); print > f }' all_screening.smi
wc -l "$CHUNK_DIR"/chunk_*.smi

# 4. Distribute scripts + chunk to each remote 
for SERVER in "${!SERVER_CHUNK[@]}"; do
  CHUNK="${SERVER_CHUNK[$SERVER]}"
  echo "[scp] $SERVER <- ${SCRIPTS[*]} + ${CHUNK}.smi"
  scp -o StrictHostKeyChecking=accept-new "${SCRIPTS[@]}" "$SERVER:~/" || { echo "[FATAL] scp scripts -> $SERVER"; exit 2; }
  scp "$CHUNK_DIR/${CHUNK}.smi" "$SERVER:~/${CHUNK}.smi"               || { echo "[FATAL] scp chunk -> $SERVER"; exit 2; }
  ssh "$SERVER" "mkdir -p ~/enamine_outputs"
done
echo "[done] stage 0 complete. Next: ./01_run_distributed.sh"