#!/usr/bin/env python3
"""Cek paritas fitur: MQL5 (DLFeatureEngine.mqh) vs Python (dlea/features.py).

Scripts/DL_ExportHistory.mq5 menulis dua file ke MQL5/Files:
  <SYMBOL>_<TF>.csv                 — OHLCV
  <SYMBOL>_<TF>_features_mql5.csv   — fitur yang dihitung EA untuk N bar terakhir

  python check_parity.py --csv XAUUSD_M15.csv --features XAUUSD_M15_features_mql5.csv

WAJIB lulus sebelum model dipakai: bila fitur berbeda, model menerima masukan
yang tidak pernah dilihatnya saat training dan sinyalnya tidak bermakna.
"""
from __future__ import annotations

import argparse
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dlea import data
from dlea.features import FEATURE_NAMES, compute_features


def compare(df: pd.DataFrame, mql: pd.DataFrame, tol: float = 1e-5) -> tuple[bool, pd.DataFrame]:
    py = pd.DataFrame(compute_features(df), columns=FEATURE_NAMES).assign(time=df["time"])
    merged = mql.merge(py, on="time", suffixes=("_mql", "_py"))
    if merged.empty:
        raise SystemExit("Tidak ada bar dengan waktu yang sama di kedua file.")
    rows = []
    for name in FEATURE_NAMES:
        d = (merged[f"{name}_mql"] - merged[f"{name}_py"]).abs()
        rows.append({"fitur": name, "selisih_maks": float(d.max()), "bar": int(d.notna().sum()),
                     "status": "OK" if d.max() <= tol else "BEDA"})
    table = pd.DataFrame(rows)
    return bool((table["status"] == "OK").all()), table


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--csv", required=True)
    p.add_argument("--features", required=True)
    p.add_argument("--tol", type=float, default=1e-5)
    args = p.parse_args(argv)

    df = data.load_csv(args.csv)
    mql = pd.read_csv(args.features)
    mql.columns = [c.strip().lower() for c in mql.columns]
    missing = [c for c in ["time"] + FEATURE_NAMES if c not in mql.columns]
    if missing:
        raise SystemExit(f"Kolom hilang di {args.features}: {missing} (versi fitur berbeda?)")
    mql["time"] = pd.to_datetime(mql["time"].astype(str), format="%Y.%m.%d %H:%M")

    ok, table = compare(df, mql, args.tol)
    print(table.to_string(index=False))
    print("\nPARITAS OK — fitur MQL5 identik dengan Python." if ok else
          "\nPARITAS GAGAL — perbaiki DLFeatureEngine.mqh / features.py sebelum memakai model.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
