//+------------------------------------------------------------------+
//| ORB_SMC_NextGen.mq5                                             |
//| Expert Advisor: ORB (Opening Range Breakout) + Smart Money       |
//| Concepts (SMC/ICT) — build baru dari nol, arsitektur modular.    |
//|                                                                  |
//| ARSITEKTUR (folder Include\ORB_SMC_NextGen\):                    |
//|   Defines             — enum, konstanta, prefix, palet warna,    |
//|                         struct bersama, helper pip multi-pair    |
//|   Helpers             — EAMagic + ATR (butuh input → include     |
//|                         setelah blok input)                      |
//|   SessionManager      — deteksi sesi (broker time + GMT offset), |
//|                         OR per sesi (Asia/London/NY TERPISAH),   |
//|                         reset hari trading baru                  |
//|   ORBDetector         — validasi breakout (body close vs wick,   |
//|                         min range size, false-breakout filter)   |
//|   SMCEngine           — BOS/CHoCH, swing, liquidity pools, OB,   |
//|                         FVG (semua closed-bar based)             |
//|   ConfluenceValidator — skor confluence + gate tunggal entry     |
//|   RiskManager         — sizing % risiko, SL struktur, TP multi-  |
//|                         level, max daily loss/trades             |
//|   TradeExecutor       — CTrade, retry, 2 mode entry, expiry      |
//|                         berbasis bar, force-close per sesi       |
//|   VisualRenderer      — semua elemen chart + cleanup prefix      |
//|   NewsFilter          — kalender investing.com via WebRequest    |
//|   Dashboard           — panel info on-chart                      |
//|                                                                  |
//| CATATAN SETUP WAJIB:                                             |
//|  - NewsFilter memakai WebRequest() ke https://sslecal2.investing.com/ |
//|    → tambahkan URL tsb ke Tools → Options → Expert Advisors →    |
//|    "Allow WebRequest for listed URL". Tanpa itu fetch gagal      |
//|    (fail-safe: EA tetap jalan, filter news nonaktif).            |
//|  - InpGMTOffset = offset jam broker terhadap UTC (musim dingin). |
//|  - Waktu sesi diinput dalam UTC (Asia 00-06, London 08-16,       |
//|    NY 13-21) — EA mengonversi ke waktu broker via InpGMTOffset.  |
//+------------------------------------------------------------------+
#property copyright   "ORB SMC NextGen — modular build"
#property version     "1.00"
#property description "ORB + SMC modular EA | Retest entry | Multi-pair | Session force-close"

//--- Tipe & konstanta inti (TIDAK mereferensikan input — aman di-include paling awal)
#include <ORB_SMC_NextGen\Defines.mqh>

//===================================================================
// PARAMETER INPUT (grup rapi — WAJIB di atas include lain karena
// modul di bawah mereferensikan input ini)
//===================================================================
//--- Session Settings ---
input group "=== Session Settings (jam UTC) ==="
input bool   InpEnableAsia   = true;   // Aktifkan sesi Asia (00:00-06:00 UTC)
input int    InpAsiaStart    = 0;      // Jam mulai Asia (UTC)
input int    InpAsiaEnd      = 6;      // Jam selesai Asia (UTC)
input bool   InpEnableLondon = true;   // Aktifkan sesi London (08:00-16:00 UTC)
input int    InpLondonStart  = 8;      // Jam mulai London (UTC)
input int    InpLondonEnd    = 16;     // Jam selesai London (UTC)
input bool   InpEnableNY     = true;   // Aktifkan sesi New York (13:00-21:00 UTC)
input int    InpNYStart      = 13;     // Jam mulai New York (UTC)
input int    InpNYEnd        = 21;     // Jam selesai New York (UTC)
input int    InpGMTOffset    = 2;      // Offset broker → UTC (jam; +2 = broker UTC+2)

//--- ORB Settings ---
input group "=== ORB Settings ==="
input int    InpRangeMinutes          = 30;    // Durasi Opening Range (menit pertama sesi)
input double InpMinRangePips          = 0.0;   // Ukuran minimum OR (pip; 0 = off)
input double InpBreakoutBufferPips    = 0.0;   // Buffer konfirmasi breakout (pip di luar level OR)
input int    InpBreakoutConfirmBars   = 1;     // Bar closed di luar OR utk konfirmasi (1 = body close)
input bool   InpRequireBodyClose      = true;  // Wajib body-close menembus OR (wick-only = tunggu)

