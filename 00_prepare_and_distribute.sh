set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <input1> [input2 ...]   (.sdf / .smi / .cxsmiles / .txt)"
  exit 1
fi
INPUTS=("$@")

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

# 1. Normalise every input to a SMILES file (SMILES in column 1, ID in column 2)
SMI_FILES=()
for f in "${INPUTS[@]}"; do
  [ -f "$f" ] || { echo "[FATAL] no such file: $f"; exit 1; }
  base=$(basename "$f"); out="${base%.*}.smi"
  case "$f" in
    *.sdf|*.SDF)
      echo "[convert] $f -> $out"
      python sdf2smi.py "$f" "$out" || { echo "[FATAL] sdf2smi failed on $f"; exit 1; } ;;
    *.smi|*.cxsmiles|*.txt|*.ism)
      echo "[use] $f -> $out (assumed SMILES in column 1)"
      [ "$f" != "$out" ] && cp "$f" "$out" ;;
    *)
      echo "[FATAL] unrecognised input type: $f (expected .sdf/.smi/.cxsmiles/.txt)"; exit 1 ;;
  esac
  SMI_FILES+=("$out")
done

# 2. Combine all inputs
cat "${SMI_FILES[@]}" > all_input.smi
N=$(wc -l < all_input.smi); echo "[combine] total molecules: $N"
[ "$N" -lt 6 ] && { echo "[FATAL] too few molecules to split across 6 nodes"; exit 1; }

# 3. Even 6-way split (prep is CPU-bound, so card speed doesn't affect balance)
PER=$(( (N + 5) / 6 ))
awk -v n="$PER" -v d="$CHUNK_DIR" \
  '{ f=sprintf("%s/chunk_%02d.smi", d, int((NR-1)/n)+1); print > f }' all_input.smi
wc -l "$CHUNK_DIR"/chunk_*.smi

# 4. Distribute scripts + chunk to each remote (chunk_01 stays on Apollo)
for SERVER in "${!SERVER_CHUNK[@]}"; do
  CHUNK="${SERVER_CHUNK[$SERVER]}"
  echo "[scp] $SERVER <- ${SCRIPTS[*]} + ${CHUNK}.smi"
  scp -o StrictHostKeyChecking=accept-new "${SCRIPTS[@]}" "$SERVER:~/" || { echo "[FATAL] scp scripts -> $SERVER"; exit 2; }
  scp "$CHUNK_DIR/${CHUNK}.smi" "$SERVER:~/${CHUNK}.smi"               || { echo "[FATAL] scp chunk -> $SERVER"; exit 2; }
  ssh "$SERVER" "mkdir -p ~/enamine_outputs"
done
echo "[done] stage 0 complete. Next: ./01_run_distributed.sh"