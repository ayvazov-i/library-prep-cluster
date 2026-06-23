# Library Prep — Cluster Scatter-Gather

GPU-accelerated 3D library preparation across a Beowulf cluster (no shared
filesystem; data moved by `scp`). Takes raw supplier libraries (SDF or SMILES)
and produces one docking-ready 3D SDF: filtered, deduplicated, protonated to a
single state at pH 7.4, embedded to 3D (one conformer per molecule).

## Usage

Run on Apollo (head node), from the directory holding the scripts:

```bash
# 0. stage any library (SDF / SMILES / cxsmiles), split across the cluster
./00_prepare_and_distribute.sh lib1.sdf [lib2.smi ...]

# 1. run prep + 3D conformer generation on all 6 nodes in parallel
./01_run_distributed.sh

# 2. gather the node outputs and merge into the final library
./02_gather_merge.sh
```

Output: `~/enamine_outputs/screening_collection_3d.sdf`

After stage 1, check each `~/enamine_outputs/chunk_NN.sdf` has a non-zero
conformer count before merging:
```bash
grep -c '^\$\$\$\$' ~/enamine_outputs/chunk_*.sdf
```

## Notes

- Cluster: Apollo (RTX 5090, runs chunk_01) + 5 remote RTX 4090 workers. Colossus
  is excluded (nvMolKit/CUDA driver incompatibility).
- Protonation is single-state pH 7.4 by default.
- Conda env `chem` must exist on every node (no shared filesystem).
