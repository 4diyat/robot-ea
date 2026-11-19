"""dlea — pipeline deep learning untuk DL_Signal_EA (MT5).

Alur: CSV OHLCV (MT5) -> fitur -> label triple-barrier -> model TensorFlow
-> evaluasi + backtest -> ekspor ONNX + preset .set untuk EA.
"""
