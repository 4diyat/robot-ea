# DL_Signal_EA — Expert Advisor deep learning (TensorFlow → ONNX → MT5)

EA MT5 yang memprediksi pergerakan harga jangka pendek dengan model deep learning dan mengubahnya menjadi sinyal BUY/SELL. Model dilatih di Python dengan **TensorFlow**, diekspor ke **ONNX**, lalu dijalankan langsung di dalam EA oleh runtime ONNX bawaan MT5 — tanpa server Python, tanpa DLL.

> **Status verifikasi.** Pipeline Python sudah dijalankan ujung-ke-ujung (17 test lulus; training walk-forward, backtest, dan ekspor ONNX dicek). Kode MQL5 **belum di-compile** (tidak ada MetaEditor di lingkungan pembuatannya) dan **belum pernah dilatih pada data pasar nyata**. Belum ada bukti strategi ini menguntungkan — itu baru bisa dijawab setelah langkah 1–7 di bawah dijalankan pada data broker Anda.

## 1. Arsitektur

```
 MT5 (broker)                         Python / TensorFlow                         MT5 (EA)
┌──────────────────────┐   CSV    ┌────────────────────────────────┐   ONNX   ┌────────────────────────────┐
│ DL_ExportHistory.mq5 │ ───────► │ features.py   15 fitur/bar     │ ───────► │ DLFeatureEngine.mqh        │
│  OHLCV + spread      │          │ labels.py     triple-barrier   │  + .set  │   fitur yang SAMA          │
│  + fitur versi MQL5  │          │ model.py      TCN / CNN-LSTM   │          │ DLModel.mqh  OnnxRun       │
└──────────┬───────────┘          │ backtest.py   aturan = EA      │          │   [P(SELL),P(HOLD),P(BUY)] │
           │                      │ train.py      latih+uji+ekspor │          │ DLRisk / DLTrade           │
           │  fitur MQL5          └────────────────────────────────┘          │   SL/TP ATR, lot % risiko  │
           └────────────────────► check_parity.py (fitur MQL5 == Python?)     └────────────────────────────┘
```

| Komponen | File | Peran |
|---|---|---|
| Ekspor data | `Scripts/DL_ExportHistory.mq5` | OHLCV + spread → CSV; fitur versi MQL5 untuk uji paritas |
| Fitur | `ml/dlea/features.py` ↔ `Include/DL_Signal_EA/DLFeatureEngine.mqh` | 15 fitur per bar, definisi identik di dua bahasa |
| Label | `ml/dlea/labels.py` | Triple-barrier: SELL / HOLD / BUY |
| Model | `ml/dlea/model.py` | TCN (default) atau CNN-LSTM |
| Evaluasi | `ml/dlea/backtest.py`, `ml/dlea/dataset.py`, `ml/train.py` | Walk-forward, backtest dengan spread bid/ask, pemilihan threshold, syarat lulus |
| Ekspor | `ml/dlea/export.py` | ONNX opset 13 + `meta.json` + preset `.set` |
| EA | `DL_Signal_EA.mq5` + `Include/DL_Signal_EA/*.mqh` | Inferensi per bar, eksekusi, manajemen risiko |

### 1.1 Masukan model: 15 fitur × 64 bar

Tensor `[1, lookback=64, 15]`. Semua fitur dinormalisasi terhadap ATR sehingga stasioner dan tidak bergantung pada level harga:

| Kelompok | Fitur |
|---|---|
| Momentum | `ret1`, `ret3`, `ret12` — log-return 1/3/12 bar ÷ (ATR/close) |
| Bentuk candle | `body`, `upper_wick`, `lower_wick`, `bar_range` — ÷ ATR |
| Tren | `sma_fast_dist`, `sma_slow_dist` — jarak close ke SMA20/SMA50 ÷ ATR |
| Osilator | `rsi` (Cutler 14, skala −1…1), `range_pos` (posisi close di rentang 20 bar) |
| Volatilitas & aktivitas | `vol_regime` = ln(ATR14/ATR50), `vol_rel` = tick volume relatif 20 bar |
| Waktu | `tod_sin`, `tod_cos` — jam dalam hari (waktu server broker) |

