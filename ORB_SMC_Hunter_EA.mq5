//+------------------------------------------------------------------+
//|                                           ORB_SMC_Hunter_EA.mq5 |
//| ORB (Opening Range Breakout) + Smart Money Concepts — build      |
//| modular dari nol (arsitektur: DataService terpusat, settings      |
//| snapshot, zona OB/FVG terunifikasi, state machine PER SESI).     |
//|                                                                  |
//| CATATAN SETUP WAJIB (NewsFilter):                                 |
//|   MT5 → Tools → Options → Expert Advisors → "Allow WebRequest    |
//|   for listed URL" → tambahkan:                                    |
//|       https://sslecal2.investing.com/                             |
//|   Tanpa ini fetch news selalu gagal. EA bersifat FAIL-SAFE:       |
//|   tetap trading, news filter nonaktif (status NO DATA), warning  |
//|   dicetak ke log & dashboard.                                     |
//|                                                                  |
//| WAKTU SESI: default dalam JAM BROKER (lihat InpTimeBase).         |
//|   InpGMTOffset = broker − UTC. News (UTC) dikonversi via offset.  |
//|                                                                  |
//| PIPELINE (bar closed only — tanpa repaint/lookahead):             |
//|   SessionManager → ORBDetector → ConfluenceValidator(gates+skor) |
//|   → WAIT_RETEST (Execution: reaksi candle | Pending: limit+expiry |
//|   bar) → RiskManager (SL struktural/TP1 partial/trailing) →      |
//|   TradeExecutor → force-close per sesi.                           |
//+------------------------------------------------------------------+
#property copyright   "ORB SMC Hunter"
#property link        ""
#property version     "0.10"
#property description "ORB+SMC modular EA · retest-only entry · per-session force-close · news filter fail-safe"

//--- tipe/konstanta dulu (tidak menyentuh input)
#include <ORB_SMC_Hunter\HunterDefines.mqh>
#include <ORB_SMC_Hunter\HunterSettings.mqh>

//===================================================================
// INPUT — seluruhnya divalidasi di OnInit lalu dibekukan ke
// SHunterSettings; modul tidak membaca input langsung.
//===================================================================
input group "=== Session Settings ==="
input bool                InpEnableAsia      = true;           // Aktifkan sesi Asia
input int                 InpAsiaStart       = 2;              // Asia mulai (jam)
input int                 InpAsiaEnd         = 8;              // Asia selesai (jam)
input bool                InpEnableLondon    = true;           // Aktifkan sesi London
input int                 InpLondonStart     = 14;             // London mulai (jam)
input int                 InpLondonEnd       = 22;             // London selesai (jam)
input bool                InpEnableNY        = true;           // Aktifkan sesi New York
input int                 InpNYStart         = 19;             // NY mulai (jam)
input int                 InpNYEnd           = 3;              // NY selesai (jam; <mulai = lewat tengah malam)
input ENUM_HUNT_TIME_BASE InpTimeBase        = HUNT_TIME_BASE_BROKER; // Basis jam input sesi
input int                 InpGMTOffset       = 2;              // Offset broker−UTC (jam)

input group "=== ORB Settings ==="
input int                 InpRangeMinutes    = 30;             // Durasi Opening Range (menit pertama sesi)
input double              InpMinRangePips    = 0.0;            // Ukuran minimum OR (pips; 0=off)
input double              InpBreakoutBufferPips = 0.0;         // Buffer close di luar level OR (pips)
input bool                InpRequireBodyClose = true;          // Wajib body-close (wick-only ditolak)

input group "=== SMC Settings ==="
input int                 InpSwingLookback   = 3;              // Swing lookback kiri/kanan (bar closed)
input bool                InpRequireLiquiditySweep = true;     // Wajib sweep pool searah breakout
input bool                InpRequireFVGRetest = true;          // Wajib retest OB/FVG (no direct entry)
input int                 InpRetestMaxBars   = 10;             // Maks bar menunggu retest (invalidasi/expiry)
input double              InpMaxExtensionBeforeRetest = 50.0;  // Ekstensi maks sebelum retest (% dari OR)
input double              InpLiqTolerancePips = 2.0;           // Toleransi equal highs/lows (pips)
input bool                InpUseFVGAsZone    = true;           // FVG boleh jadi zona retest
input double              InpOBDisplacementAtr = 1.0;          // Displacement OB minimum (×ATR)
input int                 InpATRPeriod       = 14;             // Periode ATR (buffer SL & volatilitas)
input ENUM_TIMEFRAMES     InpHTFTimeframe    = PERIOD_H4;      // Timeframe bias struktur (HTF)

