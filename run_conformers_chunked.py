"""
Standalone chunked GPU conformer runner.

Reads a final SMILES file (the output of library_pipeline.py up through
ionisation), and runs nvMolKit conformer generation in bounded-memory
chunks. Appends each chunk's SDF to a single combined output, then frees
the chunk's molecules before loading the next one.

Why this exists:
    `generate_conformers_nvmolkit` in library_pipeline.py loads ALL mols
    into RAM before calling EmbedMolecules. At ~2M mols (1M input post-
    expansion) this OOMs. Chunking caps memory at chunk_size mols.

Usage:
    python run_conformers_chunked.py \\
        --input scale_test_1m_final.smi \\
        --output scale_test_1m.sdf \\
        --chunk-size 200000 \\
        --n-conformers 10
"""
import argparse
import gc
import os
import sys
import time
from pathlib import Path

import pandas as pd
from rdkit import Chem, RDLogger
from rdkit.Chem import AllChem, SDWriter
from rdkit.Chem.rdDistGeom import ETKDGv3


def silence_rdkit_warnings():
    """Suppress UFFTYPER / hypervalent-S warnings flooding the log."""
    RDLogger.DisableLog("rdApp.warning")


def load_smiles_tsv(path):
    """Load the *_final.smi file written by library_pipeline.py.

    The file is tab-delimited with a pandas header (SMILES, ID, ...).
    """
    df = pd.read_csv(path, sep="\t")
    # Defensive: pipeline writes SMILES column first, then ID
    if "SMILES" not in df.columns or "ID" not in df.columns:
        raise ValueError(
            f"Expected columns 'SMILES' and 'ID' in {path}, got {list(df.columns)}"
        )
    return df


def process_chunk(df_chunk, writer, n_conformers, mmff_max_iters,
                  batch_size, batches_per_gpu, gpu_ids,
                  preprocessing_threads, chunk_idx, n_chunks):
    """Embed + MMFF-minimise one chunk, write conformers to writer.

    Returns (n_written, n_parse_fail, n_mmff_skipped, dt_seconds).
    """
    from nvmolkit.embedMolecules import EmbedMolecules
    from nvmolkit.mmffOptimization import MMFFOptimizeMoleculesConfs
    from nvmolkit.types import HardwareOptions

    t0 = time.time()
    print(f"\n  --- Chunk {chunk_idx + 1}/{n_chunks} "
          f"({len(df_chunk):,} input mols) ---")

    # 1. SMILES -> Mol with explicit Hs
    mols = []
    parse_fail = 0
    for _, row in df_chunk.iterrows():
        m = Chem.MolFromSmiles(row["SMILES"])
        if m is None:
            parse_fail += 1
            continue
        m = Chem.AddHs(m)
        m.SetProp("_Name", str(row["ID"]))
        mols.append(m)
    print(f"      Prepared {len(mols):,} mols ({parse_fail} parse failures)")

    if not mols:
        return 0, parse_fail, 0, time.time() - t0

    # 2. ETKDG params
    params = ETKDGv3()
    params.useRandomCoords = True

    # 3. Hardware config
    hw = HardwareOptions(
        preprocessingThreads=preprocessing_threads,
        batchSize=batch_size,
        batchesPerGpu=batches_per_gpu,
        gpuIds=gpu_ids if gpu_ids else [],
    )

    # 4. GPU embed
    t_embed = time.time()
    EmbedMolecules(mols, params, confsPerMolecule=n_conformers,
                   hardwareOptions=hw)
    print(f"      embed: {time.time() - t_embed:.1f}s")

    # 5. Partition by MMFF parametrisability (hypervalent S etc. fail)
    mmff_ok, mmff_bad = [], []
    for m in mols:
        if AllChem.MMFFGetMoleculeProperties(m, mmffVariant="MMFF94s") is None:
            mmff_bad.append(m)
        else:
            mmff_ok.append(m)

    # 6. GPU MMFF minimise
    t_mmff = time.time()
    energies = MMFFOptimizeMoleculesConfs(
        mmff_ok, maxIters=mmff_max_iters, hardwareOptions=hw
    )
    print(f"      mmff:  {time.time() - t_mmff:.1f}s "
          f"({len(mmff_bad)} skipped)")

    # 7. Write to the shared writer
    n_written = 0
    for m, mol_energies in zip(mmff_ok, energies):
        for cid in range(m.GetNumConformers()):
            if cid < len(mol_energies):
                m.SetProp("MMFF_Energy", f"{mol_energies[cid]:.3f}")
            m.SetProp("MMFF_Minimised", "True")
            writer.write(m, confId=cid)
            n_written += 1
    for m in mmff_bad:
        for cid in range(m.GetNumConformers()):
            m.SetProp("MMFF_Minimised", "False")
            writer.write(m, confId=cid)
            n_written += 1

    dt = time.time() - t0
    rate = n_written / dt if dt > 0 else 0
    print(f"      wrote {n_written:,} confs in {dt:.1f}s "
          f"({rate:.0f} confs/s)")

    # 8. Free everything before the next chunk
    del mols, mmff_ok, mmff_bad, energies
    gc.collect()

    return n_written, parse_fail, 0, dt