Dua keputusan desain yang menentukan:

- **Hanya jendela terbatas** (SMA, jumlah sederhana) — tidak ada EMA/Wilder rekursif. Nilai fitur tidak bergantung pada panjang riwayat chart, sehingga bisa direplikasi persis di MQL5. Ketidakcocokan fitur training vs live adalah sumber kegagalan paling umum pada EA berbasis ML.
- **Normalisasi z-score ditanam di dalam model** (layer `Normalization` dengan statistik periode train). EA cukup mengirim fitur mentah; tidak ada file scaler yang bisa tertinggal atau salah versi.

### 1.2 Target: label triple-barrier

Keputusan diambil saat bar *t* close; entry di open bar *t+1*; SL = `sl_atr`×ATR, TP = `tp_atr`×ATR; batas tahan `horizon` bar.

- **BUY** — posisi long menyentuh TP sebelum SL dalam `horizon` bar
- **SELL** — posisi short menyentuh TP sebelum SL
- **HOLD** — tidak ada yang menang, atau ambigu (TP dan SL tersentuh di bar yang sama)

Label ini menjawab pertanyaan yang benar-benar dihadapi EA ("kalau masuk sekarang dengan SL/TP ini, arah mana yang menang?"), bukan sekadar "apakah close berikutnya naik". Default: `horizon=8`, `tp_atr=sl_atr=1.5` (M15 → prediksi ±2 jam).

**Spread ikut dihitung.** Bar MT5 adalah harga bid, sedangkan order long masuk di ask dan SL/TP posisi short dipicu oleh ask. Label dan backtest memakai geometri yang sama dengan EA:

| | Entry | SL/TP dipicu oleh | Keluar-waktu |
|---|---|---|---|
| Long | ask = open + spread | bid (high/low bar) | bid (close) |
| Short | bid = open | ask = high/low bar + spread | ask (close + spread) |

Akibatnya TP selalu sedikit lebih jauh dan SL sedikit lebih dekat daripada yang terlihat di chart. Sebuah bar yang "hampir" menyentuh TP tidak dilabeli menang.

### 1.3 Model

**TCN (default, disarankan)** — Temporal Convolutional Network, ±26 ribu parameter:

```
fitur [64×15] → z-score → Conv1D 1×1 (32)
  → 4 blok residual: [Conv1D kausal k=3, dilasi d] ×2 + SpatialDropout,  d = 1, 2, 4, 8
  → ambil langkah waktu terakhir → Dense 32 + Dropout → Softmax 3
```

Alasan memilih TCN ketimbang LSTM:

- Receptive field 61 bar (≈ lookback) dengan konvolusi **kausal** — bar *t* tidak pernah melihat bar sesudahnya.
- Diekspor menjadi operator ONNX dasar (Conv/Relu/Add/MatMul/Softmax). LSTM Keras diekspor sebagai operator `Loop`, yang lebih lambat dan kurang portabel.
- Sengaja kecil. Rasio sinyal/derau data harga sangat rendah; model besar hanya menghafal derau. Regularisasi: dropout 0.2, L2, early stopping, bobot kelas seimbang.

**CNN-LSTM (alternatif, `--arch cnn_lstm`)** — Conv1D(32) → LSTM(48) → Dense → Softmax. Ekspor ONNX-nya sudah diuji cocok dengan Keras, tetapi belum pernah dijalankan di MT5.

### 1.4 Dari probabilitas ke order

```
BUY  bila P(BUY)  ≥ threshold  dan  P(BUY)  − P(SELL) ≥ margin
SELL bila P(SELL) ≥ threshold  dan  P(SELL) − P(BUY)  ≥ margin
```

Aturan EA (identik dengan `backtest.py`, supaya hasil riset bisa dibandingkan dengan Strategy Tester):

- Keputusan sekali per bar pada tick pertama bar baru, hanya dari bar yang sudah close.
- Satu posisi pada satu waktu; SL/TP = kelipatan ATR14; tutup paksa setelah `InpMaxHoldBars` bar.
- Lot dihitung dari % risiko terhadap jarak SL. Bila lot minimum pun melebihi batas risiko, trade dilewati.

