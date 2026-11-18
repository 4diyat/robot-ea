//+------------------------------------------------------------------+
//| DL_Signal_EA — DLFeatureEngine.mqh                              |
//| Menghitung fitur model dari bar yang SUDAH CLOSE (shift >= 1).   |
//|                                                                  |
//| Cermin baris-demi-baris dari:                                    |
//|   ml/dlea/features.py::compute_features                          |
//|   ml/tests/test_pipeline.py::feature_row_reference               |
//| Semua fitur memakai jendela terbatas (tanpa EMA/Wilder rekursif) |
//| sehingga hasilnya tidak bergantung pada panjang riwayat chart.   |
//| Verifikasi: Scripts/DL_ExportHistory.mq5 + ml/check_parity.py.   |
//|                                                                  |
//| Dipakai oleh EA dan script ekspor — tidak mereferensikan input.  |
//+------------------------------------------------------------------+
#ifndef DL_FEATURE_ENGINE_MQH
#define DL_FEATURE_ENGINE_MQH

#include <DL_Signal_EA\DLDefines.mqh>

//+------------------------------------------------------------------+
//| Batasi nilai ke [-DL_CLIP, DL_CLIP]; NaN/Inf -> 0                |
//+------------------------------------------------------------------+
double DLClip(const double v)
  {
   if(!MathIsValidNumber(v))
      return 0.0;
   if(v > DL_CLIP)
      return DL_CLIP;
   if(v < -DL_CLIP)
      return -DL_CLIP;
   return v;
  }
//+------------------------------------------------------------------+
//| ATR = rata-rata SEDERHANA true range `period` bar yang berakhir  |
//| di indeks i. rates[] kronologis (indeks 0 = bar tertua).         |
//| Syarat: i - period >= 0.                                         |
//+------------------------------------------------------------------+
double DLAtr(const MqlRates &rates[], const int i, const int period)
  {
   double sum = 0.0;
   for(int j = i - period + 1; j <= i; j++)
     {
      double pc = rates[j - 1].close;
      double tr = MathMax(rates[j].high - rates[j].low,
                          MathMax(MathAbs(rates[j].high - pc), MathAbs(rates[j].low - pc)));
      sum += tr;
     }
   return sum / period;
  }