//--- SMC Settings ---
input group "=== SMC Settings ==="
input int    InpSwingLookback          = 5;     // Lookback kiri/kanan konfirmasi swing
input bool   InpRequireLiquiditySweep  = true;  // Wajib liquidity sweep sebelum entry
input bool   InpRequireFVGRetest       = true;  // Wajib retest OB/FVG — TIDAK ada entry langsung saat breakout
input int    InpRetestMaxBars          = 10;    // Batas bar menunggu retest sebelum setup invalid
input double InpMaxExtensionBeforeRetest = 50.0; // Ekstensi maksimum (% dari OR) sebelum retest invalid
input double InpLiqTolerancePips       = 2.0;   // Toleransi equal highs/lows (pip)
input bool   InpUseFVGAsRetest        = true;  // FVG boleh jadi zona retest bila OB tidak tersedia
input double InpSLBufferATR           = 0.2;   // Buffer SL melampaui struktur (× ATR)
input int    InpATRPeriod             = 14;    // Periode ATR (SL buffer, ukuran volatilitas)

//--- Entry Mode ---
input group "=== Entry Mode ==="
input ENUM_ENTRY_MODE InpEntryMode = ENTRY_PENDING_ORDER; // Eksekusi: market setelah reaksi retest | Pending: limit di zona OB/FVG

//--- Risk Settings ---
input group "=== Risk Settings ==="
input double InpRiskPercent           = 1.0;    // Risiko per trade (% equity/balance)
input ENUM_RISK_BASE InpRiskBase      = RISK_BASE_BALANCE; // Basis risiko: Balance / Equity
input double InpMinRR                 = 2.0;    // Risk:Reward minimum (terhadap TP akhir)
input double InpTP1RR                 = 1.0;    // RR TP1 (partial close; 0 = nonaktif)
input double InpPartialClosePct       = 50.0;   // % posisi ditutup di TP1
input bool   InpTrailAfterTP1         = true;   // Aktifkan trailing struktur setelah TP1
input int    InpMaxTradesPerDay       = 3;      // Maksimum trade per hari (0 = tanpa batas)
input double InpMaxDailyLossPercent   = 3.0;    // Maksimum kerugian harian (% balance awal hari)
input int    InpForceCloseMinutesBeforeEnd = 30; // Force-close posisi sesi X menit sebelum sesi berakhir
input double InpMaxSpreadPips         = 35.0;   // Spread maksimum entry (pip; 0 = off)
input int    InpMaxSlippagePoints     = 30;     // Slippage maksimum (poin)
input int    InpOrderRetries          = 3;      // Retry order saat error trade server
input int    InpOrderRetryDelayMs     = 500;    // Jeda antar retry (ms)

//--- Overbought/Oversold Settings (info dashboard — bukan gate entry) ---
input group "=== Overbought / Oversold (RSI) ==="
input int    InpOBOSPeriod     = 14;    // Periode RSI
input double InpOBOSUpperLevel = 70.0;  // Level Overbought
input double InpOBOSLowerLevel = 30.0;  // Level Oversold

//--- News Settings ---
input group "=== News Settings ==="
input bool   InpEnableNewsFilter    = true;   // Aktifkan filter news (entry baru saja)
input int    InpNewsRefreshHours    = 6;      // Interval refresh data (jam)
input bool   InpIncludeMediumImpact = true;   // Sertakan event medium-impact
input string InpNewsCurrencyOverride = "";    // Override currency news (kosong = auto-detect dari _Symbol; mis. "USD")
input int    InpNewsBufferBeforeMin = 30;     // Blokir entry X menit sebelum event
input int    InpNewsBufferAfterMin  = 30;     // Blokir entry X menit setelah event

