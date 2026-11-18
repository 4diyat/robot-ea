//+------------------------------------------------------------------+
//| DL_Signal_EA.mq5                                                 |
//| Expert Advisor MT5 berbasis deep learning (TensorFlow -> ONNX)   |
//|                                                                  |
//| Alur:                                                            |
//|   1) ml/train.py melatih model TensorFlow pada data historis dan |
//|      mengekspornya ke dl_signal_model.onnx + preset .set         |
//|   2) EA ini, tiap bar baru: hitung fitur dari bar close ->       |
//|      inferensi ONNX -> [P(SELL), P(HOLD), P(BUY)] -> sinyal ->   |
//|      order market dengan SL/TP berbasis ATR + keluar berbasis    |
//|      waktu (sama persis dengan aturan label & backtest training) |
//|                                                                  |
//| Modul (Include/DL_Signal_EA/):                                   |
//|   DLDefines.mqh       — konstanta fitur/kelas (cermin Python)    |
//|   DLFeatureEngine.mqh — fitur closed-bar (cermin features.py)    |
//|   DLModel.mqh         — pembungkus runtime ONNX                  |
//|   DLRisk.mqh          — sizing % risiko, batas harian, spread    |
//|   DLTrade.mqh         — eksekusi CTrade                          |
//|                                                                  |
//| SETUP WAJIB:                                                     |
//|   - Salin dl_signal_model.onnx ke <Data Folder>\MQL5\Files\      |
//|     (atau Common\Files + InpModelInCommonFolder=true).           |
//|   - Muat preset DL_Signal_EA.set hasil training: InpTimeframe,   |
//|     InpLookback, InpSLAtr, InpTPAtr, InpMaxHoldBars HARUS sama   |
//|     dengan nilai saat training.                                  |
//|   - Jalankan Scripts/DL_ExportHistory.mq5 + ml/check_parity.py   |
//|     untuk memastikan fitur MQL5 == fitur Python.                 |
//| Dokumentasi lengkap: docs/DL_Signal_EA.md                        |
//+------------------------------------------------------------------+
#property copyright   "DL Signal EA — TensorFlow/ONNX"
#property version     "1.00"
#property description "Deep learning EA: TCN/CNN-LSTM (TensorFlow) -> ONNX -> sinyal BUY/SELL per bar"
//--- agar Strategy Tester ikut menyalin model (nama default). Bila nama file diubah,
//    sesuaikan baris ini lalu compile ulang, atau pakai InpModelInCommonFolder=true.
#property tester_file "dl_signal_model.onnx"

#include <DL_Signal_EA\DLDefines.mqh>
#include <DL_Signal_EA\DLFeatureEngine.mqh>
#include <DL_Signal_EA\DLModel.mqh>
#include <DL_Signal_EA\DLRisk.mqh>
#include <DL_Signal_EA\DLTrade.mqh>

//===================================================================
// PARAMETER INPUT
//===================================================================
input group "=== Model (harus sama dengan training) ==="
input string          InpModelFile           = "dl_signal_model.onnx"; // File model ONNX di MQL5\Files
input bool            InpModelInCommonFolder = false;      // true = cari di Common\Files
input ENUM_TIMEFRAMES InpTimeframe           = PERIOD_M15; // Timeframe data training
input int             InpLookback            = 64;         // Panjang sekuens masukan (bar)

input group "=== Sinyal ==="
input double InpProbThreshold = 0.55;  // P(arah) minimum untuk entry
input double InpProbMargin    = 0.05;  // Selisih minimum P(arah) - P(lawan)

input group "=== Trade (harus sama dengan training) ==="
input double InpSLAtr           = 1.5;   // Stop loss (x ATR14 bar close terakhir)
input double InpTPAtr           = 1.5;   // Take profit (x ATR14 bar close terakhir)
input int    InpMaxHoldBars     = 8;     // Tutup paksa setelah N bar (= horizon label)
input bool   InpCloseOnOpposite = false; // Tutup posisi saat sinyal berlawanan (tidak ada di backtest Python)

input group "=== Risk ==="
input double InpRiskPercent         = 0.5;   // Risiko per trade (% balance)
input double InpMaxDailyLossPercent = 3.0;   // Stop entry baru bila rugi harian akun >= X% (0 = off)
input int    InpMaxTradesPerDay     = 10;    // Maksimum entry per hari (0 = tanpa batas)
input double InpMaxSpreadPctOfSL    = 10.0;  // Spread maksimum (% dari jarak SL; 0 = off)
input int    InpMaxSlippagePoints   = 30;    // Slippage maksimum (poin)