//+------------------------------------------------------------------+
//| Hitung DL_NUM_FEATURES fitur untuk bar indeks i (i >= DL_WARMUP). |
//| rates[] kronologis (indeks 0 = bar tertua).                      |
//+------------------------------------------------------------------+
bool DLComputeFeatureRow(const MqlRates &rates[], const int i, double &f[])
  {
   if(i < DL_WARMUP || i >= ArraySize(rates))
      return false;
   if(ArraySize(f) < DL_NUM_FEATURES)
      ArrayResize(f, DL_NUM_FEATURES);

   double o = rates[i].open;
   double h = rates[i].high;
   double l = rates[i].low;
   double c = rates[i].close;
   if(c <= 0.0 || rates[i - 1].close <= 0.0 || rates[i - 3].close <= 0.0 || rates[i - 12].close <= 0.0)
      return false;

   double atrFast = DLAtr(rates, i, DL_ATR_FAST);
   double atrSlow = DLAtr(rates, i, DL_ATR_SLOW);
   double atr     = MathMax(atrFast, DL_EPS);
   double atrPct  = MathMax(atrFast / c, DL_EPS);

   //--- SMA close
   double smaFast = 0.0, smaSlow = 0.0;
   for(int j = i - DL_SMA_FAST + 1; j <= i; j++)
      smaFast += rates[j].close;
   smaFast /= DL_SMA_FAST;
   for(int j = i - DL_SMA_SLOW + 1; j <= i; j++)
      smaSlow += rates[j].close;
   smaSlow /= DL_SMA_SLOW;

   //--- RSI Cutler (jumlah sederhana kenaikan/penurunan), diskalakan ke [-1, 1]
   double gain = 0.0, loss = 0.0;
   for(int j = i - DL_RSI_PERIOD + 1; j <= i; j++)
     {
      double d = rates[j].close - rates[j - 1].close;
      if(d > 0.0)
         gain += d;
      else
         loss -= d;
     }
   double rsi = (gain + loss > 0.0) ? 2.0 * gain / (gain + loss) - 1.0 : 0.0;

   //--- posisi close dalam rentang high-low
   double hh = rates[i].high, ll = rates[i].low;
   for(int j = i - DL_RANGE_PERIOD + 1; j <= i; j++)
     {
      if(rates[j].high > hh)
         hh = rates[j].high;
      if(rates[j].low < ll)
         ll = rates[j].low;
     }
   double rangePos = (hh - ll > 0.0) ? 2.0 * (c - ll) / (hh - ll) - 1.0 : 0.0;

   //--- tick volume relatif
   double volMean = 0.0;
   for(int j = i - DL_VOL_PERIOD + 1; j <= i; j++)
      volMean += (double)rates[j].tick_volume;
   volMean /= DL_VOL_PERIOD;

   //--- waktu dalam hari (waktu server broker, dari waktu OPEN bar)
   MqlDateTime dt;
   TimeToStruct(rates[i].time, dt);
   double ang = 2.0 * M_PI * (double)(dt.hour * 60 + dt.min) / 1440.0;

   f[0]  = DLClip(MathLog(c / rates[i - 1].close) / atrPct);          // ret1
   f[1]  = DLClip(MathLog(c / rates[i - 3].close) / atrPct);          // ret3
   f[2]  = DLClip(MathLog(c / rates[i - 12].close) / atrPct);         // ret12
   f[3]  = DLClip((c - o) / atr);                                     // body
   f[4]  = DLClip((h - MathMax(o, c)) / atr);                         // upper_wick
   f[5]  = DLClip((MathMin(o, c) - l) / atr);                         // lower_wick
   f[6]  = DLClip((h - l) / atr);                                     // bar_range
   f[7]  = DLClip((c - smaFast) / atr);                               // sma_fast_dist
   f[8]  = DLClip((c - smaSlow) / atr);                               // sma_slow_dist
   f[9]  = DLClip(rsi);                                               // rsi
   f[10] = DLClip(rangePos);                                          // range_pos
   f[11] = DLClip(MathLog(((double)rates[i].tick_volume + 1.0) / (volMean + 1.0))); // vol_rel
   f[12] = DLClip(MathLog(MathMax(atrFast, DL_EPS) / MathMax(atrSlow, DL_EPS)));    // vol_regime
   f[13] = DLClip(MathSin(ang));                                      // tod_sin
   f[14] = DLClip(MathCos(ang));                                      // tod_cos
   return true;
  }
//+------------------------------------------------------------------+
//| Bangun tensor masukan model dari `lookback` bar close terakhir.  |
//|   x          : matriks [lookback x DL_NUM_FEATURES], baris 0 =   |
//|                bar tertua, baris terakhir = bar close terbaru    |
//|   atrLast    : ATR(DL_ATR_FAST) pada bar close terbaru (untuk    |
//|                SL/TP — definisi sama dengan label training)      |
//|   lastBarTime: waktu open bar close terbaru                      |
//+------------------------------------------------------------------+
bool DLBuildFeatureMatrix(const string symbol, const ENUM_TIMEFRAMES tf, const int lookback,
                          matrixf &x, double &atrLast, datetime &lastBarTime)
  {
   int need = lookback + DL_WARMUP;
   MqlRates rates[];
   ArraySetAsSeries(rates, false);                   // indeks 0 = tertua
   int copied = CopyRates(symbol, tf, 1, need, rates); // mulai shift 1 -> bar berjalan TIDAK ikut
   if(copied != need)
      return false;

   if(!x.Resize(lookback, DL_NUM_FEATURES))
      return false;

   double f[];
   ArrayResize(f, DL_NUM_FEATURES);
   for(int k = 0; k < lookback; k++)
     {
      if(!DLComputeFeatureRow(rates, DL_WARMUP + k, f))
         return false;
      for(int j = 0; j < DL_NUM_FEATURES; j++)
         x[k][j] = (float)f[j];
     }
   atrLast     = DLAtr(rates, need - 1, DL_ATR_FAST);
   lastBarTime = rates[need - 1].time;
   return true;
  }

#endif // DL_FEATURE_ENGINE_MQH