//--- Visual Settings ---
input group "=== Visual Settings ==="
input bool   InpShowOB            = true;  // Tampilkan Order Block
input bool   InpShowFVG           = true;  // Tampilkan Fair Value Gap
input bool   InpShowStructure     = true;  // Tampilkan BOS/CHoCH + label swing HH/HL/LH/LL
input bool   InpShowSweep         = true;  // Tampilkan marker liquidity sweep
input bool   InpShowEntryArrows   = true;  // Tampilkan panah entry/retest + label SL/TP/RR
input bool   InpShowPivot         = true;  // Tampilkan pivot harian PP/R1-R3/S1-S3
input bool   InpShowVolumeProfile = true;  // Tampilkan volume profile (VAH/VAL/POC)
input bool   InpShowNewsMarkers   = true;  // Tampilkan marker + shading window news
input bool   InpShowPriceLabels   = true;  // Label harga pada elemen level (OR/OB/FVG/swing/BOS-CHoCH/sweep/pivot/VP)

//--- General ---
input group "=== General ==="
input int    InpMagicNumber          = 20260801; // Magic number dasar
input bool   InpMagicAutoChartOffset = false;    // Tambah offset ChartID ke magic (multi-chart; catat: ChartID bisa berubah setelah chart dibuka ulang)
input bool   InpShowDashboard        = true;     // Tampilkan dashboard panel
input int    InpDashboardCorner      = 0;        // Posisi panel: 0=kiri-atas 1=kanan-atas 2=kiri-bawah 3=kanan-bawah
input int    InpDashboardFontSize    = 8;        // Ukuran font dashboard (8-9pt; min 6, maks 12)

//===================================================================
// MODUL (urutan sesuai dependency; guard #ifndef mencegah duplikat)
//===================================================================
#include <ORB_SMC_NextGen\Helpers.mqh>             // EAMagic/GetATR — SETELAH input
#include <ORB_SMC_NextGen\SessionManager.mqh>
#include <ORB_SMC_NextGen\ORBDetector.mqh>
#include <ORB_SMC_NextGen\SMCEngine.mqh>
#include <ORB_SMC_NextGen\RiskManager.mqh>
#include <ORB_SMC_NextGen\TradeExecutor.mqh>
#include <ORB_SMC_NextGen\NewsFilter.mqh>
#include <ORB_SMC_NextGen\ConfluenceValidator.mqh>
#include <ORB_SMC_NextGen\VisualRenderer.mqh>
#include <ORB_SMC_NextGen\Dashboard.mqh>

//===================================================================
// OBJEK GLOBAL MODUL + STATE MACHINE
//===================================================================
CSessionManager      g_sessions;
CORBDetector         g_orb;
CSMCEngine           g_smc;
CRiskManager         g_risk;
CTradeExecutor       g_executor;
CNewsFilter          g_news;
CConfluenceValidator g_confluence;
CVisualRenderer      g_visual;
CDashboard           g_dashboard;

//--- state per sesi (satu mesin per sesi — force-close hanya mematikan sesinya sendiri)
ENUM_EA_STATE  g_state[SESS_COUNT];
datetime       g_stateTime[SESS_COUNT];   // waktu transisi state (basis countdown)
bool           g_forceClosed[SESS_COUNT]; // force-close sudah dieksekusi hari ini per sesi

//--- deteksi bar baru (tunggal, dipakai semua modul)
datetime       g_lastBarTime = 0;
bool           g_isNewBar    = false;
datetime       g_lastNewsUpdate = 0;   // deteksi refresh news (untuk redraw marker)

//===================================================================
// EVENT HANDLERS
//===================================================================
//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   Print("==============================================================");
   Print(EA_TITLE, " v", EA_VERSION, " | ", _Symbol, " ", StringSubstr(EnumToString((ENUM_TIMEFRAMES)PERIOD_CURRENT), 7),
         " | Entry mode: ", (InpEntryMode == ENTRY_EXECUTION ? "EXECUTION" : "PENDING_ORDER"));
   Print("CATATAN SETUP: bila InpEnableNewsFilter=true, pastikan URL berikut diizinkan:");
   Print("  Tools > Options > Expert Advisors > Allow WebRequest: https://sslecal2.investing.com/");
   Print("==============================================================");

   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   if(!g_sessions.Init())      return INIT_FAILED;
   if(!g_orb.Init())           return INIT_FAILED;
   if(!g_smc.Init())           return INIT_FAILED;
   if(!g_risk.Init())          return INIT_FAILED;
   if(!g_executor.Init())      return INIT_FAILED;
   if(!g_news.Init())          return INIT_FAILED;
   if(!g_confluence.Init())    return INIT_FAILED;
   if(!g_visual.Init())        return INIT_FAILED;
   if(!g_dashboard.Init())     return INIT_FAILED;

   for(int s = 0; s < SESS_COUNT; s++)
     {
      g_state[s]       = STATE_IDLE;
      g_stateTime[s]   = 0;
      g_forceClosed[s] = false;
     }

   g_lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   g_isNewBar    = false;

   if(InpShowDashboard)
      EventSetTimer(1);   // countdown per detik (candle timer + countdown news)

   g_lastNewsUpdate = g_news.GetLastUpdate();
   if(g_lastNewsUpdate > 0)
      g_visual.OnNewsRefresh();   // gambar marker news dari cache yang sudah ada

   Print(EA_TITLE, " : inisialisasi selesai — magic ", EAMagic(),
         " | ", (InpEnableNewsFilter ? "news filter ON" : "news filter OFF"));
   return INIT_SUCCEEDED;
  }
