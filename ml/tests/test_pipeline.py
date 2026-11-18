"""Uji pipeline: paritas fitur, anti-lookahead, label, backtest, dan round-trip ONNX.

Jalankan dari folder ml/:  python -m pytest -q
"""
import math
import os
import sys

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from dlea import backtest as bt
from dlea import data, features as F
from dlea.dataset import refit_split, valid_window_ends, walk_forward_splits
from dlea.labels import BUY, HOLD, SELL, triple_barrier_labels


@pytest.fixture(scope="module")
def df():
    return data.make_synthetic(1500, seed=3)


# --------------------------------------------------------------------------
# Implementasi referensi baris-per-baris. Ini adalah "kembaran" Python dari
# DLComputeFeatureRow() di Include/DL_Signal_EA/DLFeatureEngine.mqh — jaga agar
# keduanya identik baris demi baris.
# --------------------------------------------------------------------------
def _atr_ref(h, l, c, i, period):
    s = 0.0
    for j in range(i - period + 1, i + 1):
        pc = c[j - 1]
        s += max(h[j] - l[j], max(abs(h[j] - pc), abs(l[j] - pc)))
    return s / period


def _clip(v):
    if not math.isfinite(v):
        return 0.0
    return max(-F.CLIP, min(F.CLIP, v))


def feature_row_reference(o, h, l, c, v, minutes, i):
    atr_fast = _atr_ref(h, l, c, i, F.ATR_FAST)
    atr_slow = _atr_ref(h, l, c, i, F.ATR_SLOW)
    atr = max(atr_fast, F.EPS)
    atr_pct = max(atr_fast / c[i], F.EPS)

    sma_fast = sum(c[i - F.SMA_FAST + 1:i + 1]) / F.SMA_FAST
    sma_slow = sum(c[i - F.SMA_SLOW + 1:i + 1]) / F.SMA_SLOW

    gain = loss = 0.0
    for j in range(i - F.RSI_PERIOD + 1, i + 1):
        d = c[j] - c[j - 1]
        if d > 0:
            gain += d
        else:
            loss -= d
    rsi = 2.0 * gain / (gain + loss) - 1.0 if gain + loss > 0 else 0.0

    hh = max(h[i - F.RANGE_PERIOD + 1:i + 1])
    ll = min(l[i - F.RANGE_PERIOD + 1:i + 1])
    range_pos = 2.0 * (c[i] - ll) / (hh - ll) - 1.0 if hh - ll > 0 else 0.0

    vol_mean = sum(v[i - F.VOL_PERIOD + 1:i + 1]) / F.VOL_PERIOD
    ang = 2.0 * math.pi * minutes[i] / 1440.0
    row = [
        math.log(c[i] / c[i - 1]) / atr_pct,
        math.log(c[i] / c[i - 3]) / atr_pct,
        math.log(c[i] / c[i - 12]) / atr_pct,
        (c[i] - o[i]) / atr,
        (h[i] - max(o[i], c[i])) / atr,
        (min(o[i], c[i]) - l[i]) / atr,
        (h[i] - l[i]) / atr,
        (c[i] - sma_fast) / atr,
        (c[i] - sma_slow) / atr,
        rsi,
        range_pos,
        math.log((v[i] + 1.0) / (vol_mean + 1.0)),
        math.log(max(atr_fast, F.EPS) / max(atr_slow, F.EPS)),
        math.sin(ang),
        math.cos(ang),
    ]
    return [_clip(x) for x in row]


def test_features_match_reference(df):
    feats = F.compute_features(df)
    assert feats.shape == (len(df), F.NUM_FEATURES)
    assert np.isnan(feats[:F.WARMUP]).all()
    assert np.isfinite(feats[F.WARMUP:]).all()
    o, h, l, c, v = (df[k].to_numpy(float) for k in ("open", "high", "low", "close", "tick_volume"))
    minutes = (df["time"].dt.hour * 60 + df["time"].dt.minute).to_numpy()
    for i in list(range(F.WARMUP, F.WARMUP + 40)) + list(range(len(df) - 40, len(df))):
        np.testing.assert_allclose(feats[i], feature_row_reference(o, h, l, c, v, minutes, i),
                                   rtol=1e-9, atol=1e-9)


