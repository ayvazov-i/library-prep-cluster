#!/usr/bin/env python3
"""Resume from intermediate_05_deduplicated.csv.

Re-ionise the already-filtered/stereo/deduplicated set at a SINGLE predominant
protonation state, then write <chunk>_final.smi ready for conformers. This skips
the expensive BRENK/Lipinski filtering and stereo steps, which are already banked
in the intermediate CSV.

Single-state behaviour comes from the patched dimorphite wrapper in
library_pipeline.py (precision=0.0 by default); passing min_ph == max_ph == 7.4
gives the one most-predominant state per compound, the Open Babel `-p 7.4`
equivalent.

Usage:
  python resume_ionise.py intermediate_05_deduplicated.csv chunk_NN_final.smi [pH]
"""
import sys
import pandas as pd
from rdkit import Chem
from library_pipeline import ionise_molecules

inp = sys.argv[1]
out_smi = sys.argv[2]
ph = float(sys.argv[3]) if len(sys.argv) > 3 else 7.4

df = pd.read_csv(inp)
print(f"Loaded {len(df):,} deduplicated molecules from {inp}")

# Single predominant state at this pH (patched wrapper -> precision=0.0)
df = ionise_molecules(df, min_ph=ph, max_ph=ph)

# Mirror the post-ionise re-dedup in library_pipeline.main()
before = len(df)
df["canonical"] = df["SMILES"].apply(
    lambda s: Chem.MolToSmiles(Chem.MolFromSmiles(s), isomericSmiles=True)
    if Chem.MolFromSmiles(s) is not None else None)
df = df.dropna(subset=["canonical"]).drop_duplicates(subset=["canonical"])
df["SMILES"] = df["canonical"]
df = df.drop(columns=["canonical"])
print(f"Re-dedup: {before:,} -> {len(df):,}")

df.to_csv(out_smi, sep="\t", index=False)
print(f"Wrote {len(df):,} molecules -> {out_smi}")