//+------------------------------------------------------------------+
//| Deinitialization — WAJIB bersihkan semua objek EA                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_visual.CleanupAll();      // semua objek ber-prefix ORBSMC_
   g_dashboard.Deinit();       // dashboard (prefix ORBSMC_DASH_)

   // Jaga-jaga ganda: pastikan tidak ada objek EA tersisa
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(name == "")
         continue;
      if(StringFind(name, PREFIX_ALL) == 0)
         ObjectDelete(0, name);
     }
   Comment("");
   Print(EA_TITLE, " : deinit — semua objek chart dibersihkan (reason ", reason, ")");
  }
//+------------------------------------------------------------------+
//| Tick — pipeline utama                                            |
//+------------------------------------------------------------------+
void OnTick()
  {
   // --- deteksi bar baru ---
   datetime curBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   g_isNewBar = (curBar != g_lastBarTime);

   // --- modul tick-based (murah) ---
   g_sessions.OnTick();     // hari baru / jadwal sesi
   g_news.OnTick();         // jadwal refresh periodik
   g_executor.OnTick();     // sinkron posisi, partial close, monitoring

   // --- cache news diperbarui → redraw marker news + dashboard ---
   datetime nu = g_news.GetLastUpdate();
   if(nu != g_lastNewsUpdate && nu > 0)
     {
      g_lastNewsUpdate = nu;
      g_visual.OnNewsRefresh();
      g_dashboard.OnNewsRefresh();
     }

   if(g_isNewBar)
     {
      g_lastBarTime = curBar;

      // --- hari trading baru → reset semua konteks ---
      if(g_sessions.IsNewTradingDay())
        {
         for(int s = 0; s < SESS_COUNT; s++)
           {
            g_state[s]       = STATE_IDLE;
            g_stateTime[s]   = 0;
            g_forceClosed[s] = false;
            g_confluence.Reset(s);
            g_orb.Reset(s);
           }
         g_risk.CheckNewDay();   // snapshot balance & reset counter harian
         g_visual.MarkStaticDirty();
         Print(EA_TITLE, " : hari trading baru — state semua sesi di-reset");
        }

      // --- pipeline bar baru ---
      g_sessions.OnNewBar();    // finalisasi OR
      g_smc.OnNewBar();         // rebuild struktur
      g_orb.OnNewBar();         // counter + false-breakout
      g_confluence.OnNewBar();  // invalidasi retest
      g_executor.OnNewBar();    // expiry pending + trailing
      RunStateMachine();        // logika entry/force-close per sesi
      g_visual.OnNewBar();      // redraw static layers
      g_dashboard.OnNewBar();   // data non-kritis + RSI
     }
   else
     {
      g_visual.OnTick();        // dynamic layers (entry arrows)
      g_dashboard.OnTick();     // floating P/L, countdown
     }
  }
//+------------------------------------------------------------------+
//| Timer — countdown per detik (candle timer dashboard)             |
//+------------------------------------------------------------------+
void OnTimer()
  {
   g_dashboard.OnTimer();
  }
//+------------------------------------------------------------------+
//| Trade event — deteksi fill/close & refresh visual                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != EAMagic())
      return;
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_OUT)
     {
      g_visual.MarkEntryDirty();
      g_dashboard.OnTick();
     }
  }
//+------------------------------------------------------------------+
//| Chart event — redraw saat chart diubah ukurannya                 |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
      g_visual.MarkStaticDirty();
  }

