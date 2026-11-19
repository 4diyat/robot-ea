#!/usr/bin/env python3
"""Latih model DL_Signal_EA, validasi walk-forward, lalu ekspor ke ONNX.

Contoh:
  python train.py --csv data/XAUUSD_M15.csv --out artifacts/xauusd_m15 --extra-cost 0.10
  python train.py --csv data/XAUUSD_M15.csv --out artifacts/xauusd_m15 --extra-cost 0.10 --refit
  python train.py --synthetic 40000 --synthetic-signal 0.5 --out artifacts/smoke   # uji pipeline

Validasi: `--test-frac` terakhir dari data dibagi menjadi `--folds` blok test
berurutan. Tiap blok diuji oleh model yang hanya dilatih pada data SEBELUM blok
itu. Kesimpulan diambil dari gabungan semua blok + konsistensi antar-fold.

Keluaran di --out:
  dl_signal_model.onnx  -> salin ke <Data Folder>/MQL5/Files/
  DL_Signal_EA.set      -> preset EA (lookback/threshold/SL/TP/horizon hasil training)
  report.json           -> hasil per fold, gabungan, syarat lulus
  oos_trades.csv        -> semua trade out-of-sample (untuk dibandingkan dengan Strategy Tester)
  meta.json, model.keras
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--csv", help="CSV OHLCV dari Scripts/DL_ExportHistory.mq5 (atau ekspor bawaan MT5)")
    src.add_argument("--synthetic", type=int, metavar="N", help="pakai N bar data sintetis (uji pipeline saja)")
    p.add_argument("--synthetic-signal", type=float, default=0.0, help="kekuatan momentum tertanam (0 = random walk)")
    p.add_argument("--point", type=float, default=None, help="ukuran point (hanya untuk ekspor bawaan MT5)")
    p.add_argument("--out", default="artifacts/run", help="folder keluaran")
    p.add_argument("--arch", choices=["tcn", "cnn_lstm"], default="tcn")
    p.add_argument("--lookback", type=int, default=64, help="panjang sekuens masukan (bar)")
    p.add_argument("--horizon", type=int, default=8, help="horizon prediksi / batas tahan posisi (bar)")
    p.add_argument("--tp-atr", type=float, default=1.5, help="TP dalam kelipatan ATR")
    p.add_argument("--sl-atr", type=float, default=1.5, help="SL dalam kelipatan ATR")
    p.add_argument("--margin", type=float, default=0.05, help="selisih minimum P(arah) - P(lawan)")
    p.add_argument("--extra-cost", type=float, default=0.0,
                   help="komisi + slippage per trade dalam satuan harga (spread sudah dimodelkan dari CSV)")
    p.add_argument("--folds", type=int, default=4, help="jumlah blok test walk-forward (1 = split tunggal)")
    p.add_argument("--test-frac", type=float, default=0.40, help="porsi data (terakhir) untuk seluruh blok test")
    p.add_argument("--val-frac", type=float, default=0.10, help="porsi data untuk validasi tiap fold")
    p.add_argument("--refit", action="store_true",
                   help="setelah walk-forward, latih ulang model yang diekspor pada data terbaru "
                        "(validasi = --val-frac terakhir; model ini tidak punya periode test sendiri)")
    p.add_argument("--epochs", type=int, default=40)
    p.add_argument("--batch-size", type=int, default=256)
    p.add_argument("--lr", type=float, default=1e-3)
    p.add_argument("--dropout", type=float, default=0.2)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--opset", type=int, default=13)
    p.add_argument("--verbose", action="store_true", help="cetak log tiap epoch dan tabel threshold tiap fold")
    args = p.parse_args(argv)
    if args.folds < 1 or not 0 < args.test_frac < 1 or not 0 < args.val_frac < 1 \
            or args.test_frac + args.val_frac >= 0.9:
        p.error("butuh --folds >= 1 dan --test-frac + --val-frac < 0.9 (sisanya untuk train fold pertama)")
    return args


def classification_report(y: np.ndarray, probs: np.ndarray) -> dict:
    pred = probs.argmax(axis=1)
    cm = np.zeros((3, 3), dtype=int)
    np.add.at(cm, (y, pred), 1)
    prec = [cm[k, k] / cm[:, k].sum() if cm[:, k].sum() else 0.0 for k in range(3)]
    rec = [cm[k, k] / cm[k].sum() if cm[k].sum() else 0.0 for k in range(3)]
    f1 = [2 * a * b / (a + b) if a + b else 0.0 for a, b in zip(prec, rec)]
    logloss = float(-np.log(np.clip(probs[np.arange(len(y)), y], 1e-9, 1.0)).mean())
    prior = np.bincount(y, minlength=3) / len(y)
    return {
        "n": int(len(y)),
        "accuracy": float((pred == y).mean()),
        "baseline_accuracy": float(prior.max()),                       # selalu tebak kelas mayoritas
        "log_loss": logloss,
        "baseline_log_loss": float(-(prior[prior > 0] * np.log(prior[prior > 0])).sum()),  # tebak prior kelas
        "macro_f1": float(np.mean(f1)),
        "precision": [float(x) for x in prec],
        "recall": [float(x) for x in rec],
        "confusion_matrix": cm.tolist(),
    }


def acceptance_checks(folds: list[dict], oos: dict) -> tuple[list[dict], bool]:
    """Syarat lulus. Semua harus terpenuhi agar kesimpulannya 'ada indikasi edge'."""
    k = len(folds)
    min_trades = max(50, 25 * k)
    need_folds = math.ceil(2 * k / 3)
    consistent = sum(1 for f in folds if f["validation_backtest"]["avg_r"] > 0 and f["test_backtest"]["avg_r"] > 0)
    checks = [
        {"name": f"jumlah trade out-of-sample >= {min_trades}", "value": oos["trades"],
         "passed": oos["trades"] >= min_trades},
        {"name": "rata-rata R out-of-sample > 0 (setelah biaya)", "value": round(oos["avg_r"], 4),
         "passed": oos["avg_r"] > 0},
        {"name": "t-stat out-of-sample >= 2", "value": round(oos["t_stat"], 2), "passed": oos["t_stat"] >= 2.0},
        {"name": f"fold dengan validasi DAN test positif >= {need_folds} dari {k}", "value": consistent,
         "passed": consistent >= need_folds},
    ]
    return checks, all(c["passed"] for c in checks)


def main(argv=None) -> dict:
    args = parse_args(argv)
    import keras
    import pandas as pd

    from dlea import backtest as bt
    from dlea import data, export
    from dlea.dataset import WindowDataset, refit_split, valid_window_ends, walk_forward_splits
    from dlea.features import FEATURE_NAMES, FEATURE_VERSION, NUM_FEATURES, compute_atr, compute_features
    from dlea.labels import CLASS_NAMES, triple_barrier_labels
    from dlea.model import BUILDERS

    os.makedirs(args.out, exist_ok=True)

    # ---------------------------------------------------------------- 1. data
    if args.csv:
        df = data.load_csv(args.csv, point=args.point)
        source = os.path.basename(args.csv)
    else:
        df = data.make_synthetic(args.synthetic, seed=args.seed, signal=args.synthetic_signal)
        source = f"SINTETIS(n={args.synthetic}, signal={args.synthetic_signal})"
    tf_min = data.timeframe_minutes(df)
    times = df["time"]
    day = lambda i: str(times.iloc[int(i)])[:10]
    print(f"[1] data: {source} | {len(df)} bar | {times.iloc[0]} -> {times.iloc[-1]} | TF ~{tf_min} menit")
    if float(df["spread"].max()) == 0.0:
        print("    PERINGATAN: kolom spread = 0 -> backtest tanpa biaya spread, hasil terlalu optimis.")
    if args.extra_cost == 0.0:
        print("    Catatan: --extra-cost = 0 (komisi & slippage tidak diperhitungkan).")

    # ------------------------------------------------------- 2. fitur + label
    feats = compute_features(df)
    atr = compute_atr(df)
    labels = triple_barrier_labels(df["open"], df["high"], df["low"], atr, args.horizon, args.tp_atr, args.sl_atr,
                                   spread=df["spread"])
    ends = valid_window_ends(feats, labels, args.lookback)
    feats32 = np.nan_to_num(feats, nan=0.0).astype("float32")
    embargo = args.horizon + args.lookback
    splits = walk_forward_splits(ends, len(df), args.folds, args.val_frac, args.test_frac, embargo, args.horizon)
    smallest = min(min(len(s["train"]), len(s["val"]), len(s["test"])) for s in splits)
    if smallest < 300:
        raise SystemExit(f"Data terlalu sedikit untuk {args.folds} fold (bagian terkecil hanya {smallest} sampel). "
                         "Tambah data atau kurangi --folds.")
    dist = (np.bincount(labels[ends], minlength=3) / len(ends)).round(3).tolist()
    print(f"[2] {len(ends)} sampel | distribusi label {CLASS_NAMES} = {dist} | embargo {embargo} bar")

    # ---------------------------------------------------------- alat bantu fold
    def fit(split: dict, seed: int):
        """Latih satu model pada split['train'], early stopping pada split['val']."""
        tr, va = split["train"], split["val"]
        keras.backend.clear_session()
        keras.utils.set_random_seed(seed)
        rows = feats[tr[0] - args.lookback + 1: tr[-1] + 1]          # statistik HANYA dari periode train fold ini
        counts = np.bincount(labels[tr], minlength=3)
        class_weight = (len(tr) / (3.0 * np.maximum(counts, 1))).astype("float32")
        model = BUILDERS[args.arch](args.lookback, NUM_FEATURES, rows.mean(axis=0), rows.var(axis=0) + 1e-8,
                                    dropout=args.dropout)
        model.compile(optimizer=keras.optimizers.Adam(args.lr), loss="sparse_categorical_crossentropy",
                      metrics=["accuracy"])
        hist = model.fit(
            WindowDataset(feats32, tr, labels, args.lookback, args.batch_size, shuffle=True,
                          class_weight=class_weight, seed=seed),
            validation_data=WindowDataset(feats32, va, labels, args.lookback, args.batch_size),
            epochs=args.epochs, verbose=2 if args.verbose else 0,
            callbacks=[keras.callbacks.EarlyStopping("val_loss", patience=6, restore_best_weights=True),
                       keras.callbacks.ReduceLROnPlateau("val_loss", factor=0.5, patience=3, min_lr=1e-5)],
        )
        return model, hist.history

    def predict(model, idx):
        return model.predict(WindowDataset(feats32, idx, None, args.lookback, 1024), verbose=0)

    def backtest(idx, probs, thr, last_bar=None):
        return bt.simulate(df, atr, idx, bt.probs_to_signal(probs, thr, args.margin), args.horizon,
                           args.tp_atr, args.sl_atr, args.extra_cost, last_bar=last_bar)

    def pick_threshold(split: dict, p_va):
        """Threshold dipilih di VALIDASI: t-stat rata-rata R tertinggi dengan jumlah trade minimum."""
        va = split["val"]
        min_trades = max(50, len(va) // 100)
        grid = [(round(float(thr), 2), bt.metrics(backtest(va, p_va, thr, last_bar=split["test_start"])))
                for thr in np.arange(0.36, 0.701, 0.02)]
        eligible = [g for g in grid if g[1]["trades"] >= min_trades]
        thr, m = max(eligible, key=lambda g: g[1]["t_stat"]) if eligible else grid[0]
        if args.verbose:
            for g_thr, g in grid:
                print(f"        thr {g_thr:.2f}: {g['trades']:5d} trade | avg {g['avg_r']:+.3f}R | "
                      f"t {g['t_stat']:+.2f}{' <-' if g_thr == thr else ''}")
        return thr, m

    # ------------------------------------------------------ 3. walk-forward
    print(f"[3] walk-forward {args.folds} fold (train melebar) | model {args.arch} | "
          f"train fold 1 = {len(splits[0]['train'])} sampel, tiap blok test ~{len(splits[0]['test'])} sampel")
    fold_reports, oos_trades = [], []
    model = threshold = None
    for s in splits:
        tr, va, te = s["train"], s["val"], s["test"]
        model, hist = fit(s, args.seed + s["fold"])
        threshold, val_bt = pick_threshold(s, predict(model, va))
        p_te = predict(model, te)
        trades = backtest(te, p_te, threshold, last_bar=s["test_end"])
        test_bt, test_cls = bt.metrics(trades), classification_report(labels[te], p_te)
        oos_trades.append(trades.assign(fold=s["fold"]))
        fold_reports.append({
            "fold": s["fold"],
            "periods": {"train": [day(tr[0]), day(tr[-1])], "val": [day(va[0]), day(va[-1])],
                        "test": [day(te[0]), day(te[-1])]},
            "samples": {"train": len(tr), "val": len(va), "test": len(te)},
            "epochs_run": len(hist["loss"]), "best_val_loss": float(min(hist["val_loss"])),
            "threshold": threshold, "validation_backtest": val_bt, "test_backtest": test_bt,
            "test_classification": test_cls,
        })
        print(f"    fold {s['fold']}/{args.folds} | test {day(te[0])} -> {day(te[-1])} | thr {threshold:.2f} | "
              f"val {val_bt['trades']:4d} trade {val_bt['avg_r']:+.3f}R | "
              f"test {test_bt['trades']:4d} trade {test_bt['avg_r']:+.3f}R t {test_bt['t_stat']:+.2f} | "
              f"log-loss {test_cls['log_loss']:.4f} (baseline {test_cls['baseline_log_loss']:.4f})")

    # -------------------------------------- 4. gabungan out-of-sample + syarat lulus
    all_trades = pd.concat(oos_trades, ignore_index=True)
    oos = bt.metrics(all_trades)
    checks, edge = acceptance_checks(fold_reports, oos)
    verdict = ("ADA INDIKASI EDGE out-of-sample (lanjutkan ke Strategy Tester + demo)"
               if edge else "TIDAK ADA EDGE YANG TERBUKTI out-of-sample -> JANGAN dipakai live")
    print(f"[4] GABUNGAN OUT-OF-SAMPLE ({args.folds} fold, {day(splits[0]['test'][0])} -> {day(splits[-1]['test'][-1])})")
    print(f"    {oos['trades']} trade | win {oos['win_rate']:.1%} | avg {oos['avg_r']:+.3f}R | "
          f"total {oos['total_r']:+.1f}R | PF {oos['profit_factor']:.2f} | maxDD {oos['max_dd_r']:.1f}R | "
          f"t-stat {oos['t_stat']:+.2f} | spread rata-rata {oos['avg_spread_r']:.3f}R")
    print("[5] SYARAT LULUS")
    for c in checks:
        print(f"    [{'x' if c['passed'] else ' '}] {c['name']}: {c['value']}")
    print(f"    KESIMPULAN: {verdict}")

    # ---------------------------------------------------------------- 6. ekspor
    last = splits[-1]
    exported = {"from": f"fold {last['fold']}", "threshold": threshold,
                "test_period": fold_reports[-1]["periods"]["test"],
                "note": "model fold terakhir; periode test-nya bisa dipakai untuk membandingkan dengan Strategy Tester"}
    sample_idx = last["test"][:64]
    if args.refit:
        r = refit_split(ends, len(df), args.val_frac, embargo)
        model, hist = fit(r, args.seed + 1000)
        threshold, refit_val = pick_threshold(r, predict(model, r["val"]))
        exported = {"from": "refit", "threshold": threshold, "test_period": None,
                    "train_period": [day(r["train"][0]), day(r["train"][-1])],
                    "val_period": [day(r["val"][0]), day(r["val"][-1])], "validation_backtest": refit_val,
                    "note": "dilatih ulang pada data terbaru; TIDAK punya periode test sendiri — "
                            "perkiraan kinerjanya adalah hasil walk-forward di atas"}
        sample_idx = r["val"][:64]
        print(f"[6] refit: train {exported['train_period'][0]} -> {exported['train_period'][1]} | thr {threshold:.2f} | "
              f"val {refit_val['trades']} trade {refit_val['avg_r']:+.3f}R (model ini tidak punya periode test)")

    onnx_path = os.path.join(args.out, "dl_signal_model.onnx")
    sample = feats32[sample_idx[:, None] + np.arange(-args.lookback + 1, 1)[None, :]]
    onnx_diff = export.export_onnx(model, onnx_path, args.lookback, NUM_FEATURES, sample, opset=args.opset)
    if onnx_diff > 1e-4:
        raise SystemExit(f"Ekspor ONNX tidak cocok dengan Keras (selisih maks {onnx_diff:.2e}).")
    model.save(os.path.join(args.out, "model.keras"))

    for col in ("signal_bar", "entry_bar", "exit_bar"):
        all_trades[col.replace("_bar", "_time")] = times.to_numpy()[all_trades[col].to_numpy(int)]
    all_trades.to_csv(os.path.join(args.out, "oos_trades.csv"), index=False,
                      columns=["fold", "signal_time", "entry_time", "exit_time", "dir", "entry", "exit",
                               "reason", "r", "spread_r"])

    report = {
        "source": source, "bars": len(df), "timeframe_minutes": tf_min, "arch": args.arch,
        "feature_version": FEATURE_VERSION, "feature_names": FEATURE_NAMES, "class_names": CLASS_NAMES,
        "lookback": args.lookback, "horizon": args.horizon, "tp_atr": args.tp_atr, "sl_atr": args.sl_atr,
        "margin": args.margin, "extra_cost": args.extra_cost,
        "walk_forward": {"folds": args.folds, "test_frac": args.test_frac, "val_frac": args.val_frac,
                         "embargo_bars": embargo},
        "folds": fold_reports, "out_of_sample": oos, "checks": checks,
        "edge_found": bool(edge), "verdict": verdict,
        "exported_model": exported, "threshold": threshold,
        "onnx_max_abs_diff": onnx_diff, "onnx_opset": args.opset,
    }
    export.write_meta(os.path.join(args.out, "meta.json"),
                      {k: report[k] for k in ("source", "timeframe_minutes", "arch", "feature_version",
                                              "feature_names", "class_names", "lookback", "horizon", "tp_atr",
                                              "sl_atr", "threshold", "margin", "edge_found", "exported_model",
                                              "onnx_opset")}
                      | {"onnx_input": [1, args.lookback, NUM_FEATURES], "onnx_output": [1, 3]})
    with open(os.path.join(args.out, "report.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, default=float)
    export.write_preset(os.path.join(args.out, "DL_Signal_EA.set"), model_file=onnx_path, tf_minutes=tf_min,
                        lookback=args.lookback, threshold=threshold, margin=args.margin, sl_atr=args.sl_atr,
                        tp_atr=args.tp_atr, horizon=args.horizon,
                        note=f"{source}; model {exported['from']}; edge_found={edge}")
    print(f"[{7 if args.refit else 6}] ekspor ({exported['from']}): {onnx_path} "
          f"(selisih maks Keras vs ONNX Runtime = {onnx_diff:.1e}) + DL_Signal_EA.set, report.json, "
          f"oos_trades.csv, meta.json")
    return report


if __name__ == "__main__":
    main()