Pengaman tambahan yang **tidak** ada di backtest Python: batas rugi harian (tingkat akun), batas jumlah entry per hari, filter spread (% dari jarak SL), dan opsi tutup saat sinyal berlawanan (default mati).

## 2. Langkah penerapan

### Langkah 1 — Ekspor data historis dari MT5

1. Salin `Include/DL_Signal_EA/` → `<Data Folder>\MQL5\Include\`, `Scripts/DL_ExportHistory.mq5` → `MQL5\Scripts\`, `DL_Signal_EA.mq5` → `MQL5\Experts\`. Compile ketiganya (F7).
2. Naikkan *Tools → Options → Charts → Max bars in chart*, buka chart simbol/timeframe target (mis. XAUUSD M15), jalankan script `DL_ExportHistory`.
3. Hasil di `MQL5\Files\`: `XAUUSD_M15.csv` dan `XAUUSD_M15_features_mql5.csv`. Salin ke `ml/data/`.

Usahakan ≥ 50.000 bar (M15 ≈ 2 tahun). Latih pada data broker yang akan dipakai trading: fitur waktu memakai jam server, dan tick volume berbeda antar broker.

### Langkah 2 — Siapkan Python

```bash
cd ml
python -m venv .venv && source .venv/bin/activate    # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python -m pytest -q                                   # 17 test harus lulus
```

### Langkah 3 — Cek paritas fitur (wajib)

```bash
python check_parity.py --csv data/XAUUSD_M15.csv --features data/XAUUSD_M15_features_mql5.csv
```

Harus berakhir `PARITAS OK`. Bila ada fitur berstatus `BEDA`, model akan menerima masukan yang tidak pernah dilihatnya saat training — jangan lanjut sebelum diperbaiki.

### Langkah 4 — Latih dan evaluasi (walk-forward)

```bash
python train.py --csv data/XAUUSD_M15.csv --out artifacts/xauusd_m15 --extra-cost 0.10
```

`--extra-cost` = komisi + slippage per trade dalam satuan harga (angka `0.10` hanya contoh — isi sesuai broker Anda). Spread sudah dimodelkan dari kolom `spread` di CSV, tetapi spread per bar di riwayat MT5 cenderung lebih kecil daripada spread nyata saat pasar bergejolak, jadi sebaiknya `--extra-cost` tidak dibiarkan 0.

**Skema validasi.** 40% data terakhir (`--test-frac`) dibagi menjadi 4 blok test berurutan (`--folds`). Tiap blok diuji oleh model yang hanya dilatih pada data *sebelum* blok itu:

```
fold 1: [ train ................ ][ val ][ test 1 ]
fold 2: [ train ......................... ][ val ][ test 2 ]
fold 3: [ train .................................. ][ val ][ test 3 ]
fold 4: [ train ........................................... ][ val ][ test 4 ]
```

- **train** melebar tiap fold; statistik normalisasi dihitung ulang dari train fold itu saja.
- **val** (`--val-frac`, 10% data tepat sebelum blok test) dipakai untuk early stopping dan memilih `threshold` (t-stat rata-rata R tertinggi, dengan jumlah trade minimum).
- **test** tidak pernah dilihat model fold tersebut. Di tiap batas dibuang `horizon + lookback` bar (embargo) supaya label tidak menyentuh periode berikutnya.

Empat fold berarti empat kali training; pada uji saya (CPU 2 core, 40.000 bar, `--epochs 12`) butuh sekitar 7 menit. `--folds 1 --test-frac 0.15 --val-frac 0.15` memberi split tunggal yang lebih cepat untuk percobaan awal.

**Syarat lulus.** Kesimpulan "ada indikasi edge" hanya muncul bila keempatnya terpenuhi:

| Syarat | Alasan |
|---|---|
| Jumlah trade out-of-sample ≥ 25 × jumlah fold (minimum 50) | Sampel terlalu kecil tidak bisa disimpulkan |
| Rata-rata R gabungan > 0 setelah spread dan biaya | Expectancy positif per trade (1R = jarak SL) |
| t-stat gabungan ≥ 2 | Kemungkinan bukan kebetulan; syarat minimum, bukan jaminan |
| Validasi **dan** test sama-sama positif di ≥ ⅔ fold (3 dari 4) | Hasil harus konsisten antar periode, bukan ditopang satu periode bagus |

Yang tercetak: satu baris per fold, lalu `[4] GABUNGAN OUT-OF-SAMPLE`, lalu `[5] SYARAT LULUS` berupa daftar centang dan `KESIMPULAN`. Bila kesimpulannya `TIDAK ADA EDGE YANG TERBUKTI`, jangan dipakai live — ini hasil yang paling sering terjadi, dan itu wajar.

Log-loss per fold hanya informasi tambahan. Log-loss di bawah baseline **tidak** berarti model bisa menebak arah: pada data random walk pun log-loss turun, karena model bisa menebak kapan hasilnya HOLD (dari volatilitas) tanpa tahu arah. Yang menentukan adalah hasil backtest.

**Model yang diekspor.** Secara default yang diekspor adalah model fold terakhir. Model ini punya periode test sendiri (tercatat di `report.json` → `exported_model.test_period`), sehingga hasil Strategy Tester di periode itu bisa dibandingkan langsung dengan `oos_trades.csv`. Dengan `--refit`, setelah walk-forward selesai model dilatih ulang pada data terbaru (validasi = 10% terakhir) dan itulah yang diekspor. Model refit lebih mutakhir tetapi tidak punya periode test sendiri; perkiraan kinerjanya adalah hasil walk-forward.

Keluaran di folder `--out`:

| File | Isi |
|---|---|
| `dl_signal_model.onnx` | Model untuk MT5 |
| `DL_Signal_EA.set` | Preset EA sesuai model (lookback, threshold, SL/TP, horizon) |
| `report.json` | Hasil per fold, gabungan out-of-sample, syarat lulus, info model yang diekspor |
| `oos_trades.csv` | Semua trade out-of-sample (waktu entry/exit, arah, alasan keluar, R) |
| `meta.json`, `model.keras` | Metadata dan model Keras asli |

Parameter riset utama: `--horizon`, `--tp-atr`, `--sl-atr`, `--lookback`, `--arch`. Walk-forward tidak membuat tuning jadi aman: setiap kali Anda mengubah parameter lalu melihat hasil out-of-sample, hasil itu ikut "terpakai". Sisihkan periode terakhir yang benar-benar tidak pernah disentuh untuk pengujian akhir.

### Langkah 5 — Pasang model di MT5

1. Salin `artifacts/xauusd_m15/dl_signal_model.onnx` → `<Data Folder>\MQL5\Files\`.
2. Pasang `DL_Signal_EA` di chart, lalu **Load** preset `DL_Signal_EA.set` dari folder hasil training. Preset itu mengisi `InpTimeframe`, `InpLookback`, `InpProbThreshold`, `InpProbMargin`, `InpSLAtr`, `InpTPAtr`, `InpMaxHoldBars` — nilainya harus sama dengan saat training.
3. Saat start, EA menjalankan uji inferensi. Bila file model tidak ada atau bentuk tensor tidak cocok, EA menolak jalan (`INIT_FAILED`) dengan pesan di tab *Experts*.

### Langkah 6 — Strategy Tester

Pakai model fold terakhir (jalankan `train.py` tanpa `--refit`) dan uji pada periode `exported_model.test_period` di `report.json` — bukan periode train, karena di sana hasilnya pasti terlihat bagus. Mode *Every tick based on real ticks*. Bandingkan jumlah trade, win rate, dan expectancy dengan baris fold terakhir di `oos_trades.csv`. Selisih kecil wajar (Python memakai bar, tester memakai tick); selisih besar berarti ada ketidakcocokan yang harus dicari dulu.

EA mendeklarasikan `#property tester_file "dl_signal_model.onnx"` agar tester ikut menyalin model. Bila nama file diganti, sesuaikan baris itu lalu compile ulang, atau taruh model di `Common\Files` dan set `InpModelInCommonFolder=true`.

