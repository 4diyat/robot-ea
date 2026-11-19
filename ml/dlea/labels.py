"""Label triple-barrier (Lopez de Prado) — diselaraskan dengan cara EA trading.

Keputusan diambil saat bar t close; EA masuk di open bar t+1 dengan
SL = sl_atr x ATR_t dan TP = tp_atr x ATR_t, lalu keluar paksa setelah
`horizon` bar. Label menjawab: "kalau masuk sekarang, arah mana yang menang?"

  BUY  (2): posisi long menyentuh TP sebelum SL dalam `horizon` bar
  SELL (0): posisi short menyentuh TP sebelum SL dalam `horizon` bar
  HOLD (1): tidak ada yang menang (timeout) atau ambigu (TP & SL di bar yang sama)
  -1      : label tidak tersedia (ATR belum valid / data masa depan kurang)

Geometri spread (bar MT5 = harga BID), sama dengan backtest.py dan EA:
  long : beli di ASK (= open + spread); SL/TP dipicu saat BID menyentuhnya
  short: jual di BID (= open);          SL/TP dipicu saat ASK (= bid + spread) menyentuhnya
Akibatnya TP selalu sedikit lebih jauh dan SL sedikit lebih dekat daripada
yang terlihat di chart bid — label ikut memperhitungkannya.
"""
from __future__ import annotations

import numpy as np

SELL, HOLD, BUY = 0, 1, 2
CLASS_NAMES = ["SELL", "HOLD", "BUY"]


def _first_touch(high, low, start, upper, lower, horizon):
    """+1 jika `upper` tersentuh lebih dulu, -1 jika `lower`, 0 jika tidak ada/ambigu."""
    n = len(high)
    res = np.zeros(n, dtype=np.int8)
    done = np.zeros(n, dtype=bool)
    for k in range(horizon):
        j = start + k
        ok = (j < n) & ~done
        jj = np.where(ok, j, 0)
        up = ok & (high[jj] >= upper)
        dn = ok & (low[jj] <= lower)
        res[up & ~dn] = 1
        res[dn & ~up] = -1
        done |= up | dn          # up & dn bersamaan -> ambigu -> tetap 0
    return res


def triple_barrier_labels(open_, high, low, atr, horizon: int, tp_atr: float, sl_atr: float,
                          spread=None) -> np.ndarray:
    """`spread` = spread per bar dalam satuan harga (None = 0)."""
    open_ = np.asarray(open_, float)
    high = np.asarray(high, float)
    low = np.asarray(low, float)
    atr = np.asarray(atr, float)
    n = len(open_)
    sp = np.zeros(n) if spread is None else np.asarray(spread, float)
    t = np.arange(n)
    start = t + 1                                   # bar entry
    valid = (t + horizon < n) & np.isfinite(atr) & (atr > 0)
    e = np.minimum(start, n - 1)
    bid_entry = np.where(valid, open_[e], np.nan)
    ask_entry = bid_entry + sp[e]
    a = np.where(valid, atr, np.nan)

    with np.errstate(invalid="ignore"):
        # long: entry di ask, barrier dibandingkan dengan high/low BID
        long_res = _first_touch(high, low, start, ask_entry + tp_atr * a, ask_entry - sl_atr * a, horizon)
        # short: entry di bid, barrier dibandingkan dengan high/low ASK
        short_res = _first_touch(high + sp, low + sp, start, bid_entry + sl_atr * a, bid_entry - tp_atr * a,
                                 horizon)

    long_win = long_res == 1
    short_win = short_res == -1
    y = np.full(n, HOLD, dtype=np.int64)
    y[long_win & ~short_win] = BUY
    y[short_win & ~long_win] = SELL
    y[~valid] = -1
    return y
