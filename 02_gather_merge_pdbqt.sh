#!/usr/bin/env bash
# Stage 2: pull every node's chunk SDF back to Apollo, merge by byte-stream
# concatenation (NOT canonical dedup), then convert to PDBQT for UniDock-Pro.
set -uo pipefail

OUTPUT_DIR="${1:-$HOME/enamine_outputs}"
MERGED="$OUTPUT_DIR/screening_collection_3d.sdf"
PDBQT_DIR="$OUTPUT_DIR/pdbqt"
mkdir -p "$PDBQT_DIR"

declare -A SERVER_CHUNK=(
  ["leviathan.bch.ed.ac.uk"]="chunk_02"
  ["executor.bch.ed.ac.uk"]="chunk_03"
  ["behemoth.bch.ed.ac.uk"]="chunk_04"
  ["atlas.bch.ed.ac.uk"]="chunk_05"
  ["colossus.bch.ed.ac.uk"]="chunk_06"
  ["cerberus.bch.ed.ac.uk"]="chunk_07"
)

# ── 1. Gather remote outputs (chunk_01 is already local on Apollo) ───────────
for SERVER in "${!SERVER_CHUNK[@]}"; do
  CHUNK="${SERVER_CHUNK[$SERVER]}"
  echo "[gather] $SERVER:~/enamine_outputs/${CHUNK}.sdf"
  scp "$SERVER:~/enamine_outputs/${CHUNK}.sdf" "$OUTPUT_DIR/" \
    || echo "[WARN] could not fetch ${CHUNK}.sdf from $SERVER"
done

# ── 2. Byte-stream merge ─────────────────────────────────────────────────────
#     SDF records are delimited by $$$$; plain cat preserves every conformer.
#     Do NOT canonical-SMILES dedup here — that discards records.
echo "[merge] concatenating chunk SDFs -> $MERGED"
shopt -s nullglob
SDFS=("$OUTPUT_DIR"/chunk_0[1-7].sdf)
if [ ${#SDFS[@]} -eq 0 ]; then echo "[FATAL] no chunk SDFs to merge"; exit 1; fi
cat "${SDFS[@]}" > "$MERGED"
N_REC=$(grep -c '^\$\$\$\$' "$MERGED" || true)
echo "[merge] merged ${#SDFS[@]} files, $N_REC records -> $MERGED"

# ── 3. PDBQT for UniDock-Pro ─────────────────────────────────────────────────
#     UniDock-Pro needs PDBQT (SDF input silently falls back to rigid docking).
#     sdf_to_pdbqt.py is NOT in the project and Meeko's API is version-sensitive,
#     so confirm its flags before trusting this call at full scale.
if [ -f "$HOME/sdf_to_pdbqt.py" ]; then
  echo "[pdbqt] running ~/sdf_to_pdbqt.py  (CONFIRM these flags match your script)"
  python "$HOME/sdf_to_pdbqt.py" --input "$MERGED" --output "$PDBQT_DIR" \
    || echo "[WARN] sdf_to_pdbqt.py failed — check its actual interface / Meeko version"
else
  echo "[pdbqt] ~/sdf_to_pdbqt.py not found. Convert manually, e.g.:"
  echo "        python sdf_to_pdbqt.py --input $MERGED --output $PDBQT_DIR"
  echo "        (This step is heavy at ~5M ligands — consider distributing it the"
  echo "         same way as stage 1, and confirm with Boyang how UniDock expects"
  echo "         the PDBQT laid out: one dir, sharded subdirs, or a batch list.)"
fi
echo "[done] stage 2 complete"