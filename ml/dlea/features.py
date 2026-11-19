"""Fitur model — SUMBER KEBENARAN untuk Include/DL_Signal_EA/DLFeatureEngine.mqh.

Aturan desain (penting untuk paritas training <-> EA):
  * Setiap fitur hanya memakai JENDELA TERBATAS bar yang sudah close (<= t).
    Tidak ada EMA/Wilder rekursif, sehingga nilainya tidak bergantung pada
    panjang riwayat dan bisa direplikasi persis di MQL5.
  * Semua fitur dinormalisasi terhadap volatilitas (ATR) -> stasioner dan
    tidak bergantung pada level harga instrumen.
  * Urutan kolom = FEATURE_NAMES. Mengubah apa pun di sini WAJIB diikuti
    perubahan yang sama di DLFeatureEngine.mqh dan menaikkan FEATURE_VERSION.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

FEATURE_VERSION = 1
FEATURE_NAMES = [
    "ret1",           # ln(c_t / c_{t-1})  / (ATR/c)
    "ret3",           # ln(c_t / c_{t-3})  / (ATR/c)
    "ret12",          # ln(c_t / c_{t-12}) / (ATR/c)
    "body",           # (close - open) / ATR
    "upper_wick",     # (high - max(open, close)) / ATR
    "lower_wick",     # (min(open, close) - low) / ATR
    "bar_range",      # (high - low) / ATR
    "sma_fast_dist",  # (close - SMA20) / ATR
    "sma_slow_dist",  # (close - SMA50) / ATR
    "rsi",            # RSI Cutler(14) diskalakan ke [-1, 1]
    "range_pos",      # posisi close di rentang high-low 20 bar, [-1, 1]
    "vol_rel",        # ln((tickvol + 1) / (rata-rata tickvol 20 + 1))
    "vol_regime",     # ln(ATR14 / ATR50)
    "tod_sin",        # sin(2*pi * menit_dalam_hari / 1440)  (waktu server broker)
    "tod_cos",        # cos(2*pi * menit_dalam_hari / 1440)
]
NUM_FEATURES = len(FEATURE_NAMES)

ATR_FAST = 14
ATR_SLOW = 50
SMA_FAST = 20
SMA_SLOW = 50
RSI_PERIOD = 14
RANGE_PERIOD = 20
VOL_PERIOD = 20
WARMUP = 50      # indeks bar pertama yang semua fiturnya valid
EPS = 1e-12
CLIP = 10.0


def true_range(high: np.ndarray, low: np.ndarray, close: np.ndarray) -> np.ndarray:
    prev = np.empty_like(close)
    prev[0] = np.nan
    prev[1:] = close[:-1]
    tr = np.maximum(high - low, np.maximum(np.abs(high - prev), np.abs(low - prev)))
    tr[0] = np.nan
    return tr


def _sma(x: np.ndarray, n: int) -> np.ndarray:
    return pd.Series(x).rolling(n, min_periods=n).mean().to_numpy()


def _rsum(x: np.ndarray, n: int) -> np.ndarray:
    return pd.Series(x).rolling(n, min_periods=n).sum().to_numpy()


def compute_atr(df: pd.DataFrame, period: int = ATR_FAST) -> np.ndarray:
    """ATR = rata-rata sederhana true range `period` bar (bukan Wilder)."""
    return _sma(true_range(df["high"].to_numpy(float), df["low"].to_numpy(float),
                           df["close"].to_numpy(float)), period)


def compute_features(df: pd.DataFrame) -> np.ndarray:
    """Kembalikan matriks [n_bar, NUM_FEATURES] float64; baris < WARMUP = NaN.

    Baris t hanya memakai bar <= t (lihat tests/test_pipeline.py::test_no_lookahead).
    """
    o = df["open"].to_numpy(float)
    h = df["high"].to_numpy(float)
    l = df["low"].to_numpy(float)
    c = df["close"].to_numpy(float)
    v = df["tick_volume"].to_numpy(float)
    n = len(df)

    tr = true_range(h, l, c)
    atr_f = _sma(tr, ATR_FAST)
    atr_s = _sma(tr, ATR_SLOW)
    atr = np.maximum(atr_f, EPS)
    atr_pct = np.maximum(atr_f / c, EPS)

    def logret(k: int) -> np.ndarray:
        out = np.full(n, np.nan)
        out[k:] = np.log(c[k:] / c[:-k])
        return out

    diff = np.full(n, np.nan)
    diff[1:] = c[1:] - c[:-1]
    gain = _rsum(np.maximum(diff, 0.0), RSI_PERIOD)
    loss = _rsum(np.maximum(-diff, 0.0), RSI_PERIOD)
    tot = gain + loss
    with np.errstate(invalid="ignore", divide="ignore"):
        rsi = np.where(tot > 0.0, 2.0 * gain / np.where(tot > 0.0, tot, 1.0) - 1.0, 0.0)
    rsi[np.isnan(tot)] = np.nan

    hh = pd.Series(h).rolling(RANGE_PERIOD, min_periods=RANGE_PERIOD).max().to_numpy()
    ll = pd.Series(l).rolling(RANGE_PERIOD, min_periods=RANGE_PERIOD).min().to_numpy()
    span = hh - ll
    with np.errstate(invalid="ignore", divide="ignore"):
        range_pos = np.where(span > 0.0, 2.0 * (c - ll) / np.where(span > 0.0, span, 1.0) - 1.0, 0.0)
    range_pos[np.isnan(span)] = np.nan

    minutes = (df["time"].dt.hour * 60 + df["time"].dt.minute).to_numpy(float)
    ang = 2.0 * np.pi * minutes / 1440.0

    cols = [
        logret(1) / atr_pct,
        logret(3) / atr_pct,
        logret(12) / atr_pct,
        (c - o) / atr,
        (h - np.maximum(o, c)) / atr,
        (np.minimum(o, c) - l) / atr,
        (h - l) / atr,
        (c - _sma(c, SMA_FAST)) / atr,
        (c - _sma(c, SMA_SLOW)) / atr,
        rsi,
        range_pos,
        np.log((v + 1.0) / (_sma(v, VOL_PERIOD) + 1.0)),
        np.log(np.maximum(atr_f, EPS) / np.maximum(atr_s, EPS)),
        np.sin(ang),
        np.cos(ang),
    ]
    feats = np.clip(np.column_stack(cols), -CLIP, CLIP)
    feats[:WARMUP] = np.nan
    return feats
