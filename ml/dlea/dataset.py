"""Windowing sekuens + split walk-forward kronologis dengan embargo."""
from __future__ import annotations

import keras
import numpy as np


def valid_window_ends(feats: np.ndarray, labels: np.ndarray | None, lookback: int) -> np.ndarray:
    """Indeks bar t di mana jendela [t-lookback+1 .. t] lengkap (dan label tersedia)."""
    row_ok = np.isfinite(feats).all(axis=1)
    bad_cum = np.concatenate([[0], np.cumsum(~row_ok)])
    t = np.arange(len(feats))
    start = t - lookback + 1
    ok = start >= 0
    ok[ok] &= (bad_cum[t[ok] + 1] - bad_cum[start[ok]]) == 0
    if labels is not None:
        ok &= labels >= 0
    return t[ok]


def walk_forward_splits(ends: np.ndarray, n_bars: int, folds: int, val_frac: float, test_frac: float,
                        embargo: int, horizon: int) -> list[dict]:
    """Walk-forward dengan jendela train yang melebar (expanding / anchored).

    `test_frac` terakhir dari data dibagi menjadi `folds` blok test berurutan.
    Untuk tiap blok:  [ train ........ ][embargo][ val ][embargo][ test ]
      train = semua bar sebelum blok validasi
      val   = `val_frac` data tepat sebelum blok test (early stopping + pilih threshold)
      test  = blok itu sendiri — tidak pernah dilihat model fold tersebut
    `embargo` bar dibuang di tiap batas supaya label (melihat `horizon` bar ke
    depan) tidak menyentuh periode berikutnya. folds=1 -> split tunggal biasa.
    """
    test_len = int(n_bars * test_frac / folds)
    val_len = int(n_bars * val_frac)
    out = []
    for k in range(folds):
        test_start = n_bars - (folds - k) * test_len
        test_end = n_bars if k == folds - 1 else test_start + test_len
        val_start = test_start - val_len
        out.append({
            "fold": k + 1, "val_start": val_start, "test_start": test_start, "test_end": test_end,
            "train": ends[ends < val_start - embargo],
            "val": ends[(ends >= val_start) & (ends < test_start - embargo)],
            # posisi dari sinyal test harus selesai di dalam blok (tidak menumpuk dengan fold berikutnya)
            "test": ends[(ends >= test_start) & (ends + horizon < test_end)],
        })
    return out


def refit_split(ends: np.ndarray, n_bars: int, val_frac: float, embargo: int) -> dict:
    """Split untuk model produksi: train = semua data kecuali `val_frac` terakhir (validasi)."""
    val_start = n_bars - int(n_bars * val_frac)
    return {"fold": "refit", "val_start": val_start, "test_start": n_bars, "test_end": n_bars,
            "train": ends[ends < val_start - embargo], "val": ends[ends >= val_start], "test": ends[:0]}


class WindowDataset(keras.utils.PyDataset):
    """Menghasilkan batch (X[b, lookback, F], y, bobot) tanpa menyalin semua jendela ke RAM."""

    def __init__(self, feats32: np.ndarray, ends: np.ndarray, labels: np.ndarray | None, lookback: int,
                 batch_size: int = 256, shuffle: bool = False, class_weight: np.ndarray | None = None,
                 seed: int = 0, **kwargs):
        super().__init__(**kwargs)
        self.feats = feats32
        self.ends = np.asarray(ends)
        self.labels = labels
        self.offsets = np.arange(-lookback + 1, 1)
        self.batch_size = batch_size
        self.shuffle = shuffle
        self.class_weight = class_weight
        self.rng = np.random.default_rng(seed)
        self.order = np.arange(len(self.ends))
        if shuffle:
            self.rng.shuffle(self.order)

    def __len__(self):
        return int(np.ceil(len(self.ends) / self.batch_size))

    def __getitem__(self, i):
        sel = self.ends[self.order[i * self.batch_size:(i + 1) * self.batch_size]]
        x = self.feats[sel[:, None] + self.offsets[None, :]]
        if self.labels is None:
            return (x,)
        y = self.labels[sel]
        if self.class_weight is None:
            return x, y
        return x, y, self.class_weight[y].astype("float32")

    def on_epoch_end(self):
        if self.shuffle:
            self.rng.shuffle(self.order)