//===================================================================
// STATE MACHINE (per sesi) — dipanggil saat bar baru
//===================================================================
//+------------------------------------------------------------------+
//| Inti logika per sesi                                             |
//+------------------------------------------------------------------+
void RunStateMachine()
  {
   // ================================================================
   // 0. FORCE-CLOSE CHECK — dijalankan SEBELUM logika entry apa pun,
   //    sehingga tidak mungkin ada entry baru setelah jendela
   //    force-close aktif di sesi yang sama.
   // ================================================================
   for(int s = 0; s < SESS_COUNT; s++)
     {
      const SSessionTimes &t = g_sessions.GetTimes(s);
      if(!t.enabled || !t.valid)
         continue;
      if(g_sessions.IsForceCloseWindow(s) && !g_forceClosed[s])
        {
         g_forceClosed[s] = true;
         int actions = g_executor.ForceCloseSession(s);   // posisi + pending SESI INI saja
         g_executor.PreventNewEntries(s);
         g_confluence.InvalidateSession(s);
         g_state[s]     = STATE_IDLE;
         g_stateTime[s] = TimeCurrent();
         g_visual.MarkStaticDirty();
         Print(EA_TITLE, " : FORCE-CLOSE ", g_sessions.SessionName(s), " — ", actions, " aksi (posisi+pending)");
        }
     }

   // ================================================================
   // 1. PROTEKSI GLOBAL (berlaku semua sesi)
   // ================================================================
   bool   globalBlock = false;
   string blockReason = "";
   if(g_risk.IsDailyLossLimitHit())  { globalBlock = true; blockReason = "batas kerugian harian"; }
   else if(g_risk.IsMaxTradesReached()) { globalBlock = true; blockReason = "batas trade harian"; }

   // ================================================================
   // 2. STATE PER SESI
   // ================================================================
   for(int s = 0; s < SESS_COUNT; s++)
     {
      const SSessionTimes &t = g_sessions.GetTimes(s);
      if(!t.enabled || !t.valid)
         continue;

      datetime nowUtc = g_sessions.ToUtc(TimeCurrent());
      ENUM_EA_STATE st = g_state[s];

      // --- di luar jam sesi: idle (posisi tetap dipantau executor) ---
      if(nowUtc < t.startUtc || nowUtc >= t.endUtc)
        {
         if(st != STATE_IDLE && st != STATE_TRADED)
           {
            g_state[s] = STATE_IDLE;
            g_confluence.InvalidateSession(s);
            g_orb.Reset(s);
           }
         continue;
        }

      switch(st)
        {
         // ----------------------------------------------------------
         case STATE_IDLE:
           {
            if(g_forceClosed[s])
               break;   // sesi ini sudah force-close → tidak boleh entry lagi
            if(nowUtc < t.rangeEndUtc)
              {
               g_state[s]     = STATE_RANGE_FORMING;
               g_stateTime[s] = TimeCurrent();
              }
           }
           break;

         // ----------------------------------------------------------
         case STATE_RANGE_FORMING:
           {
            if(g_sessions.RangeFormed(s))
              {
               const SSessionRange &r = g_sessions.GetRange(s);
               if(g_orb.IsValidRangeSize(r))
                 {
                  g_state[s] = STATE_WAITING_BREAKOUT;
                  Print(EA_TITLE, " : ", g_sessions.SessionName(s), " OR terbentuk: ",
                        FmtPrice(r.low), " - ", FmtPrice(r.high), " (", DoubleToString(r.sizePips, 1), " pip)");
                 }
               else
                 {
                  Print(EA_TITLE, " : ", g_sessions.SessionName(s), " OR terlalu kecil (",
                        DoubleToString(r.sizePips, 1), " pip < ", DoubleToString(InpMinRangePips, 1), ") — sesi dilewati");
                  g_state[s] = STATE_IDLE;
                 }
               g_stateTime[s] = TimeCurrent();
               g_visual.MarkStaticDirty();
              }
           }
           break;

         // ----------------------------------------------------------
         case STATE_WAITING_BREAKOUT:
           {
            // false-breakout: close kembali masuk range → void
            if(g_orb.SignalVoided(s))
              {
               Print(EA_TITLE, " : ", g_sessions.SessionName(s), " false breakout — setup dibatalkan");
               g_state[s] = STATE_IDLE;
               g_orb.Reset(s);
               g_confluence.InvalidateSession(s);
               g_visual.MarkStaticDirty();
               break;
              }

            SBreakoutSignal brk;
            if(g_orb.DetectBreakout(s, brk))
              {
               g_sessions.UpdateRangeStatus(s,
                                            (brk.dir == BREAK_UP ? RANGE_BREAKOUT_UP : RANGE_BREAKOUT_DOWN),
                                            brk.dir, brk.barTime);
               g_visual.MarkStaticDirty();

               if(globalBlock)
                 {
                  Print(EA_TITLE, " : ", g_sessions.SessionName(s), " breakout terjadi tapi entry diblokir — ", blockReason);
                  g_state[s] = STATE_IDLE;
                  g_orb.Reset(s);
                  break;
                 }

               SValidationResult res;
               if(g_confluence.Evaluate(s, res))
                 {
                  g_state[s]     = STATE_BREAKOUT_CONFIRMED;
                  g_stateTime[s] = TimeCurrent();
                 }
               else
                 {
                  Print(EA_TITLE, " : ", g_sessions.SessionName(s), " breakout DITOLAK — ", res.rejectReason);
                  g_state[s] = STATE_IDLE;   // izinkan setup baru (breakout lain) di sesi ini
                  g_orb.Reset(s);
                  g_confluence.InvalidateSession(s);
                 }
              }
           }
           break;

         // ----------------------------------------------------------
         case STATE_BREAKOUT_CONFIRMED:
           {
            g_state[s]     = STATE_WAITING_RETEST;
            g_stateTime[s] = TimeCurrent();
           }
           break;

         // ----------------------------------------------------------
         case STATE_WAITING_RETEST:
           {
            // setup invalid (bar habis / over-extension / sesi berakhir)?
            if(!g_confluence.HasActiveSetup(s))
              {
               g_state[s] = STATE_IDLE;
               break;
              }
            if(g_confluence.IsRetestInvalid(s))
              {
               Print(EA_TITLE, " : ", g_sessions.SessionName(s), " retest invalid — setup dibatalkan");
               g_confluence.InvalidateSession(s);
               g_state[s] = STATE_IDLE;
               g_orb.Reset(s);
               g_visual.MarkStaticDirty();
               break;
              }

            const SValidationResult &res = g_confluence.LastResult(s);

            if(InpEntryMode == ENTRY_EXECUTION)
              {
               // --- reaksi retest (wick rejection / close searah) di closed bar ---
               SRetestZone confirmed;
               if(g_smc.IsReactedAtZone(res.zone, res.dir, res.breakTime, confirmed))
                 {
                  SRiskPlan plan;
                  if(g_risk.BuildRiskPlan(res.dir, confirmed.entryPrice, res.zone, g_smc.GetHTFBias(), plan))
                    {
                     if(g_executor.OpenMarket(res.dir, plan, s))
                       {
                        g_state[s] = STATE_TRADED;
                        g_confluence.InvalidateSession(s);   // setup selesai dikonsumsi
                        g_visual.MarkEntryDirty();
                       }
                     else
                       {
                        Print(EA_TITLE, " : ", g_sessions.SessionName(s), " eksekusi market GAGAL");
                        g_state[s] = STATE_IDLE;
                        g_confluence.InvalidateSession(s);
                       }
                    }
                  else
                    {
                     Print(EA_TITLE, " : ", g_sessions.SessionName(s), " risk plan gagal — setup dibatalkan");
                     g_state[s] = STATE_IDLE;
                     g_confluence.InvalidateSession(s);
                    }
                 }
              }
            else
              {
               // --- ENTRY_PENDING_ORDER: pasang limit SEKALI di tepi zona ---
               if(!g_executor.SessionHasPending(s))
                 {
                  SRiskPlan plan;
                  if(g_risk.BuildRiskPlan(res.dir, res.zone.entryPrice, res.zone, g_smc.GetHTFBias(), plan))
                    {
                     if(g_executor.PlacePending(res.dir, plan, s))
                       {
                        g_state[s] = STATE_TRADED;   // kelola fill/expiry dari sini
                        g_visual.MarkEntryDirty();
                       }
                     else
                       {
                        Print(EA_TITLE, " : ", g_sessions.SessionName(s), " pemasangan pending GAGAL");
                        g_state[s] = STATE_IDLE;
                        g_confluence.InvalidateSession(s);
                       }
                    }
                  else
                    {
                     Print(EA_TITLE, " : ", g_sessions.SessionName(s), " risk plan gagal — setup dibatalkan");
                     g_state[s] = STATE_IDLE;
                     g_confluence.InvalidateSession(s);
                    }
                 }
              }
           }
           break;

         // ----------------------------------------------------------
         case STATE_READY_ENTRY:
           {
            // state transien (jarang tercapai — eksekusi langsung di WAITING_RETEST);
            // fallback aman: kembalikan ke waiting retest.
            g_state[s] = STATE_WAITING_RETEST;
           }
           break;

         // ----------------------------------------------------------
         case STATE_TRADED:
           {
            // posisi & pending sudah tidak ada → selesai
            if(!g_executor.SessionHasPosition(s) && !g_executor.SessionHasPending(s))
              {
               g_state[s] = STATE_IDLE;
               g_confluence.InvalidateSession(s);
               break;
              }
            // pending masih menggantung tapi setup sudah invalid (over-extension) → hapus lebih awal
            if(g_executor.SessionHasPending(s) && !g_confluence.HasActiveSetup(s))
              {
               ulong ticket = g_executor.GetPendingTicket();
               if(ticket != 0 && g_executor.DeletePending(ticket))
                  Print(EA_TITLE, " : ", g_sessions.SessionName(s), " pending dihapus lebih awal — setup invalid");
               g_state[s] = STATE_IDLE;
              }
           }
           break;
        }
     }
  }