def main():
    p = argparse.ArgumentParser(
        description="Chunked GPU conformer generation (memory-bounded)",
    )
    p.add_argument("--input", required=True,
                   help="Tab-delimited SMILES file (e.g. *_final.smi from "
                        "library_pipeline.py)")
    p.add_argument("--output", required=True, help="Output SDF file")
    p.add_argument("--chunk-size", type=int, default=200_000,
                   help="Molecules per GPU chunk (default: 200000)")
    p.add_argument("--n-conformers", type=int, default=10,
                   help="Conformers per molecule (default: 10)")
    p.add_argument("--mmff-max-iters", type=int, default=200)
    p.add_argument("--batch-size", type=int, default=500)
    p.add_argument("--batches-per-gpu", type=int, default=4)
    p.add_argument("--gpu-ids", type=int, nargs="+", default=None)
    p.add_argument("--preprocessing-threads", type=int, default=8)
    p.add_argument("--silence-warnings", action="store_true", default=True,
                   help="Suppress UFFTYPER warnings (default: on)")
    args = p.parse_args()

    if args.silence_warnings:
        silence_rdkit_warnings()

    print("=" * 60)
    print("CHUNKED GPU CONFORMER GENERATION")
    print("=" * 60)
    print(f"Input:       {args.input}")
    print(f"Output:      {args.output}")
    print(f"Chunk size:  {args.chunk_size:,}")
    print(f"Confs/mol:   {args.n_conformers}")

    t_total = time.time()

    # Load the full SMILES table (just the strings — cheap)
    df = load_smiles_tsv(args.input)
    n_total = len(df)
    n_chunks = (n_total + args.chunk_size - 1) // args.chunk_size
    print(f"\nLoaded {n_total:,} mols -> {n_chunks} chunks")

    # Single shared writer; each chunk appends to it
    writer = SDWriter(args.output)
    total_written = 0
    total_parse_fail = 0

    try:
        for ci in range(n_chunks):
            start = ci * args.chunk_size
            end = min(start + args.chunk_size, n_total)
            chunk = df.iloc[start:end]

            n_written, n_pf, _, dt = process_chunk(
                chunk, writer,
                n_conformers=args.n_conformers,
                mmff_max_iters=args.mmff_max_iters,
                batch_size=args.batch_size,
                batches_per_gpu=args.batches_per_gpu,
                gpu_ids=args.gpu_ids,
                preprocessing_threads=args.preprocessing_threads,
                chunk_idx=ci, n_chunks=n_chunks,
            )
            total_written += n_written
            total_parse_fail += n_pf

            # Running average + ETA
            elapsed = time.time() - t_total
            done_mols = end
            rate = done_mols / elapsed if elapsed > 0 else 0
            remaining = n_total - done_mols
            eta = remaining / rate if rate > 0 else 0
            print(f"      cumulative: {total_written:,} confs, "
                  f"{elapsed:.0f}s elapsed, ETA {eta:.0f}s "
                  f"({eta/60:.1f}m)")
    finally:
        writer.close()

    total_time = time.time() - t_total
    rate = total_written / total_time if total_time > 0 else 0
    print("\n" + "=" * 60)
    print("DONE")
    print("=" * 60)
    print(f"Conformers written: {total_written:,}")
    print(f"Parse failures:     {total_parse_fail:,}")
    print(f"Total time:         {total_time:.0f}s "
          f"({total_time / 3600:.2f}h)")
    print(f"Throughput:         {rate:.1f} confs/s")
    print(f"Output:             {args.output}")


if __name__ == "__main__":
    main()