input group "=== General ==="
input long   InpMagicNumber = 20261113; // Magic number
input bool   InpShowPanel   = true;     // Tampilkan panel status (Comment)
input bool   InpVerboseLog  = true;     // Log probabilitas tiap bar

//===================================================================
// STATE
//===================================================================
CDLModel g_model;
CDLRisk  g_risk;
CDLTrade g_trade;

datetime g_lastBarTime = 0;      // waktu open bar berjalan yang terakhir diproses
double   g_probs[];              // [P(SELL), P(HOLD), P(BUY)] bar terakhir
double   g_atr         = 0.0;
int      g_signal      = DL_SIGNAL_NONE;
string   g_status      = "menunggu bar baru";

//+------------------------------------------------------------------+
//| Aturan sinyal — identik dengan ml/dlea/backtest.py::probs_to_signal |
//+------------------------------------------------------------------+
int DecideSignal(const double &probs[])
  {
   double pSell = probs[DL_CLASS_SELL];
   double pBuy  = probs[DL_CLASS_BUY];
   if(pBuy >= InpProbThreshold && pBuy - pSell >= InpProbMargin)
      return DL_SIGNAL_BUY;
   if(pSell >= InpProbThreshold && pSell - pBuy >= InpProbMargin)
      return DL_SIGNAL_SELL;
   return DL_SIGNAL_NONE;
  }
//+------------------------------------------------------------------+
//| Filter + eksekusi entry. Mengembalikan teks status untuk panel.  |
//+------------------------------------------------------------------+
string TryEntry()
  {
   if(g_signal == DL_SIGNAL_NONE)
      return "tidak ada sinyal";
   if(g_atr <= 0.0)
      return "ATR tidak valid";
   if(g_risk.DailyLossHit())
      return "batas rugi harian tercapai — entry diblokir";
   if(g_risk.MaxTradesReached())
      return "batas jumlah trade harian tercapai";

   double slDist = InpSLAtr * g_atr;
   double tpDist = InpTPAtr * g_atr;
   if(!g_risk.SpreadOk(slDist))
      return "spread terlalu lebar — entry dilewati";

   double lots = g_risk.LotsForRisk(slDist);
   if(lots <= 0.0)
      return "lot tidak valid untuk risiko ini — entry dilewati";

   bool   isBuy = (g_signal == DL_SIGNAL_BUY);
   string side  = isBuy ? "BUY" : "SELL";
   double pDir  = isBuy ? g_probs[DL_CLASS_BUY] : g_probs[DL_CLASS_SELL];
   if(!g_trade.Open(g_signal, lots, slDist, tpDist, StringFormat("DL %s p=%.2f", side, pDir)))
      return "order ditolak (lihat log)";
   return StringFormat("entry %s %.2f lot", side, lots);
  }
