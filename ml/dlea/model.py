"""Arsitektur model (Keras / TensorFlow).

Masukan : tensor [batch, lookback, NUM_FEATURES] berisi fitur MENTAH
          (normalisasi z-score sudah ditanam di dalam graf model, jadi EA
          tidak perlu file scaler terpisah).
Keluaran: softmax 3 kelas -> [P(SELL), P(HOLD), P(BUY)].
"""
from __future__ import annotations

import keras
import numpy as np
from keras import layers, regularizers


def _head(x, dropout: float, l2: float):
    x = layers.Dense(32, activation="relu", kernel_regularizer=regularizers.l2(l2))(x)
    x = layers.Dropout(dropout)(x)
    return layers.Dense(3, activation="softmax", name="probs")(x)


def build_tcn(lookback: int, n_features: int, mean: np.ndarray, var: np.ndarray, filters: int = 32,
              kernel: int = 3, dilations=(1, 2, 4, 8), dropout: float = 0.2, l2: float = 1e-4) -> keras.Model:
    """Temporal Convolutional Network: blok residual konvolusi kausal ber-dilasi.

    Receptive field = 1 + 2*(kernel-1)*sum(dilations) = 61 bar untuk nilai default,
    kira-kira sama dengan lookback 64. Hanya memakai operator ONNX dasar
    (Conv/Relu/Add/MatMul/Softmax) -> paling aman & cepat dijalankan di MT5.
    """
    inp = keras.Input((lookback, n_features), name="features")
    x = layers.Normalization(axis=-1, mean=mean, variance=var, name="zscore")(inp)
    x = layers.Conv1D(filters, 1, name="proj")(x)
    for d in dilations:
        skip = x
        x = layers.Conv1D(filters, kernel, padding="causal", dilation_rate=d, activation="relu",
                          kernel_regularizer=regularizers.l2(l2))(x)
        x = layers.SpatialDropout1D(dropout)(x)
        x = layers.Conv1D(filters, kernel, padding="causal", dilation_rate=d, activation="relu",
                          kernel_regularizer=regularizers.l2(l2))(x)
        x = layers.SpatialDropout1D(dropout)(x)
        x = layers.Add()([skip, x])
    x = layers.Cropping1D((lookback - 1, 0), name="last_step")(x)   # ambil langkah waktu terakhir
    x = layers.Flatten()(x)
    return keras.Model(inp, _head(x, dropout, l2), name="dl_signal_tcn")


def build_cnn_lstm(lookback: int, n_features: int, mean: np.ndarray, var: np.ndarray, filters: int = 32,
                   units: int = 48, dropout: float = 0.2, l2: float = 1e-4) -> keras.Model:
    """Alternatif: Conv1D (pola lokal antar-bar) -> LSTM (ketergantungan urutan).

    Catatan ekspor: LSTM dikonversi menjadi operator ONNX `Loop`, tetap bisa
    dijalankan ONNX Runtime tetapi lebih lambat dan kurang portabel dibanding TCN.
    """
    inp = keras.Input((lookback, n_features), name="features")
    x = layers.Normalization(axis=-1, mean=mean, variance=var, name="zscore")(inp)
    x = layers.Conv1D(filters, 3, padding="causal", activation="relu",
                      kernel_regularizer=regularizers.l2(l2))(x)
    x = layers.SpatialDropout1D(dropout)(x)
    x = layers.LSTM(units, kernel_regularizer=regularizers.l2(l2))(x)
    x = layers.Dropout(dropout)(x)
    return keras.Model(inp, _head(x, dropout, l2), name="dl_signal_cnn_lstm")


BUILDERS = {"tcn": build_tcn, "cnn_lstm": build_cnn_lstm}
