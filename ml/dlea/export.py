"""Ekspor model Keras -> ONNX (untuk OnnxCreate/OnnxRun di MQL5) + metadata + preset EA."""
from __future__ import annotations

import json
import os

import numpy as np

# Nilai ENUM_TIMEFRAMES MQL5 (untuk baris InpTimeframe di file .set)
MT5_TIMEFRAMES = {1: 1, 5: 5, 15: 15, 30: 30, 60: 16385, 240: 16388, 1440: 16408}


def export_onnx(model, path: str, lookback: int, n_features: int, sample: np.ndarray, opset: int = 13) -> float:
    """Ekspor dengan bentuk masukan TETAP [1, lookback, n_features] float32.

    Mengembalikan selisih absolut maksimum Keras vs ONNX Runtime pada `sample`.
    (Catatan: `model.export(format="onnx")` bawaan Keras 3.15 menjadikan konstanta
    layer Normalization sebagai input graf -> tidak bisa dipakai; tf2onnx benar.)
    """
    import onnxruntime as ort
    import tensorflow as tf
    import tf2onnx

    spec = (tf.TensorSpec((1, lookback, n_features), tf.float32, name="features"),)
    tf2onnx.convert.from_keras(model, input_signature=spec, opset=opset, output_path=path)

    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    inp, out = sess.get_inputs()[0], sess.get_outputs()[0]
    assert list(inp.shape) == [1, lookback, n_features], inp.shape
    assert list(out.shape) == [1, 3], out.shape
    ref = model.predict(sample, verbose=0)
    got = np.concatenate([sess.run(None, {inp.name: sample[i:i + 1]})[0] for i in range(len(sample))])
    return float(np.abs(ref - got).max())


def write_meta(path: str, meta: dict) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2, default=float)


def write_preset(path: str, *, model_file: str, tf_minutes: int | None, lookback: int, threshold: float,
                 margin: float, sl_atr: float, tp_atr: float, horizon: int, note: str) -> None:
    """Preset .set untuk DL_Signal_EA — hanya parameter yang HARUS sama dengan training."""
    lines = [
        f"; DL_Signal_EA — preset hasil training ({note})",
        "; Dibuat otomatis oleh ml/train.py. Parameter di bawah HARUS sama dengan saat training.",
        "",
        f"InpModelFile={os.path.basename(model_file)}",
    ]
    if tf_minutes in MT5_TIMEFRAMES:
        lines.append(f"InpTimeframe={MT5_TIMEFRAMES[tf_minutes]}")
    lines += [
        f"InpLookback={lookback}",
        f"InpProbThreshold={threshold:.2f}",
        f"InpProbMargin={margin:.2f}",
        f"InpSLAtr={sl_atr}",
        f"InpTPAtr={tp_atr}",
        f"InpMaxHoldBars={horizon}",
        "",
    ]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
