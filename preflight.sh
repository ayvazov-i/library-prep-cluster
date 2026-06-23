set -uo pipefail

NODES=(apollo leviathan.bch.ed.ac.uk executor.bch.ed.ac.uk \
       behemoth.bch.ed.ac.uk atlas.bch.ed.ac.uk cerberus.bch.ed.ac.uk)

CHECK='import sys
try:
    import rdkit, dimorphite_dl, pandas
    from nvmolkit.embedMolecules import EmbedMolecules   # GPU embed import
    print("OK", "rdkit", rdkit.__version__,
          "| dimorphite", getattr(dimorphite_dl,"__version__","?"))
except Exception as e:
    print("FAIL", type(e).__name__, str(e)[:120]); sys.exit(1)'

fail=0
for N in "${NODES[@]}"; do
  echo -n "$N: "
  if [ "$N" = apollo ]; then
    RES=$(source "$HOME/miniconda3/etc/profile.d/conda.sh"; conda activate chem 2>/dev/null; python -c "$CHECK" 2>&1)
  else
    RES=$(ssh -o BatchMode=yes "$N" "source ~/miniconda3/etc/profile.d/conda.sh; conda activate chem 2>/dev/null; python -c '$CHECK'" 2>&1)
  fi
  echo "$RES"
  echo "$RES" | grep -q '^OK' || fail=1
done

echo "---"
if [ "$fail" -eq 0 ]; then
  echo "All nodes OK. Confirm the rdkit/dimorphite versions above MATCH across nodes."
else
  echo "ONE OR MORE NODES FAILED — fix the env before running 00/01."
  exit 1
fi