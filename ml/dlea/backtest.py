"""Backtest berbasis bar yang meniru aturan eksekusi EA (satu posisi pada satu waktu).

Aturan (sama dengan DL_Signal_EA.mq5):
  * sinyal dihitung saat bar t close, entry di open bar t+1
  * SL = sl_atr x ATR_t, TP = tp_atr x ATR_t (dihitung dari harga entry)
  * keluar paksa setelah `horizon` bar (di close bar t+horizon)

Spread dimodelkan lewat harga, bukan sebagai potongan tetap (bar MT5 = BID):
  * long : beli di ASK = open + spread; SL/TP dipicu BID; keluar-waktu di BID
  * short: jual di BID = open; SL/TP dipicu ASK = bid + spread bar itu; keluar-waktu di ASK
  * `extra_cost` (komisi + slippage, satuan harga) dipotong tetap per trade

Asumsi pesimis:
  * SL dan TP tersentuh di bar yang sama -> SL dulu
  * bar dibuka melewati SL (gap) -> SL terisi di harga open (lebih buruk dari SL)
Hasil dalam kelipatan R (1R = jarak SL).
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from .labels import BUY, SELL


def probs_to_signal(probs: np.ndarray, threshold: float, margin: float) -> np.ndarray:
    """+1 = BUY, -1 = SELL, 0 = tidak ada sinyal. Aturan yang sama dipakai EA."""
    p_sell, p_buy = probs[:, SELL], probs[:, BUY]
    sig = np.zeros(len(probs), dtype=np.int8)
    sig[(p_buy >= threshold) & (p_buy - p_sell >= margin)] = 1
    sig[(p_sell >= threshold) & (p_sell - p_buy >= margin)] = -1
    return sig


COLUMNS = ["signal_bar", "entry_bar", "exit_bar", "dir", "entry", "exit", "reason", "r", "spread_r"]


def simulate(df: pd.DataFrame, atr: np.ndarray, signal_bars: np.ndarray, signals: np.ndarray,
             horizon: int, tp_atr: float, sl_atr: float, extra_cost: float = 0.0,
             last_bar: int | None = None) -> pd.DataFrame:
    """`last_bar`: posisi hanya dibuka bila seluruh masa tahannya selesai sebelum bar ini."""
    o, h, l, c = (df[k].to_numpy(float) for k in ("open", "high", "low", "close"))
    sp = df["spread"].to_numpy(float)
    stop = len(df) if last_bar is None else min(len(df), last_bar)
    rows = []
    flat_from = -1                       # bar sinyal paling awal yang boleh membuka posisi baru
    for t, d in zip(signal_bars, signals):
        if d == 0 or t < flat_from or t + horizon >= stop:
            continue
        a = atr[t]
        if not np.isfinite(a) or a <= 0:
            continue
        e, x = t + 1, t + horizon
        risk = sl_atr * a
        if d > 0:
            entry = o[e] + sp[e]                                   # beli di ask
            sl, tp = entry - risk, entry + tp_atr * a
            exit_bar, exit_px, reason = x, c[x], "time"            # jual di bid
            for j in range(e, x + 1):
                if l[j] <= sl:
                    exit_bar, exit_px, reason = j, min(sl, o[j]), "sl"
                    break
                if h[j] >= tp:
                    exit_bar, exit_px, reason = j, tp, "tp"
                    break
            pnl = exit_px - entry
        else:
            entry = o[e]                                           # jual di bid
            sl, tp = entry + risk, entry - tp_atr * a
            exit_bar, exit_px, reason = x, c[x] + sp[x], "time"    # beli kembali di ask
            for j in range(e, x + 1):
                if h[j] + sp[j] >= sl:
                    exit_bar, exit_px, reason = j, max(sl, o[j] + sp[j]), "sl"
                    break
                if l[j] + sp[j] <= tp:
                    exit_bar, exit_px, reason = j, tp, "tp"
                    break
            pnl = entry - exit_px
        rows.append((t, e, exit_bar, int(d), entry, exit_px, reason, (pnl - extra_cost) / risk, sp[e] / risk))
        flat_from = exit_bar
    return pd.DataFrame(rows, columns=COLUMNS)


def metrics(trades: pd.DataFrame) -> dict:
    if len(trades) == 0:
        return {"trades": 0, "win_rate": 0.0, "avg_r": 0.0, "total_r": 0.0, "profit_factor": 0.0,
                "max_dd_r": 0.0, "t_stat": 0.0, "avg_spread_r": 0.0}
    r = trades["r"].to_numpy()
    eq = np.cumsum(r)
    gross_win, gross_loss = r[r > 0].sum(), -r[r < 0].sum()
    sd = r.std(ddof=1) if len(r) > 1 else 0.0
    return {
        "trades": int(len(r)),
        "win_rate": float((r > 0).mean()),
        "avg_r": float(r.mean()),
        "total_r": float(r.sum()),
        "profit_factor": float(gross_win / gross_loss) if gross_loss > 0 else float("inf"),
        "max_dd_r": float((np.maximum.accumulate(np.maximum(eq, 0.0)) - eq).max()),
        "t_stat": float(r.mean() / (sd / np.sqrt(len(r)))) if sd > 0 else 0.0,
        "avg_spread_r": float(trades["spread_r"].mean()),
    }
