//+------------------------------------------------------------------+
//| DL_ExportHistory.mq5 (Script)                                    |
//| Ekspor data historis untuk training DL_Signal_EA.                |
//|                                                                  |
//| Menulis ke <Data Folder>\MQL5\Files\:                            |
//|   <SYMBOL>_<TF>.csv                                              |
//|       time,open,high,low,close,tick_volume,spread                |
//|       (spread dalam satuan HARGA = spread poin x _Point)         |
//|   <SYMBOL>_<TF>_features_mql5.csv   (bila InpExportFeatures)     |
//|       fitur yang dihitung DLFeatureEngine.mqh untuk N bar        |
//|       terakhir — dibandingkan dengan Python oleh                 |
//|       ml/check_parity.py                                         |
//|                                                                  |
//| Hanya bar yang sudah close yang diekspor (bar berjalan dibuang). |
//| Jumlah bar dibatasi "Max bars in chart" (Tools -> Options ->     |
//| Charts) dan riwayat yang tersedia di broker.                     |
//+------------------------------------------------------------------+
#property copyright "DL Signal EA — TensorFlow/ONNX"
#property version   "1.00"
#property script_show_inputs

#include <DL_Signal_EA\DLDefines.mqh>
#include <DL_Signal_EA\DLFeatureEngine.mqh>

input int             InpBars           = 100000;         // Jumlah bar close yang diekspor
input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_CURRENT; // Timeframe
input bool            InpExportFeatures = true;           // Ekspor juga fitur MQL5 (uji paritas)
input int             InpFeatureRows    = 2000;           // Jumlah bar terakhir untuk file fitur

//+------------------------------------------------------------------+
void OnStart()
  {
   ENUM_TIMEFRAMES tf = (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTimeframe;
   string tfName = StringSubstr(EnumToString(tf), 7);          // "PERIOD_M15" -> "M15"
   string base   = _Symbol + "_" + tfName;

   MqlRates rates[];
   ArraySetAsSeries(rates, false);                              // indeks 0 = bar tertua
   int copied = CopyRates(_Symbol, tf, 1, InpBars, rates);      // shift 1 -> tanpa bar berjalan
   if(copied <= DL_WARMUP)
     {
      PrintFormat("[DL_Export] CopyRates gagal/kurang data (copied=%d, error %d)", copied, GetLastError());
      return;
     }

   //--- 1) OHLCV
   string fileName = base + ".csv";
   int fh = FileOpen(fileName, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE)
     {
      PrintFormat("[DL_Export] gagal membuka %s (error %d)", fileName, GetLastError());
      return;
     }
   FileWrite(fh, "time,open,high,low,close,tick_volume,spread");
   for(int i = 0; i < copied; i++)
     {
      FileWrite(fh, StringFormat("%s,%s,%s,%s,%s,%I64d,%s",
                                 TimeToString(rates[i].time, TIME_DATE | TIME_MINUTES),
                                 DoubleToString(rates[i].open, _Digits),
                                 DoubleToString(rates[i].high, _Digits),
                                 DoubleToString(rates[i].low, _Digits),
                                 DoubleToString(rates[i].close, _Digits),
                                 rates[i].tick_volume,
                                 DoubleToString(rates[i].spread * _Point, _Digits)));
     }
   FileClose(fh);
   PrintFormat("[DL_Export] %d bar (%s -> %s) ditulis ke MQL5\\Files\\%s", copied,
               TimeToString(rates[0].time), TimeToString(rates[copied - 1].time), fileName);

   //--- 2) fitur versi MQL5 untuk uji paritas
   if(!InpExportFeatures)
      return;
   string featName = base + "_features_mql5.csv";
   fh = FileOpen(featName, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE)
     {
      PrintFormat("[DL_Export] gagal membuka %s (error %d)", featName, GetLastError());
      return;
     }
   FileWrite(fh, "time," + DL_FEATURE_HEADER);
   int first = MathMax(DL_WARMUP, copied - InpFeatureRows);
   int rows  = 0;
   double f[];
   ArrayResize(f, DL_NUM_FEATURES);
   for(int i = first; i < copied; i++)
     {
      if(!DLComputeFeatureRow(rates, i, f))
         continue;
      string line = TimeToString(rates[i].time, TIME_DATE | TIME_MINUTES);
      for(int j = 0; j < DL_NUM_FEATURES; j++)
         line += "," + DoubleToString(f[j], 10);
      FileWrite(fh, line);
      rows++;
     }
   FileClose(fh);
   PrintFormat("[DL_Export] %d baris fitur (versi %d) ditulis ke MQL5\\Files\\%s", rows, DL_FEATURE_VERSION, featName);
  }
//+------------------------------------------------------------------+
