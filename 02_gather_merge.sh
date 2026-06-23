
set -uo pipefail

OUTPUT_DIR="${1:-$HOME/enamine_outputs}"
MERGED="$OUTPUT_DIR/screening_collection_3d.sdf"

declare -A SERVER_CHUNK=(
  ["leviathan.bch.ed.ac.uk"]="chunk_02"
  ["executor.bch.ed.ac.uk"]="chunk_03"
  ["behemoth.bch.ed.ac.uk"]="chunk_04"
  ["atlas.bch.ed.ac.uk"]="chunk_05"
  ["cerberus.bch.ed.ac.uk"]="chunk_06"
)

for SERVER in "${!SERVER_CHUNK[@]}"; do
  CHUNK="${SERVER_CHUNK[$SERVER]}"
  echo "[gather] $SERVER:~/enamine_outputs/${CHUNK}.sdf"
  scp "$SERVER:~/enamine_outputs/${CHUNK}.sdf" "$OUTPUT_DIR/" || echo "[WARN] could not fetch ${CHUNK}.sdf from $SERVER"
done

shopt -s nullglob
SDFS=("$OUTPUT_DIR"/chunk_0[1-6].sdf)
[ ${#SDFS[@]} -eq 0 ] && { echo "[FATAL] no chunk SDFs to merge"; exit 1; }
cat "${SDFS[@]}" > "$MERGED"
echo "[merge] merged ${#SDFS[@]} files, $(grep -c '^\$\$\$\$' "$MERGED") records -> $MERGED"