input group "=== Confluence Settings ==="
input int                 InpMinConfluenceScore = 60;          // Skor confluence minimum 0..100

input group "=== Entry Mode ==="
input ENUM_ENTRY_MODE     InpEntryMode       = ENTRY_PENDING_ORDER; // 0=Execution(market) 1=Pending(limit@zona)

input group "=== Risk Settings ==="
input double              InpRiskPercent     = 0.5;            // Risiko per trade (% dari basis)
input ENUM_HUNT_RISK_BASE InpRiskBase        = HUNT_RISK_BASE_BALANCE; // Basis risiko
input double              InpMinRR           = 2.0;            // RR minimum (ke TP akhir)
input double              InpTP1RR           = 1.0;            // RR TP1 untuk partial (0=off)
input double              InpPartialClosePct = 50.0;           // % ditutup di TP1
input bool                InpTrailAfterTP1   = true;           // Trailing struktur setelah TP1
input int                 InpMaxTradesPerDay = 3;              // Maks trade/hari (0=unlimited)
input double              InpMaxDailyLossPercent = 3.0;        // Maks loss harian % (0=off)
input int                 InpForceCloseMinutesBeforeEnd = 30;  // Menit sebelum akhir sesi → force-close
input double              InpMaxSpreadPips   = 0.0;            // Maks spread entry (pips; 0=off)
input int                 InpMaxSlippagePoints = 30;           // Deviation maks (points)
input int                 InpOrderRetries    = 3;              // Retry order saat error server
input int                 InpOrderRetryDelayMs = 500;          // Jeda antar retry (ms)

input group "=== Overbought/Oversold (info dashboard) ==="
input int                 InpOBOSPeriod      = 14;             // Periode RSI
input double              InpOBOSUpperLevel  = 70.0;           // Level Overbought (>=)
input double              InpOBOSLowerLevel  = 30.0;           // Level Oversold (<=)

input group "=== News Settings ==="
input bool                InpEnableNewsFilter   = true;        // Aktifkan news filter (entry baru saja)
input int                 InpNewsRefreshHours   = 6;           // Interval refresh data (jam)
input bool                InpIncludeMediumImpact = true;       // Sertakan impact medium
input string              InpNewsCurrencyOverride = "";        // Override currency (kosong=auto base/quote)
input int                 InpNewsBufferBeforeMin = 30;         // Blokir X menit sebelum event
input int                 InpNewsBufferAfterMin  = 30;         // Blokir X menit setelah event
input int                 InpNewsFetchTimeoutMs = 8000;         // Timeout WebRequest (ms)
input int                 InpNewsCacheMaxAgeHours = 48;        // Cache dianggap stale setelah (jam)

input group "=== Visual Settings ==="
input bool                InpShowOB          = true;           // Order Block boxes
input bool                InpShowFVG         = true;           // Fair Value Gap boxes
input bool                InpShowStructure   = true;           // BOS/CHoCH + HH/HL/LH/LL
input bool                InpShowSweep       = true;           // Liquidity sweep markers
input bool                InpShowEntryArrows = true;           // Entry/retest arrows + labels
input bool                InpShowPivot       = true;           // Daily pivots PP/R/S
input bool                InpShowVolumeProfile = true;         // Volume Profile VAH/VAL/POC
input bool                InpShowNewsMarkers = true;           // News vline + shading window

input group "=== General ==="
input long                InpMagicNumber     = 20260830;      // Magic number EA
input bool                InpShowDashboard   = true;           // Tampilkan dashboard
input ENUM_BASE_CORNER    InpDashboardCorner = CORNER_LEFT_UPPER; // Pojok panel
input int                 InpDashboardFontSize = 9;            // Font size panel (6..12)

//--- modul (setelah blok input — mereferensikan Inp* hanya lewat snapshot)
#include <ORB_SMC_Hunter\DataService.mqh>
#include <ORB_SMC_Hunter\SessionManager.mqh>
#include <ORB_SMC_Hunter\ORBDetector.mqh>
#include <ORB_SMC_Hunter\SMCEngine.mqh>
#include <ORB_SMC_Hunter\NewsFilter.mqh>
#include <ORB_SMC_Hunter\RiskManager.mqh>
#include <ORB_SMC_Hunter\ConfluenceValidator.mqh>
#include <ORB_SMC_Hunter\TradeExecutor.mqh>
#include <ORB_SMC_Hunter\VisualRenderer.mqh>
#include <ORB_SMC_Hunter\Dashboard.mqh>