def test_no_lookahead(df):
    """Mengubah bar masa depan tidak boleh mengubah fitur bar sebelumnya."""
    cut = 900
    base = F.compute_features(df)
    mod = df.copy()
    rng = np.random.default_rng(0)
    bump = 1.0 + rng.uniform(0.01, 0.05, len(df) - cut)
    for k in ("open", "high", "low", "close"):
        mod.loc[cut:, k] = mod.loc[cut:, k].to_numpy() * bump
    mod.loc[cut:, "tick_volume"] = mod.loc[cut:, "tick_volume"] * 3
    changed = F.compute_features(mod)
    np.testing.assert_array_equal(base[F.WARMUP:cut], changed[F.WARMUP:cut])
    assert not np.allclose(base[cut:], changed[cut:])


def test_features_do_not_depend_on_history_length(df):
    """Jendela terbatas: memotong riwayat lama tidak mengubah fitur (syarat paritas dengan EA)."""
    full = F.compute_features(df)
    tail = F.compute_features(df.iloc[700:].reset_index(drop=True))
    np.testing.assert_allclose(full[700 + F.WARMUP:], tail[F.WARMUP:], rtol=1e-9, atol=1e-9)


def test_triple_barrier_labels():
    # 8 bar; ATR = 1 konstan; tp = sl = 1.0; horizon = 2. Entry = open bar t+1.
    o = np.array([100, 100, 100, 100, 100, 100, 100, 100.0])
    h = np.array([100.2, 101.5, 100.2, 100.2, 101.5, 100.2, 100.2, 100.2])
    l = np.array([99.8, 99.8, 98.5, 99.8, 98.5, 99.8, 99.8, 99.8])
    y = triple_barrier_labels(o, h, l, np.ones(8), horizon=2, tp_atr=1.0, sl_atr=1.0)
    assert y[0] == BUY       # bar 1 menyentuh 101 lebih dulu
    assert y[1] == SELL      # bar 2 menyentuh 99 lebih dulu
    assert y[2] == HOLD      # bar 3 netral, bar 4 menyentuh keduanya -> ambigu
    assert y[3] == HOLD      # bar 4 menyentuh keduanya -> ambigu
    assert y[4] == HOLD      # bar 5-6 netral -> timeout
    assert y[5] == HOLD
    assert (y[6:] == -1).all()   # data masa depan tidak cukup


def test_labels_account_for_spread():
    """Long masuk di ask & dipicu bid; short masuk di bid & dipicu ask -> TP lebih jauh sebesar spread."""
    o = np.full(6, 100.0)
    h = np.array([100.1, 101.2, 100.1, 100.1, 100.1, 100.1])
    l = np.array([99.9, 99.9, 99.9, 98.8, 99.9, 99.9])
    kw = dict(horizon=1, tp_atr=1.0, sl_atr=1.0)
    y0 = triple_barrier_labels(o, h, l, np.ones(6), **kw)
    assert y0[0] == BUY and y0[2] == SELL              # tanpa spread: bid 101.2 >= 101, bid 98.8 <= 99
    y1 = triple_barrier_labels(o, h, l, np.ones(6), spread=np.full(6, 0.3), **kw)
    assert y1[0] == HOLD                               # TP long = 100.3 + 1 = 101.3 > high bid 101.2
    assert y1[2] == HOLD                               # low ask = 98.8 + 0.3 = 99.1 > TP short 99.0
    y2 = triple_barrier_labels(o, h, l, np.ones(6), spread=np.full(6, 0.15), **kw)
    assert y2[0] == BUY and y2[2] == SELL              # 101.2 >= 101.15 ; 98.95 <= 99.0


def test_labels_only_use_future_bars(df):
    atr = F.compute_atr(df)
    y = triple_barrier_labels(df["open"], df["high"], df["low"], atr, 8, 1.5, 1.5)
    mod = df.copy()
    mod.loc[:500, ["high", "low"]] = mod.loc[:500, ["open", "open"]].to_numpy()   # ubah masa lalu saja
    y2 = triple_barrier_labels(mod["open"], mod["high"], mod["low"], atr, 8, 1.5, 1.5)
    np.testing.assert_array_equal(y[501:], y2[501:])


