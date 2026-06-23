# Library Prep — Cluster Scatter-Gather

GPU-accelerated 3D library preparation across a Beowulf cluster (Apollo head
node + remote workers, no shared filesystem).

- `library_pipeline.py` — per-chunk prep: merge, salt-strip, filter
  (Lipinski/BRENK/PAINS), stereo, dedup, protonation (Dimorphite), conformers.
- `run_conformers_chunked.py` — memory-bounded GPU conformer generation.
- `sdf2smi.py` — supplier SDF → SMILES, preserving catalog IDs.
- `00_prepare_and_distribute.sh` — convert, combine, weighted-split, scp to nodes.
- `01a_run_remotes.sh` / `01b_run_apollo.sh` — distributed prep + conformers.
- `resume_ionise.py` + `03*_resume*.sh` — re-ionise from banked intermediates.
- `02_gather_merge_pdbqt.sh` — gather, byte-stream merge.