//===================================================================
// HELPER INTERNAL
//===================================================================
//+------------------------------------------------------------------+
//| Validasi input & normalisasi (peringatan — tidak pernah fatal    |
//| kecuali nilai yang benar-benar mustahil).                        |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   bool ok = true;

   if(InpRangeMinutes <= 0 || InpRangeMinutes > 240)
     {
      Print(EA_TITLE, " : InpRangeMinutes tidak valid (", InpRangeMinutes, ") — harus 1..240");
      ok = false;
     }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 10.0)
     {
      Print(EA_TITLE, " : PERINGATAN — InpRiskPercent di luar 0..10% (", DoubleToString(InpRiskPercent, 2), ")");
     }
   if(InpGMTOffset < -12 || InpGMTOffset > 14)
      Print(EA_TITLE, " : PERINGATAN — InpGMTOffset di luar -12..14 (", InpGMTOffset, ")");
   if(InpMinRR < 0.0)
      Print(EA_TITLE, " : PERINGATAN — InpMinRR negatif; dianggap 0");
   if(InpSwingLookback < 2)
      Print(EA_TITLE, " : PERINGATAN — InpSwingLookback minimal 2 (dipakai 2)");
   if(InpDashboardFontSize < 6 || InpDashboardFontSize > 12)
      Print(EA_TITLE, " : PERINGATAN — InpDashboardFontSize dianjurkan 6..12");
   if(InpMaxDailyLossPercent < 0.0)
      Print(EA_TITLE, " : PERINGATAN — InpMaxDailyLossPercent negatif; proteksi nonaktif");
   if(InpNewsBufferBeforeMin < 0 || InpNewsBufferAfterMin < 0)
      Print(EA_TITLE, " : PERINGATAN — buffer news negatif; dianggap 0");
   if(InpMaxExtensionBeforeRetest < 0.0)
      Print(EA_TITLE, " : PERINGATAN — InpMaxExtensionBeforeRetest negatif; dianggap 0");

   return ok;
  }
//+------------------------------------------------------------------+
//| Nama state → string (log & dashboard)                            |
//+------------------------------------------------------------------+
string StateToString(ENUM_EA_STATE st)
  {
   switch(st)
     {
      case STATE_IDLE:               return "Idle";
      case STATE_RANGE_FORMING:      return "Range forming";
      case STATE_WAITING_BREAKOUT:   return "Waiting breakout";
      case STATE_BREAKOUT_CONFIRMED: return "Breakout confirmed";
      case STATE_WAITING_RETEST:     return "Waiting retest";
      case STATE_READY_ENTRY:        return "Ready entry";
      case STATE_TRADED:             return "Traded";
     }
   return "?";
  }