def test_walk_forward_splits():
    n, lookback, horizon = 10000, 64, 8
    embargo = horizon + lookback
    feats = np.zeros((n, 3))
    feats[:F.WARMUP] = np.nan
    labels = np.ones(n, dtype=int)
    labels[n - horizon:] = -1
    ends = valid_window_ends(feats, labels, lookback)
    assert ends[0] == F.WARMUP + lookback - 1

    splits = walk_forward_splits(ends, n, folds=4, val_frac=0.10, test_frac=0.40, embargo=embargo, horizon=horizon)
    assert [s["fold"] for s in splits] == [1, 2, 3, 4]
    assert splits[0]["test_start"] == 6000 and splits[-1]["test_end"] == n
    prev_train = 0
    for i, s in enumerate(splits):
        tr, va, te = s["train"], s["val"], s["test"]
        # label train tidak menyentuh validasi; label validasi tidak menyentuh test
        assert tr[-1] + horizon < s["val_start"] <= va[0]
        assert va[-1] + horizon < s["test_start"] <= te[0]
        assert te[-1] + horizon < s["test_end"]            # posisi test selesai di dalam bloknya
        assert len(tr) > prev_train                         # jendela train melebar
        prev_train = len(tr)
        if i:
            assert s["test_start"] == splits[i - 1]["test_end"]   # blok test berurutan, tanpa tumpang-tindih
    all_test = np.concatenate([s["test"] for s in splits])
    assert len(np.unique(all_test)) == len(all_test)

    single = walk_forward_splits(ends, n, folds=1, val_frac=0.15, test_frac=0.15, embargo=embargo, horizon=horizon)
    assert len(single) == 1 and single[0]["test_start"] == 8500 and single[0]["val_start"] == 7000

    r = refit_split(ends, n, 0.10, embargo)
    assert r["train"][-1] + horizon < r["val_start"] == 9000 and r["val"][-1] == ends[-1] and len(r["test"]) == 0


def _bars(rows):
    t = pd.date_range("2024-01-01", periods=len(rows), freq="15min")
    return pd.DataFrame(rows, columns=["open", "high", "low", "close"]).assign(time=t, tick_volume=1.0, spread=0.1)


def _one_trade(bars, direction, spread=0.1, horizon=2, **kw):
    """Sinyal di bar 0 (ATR = 1, tp = sl = 1) -> entry di open bar 1."""
    df = _bars([(100, 100.2, 99.8, 100)] + bars)
    df["spread"] = spread
    sig = np.zeros(len(df), dtype=np.int8)
    sig[0] = direction
    tr = bt.simulate(df, np.ones(len(df)), np.arange(len(df)), sig, horizon=horizon, tp_atr=1.0, sl_atr=1.0, **kw)
    assert len(tr) == 1
    return tr.iloc[0]


def test_backtest_long_spread_geometry():
    # long: beli di ask 100.1 -> TP 101.1, SL 99.1; dipicu harga BID
    t = _one_trade([(100, 101.05, 99.9, 101.0), (101, 101.1, 100.9, 101.0)], +1)
    assert (t["entry"], t["reason"], t["exit_bar"]) == (100.1, "tp", 2)    # bar 1 (bid 101.05) belum kena
    assert t["r"] == pytest.approx(1.0) and t["spread_r"] == pytest.approx(0.1)
    t = _one_trade([(100, 100.3, 99.9, 100.2), (100.2, 100.5, 100.1, 100.4)], +1)
    assert t["reason"] == "time" and t["r"] == pytest.approx(100.4 - 100.1)   # keluar-waktu di bid
    t = _one_trade([(100, 100.2, 99.1, 99.5), (99.5, 99.6, 99.4, 99.5)], +1)
    assert t["reason"] == "sl" and t["r"] == pytest.approx(-1.0)              # bid 99.1 <= SL 99.1


def test_backtest_short_spread_geometry():
    # short: jual di bid 100 -> SL 101, TP 99; dipicu harga ASK = bid + 0.1
    t = _one_trade([(100, 100.95, 99.9, 100.5), (100.5, 100.6, 100.4, 100.5)], -1)
    assert (t["entry"], t["reason"], t["exit_bar"]) == (100.0, "sl", 1)     # ask 101.05 >= SL walau bid 100.95
    assert t["r"] == pytest.approx(-1.0)
    t = _one_trade([(100, 100.1, 98.95, 99.2), (99.2, 99.3, 98.9, 99.0)], -1)
    assert (t["reason"], t["exit_bar"]) == ("tp", 2)                        # bar 1: ask 99.05 > TP; bar 2: 99.0
    assert t["r"] == pytest.approx(1.0)
    t = _one_trade([(100, 100.1, 99.7, 99.8), (99.8, 99.9, 99.5, 99.6)], -1)
    assert t["reason"] == "time" and t["r"] == pytest.approx(100.0 - (99.6 + 0.1))   # beli kembali di ask