//===================================================================
// GLOBAL STATE (orkestrator memiliki state machine per sesi)
//===================================================================
SHunterSettings     g_settings;                 // snapshot input (dibekukan)
CDataService        g_data;                     // sumber data tunggal
CSessionManager     g_sessions;                 // sesi + OR per sesi
CORBDetector        g_orb;                      // validasi breakout
CSMCEngine          g_smc;                      // struktur, zona, bias
CConfluenceValidator g_conf;                    // gate + skor
CRiskManager        g_risk;                     // sizing & limit harian
CTradeExecutor      g_exec;                     // eksekusi & force-close
CNewsFilter         g_news;                     // kalender & blokir entry
CVisualRenderer     g_visual;                   // elemen chart
CHunterDashboard    g_dash;                     // panel info

ENUM_HUNT_STATE     g_state[HUNT_SESSION_COUNT];// state machine PER SESI
SSignalPlan         g_plan[HUNT_SESSION_COUNT]; // plan aktif per sesi (maks 1/sesi)
datetime            g_lastBarTime = 0;          // deteksi bar baru

//--- forward decl helper lokal EA ----------------------------------------
bool     SnapshotSettings(SHunterSettings &s);
void     StateToString(const ENUM_HUNT_STATE st,string &out);
void     AdvanceState(const int session,const ENUM_HUNT_STATE to);

//+------------------------------------------------------------------+
//| UTC "sekarang" yang aman untuk tester: TimeGMT() tidak reliable  |
//| saat backtest → derivasi TimeCurrent() - gmtOffset.               |
//+------------------------------------------------------------------+
datetime HuntNowUtc(const SHunterSettings &cfg)
  {
   if(MQLInfoInteger(MQL_TESTER))
      return(TimeCurrent()-cfg.gmtOffset*3600);
   return(TimeGMT());
  }

//+------------------------------------------------------------------+
//| Nama state utk dashboard/log. |return| string label.             |
//+------------------------------------------------------------------+
void StateToString(const ENUM_HUNT_STATE st,string &out)
  {
   out="";
   switch(st)
     {
      case HUNT_STATE_IDLE:               out="Idle";               break;
      case HUNT_STATE_RANGE_FORMING:      out="Range forming";      break;
      case HUNT_STATE_WAIT_BREAKOUT:      out="Waiting breakout";   break;
      case HUNT_STATE_BREAKOUT_CONFIRMED: out="Breakout confirmed"; break;
      case HUNT_STATE_WAIT_RETEST:        out="Waiting retest";     break;
      case HUNT_STATE_READY_ENTRY:        out="Ready entry";        break;
      case HUNT_STATE_MANAGING:           out="In position";        break;
      case HUNT_STATE_FORCE_CLOSED:       out="Force closed";       break;
      default:                            out="?";                   break;
     }
  }

//+------------------------------------------------------------------+
//| Transisi state terpusat: log "SESSION: old → new".               |
//+------------------------------------------------------------------+
void AdvanceState(const int session,const ENUM_HUNT_STATE to)
  {
   if(session<0 || session>=HUNT_SESSION_COUNT)
      return;
   if(g_state[session]==to)
      return;
   string from,tostr;
   StateToString(g_state[session],from);
   StateToString(to,tostr);
   PrintFormat("%s | %s: %s -> %s",HUNT_NAME,
               CSessionManager::SessionName(session),from,tostr);
   g_state[session]=to;
  }

//+------------------------------------------------------------------+
//| Bekukan input → settings + normalisasi waktu & konstanta simbol. |
//| @return false + Alert bila input tidak valid (OnInit gagal).    |
//+------------------------------------------------------------------+
bool SnapshotSettings(SHunterSettings &s)
  {
   //--- TODO(impl): validasi rentang (rangeMinutes 1..720, riskPercent
   //---     0.01..10, retestMaxBars 1..500, font 6..12, corner 0..3,
   //---     jam 0..23, end<start = lintas hari, minRR>=0.5, dst.)
   //---     + pipSize dari digits + konversi jam sesi → UTC per InpTimeBase.
   SettingsDefaults(s);
   return(true);
  }