### Langkah 7 — Demo, lalu live

Jalankan di akun demo minimal 1–2 bulan dengan `InpRiskPercent` kecil. Pantau log probabilitas per bar (`InpVerboseLog`) dan bandingkan dengan distribusi di data test.

### Langkah 8 — Latih ulang berkala

Pasar berubah. Ulangi langkah 1, 3, 4 secara berkala (mis. tiap bulan) dengan data terbaru, dan hanya ganti model bila walk-forward barunya lulus. Untuk model yang dipasang live, tambahkan `--refit` supaya data paling baru ikut dipakai melatih.

## 3. Yang sudah diverifikasi

Dijalankan dengan TensorFlow 2.21, Keras 3.15, tf2onnx 1.17, ONNX Runtime 1.31 (Python 3.11):

| Pemeriksaan | Hasil |
|---|---|
| `pytest` (17 test) | Lulus: fitur = implementasi referensi baris-per-baris; tanpa lookahead; fitur tidak bergantung panjang riwayat; label termasuk geometri spread; backtest long/short dengan bid/ask, gap, dan biaya; split walk-forward tanpa tumpang-tindih label; syarat lulus; round-trip ONNX kedua arsitektur; konstanta `DLDefines.mqh` = `features.py` |
| Ekspor ONNX | Selisih maksimum Keras vs ONNX Runtime ≈ 1e-7; masukan `[1,64,15]`, keluaran `[1,3]` |
| Data sintetis **random walk** (40.000 bar, 4 fold) | Tidak lulus, sebagaimana mestinya: 359 trade, −0,035R/trade, t-stat −0,67; 0 dari 4 fold konsisten → pipeline tidak membocorkan masa depan |
| Data sintetis dengan **momentum tertanam** (40.000 bar, 4 fold) | Lulus keempat syarat: 2.852 trade, +0,307R/trade, t-stat +17,8; 4 dari 4 fold konsisten → pipeline mampu belajar bila sinyal memang ada |

