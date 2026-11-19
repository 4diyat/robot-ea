//+------------------------------------------------------------------+
//| DL_Signal_EA — DLDefines.mqh                                    |
//| Konstanta bersama EA + script ekspor. TIDAK mereferensikan input |
//| sehingga aman di-include paling awal.                            |
//|                                                                  |
//| PENTING: nilai di bawah adalah cermin dari ml/dlea/features.py.  |
//| Mengubah salah satunya WAJIB diikuti perubahan di sisi lain +    |
//| menaikkan DL_FEATURE_VERSION + melatih ulang model.              |
//+------------------------------------------------------------------+
#ifndef DL_DEFINES_MQH
#define DL_DEFINES_MQH

#define DL_FEATURE_VERSION 1
#define DL_NUM_FEATURES    15    // jumlah fitur per bar (= len(FEATURE_NAMES))
#define DL_NUM_CLASSES     3     // keluaran softmax

#define DL_ATR_FAST        14
#define DL_ATR_SLOW        50
#define DL_SMA_FAST        20
#define DL_SMA_SLOW        50
#define DL_RSI_PERIOD      14
#define DL_RANGE_PERIOD    20
#define DL_VOL_PERIOD      20
#define DL_WARMUP          50    // bar tambahan di depan jendela untuk indikator terpanjang
#define DL_EPS             1e-12
#define DL_CLIP            10.0

//--- indeks kelas pada keluaran model: [P(SELL), P(HOLD), P(BUY)]
#define DL_CLASS_SELL      0
#define DL_CLASS_HOLD      1
#define DL_CLASS_BUY       2

//--- nama kolom fitur (urutan = urutan kolom tensor masukan)
#define DL_FEATURE_HEADER  "ret1,ret3,ret12,body,upper_wick,lower_wick,bar_range,sma_fast_dist,sma_slow_dist,rsi,range_pos,vol_rel,vol_regime,tod_sin,tod_cos"

enum ENUM_DL_SIGNAL
  {
   DL_SIGNAL_SELL = -1,
   DL_SIGNAL_NONE = 0,
   DL_SIGNAL_BUY  = 1
  };

#endif // DL_DEFINES_MQH
