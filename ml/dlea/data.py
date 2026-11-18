"""Pemuatan data historis MT5 + generator data sintetis (HANYA untuk uji pipeline)."""
from __future__ import annotations

import numpy as np
import pandas as pd

COLUMNS = ["time", "open", "high", "low", "close", "tick_volume", "spread"]


def load_csv(path: str, point: float | None = None) -> pd.DataFrame:
    """Muat CSV OHLCV.

    Format yang didukung:
      1. Keluaran Scripts/DL_ExportHistory.mq5 (disarankan):
         time,open,high,low,close,tick_volume,spread   — spread dalam satuan HARGA.
      2. Ekspor bawaan MT5 (Symbols -> Bars -> Export Bars), tab-separated:
         <DATE> <TIME> <OPEN> <HIGH> <LOW> <CLOSE> <TICKVOL> <VOL> <SPREAD>
         — spread dalam POIN, perlu `point` (mis. 0.01 untuk XAUUSD 2 digit).
    """
    with open(path, "r", encoding="utf-8-sig") as fh:
        head = fh.readline()
    if head.lstrip().startswith("<DATE>"):
        raw = pd.read_csv(path, sep="\t", encoding="utf-8-sig")
        raw.columns = [c.strip().strip("<>").lower() for c in raw.columns]
        tcol = raw["time"].astype(str) if "time" in raw.columns else "00:00:00"
        time = pd.to_datetime(raw["date"].astype(str) + " " + tcol, format="%Y.%m.%d %H:%M:%S")
        spread = raw["spread"].astype(float) * point if point else 0.0
        df = pd.DataFrame({"time": time, "open": raw["open"], "high": raw["high"], "low": raw["low"],
                           "close": raw["close"], "tick_volume": raw["tickvol"], "spread": spread})
        if not point:
            print("[data] PERINGATAN: ekspor bawaan MT5 tanpa --point -> spread dianggap 0.")
    else:
        df = pd.read_csv(path, encoding="utf-8-sig")
        df.columns = [c.strip().lower() for c in df.columns]
        missing = [c for c in COLUMNS if c not in df.columns]
        if missing:
            raise ValueError(f"Kolom hilang di {path}: {missing}. Diharapkan: {COLUMNS}")
        df["time"] = pd.to_datetime(df["time"].astype(str), format="%Y.%m.%d %H:%M")
        df = df[COLUMNS]
    return clean(df)


def clean(df: pd.DataFrame) -> pd.DataFrame:
    n0 = len(df)
    df = df.drop_duplicates("time").sort_values("time").reset_index(drop=True)
    for c in COLUMNS[1:]:
        df[c] = df[c].astype(float)
    bad = (
        (df[["open", "high", "low", "close"]] <= 0).any(axis=1)
        | (df["high"] < df[["open", "close", "low"]].max(axis=1))
        | (df["low"] > df[["open", "close", "high"]].min(axis=1))
        | df[COLUMNS[1:]].isna().any(axis=1)
    )
    if bad.any():
        print(f"[data] membuang {int(bad.sum())} bar tidak konsisten (OHLC tidak valid/NaN).")
        df = df[~bad].reset_index(drop=True)
    if len(df) != n0:
        print(f"[data] {n0} baris -> {len(df)} baris setelah pembersihan.")
    return df


def timeframe_minutes(df: pd.DataFrame) -> int:
    return int(round(df["time"].diff().dt.total_seconds().median() / 60.0))


def make_synthetic(n: int = 40000, seed: int = 7, signal: float = 0.0, tf_minutes: int = 15,
                   start_price: float = 2000.0, spread: float = 0.20, sub: int = 6) -> pd.DataFrame:
    """Data OHLCV sintetis untuk MENGUJI pipeline — bukan untuk melatih model yang dipakai trading.

    signal = 0  -> random walk dengan volatility clustering. TIDAK ada yang bisa
                   diprediksi; model yang "menemukan edge" di sini berarti ada kebocoran.
    signal > 0  -> momentum tertanam (drift searah rata-rata 4 return terakhir);
                   model yang sehat harus bisa menemukannya.
    """
    rng = np.random.default_rng(seed)
    times = pd.date_range("2021-01-04", periods=int(n * 1.45) + 10, freq=f"{tf_minutes}min")
    times = times[times.day_of_week < 5][:n]
    minutes = (times.hour * 60 + times.minute).to_numpy()
    season = 1.0 + 0.5 * np.sin(2 * np.pi * (minutes - 420) / 1440.0)   # sesi ramai vs sepi

    base = 0.0007
    eps = rng.standard_normal(n)
    z = np.zeros(n)
    r = np.zeros(n)
    sig2 = np.full(n, base ** 2)
    omega, alpha, beta = 0.05 * base ** 2, 0.08, 0.87
    for t in range(n):
        if t > 0:
            sig2[t] = omega + alpha * (r[t - 1] / season[t - 1]) ** 2 + beta * sig2[t - 1]
        drift = signal * np.tanh(z[max(0, t - 4):t].mean()) if (signal and t >= 4) else 0.0
        z[t] = eps[t] + drift
        r[t] = np.sqrt(sig2[t]) * season[t] * z[t]

    sigma = np.sqrt(sig2) * season
    steps = rng.standard_normal((n, sub)) * (sigma / np.sqrt(sub))[:, None]
    steps += ((r - steps.sum(axis=1)) / sub)[:, None]          # jumlah sub-langkah = return bar
    path = np.cumsum(steps, axis=1)
    close = start_price * np.exp(np.cumsum(r))
    open_ = np.empty(n)
    open_[0] = start_price
    open_[1:] = close[:-1]
    high = np.maximum(open_ * np.exp(np.maximum(path.max(axis=1), 0.0)), np.maximum(open_, close))
    low = np.minimum(open_ * np.exp(np.minimum(path.min(axis=1), 0.0)), np.minimum(open_, close))
    vol = rng.poisson(200.0 * season * (sigma / (base * season)).clip(0.3, 5.0)).astype(float) + 1.0
    return clean(pd.DataFrame({"time": times, "open": open_, "high": high, "low": low,
                               "close": close, "tick_volume": vol, "spread": spread}))