def test_backtest_pessimistic_rules_and_costs():
    # SL & TP di bar yang sama -> SL dulu
    t = _one_trade([(100, 101.5, 98.5, 100.0), (100, 100.1, 99.9, 100.0)], +1)
    assert t["reason"] == "sl" and t["r"] == pytest.approx(-1.0)
    # gap melewati SL -> terisi di open (lebih buruk dari -1R)
    t = _one_trade([(100, 100.2, 99.9, 100.0), (98.5, 98.7, 98.4, 98.6)], +1)
    assert t["reason"] == "sl" and t["r"] == pytest.approx(98.5 - 100.1)
    t = _one_trade([(100, 100.1, 99.8, 100.0), (101.6, 101.8, 101.5, 101.7)], -1)
    assert t["reason"] == "sl" and t["r"] == pytest.approx(100.0 - (101.6 + 0.1))
    # komisi + slippage dipotong tetap
    t = _one_trade([(100, 101.05, 99.9, 101.0), (101, 101.1, 100.9, 101.0)], +1, extra_cost=0.05)
    assert t["r"] == pytest.approx(1.0 - 0.05)


def test_backtest_one_position_at_a_time():
    rows = [(100, 100.2, 99.8, 100)] * 2 + [
        (100, 101.2, 99.9, 101),     # bar 2: long dari sinyal bar 1 -> TP
        (101, 101.1, 100.9, 101),    # bar 3: entry sinyal bar 2
        (101, 102.5, 99.5, 101),     # bar 4: SL & TP bersamaan -> SL
        (101, 101.1, 100.9, 101),
        (101, 101.2, 100.8, 101.1),  # bar 6-7: tanpa barrier -> keluar waktu di close bar 7
        (101.1, 101.3, 100.9, 101.2),
        (101.2, 101.3, 101.1, 101.2),
    ]
    df = _bars(rows)
    df["spread"] = 0.0
    atr, bars = np.ones(len(df)), np.arange(len(df))
    signals = np.array([0, 1, 1, 1, 0, 1, 0, 0, 0], dtype=np.int8)
    tr = bt.simulate(df, atr, bars, signals, horizon=2, tp_atr=1.0, sl_atr=1.0)
    # sinyal bar 2 boleh (posisi pertama sudah TP di bar 2); sinyal bar 3 dilewati (masih ada posisi)
    assert tr["signal_bar"].tolist() == [1, 2, 5]
    assert tr["reason"].tolist() == ["tp", "sl", "time"]
    np.testing.assert_allclose(tr["r"], [1.0, -1.0, 101.2 - 101.0])
    m = bt.metrics(tr)
    assert m["trades"] == 3 and abs(m["total_r"] - 0.2) < 1e-9
    # last_bar: posisi yang tidak selesai sebelum batas blok tidak dibuka
    tr = bt.simulate(df, atr, bars, signals, horizon=2, tp_atr=1.0, sl_atr=1.0, last_bar=7)
    assert tr["signal_bar"].tolist() == [1, 2]


def test_acceptance_checks():
    import train
    fold = lambda v, t: {"validation_backtest": {"avg_r": v}, "test_backtest": {"avg_r": t}}
    good = {"trades": 400, "avg_r": 0.1, "t_stat": 3.0}
    checks, ok = train.acceptance_checks([fold(.1, .1), fold(.1, .2), fold(.2, .1), fold(.1, -.1)], good)
    assert ok and len(checks) == 4                                  # 3 dari 4 fold konsisten -> lulus
    _, ok = train.acceptance_checks([fold(.1, .1), fold(-.1, .2), fold(.2, .1), fold(.1, -.1)], good)
    assert not ok                                                   # validasi negatif di satu fold -> hanya 2 konsisten
    _, ok = train.acceptance_checks([fold(.1, .1)] * 4, good | {"t_stat": 1.5})
    assert not ok                                                   # tidak signifikan
    _, ok = train.acceptance_checks([fold(.1, .1)] * 4, good | {"trades": 80})
    assert not ok                                                   # terlalu sedikit trade (butuh >= 100)
    _, ok = train.acceptance_checks([fold(.1, .1)], good | {"trades": 60})
    assert ok                                                       # split tunggal: butuh >= 50 trade


def test_signal_rule():
    probs = np.array([[0.2, 0.2, 0.6], [0.6, 0.2, 0.2], [0.45, 0.10, 0.45], [0.3, 0.4, 0.3], [0.44, 0.0, 0.56]])
    assert bt.probs_to_signal(probs, 0.55, 0.10).tolist() == [1, -1, 0, 0, 1]
    assert bt.probs_to_signal(probs, 0.55, 0.15).tolist() == [1, -1, 0, 0, 0]