//+------------------------------------------------------------------+
//| Panel status sederhana                                           |
//+------------------------------------------------------------------+
void UpdatePanel()
  {
   if(!InpShowPanel)
      return;
   string sig = "-";
   if(g_signal == DL_SIGNAL_BUY)
      sig = "BUY";
   if(g_signal == DL_SIGNAL_SELL)
      sig = "SELL";
   string probs = "belum ada prediksi";
   if(ArraySize(g_probs) == DL_NUM_CLASSES)
      probs = StringFormat("P(SELL)=%.3f  P(HOLD)=%.3f  P(BUY)=%.3f",
                           g_probs[DL_CLASS_SELL], g_probs[DL_CLASS_HOLD], g_probs[DL_CLASS_BUY]);
   Comment(StringFormat("DL_Signal_EA v1.00 | %s %s | model %s\n%s\nSinyal: %s (thr %.2f, margin %.2f) | ATR %.5f\nP/L hari ini: %+.2f%% | entry hari ini: %d\nStatus: %s",
                        _Symbol, StringSubstr(EnumToString(InpTimeframe), 7), InpModelFile,
                        probs, sig, InpProbThreshold, InpProbMargin, g_atr,
                        g_risk.DailyPnLPercent(), g_risk.TradesToday(), g_status));
  }
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpLookback < 8 || InpSLAtr <= 0.0 || InpTPAtr <= 0.0 || InpMaxHoldBars < 1 ||
      InpProbThreshold <= 0.0 || InpProbThreshold > 1.0 || InpRiskPercent <= 0.0)
     {
      Print("[DL_Signal_EA] parameter input tidak valid");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!g_model.Init(InpModelFile, InpModelInCommonFolder, InpLookback))
      return INIT_FAILED;

   //--- uji jalan model dengan masukan nol: gagal di sini = model/bentuk tensor tidak cocok
   matrixf probe;
   probe.Init(InpLookback, DL_NUM_FEATURES);
   probe.Fill(0.0f);
   double p[];
   if(!g_model.Predict(probe, p))
     {
      Print("[DL_Signal_EA] uji inferensi gagal — periksa file model, InpLookback, dan versi fitur");
      return INIT_FAILED;
     }

   g_risk.Init(_Symbol, InpMagicNumber, InpRiskPercent, InpMaxDailyLossPercent,
               InpMaxTradesPerDay, InpMaxSpreadPctOfSL);
   g_trade.Init(_Symbol, InpMagicNumber, InpMaxSlippagePoints);

   //--- mulai dari bar BERIKUTNYA: tidak bertindak atas sinyal basi saat EA dipasang di tengah bar
   g_lastBarTime = iTime(_Symbol, InpTimeframe, 0);

   PrintFormat("[DL_Signal_EA] siap: model=%s lookback=%d fitur=%d (v%d) TF=%s SL=%.2fxATR TP=%.2fxATR hold=%d bar thr=%.2f",
               InpModelFile, InpLookback, DL_NUM_FEATURES, DL_FEATURE_VERSION,
               StringSubstr(EnumToString(InpTimeframe), 7), InpSLAtr, InpTPAtr, InpMaxHoldBars, InpProbThreshold);
   UpdatePanel();
   return INIT_SUCCEEDED;
  }
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_model.Release();
   if(InpShowPanel)
      Comment("");
  }
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- semua keputusan hanya sekali per bar, pada tick pertama bar baru
   datetime barTime = iTime(_Symbol, InpTimeframe, 0);
   if(barTime == 0 || barTime == g_lastBarTime)
      return;
   g_lastBarTime = barTime;

   g_risk.CheckNewDay();

   //--- 1) keluar berbasis waktu: posisi sudah ditahan >= InpMaxHoldBars bar
   ulong ticket = g_trade.FindPosition();
   if(ticket != 0)
     {
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      int barsHeld = iBarShift(_Symbol, InpTimeframe, openTime, false);
      if(barsHeld >= InpMaxHoldBars)
        {
         if(g_trade.Close(ticket, StringFormat("batas waktu %d bar", InpMaxHoldBars)))
            ticket = 0;
        }
     }

   //--- 2) fitur dari bar close -> inferensi
   matrixf  x;
   datetime featBarTime = 0;
   if(!DLBuildFeatureMatrix(_Symbol, InpTimeframe, InpLookback, x, g_atr, featBarTime))
     {
      g_signal = DL_SIGNAL_NONE;
      g_status = StringFormat("riwayat bar belum cukup (butuh %d bar)", InpLookback + DL_WARMUP);
      UpdatePanel();
      return;
     }
   if(!g_model.Predict(x, g_probs))
     {
      g_signal = DL_SIGNAL_NONE;
      g_status = "inferensi gagal";
      UpdatePanel();
      return;
     }
   g_signal = DecideSignal(g_probs);
   if(InpVerboseLog)
      PrintFormat("[DL_Signal_EA] bar %s | P(SELL)=%.3f P(HOLD)=%.3f P(BUY)=%.3f | ATR=%.5f | sinyal=%d",
                  TimeToString(featBarTime, TIME_DATE | TIME_MINUTES),
                  g_probs[DL_CLASS_SELL], g_probs[DL_CLASS_HOLD], g_probs[DL_CLASS_BUY], g_atr, g_signal);

   //--- 3) posisi masih terbuka: opsional tutup saat sinyal berlawanan
   if(ticket != 0)
     {
      long type = PositionSelectByTicket(ticket) ? PositionGetInteger(POSITION_TYPE) : -1;
      bool opposite = (type == POSITION_TYPE_BUY && g_signal == DL_SIGNAL_SELL) ||
                      (type == POSITION_TYPE_SELL && g_signal == DL_SIGNAL_BUY);
      if(InpCloseOnOpposite && opposite && g_trade.Close(ticket, "sinyal berlawanan"))
         ticket = 0;
     }
   if(ticket != 0)
     {
      g_status = "posisi terbuka — menunggu SL/TP/batas waktu";
      UpdatePanel();
      return;
     }

   //--- 4) entry baru (satu posisi pada satu waktu)
   g_status = TryEntry();
   UpdatePanel();
  }
//+------------------------------------------------------------------+