//+------------------------------------------------------------------+
//| OnInit — validasi, bangun handle indikator, init modul, timer.   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!SnapshotSettings(g_settings))
      return(INIT_PARAMETERS_INCORRECT);
   if(!g_data.Init(g_settings))
      return(INIT_FAILED);                       // handle indikator gagal
   if(!g_sessions.Init(g_settings,HuntNowUtc(g_settings))) // UTC-safe (tester-aware)
      return(INIT_FAILED);
   if(!g_orb.Init(g_settings))
      return(INIT_FAILED);
   g_smc.Init(g_settings,g_sessions.GetDayStartUtc());
   if(!g_news.Init(g_settings))
      PrintFormat("%s: NewsFilter init gagal — EA jalan TANPA filter news (fail-safe)",HUNT_NAME);
   if(!g_conf.Init(g_settings))
      return(INIT_FAILED);
   if(!g_risk.Init(g_settings))
      return(INIT_FAILED);
   if(!g_exec.Init(g_settings))
      return(INIT_FAILED);
   g_visual.Init(g_settings);
   g_dash.BuildLayout(g_settings);

   EventSetTimer(1);                             // candle countdown & news refresh
   PrintFormat("%s v%s init OK | TF=%s magic=%I64d",HUNT_NAME,HUNT_VERSION,
               EnumToString(_Period),g_settings.magic);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit — cleanup by reason; hapus objek per prefix ledger;     |
//| release handle; matikan timer. DILARANG meninggalkan sampah.     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_visual.ClearAllOwned();                     // prefix HUNT_* saja
   g_dash.Destroy();
   g_data.Release();                             // IndicatorRelease semua handle
   switch(reason)
     {
      case REASON_REMOVE:     PrintFormat("%s: dilepas dari chart",HUNT_NAME);    break;
      case REASON_PARAMETERS: PrintFormat("%s: reinit karena input diganti",HUNT_NAME); break;
      case REASON_CHARTCLOSE: PrintFormat("%s: chart ditutup",HUNT_NAME);         break;
      default: break;
     }
  }

//+------------------------------------------------------------------+
//| OnTick — RINGAN: gate bar baru → pipeline modul; sisanya hanya   |
//| monitoring real-time (trailing/force-close/dashboard tick).      |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- quotes selalu refresh (murah: Bid/Ask/spread dari CSymbolInfo)
   g_data.RefreshQuotes();

   const bool newBar = g_data.UpdateOnBar(600,120); // refresh cache bila bar closed baru
   if(newBar)
     {
      const datetime nowUtc = HuntNowUtc(g_settings);
      g_sessions.Update(g_data,nowUtc);
      if(g_sessions.CheckDailyRolloverRequired(nowUtc))
        {
         g_risk.OnNewDay(g_sessions.CurrentDayUtc(),AccountInfoDouble(ACCOUNT_BALANCE));
         g_smc.ResetDaily(g_sessions.GetDayStartUtc());
         g_orb.ResetAll();
         for(int s=0;s<HUNT_SESSION_COUNT;s++)
           { g_state[s]=HUNT_STATE_IDLE; g_plan[s].Reset(); }
         g_visual.RenderPivots(g_data,g_sessions.GetDayStartUtc());
         g_news.Refresh(nowUtc);                  // calendar awal hari
        }
      g_smc.Update(g_data);

      //--- per sesi: majukan state machine (TODO(impl) orkestrasi penuh:
      //    IDLE→RANGE_FORMING→WAIT_BREAKOUT→(Assess)→BREAKOUT_CONFIRMED→
      //    Review()→WAIT_RETEST→(StillValid)→READY_ENTRY→OpenMarket→MANAGING)
     }

   //--- per tick: force-close window, trailing setelah TP1, diff dashboard
   //--- TODO(impl) — delegasi: g_exec.Manage(), g_risk.ProposeTrailingSl()
  }

//+------------------------------------------------------------------+
//| OnTimer(1s) — candle countdown (bukan tiap tick), news refresh   |
//| terjadwal, sinkronisasi force-close per menit.                    |
//+------------------------------------------------------------------+
void OnTimer()
  {
   // TODO(impl): g_dash.UpdateOnTimer(secToBarClose, secToForceClose, name);
   //             g_news.RefreshIfNeeded(TimeGMT()); → RenderNews() saat berubah;
   //             force-close check (tiap detik cukup murah, tanpa CopyRates)
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction — reaktif thd fill/partial/eliminasi order;    |
//| hanya menandai ledger (jangan trading logic di sini).            |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   // TODO(impl): tipe TRADE_TRANSACTION_* → exec tag reconcile + state
   if(trans.type==TRADE_TRANSACTION_ADD || trans.type==TRADE_TRANSACTION_DELETE)
      g_exec.ReconcileTags();
  }
//+------------------------------------------------------------------+