Dua baris terakhir menguji **pipeline**, bukan pasar. Angkanya tidak mengatakan apa pun tentang hasil pada XAUUSD atau instrumen nyata lain.

## 4. Keterbatasan

- **MQL5 belum di-compile dan belum dijalankan.** Logika fiturnya ditulis sebagai cermin dari implementasi referensi Python yang sudah diuji, tetapi kesalahan sintaks atau perbedaan perilaku API baru ketahuan saat compile dan `check_parity.py`.
- **Backtest Python berbasis bar.** Urutan SL/TP dalam satu bar tidak diketahui (diasumsikan SL dulu), dan spread yang dipakai adalah satu nilai per bar dari riwayat MT5, bukan spread tiap tick. Strategy Tester dengan real ticks adalah acuan akhirnya.
- **Probabilitas tidak terkalibrasi.** Bobot kelas seimbang menggeser keluaran softmax; `threshold` adalah ambang empiris hasil validasi, bukan "peluang menang 55%".
- **Walk-forward menguji resepnya, bukan menjamin modelnya.** Model yang diekspor dengan `--refit` tidak pernah diuji out-of-sample. Jendela train selalu melebar (tidak ada opsi jendela bergeser yang membuang data lama).
- **Batas rugi harian** memakai equity seluruh akun, dan basisnya adalah balance saat EA dipasang bila dipasang di tengah hari.
- Model hanya melihat harga dan tick volume satu simbol/satu timeframe; tidak ada berita, order flow, atau korelasi antar-instrumen.

## 5. Mengubah fitur

Setiap perubahan fitur harus dilakukan di **tiga** tempat sekaligus, lalu model dilatih ulang:

1. `ml/dlea/features.py` (`compute_features`, `FEATURE_NAMES`, naikkan `FEATURE_VERSION`)
2. `ml/tests/test_pipeline.py::feature_row_reference`
3. `Include/DL_Signal_EA/DLDefines.mqh` + `DLFeatureEngine.mqh::DLComputeFeatureRow`

`pytest` memeriksa (1) vs (2) dan konstanta (3); `check_parity.py` memeriksa (1) vs perhitungan MQL5 yang sebenarnya.

---

**Disclaimer:** EA ini alat riset, bukan jaminan profit. Sebagian besar model prediksi harga jangka pendek tidak bertahan setelah biaya transaksi diperhitungkan. Jangan memakai dana nyata sebelum model lulus uji out-of-sample, Strategy Tester, dan periode demo.
