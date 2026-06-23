import sys
from rdkit import Chem

ID_PROPS = ["idnumber", "ID", "Catalog ID", "Catalog_ID", "id", "ID_NUMBER"]
inp, outp = sys.argv[1], sys.argv[2]
supp = Chem.SDMolSupplier(inp)
n_ok = n_fail = 0
id_source = None
with open(outp, "w") as out:
    for m in supp:
        if m is None:
            n_fail += 1
            continue
        idn = None
        for p in ID_PROPS:
            if m.HasProp(p):
                idn = m.GetProp(p)
                id_source = id_source or p
                break
        if idn is None:
            idn = m.GetProp("_Name") or f"mol{n_ok}"
            id_source = id_source or "_Name (title)"
        out.write(f"{Chem.MolToSmiles(m)}\t{idn}\n")
        n_ok += 1
print(f"wrote {n_ok:,} (failed {n_fail:,}); ID taken from: {id_source}")