@pytest.mark.parametrize("arch", ["tcn", "cnn_lstm"])
def test_onnx_roundtrip(arch, tmp_path):
    from dlea import export
    from dlea.model import BUILDERS
    rng = np.random.default_rng(1)
    mean, var = rng.normal(size=F.NUM_FEATURES), rng.uniform(0.5, 2.0, F.NUM_FEATURES)
    model = BUILDERS[arch](32, F.NUM_FEATURES, mean, var)
    sample = rng.normal(size=(8, 32, F.NUM_FEATURES)).astype("float32")
    diff = export.export_onnx(model, str(tmp_path / "m.onnx"), 32, F.NUM_FEATURES, sample)
    assert diff < 1e-5
    probs = model.predict(sample, verbose=0)
    np.testing.assert_allclose(probs.sum(axis=1), 1.0, atol=1e-5)


def _write_export_files(df, tmp_path, digits=2):
    """Tulis file persis seperti format Scripts/DL_ExportHistory.mq5."""
    out = df.copy()
    for k in ("open", "high", "low", "close", "spread"):
        out[k] = out[k].round(digits)
    out = data.clean(out)
    csv = tmp_path / "TEST_M15.csv"
    with open(csv, "w") as fh:
        fh.write("time,open,high,low,close,tick_volume,spread\r\n")
        for r in out.itertuples():
            fh.write(f"{r.time:%Y.%m.%d %H:%M},{r.open:.{digits}f},{r.high:.{digits}f},{r.low:.{digits}f},"
                     f"{r.close:.{digits}f},{int(r.tick_volume)},{r.spread:.{digits}f}\r\n")
    o, h, l, c, v = (out[k].to_numpy(float) for k in ("open", "high", "low", "close", "tick_volume"))
    minutes = (out["time"].dt.hour * 60 + out["time"].dt.minute).to_numpy()
    feat = tmp_path / "TEST_M15_features_mql5.csv"
    with open(feat, "w") as fh:
        fh.write("time," + ",".join(F.FEATURE_NAMES) + "\r\n")
        for i in range(len(out) - 300, len(out)):
            row = feature_row_reference(o, h, l, c, v, minutes, i)
            fh.write(f"{out['time'].iloc[i]:%Y.%m.%d %H:%M}," + ",".join(f"{x:.10f}" for x in row) + "\r\n")
    return csv, feat


def test_csv_loader_and_parity_tool(df, tmp_path):
    import check_parity
    csv, feat = _write_export_files(df, tmp_path)
    loaded = data.load_csv(str(csv))
    assert list(loaded.columns) == data.COLUMNS and data.timeframe_minutes(loaded) == 15
    assert check_parity.main(["--csv", str(csv), "--features", str(feat)]) == 0
    # fitur yang sengaja dirusak harus terdeteksi
    bad = pd.read_csv(feat)
    bad["rsi"] = bad["rsi"] + 0.01
    bad_path = tmp_path / "bad.csv"
    bad.to_csv(bad_path, index=False)
    assert check_parity.main(["--csv", str(csv), "--features", str(bad_path)]) == 1


def test_mql5_constants_match_python():
    """Konstanta di DLDefines.mqh harus sama dengan features.py."""
    import re
    path = os.path.join(os.path.dirname(__file__), "..", "..", "Include", "DL_Signal_EA", "DLDefines.mqh")
    src = open(path, encoding="utf-8").read()
    defs = dict(re.findall(r"#define\s+(DL_\w+)\s+([-\w.]+)", src))
    expect = {"DL_FEATURE_VERSION": F.FEATURE_VERSION, "DL_NUM_FEATURES": F.NUM_FEATURES, "DL_ATR_FAST": F.ATR_FAST,
              "DL_ATR_SLOW": F.ATR_SLOW, "DL_SMA_FAST": F.SMA_FAST, "DL_SMA_SLOW": F.SMA_SLOW,
              "DL_RSI_PERIOD": F.RSI_PERIOD, "DL_RANGE_PERIOD": F.RANGE_PERIOD, "DL_VOL_PERIOD": F.VOL_PERIOD,
              "DL_WARMUP": F.WARMUP, "DL_EPS": F.EPS, "DL_CLIP": F.CLIP, "DL_CLASS_SELL": SELL,
              "DL_CLASS_HOLD": HOLD, "DL_CLASS_BUY": BUY}
    for name, value in expect.items():
        assert float(defs[name]) == float(value), name
    header = re.search(r'#define\s+DL_FEATURE_HEADER\s+"([^"]+)"', src).group(1)
    assert header.split(",") == F.FEATURE_NAMES
