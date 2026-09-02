//+------------------------------------------------------------------+
//|                                           ORB_SMC_Hunter_EA.mq5 |
//| ORB (Opening Range Breakout) + Smart Money Concepts — build       |
//| modular dari nol. Arsitektur: DataService terpusat, settings        |
//| snapshot (modul TIDAK membaca input langsung), zona OB/FVG           |
//| terunifikasi (SZone), state machine PER SESI, force-close selektif,  |
//| news filter fail-safe, render HUNT_* dengan ledger presisi.          |
//|                                                                    |
//| CATATAN SETUP WAJIB (NewsFilter):                                   |
//|   MT5 → Tools → Options → Expert Advisors → "Allow WebRequest       |
//|   for listed URL" → tambahkan:                                      |
//|       https://sslecal2.investing.com                                |
//|   Tanpa izin, fetch gagal → EA TETAP jalan (fail-safe): filter news  |
//|   nonaktif, peringatan di log & dashboard "NO DATA".                |
//|                                                                    |
//| WAKTU: jam sesi default = UTC kanonik (Asia 0–6, London 7–16,       |
//|   NY 12–20) dengan InpTimeBase=UTC; offset broker−UTC DIUKUR OTOMATIS|
//|   via TimeGMT (InpAutoGmt=true; manual InpGMTOffset = fallback).      |
//|   Pip otomatis dari digits (5/3/2 → 10×point; lain → point).          |
//|                                                                    |
//| ANTI-REPAINT/LOOKAHEAD: keputusan sinyal HANYA pada CLOSED bar       |
//|   (back=0 = shift 1). Bar berjalan hanya utk monitoring real-time     |
//|   (partial TP1, trailing, force-close, dashboard).                    |
//+------------------------------------------------------------------+
#property copyright   "ORB SMC Hunter"
#property link        ""
#property version     "1.119"
#property description "ORB+SMC modular EA | retest-only entry | per-session force-close | news fail-safe"

#include <ORB_SMC_Hunter\HunterDefines.mqh>
#include <ORB_SMC_Hunter\HunterSettings.mqh>

//===================================================================
// INPUT — divalidasi & dibekukan ke SHunterSettings di OnInit;
// modul hanya membaca snapshot (lihat HunterSettings.mqh).
//===================================================================
input group "=== Session Settings ==="
input bool                InpEnableAsia      = true;            // Aktifkan sesi Asia
input int                 InpAsiaStart       = 0;               // Asia mulai (jam; basis InpTimeBase)
input int                 InpAsiaEnd         = 6;               // Asia selesai (jam)
input bool                InpEnableLondon    = true;            // Aktifkan sesi London
input int                 InpLondonStart     = 7;               // London mulai (jam)
input int                 InpLondonEnd       = 16;              // London selesai (jam)
input bool                InpEnableNY        = true;            // Aktifkan sesi New York
input int                 InpNYStart         = 12;              // NY mulai (jam)
input int                 InpNYEnd           = 20;              // NY selesai (jam; <mulai = lintas tengah malam)
input ENUM_HUNT_TIME_BASE InpTimeBase        = HUNT_TIME_BASE_UTC; // Basis: 0=broker 1=UTC 2=AUTO-DST bursa
input bool                InpAutoGmt         = true;            // Auto-ukur offset broker−UTC (chart; tester selalu pakai manual)
input int                 InpGMTOffset       = 2;               // Offset broker−UTC manual (jam) — WAJIB benar di tester

input group "=== ORB Settings ==="
input int                 InpRangeMinutes    = 30;              // Durasi Opening Range (menit pertama sesi)
input double              InpMinRangePips    = 0.0;             // Ukuran minimum OR (pips; 0=off)
input double              InpBreakoutBufferPips = 0.0;          // Buffer close di luar level OR (pips)
input bool                InpRequireBodyClose = true;           // Wajib body-close (wick-only ditolak)
input int                 InpFalseBreakBars  = 2;               // Close kembali dlm OR N bar beruntun = false break (0=off)

input group "=== SMC Settings ==="
input int                 InpSwingLookback   = 3;               // Swing lookback kiri/kanan (bar closed)
input int                 InpCHoCHSwingLookback = 0;            // Lookback validasi CHoCH HTF (0=InpSwingLookback)
input int                 InpCHoCHAlertMinutes = 60;            // Baris alert CHoCH di dashboard (menit)
input bool                InpRequireHtfBias  = true;          // G2: arah entry wajib searah bias HTF (off=counter-bias lolos gate)
input bool                InpRequireLiquiditySweep = true;      // Wajib sweep pool searah breakout
input bool                InpRequireFVGRetest = true;          // Wajib retest OB/FVG (false=opt-in entry langsung!)
input int                 InpRetestMaxBars   = 10;              // Maks bar menunggu retest (invalidasi/expiry)
input double              InpMaxExtensionBeforeRetest = 50.0;   // Ekstensi maks sebelum retest (% dari OR)
input double              InpLiqTolerancePips = 2.0;            // Toleransi equal highs/lows (pips)
input bool                InpUseFVGAsZone    = true;            // FVG boleh jadi zona retest
input bool                InpSmcScopeDay     = false;           // Sweep/BOS/zona: false=jendela sesi, true=sejak awal hari broker
input bool                InpUseBreakerBlocks = false;          // v1.07: OB patah → breaker zone (retest sisi lain)
input bool                InpRequireInducement = false;         // v1.07: wajib sweep minor-liquidity sebelum breakout
input bool                InpRequireDiscountZone = false;       // v1.07: zona wajib di discount(BUY)/premium(SELL) range hari
input bool                InpTpLiquidity       = false;         // v1.07: TP2 = pool likuiditas terdekat (RR-min tetap dijaga)
input double              InpOBDisplacementAtr = 1.0;           // Displacement OB minimum (×ATR)
input double              InpSLBufferAtrMult = 0.2;             // Buffer SL melampaui struktur (×ATR)
input int                 InpATRPeriod       = 14;              // Periode ATR (buffer SL & volatilitas)
input ENUM_TIMEFRAMES     InpHTFTimeframe    = PERIOD_H4;       // Timeframe bias struktur (HTF)

input group "=== Confluence Settings ==="
input int                 InpMinConfluenceScore = 60;           // Skor confluence minimum 0..100

input group "=== Mode Trading ==="
input ENUM_HUNT_MODE        InpMode       = HUNT_MODE_INTRADAY; // 0=INTRADAY (sesi) 1=SWING (hold overnight)
input bool                  InpSwingCloseOnOppChoch = true;     // SWING: tutup posisi saat HTF CHoCH berlawanan

input group "=== Entry Mode ==="
input ENUM_ENTRY_MODE     InpEntryMode = ENTRY_PENDING_ORDER;  // 0=Execution(market) 1=Pending(limit@zona)

input group "=== Risk Settings ==="
input double              InpRiskPercent     = 0.5;             // Risiko per trade (% dari basis)
input ENUM_HUNT_RISK_BASE InpRiskBase      = HUNT_RISK_BASE_BALANCE; // Basis risiko
input ENUM_HUNT_LOT_MODE  InpLotMode       = HUNT_LOT_FIXED;   // FIXED = lot tetap; ADAPTIVE = sizing % risiko
input double              InpFixedLots     = 0.01;            // Ukuran lot FIXED (dinormalkan ke step broker)
input double              InpMinRR           = 2.0;             // RR minimum (ke TP akhir)
input double              InpTP1RR           = 1.0;             // RR TP1 untuk partial (0=off)
input double              InpPartialClosePct = 50.0;            // % ditutup di TP1
input bool                InpTrailAfterTP1   = true;            // Trailing struktur setelah TP1
input int                 InpMaxTradesPerDay = 3;               // Maks trade/hari (0=unlimited)
input double              InpMaxDailyLossPercent = 3.0;         // Maks loss harian % (0=off)
input int                 InpForceCloseMinutesBeforeEnd = 30;   // Menit sebelum akhir sesi → force-close
input double              InpMaxSpreadPips   = 0.0;             // Maks spread entry (pips; 0=off)
input int                 InpMaxSlippagePoints = 30;            // Deviation maks (points)
input int                 InpOrderRetries    = 3;               // Retry order saat error server
input int                 InpOrderRetryDelayMs = 500;           // Jeda antar retry (ms)
input int                 InpPendingExpireHours  = 24;            // Expire pending (jam) bila simbol tolak GTC

input group "=== Overbought/Oversold (info dashboard) ==="
input int                 InpOBOSPeriod      = 14;              // Periode RSI
input double              InpOBOSUpperLevel  = 70.0;            // Level Overbought (>=)
input double              InpOBOSLowerLevel  = 30.0;            // Level Oversold (<=)

input group "=== News Settings ==="
input bool                InpEnableNewsFilter    = true;        // Aktifkan news filter (blokir entry baru saja)
input int                 InpNewsRefreshHours    = 6;           // Interval refresh data (jam)
input bool                InpIncludeMediumImpact = true;        // Sertakan impact medium
input string              InpNewsCurrencyOverride = "";         // Override currency (""=auto; "USD" / "USD,EUR")
input int                 InpNewsBufferBeforeMin = 30;          // Blokir entry X menit sebelum event
input int                 InpNewsBufferAfterMin  = 30;          // Blokir entry X menit setelah event
input int                 InpNewsFetchTimeoutMs  = 8000;        // Timeout WebRequest (ms)
input int                 InpNewsCacheMaxAgeHours = 48;         // Cache dianggap stale setelah (jam)
input int                 InpNewsTzShiftMin      = 0;           // Koreksi jam feed news (menit)
input string              InpNewsUrlBase = "https://sslecal2.investing.com"; // Base URL kalender

input group "=== Visual Settings ==="
input bool                InpShowOB          = true;            // Order Block boxes
input bool                InpShowFVG         = true;            // Fair Value Gap boxes
input bool                InpShowStructure   = true;            // BOS/CHoCH + HH/HL/LH/LL
input bool                InpShowSessionBands = true;           // Kotak outline sesi awal-akhir (v1.17: tanpa fill)
input bool                InpShowSweep       = true;            // Liquidity sweep markers
input bool                InpShowEntryArrows = true;            // Entry arrows + labels
input bool                InpShowPivot       = true;            // Daily pivots PP/R/S
input bool                InpShowVolumeProfile = true;          // Volume Profile VAH/VAL/POC
input bool                InpShowNewsMarkers = true;            // News vline + shading window

input group "=== General ==="
input long                InpMagicNumber     = 20260830;        // Magic number EA
input bool                InpShowDashboard   = true;            // Tampilkan dashboard
input ENUM_BASE_CORNER    InpDashboardCorner = CORNER_LEFT_UPPER; // Pojok panel
input int                 InpDashboardFontSize = 9;             // Font size panel (6..12)
input double              InpPipSizeOverride = 0.0;         // Override ukuran 1 pip (0=auto: 5/3/2 digit→10×point)
input int                 InpPerformanceLookbackDays = 7;   // Jendela section Performa (hari)

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
// GLOBAL STATE (orkestrator = file ini; modul tanpa akses input)
//===================================================================
SHunterSettings      g_settings;
CDataService         g_data;
CSessionManager      g_sessions;
CORBDetector         g_orb;
CSMCEngine           g_smc;
CConfluenceValidator g_conf;
CRiskManager         g_risk;
CTradeExecutor       g_exec;
CNewsFilter          g_news;
CVisualRenderer      g_visual;
CHunterDashboard     g_dash;

ENUM_HUNT_STATE      g_state[HUNT_SESSION_COUNT];    // state machine PER SESI
SSignalPlan          g_plan[HUNT_SESSION_COUNT];     // plan aktif per sesi
bool                 g_fcResidue[HUNT_SESSION_COUNT];    // force-close tertahan (market closed)
datetime             g_fcResidueLog[HUNT_SESSION_COUNT]; // throttle log retry
SBreakout            g_lastBo[HUNT_SESSION_COUNT];   // info utk dashboard
SSMCContext          g_lastCtx[HUNT_SESSION_COUNT];  // info utk dashboard
datetime               g_chochTime=0;                 // CHoCH HTF terbaru
ENUM_HUNT_DIR          g_chochFrom=HUNT_DIR_NONE;
ENUM_HUNT_DIR          g_chochTo=HUNT_DIR_NONE;
string                 g_perfFile="";                 // jurnal trade (csv)
datetime             g_lastPnlScan[HUNT_SESSION_COUNT]; // anti double-count P/L
bool                 g_timerOn=false;

//--- prototipe helper lokal ----------------------------------------
bool     SnapshotSettings(SHunterSettings &s);
void     StateToString(const ENUM_HUNT_STATE st,string &dst);
void     AdvanceState(const int session,const ENUM_HUNT_STATE to);

//--- dashboard/performa/jurnal — forward decl (definisi pasca BuildSignalLine)
void     AmdPhaseLabel(const int session,const datetime nowBrk,string &lbl,color &col);
void     DashChk(const int row,const string label,const bool hasDir,const bool ok);
void     UpdateChecklistRows(const int act,const datetime nowBrk);
void     UpdateBarDashboard(const datetime nowBrk);
void     JournalClosedTrade(const int session,const ENUM_HUNT_DIR dir,const double entry,
                            const double sl,const double lots,const double pnl);
void     UpdatePerformanceSection(void);
string   GetStateLabel(const int s);
double   ExtensionPct(const SOpenRange &r,const ENUM_HUNT_DIR dir,const double price);
void     FillSmcContext(const int s,const SOpenRange &r,const ENUM_HUNT_DIR dir,
                        const double price,SSMCContext &ctx);
bool     RetestReaction(const int s,const SSignalPlan &plan);
void     InvalidateSetup(const int s,const string why);
double   CollectRealizedPnl(const int s);
string   BuildSignalLine(const int s);
void     RenderAllStaticLayers(const datetime nowBrk);
void     PipelineOnNewBar(void);
void     ProcessSession(const int s,const datetime nowBrk);
void     RealtimeTick(void);

//+------------------------------------------------------------------+
//| Snapshot + validasi input + normalisasi (pip, jam sesi→broker).   |
//| Return false → OnInit mengembalikan INIT_PARAMETERS_INCORRECT.     |
//+------------------------------------------------------------------+
bool SnapshotSettings(SHunterSettings &s)
  {
   SettingsDefaults(s);
   s.magic                =InpMagicNumber;
   s.enableSession[HUNT_SESSION_ASIA]  =InpEnableAsia;
   s.enableSession[HUNT_SESSION_LONDON]=InpEnableLondon;
   s.enableSession[HUNT_SESSION_NY]    =InpEnableNY;
   s.gmtOffset            =InpGMTOffset;
   s.rangeMinutes         =InpRangeMinutes;
   s.minRangePips         =InpMinRangePips;
   s.breakoutBufferPips   =InpBreakoutBufferPips;
   s.requireBodyClose     =InpRequireBodyClose;
   s.falseBreakBars       =InpFalseBreakBars;
   s.swingLookback        =InpSwingLookback;
   s.chochLookback        = InpCHoCHSwingLookback;
   s.chochAlertMin        = MathMax(5,InpCHoCHAlertMinutes);
   s.perfLookbackDays     = MathMax(1,InpPerformanceLookbackDays);
   s.requireHtfBias         =InpRequireHtfBias;
   s.requireLiquiditySweep=InpRequireLiquiditySweep;
   s.requireRetest        =InpRequireFVGRetest;
   s.retestMaxBars        =InpRetestMaxBars;
   s.maxExtensionPct      =InpMaxExtensionBeforeRetest;
   s.liqTolPips           =InpLiqTolerancePips;
   s.useFvgAsZone         =InpUseFVGAsZone;
   s.smcScopeDay          =InpSmcScopeDay;
   s.useBreakers          =InpUseBreakerBlocks;
   s.requireInducement    =InpRequireInducement;
   s.requireDiscount      =InpRequireDiscountZone;
   s.tpUseLiquidity       =InpTpLiquidity;
   s.slAtrMult            =InpSLBufferAtrMult;
   s.obDisplacementAtr    =InpOBDisplacementAtr;
   s.atrPeriod            =InpATRPeriod;
   s.htf                  =InpHTFTimeframe;
   s.minScore             =InpMinConfluenceScore;
   s.entryMode            =InpEntryMode;
   s.mode                 =InpMode;
   s.swingCloseOnOppChoch =InpSwingCloseOnOppChoch;
   s.riskPercent          =InpRiskPercent;
   s.riskBase             =InpRiskBase;
   s.lotMode              =InpLotMode;
   s.fixedLots            =InpFixedLots;
   s.minRR                =InpMinRR;
   s.tp1RR                =InpTP1RR;
   s.partialClosePct      =InpPartialClosePct;
   s.trailAfterTp1        =InpTrailAfterTP1;
   s.maxTradesPerDay      =InpMaxTradesPerDay;
   s.maxDailyLossPct      =InpMaxDailyLossPercent;
   s.forceCloseMinBefore  =InpForceCloseMinutesBeforeEnd;
   s.maxSpreadPips        =InpMaxSpreadPips;
   s.maxSlippagePoints    =InpMaxSlippagePoints;
   s.orderRetries         =InpOrderRetries;
   s.orderRetryDelayMs    =InpOrderRetryDelayMs;
   s.pendingExpireHours   =InpPendingExpireHours;
   s.obosPeriod           =InpOBOSPeriod;
   s.obosUpper            =InpOBOSUpperLevel;
   s.obosLower            =InpOBOSLowerLevel;
   s.newsEnabled          =InpEnableNewsFilter;
   s.newsRefreshHours     =InpNewsRefreshHours;
   s.newsIncludeMedium    =InpIncludeMediumImpact;
   s.newsCurrencyOverride =InpNewsCurrencyOverride;
   s.newsBeforeMin        =InpNewsBufferBeforeMin;
   s.newsAfterMin         =InpNewsBufferAfterMin;
   s.newsFetchTimeoutMs   =InpNewsFetchTimeoutMs;
   s.newsCacheMaxAgeHours =InpNewsCacheMaxAgeHours;
   s.newsTzShiftMin       =InpNewsTzShiftMin;
   s.newsUrlBase          =InpNewsUrlBase;
   s.showOB               =InpShowOB;
   s.showFvg              =InpShowFVG;
   s.showStructure        =InpShowStructure;
   s.showSessionBands     =InpShowSessionBands;
   s.showSweep            =InpShowSweep;
   s.showEntryArrows      =InpShowEntryArrows;
   s.showPivot            =InpShowPivot;
   s.showVolumeProfile    =InpShowVolumeProfile;
   s.showNewsMarkers      =InpShowNewsMarkers;
   s.showDashboard        =InpShowDashboard;
   s.dashCorner           =InpDashboardCorner;
   s.dashFontSize         =InpDashboardFontSize;

   //--- validasi -----------------------------------------------------
   string err="";
   if(s.rangeMinutes<1 || s.rangeMinutes>480)
      err="InpRangeMinutes harus 1..480";
   else if(s.falseBreakBars<0 || s.falseBreakBars>10)
      err="InpFalseBreakBars harus 0..10";
   else if(s.swingLookback<2 || s.swingLookback>50)
      err="InpSwingLookback harus 2..50";
   else if(s.retestMaxBars<1 || s.retestMaxBars>100)
      err="InpRetestMaxBars harus 1..100";
   else if(s.maxExtensionPct<5.0 || s.maxExtensionPct>500.0)
      err="InpMaxExtensionBeforeRetest harus 5..500 (%)";
   else if(s.riskPercent<0.01 || s.riskPercent>10.0)
      err="InpRiskPercent harus 0.01..10";
   else if(s.fixedLots<=0.0 || s.fixedLots>100.0)
      err="InpFixedLots harus >0 dan <=100";
   else if(s.minRR<0.5 || s.minRR>20.0)
      err="InpMinRR harus 0.5..20";
   else if(s.tp1RR<0.0 || s.tp1RR>=s.minRR)
      err="InpTP1RR harus 0 (off) atau < InpMinRR";
   else if(s.partialClosePct<1.0 || s.partialClosePct>100.0)
      err="InpPartialClosePct harus 1..100";
   else if(s.forceCloseMinBefore<0 || s.forceCloseMinBefore>240)
      err="InpForceCloseMinutesBeforeEnd harus 0..240";
   else if(s.maxTradesPerDay<0 || s.maxTradesPerDay>50)
      err="InpMaxTradesPerDay harus 0..50";
   else if(s.obosPeriod<2 || s.obosPeriod>200)
      err="InpOBOSPeriod harus 2..200";
   else if(s.obosUpper<=s.obosLower)
      err="Level RSI upper harus > lower";
   else if(s.newsBeforeMin<0 || s.newsBeforeMin>240 || s.newsAfterMin<0 || s.newsAfterMin>240)
      err="Buffer news harus 0..240 menit";
   else if(s.newsRefreshHours<1 || s.newsRefreshHours>72)
      err="InpNewsRefreshHours harus 1..72";
   else if(s.orderRetries<0 || s.orderRetries>10)
      err="InpOrderRetries harus 0..10";
   else if(s.pendingExpireHours<1 || s.pendingExpireHours>336)
      err="InpPendingExpireHours harus 1..336";
   else if(s.minScore<0 || s.minScore>100)
      err="InpMinConfluenceScore harus 0..100";
   else if(s.dashFontSize<6 || s.dashFontSize>12)
      err="InpDashboardFontSize harus 6..12";
   else if(s.magic<=0)
      err="InpMagicNumber harus > 0";
   else if(InpAsiaStart<0||InpAsiaStart>23||InpAsiaEnd<0||InpAsiaEnd>23||
           InpLondonStart<0||InpLondonStart>23||InpLondonEnd<0||InpLondonEnd>23||
           InpNYStart<0||InpNYStart>23||InpNYEnd<0||InpNYEnd>23)
      err="Jam sesi harus 0..23";
   else if(!InpAutoGmt && (InpGMTOffset<-12 || InpGMTOffset>14))
      err="InpGMTOffset harus -12..14 (atau set InpAutoGmt=true)";
   else if(s.slAtrMult<0.0 || s.slAtrMult>2.0)
      err="InpSLBufferAtrMult harus 0..2";
   if(err!="")
     {
      PrintFormat("%s | INPUT INVALID: %s",HUNT_NAME,err);
      Alert(HUNT_NAME,": ",err);
      return(false);
     }
   //--- pip/point/digits (multi-pair). Indeks non-FX (digits 1/2→FX-like;
   //--- 0/4 → pip=point). Override manual: sesuaikan via kode bila perlu.
   s.digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   s.point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   s.tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(s.tickSize<=0.0)
      s.tickSize=s.point;
   if(s.digits==5 || s.digits==3 || s.digits==2)
      s.pipSize=s.point*10.0;
   else
      s.pipSize=s.point;
   s.pipOverride=InpPipSizeOverride;
   if(s.pipOverride>0.0)
      s.pipSize=s.pipOverride;                 // broker/konvensi eksotis
   //--- MODE BUNDLE (SWING, v1.02): preset konservatif utk carry overnight.
   //--- MENIMPA field-field ini dr input (nol dampak saat INTRADAY).
   if(s.mode==HUNT_MODE_SWING)
     {
      s.forceCloseMinBefore=0;                     // tak ada tutup paksa
      if(s.retestMaxBars<40)
         s.retestMaxBars=40;
      if(s.slAtrMult<0.5)
         s.slAtrMult=0.5;
      if(s.minRR<2.5)
         s.minRR=2.5;
      if(s.tp1RR>0.0 && s.tp1RR<1.5)
         s.tp1RR=1.5;
      if(s.pendingExpireHours<48)
         s.pendingExpireHours=48;
      if(s.maxExtensionPct<45.0)
         s.maxExtensionPct=45.0;
     }
   //--- offset broker−UTC: auto-ukur DI CHART SAJA — di tester TimeGMT() ==
   //--- TimeCurrent() (jam server simulasi) sehingga pengukuran SELALU 0 dan
   //--- silent-wrong; tester wajib pakai InpGMTOffset manual (A7). Lihat
   //--- ReapplyTimeBaseWindows() utk pembaruan harian.                        |
   if(InpAutoGmt && !(bool)MQLInfoInteger(MQL_TESTER))
     {
      datetime gt=TimeGMT();
      int off=(gt>0) ? (int)MathRound((double)(TimeCurrent()-gt)/3600.0) : 99;
      if(off>=-12 && off<=14)
         s.gmtOffset=off;
      else
         PrintFormat("%s | AUTO-GMT tidak valid (tester?) → fallback manual %d jam",
                     HUNT_NAME,s.gmtOffset);
     }
   //--- jam sesi → ruang BROKER ------------------------------------------------
   int inStart[HUNT_SESSION_COUNT]={InpAsiaStart,InpLondonStart,InpNYStart};
   int inEnd  [HUNT_SESSION_COUNT]={InpAsiaEnd,InpLondonEnd,InpNYEnd};
   for(int i=0;i<HUNT_SESSION_COUNT;i++)
     {
      int sh=inStart[i],eh=inEnd[i];
      if(InpTimeBase!=HUNT_TIME_BASE_BROKER)
        {
         sh=sh+s.gmtOffset;
         eh=eh+s.gmtOffset;
        }
      s.startHourBrk[i]=((sh%24)+24)%24;
      s.endHourBrk[i]  =((eh%24)+24)%24;
     }
   return(true);
  }

//+------------------------------------------------------------------+
void StateToString(const ENUM_HUNT_STATE st,string &dst)
  {
   dst="";
   switch(st)
     {
      case HUNT_STATE_IDLE:               dst="Idle";               break;
      case HUNT_STATE_RANGE_FORMING:      dst="Range forming";      break;
      case HUNT_STATE_WAIT_BREAKOUT:      dst="Waiting breakout";   break;
      case HUNT_STATE_BREAKOUT_CONFIRMED: dst="Breakout confirmed"; break;
      case HUNT_STATE_WAIT_RETEST:        dst="Waiting retest";     break;
      case HUNT_STATE_READY_ENTRY:        dst="Ready entry";        break;
      case HUNT_STATE_MANAGING:           dst="In position";        break;
      case HUNT_STATE_FORCE_CLOSED:       dst="Force closed";       break;
      default:                            dst="?";                  break;
     }
  }

/** Transisi terpusat + log. [in] session, to. Return void. */
void AdvanceState(const int session,const ENUM_HUNT_STATE to)
  {
   if(session<0 || session>=HUNT_SESSION_COUNT)
      return;
   if(g_state[session]==to)
      return;
   string from,lbl;
   StateToString(g_state[session],from);
   StateToString(to,lbl);
   PrintFormat("%s | %s: %s -> %s",HUNT_NAME,CSessionManager::SessionName(session),from,lbl);
   g_state[session]=to;
  }

string GetStateLabel(const int s)
  {
   if(s<0 || s>=HUNT_SESSION_COUNT)
      return("--");
   string st;
   StateToString(g_state[s],st);
   return(st);
  }

//+------------------------------------------------------------------+
//| Extension % dari level OR ke harga (invalidasi + skor). Div-zero   |
//| aman (HUNT_PctOfRange). [in] r, dir, price. Return persen 0..N.     |
//+------------------------------------------------------------------+
double ExtensionPct(const SOpenRange &r,const ENUM_HUNT_DIR dir,const double price)
  {
   double rng=r.high-r.low;
   if(rng<=0.0)
      return(0.0);
   double mv=(dir==HUNT_DIR_BUY ? price-r.high : r.low-price);
   if(mv<=0.0)
      return(0.0);
   return(HUNT_PctOfRange(mv,rng));
  }

//+------------------------------------------------------------------+
//| Snapshot konteks SMC utk ConfluenceValidator (loose coupling).      |
//+------------------------------------------------------------------+
void FillSmcContext(const int s,const SOpenRange &r,const ENUM_HUNT_DIR dir,
                    const double price,SSMCContext &ctx)
  {
   ctx.htfBias=g_smc.HtfBias();
   datetime since=(g_settings.smcScopeDay ? g_sessions.CurrentDayUtc()
                                         : r.sessionStart);   // v1.06: opsi anchor hari
   ctx.sweptInDirection=g_smc.IsLiquiditySwept(dir,since);
   ctx.sweepTime=g_smc.LastSweepTime(dir);
   ctx.bosSinceSweep=g_smc.HasStructureShift(dir,(ctx.sweepTime>0 ? ctx.sweepTime : since));
   SZone z;
   ctx.zoneFound=g_smc.NearestActiveZone(dir,price,since,z);
   if(ctx.zoneFound)
     {
      ctx.zoneType=z.type;
      ctx.zoneTop=z.top;
      ctx.zoneBottom=z.bottom;
      ctx.zoneId=z.id;
      int age=(int)((g_data.CurrentBarTime()-z.createdTime)/PeriodSeconds(_Period));
      ctx.zoneFresh=(age>=0 && age<=3);
     }
   else
     {
      ctx.zoneType=HUNT_ZONE_NONE;
      ctx.zoneTop=0.0;
      ctx.zoneBottom=0.0;
      ctx.zoneId=0;
      ctx.zoneFresh=false;
     }
   double atr=g_data.Atr(0);
   ctx.rangeBigAtr=(atr>0.0 && (r.high-r.low)>2.0*atr);
   ctx.extensionPct=ExtensionPct(r,dir,price);
   ctx.rsi=g_data.Rsi(0);
   ctx.rsiExtreme=(ctx.rsi!=DBL_MAX &&
                   ((dir==HUNT_DIR_BUY && ctx.rsi>=g_settings.obosUpper) ||
                    (dir==HUNT_DIR_SELL && ctx.rsi<=g_settings.obosLower)));
   //--- v1.07 inducement: minor low(BUY)/high(SELL) tersapu SETELAH anchor dan
   //--- SEBELUM bar breakout (manipulasi leg pra-break)
   ctx.inducementSwept=false;
   datetime tw=g_smc.LastMinorSweep(dir);
   if(tw>=since && g_lastBo[s].time>0 && tw<=g_lastBo[s].time)
      ctx.inducementSwept=true;
   //--- v1.07 posisi zona vs range HARI ini (discount utk BUY / premium SELL)
   ctx.pricePosOk=false;
   if(ctx.zoneFound)
     {
      double dHi=0.0,dLo=0.0;
      bool have=false;
      int nb=g_data.ClosedBars();
      for(int bb=0;bb<nb;bb++)
        {
         MqlRates br2;
         if(!g_data.GetClosedBar(bb,br2) || br2.time<since)
            break;
         if(!have)
           { dHi=br2.high; dLo=br2.low; have=true; }
         else
           {
            if(br2.high>dHi) dHi=br2.high;
            if(br2.low<dLo)  dLo=br2.low;
           }
        }
      if(have && dHi>dLo)
        {
         double eq=(dHi+dLo)/2.0;
         ctx.pricePosOk=(dir==HUNT_DIR_BUY ? ctx.zoneTop<=eq : ctx.zoneBottom>=eq);
        }
     }
  }

//+------------------------------------------------------------------+
//| EXECUTION: retest valid = bar closed menyinggung zona DAN reaksi    |
//| searah breakout (close kembali melewati mid zona). Closed-bar only. |
//+------------------------------------------------------------------+
bool RetestReaction(const int s,const SSignalPlan &plan)
  {
   MqlRates br;
   if(!g_data.GetClosedBar(0,br))
      return(false);
   if(br.time<=g_lastBo[s].time)
      return(false);                     // jangan reaktif pada bar breakout
   if(br.high<plan.zoneBottomSnap || br.low>plan.zoneTopSnap)
      return(false);                     // tidak menyinggung zona
   double mid=(plan.zoneTopSnap+plan.zoneBottomSnap)/2.0;
   if(plan.dir==HUNT_DIR_BUY)
      return(br.close>br.open && br.close>mid);
   return(br.close<br.open && br.close<mid);
  }

//+------------------------------------------------------------------+
//| v1.07: pindahkan TP2 ke pool likuiditas BELUM-tersapu terdekat searah |
//| bila RR tetap ≥ min dan jarak ≤ 4×ATR; TP1 dinormalkan (off bila ≥TP2)|
//+------------------------------------------------------------------+
void ApplyLiquidityTp(SSignalPlan &p)
  {
   double cand=g_smc.NextLiqTarget(p.dir,p.entry);
   if(cand<=0.0)
      return;
   double slDist=(p.dir==HUNT_DIR_BUY ? p.entry-p.sl : p.sl-p.entry);
   if(slDist<=0.0)
      return;
   double dist=MathAbs(cand-p.entry);
   double atr=g_data.Atr(0);
   if(atr>0.0 && dist>4.0*atr)
      return;
   if(dist/slDist<g_settings.minRR)
      return;
   p.tp2=g_data.NormalizePrice(cand);
   if(g_settings.tp1RR<=0.0)
      p.tp1=0.0;
   else
     {
      double t1d=(p.dir==HUNT_DIR_BUY ? 1.0 : -1.0)*g_settings.tp1RR*slDist;
      p.tp1=g_data.NormalizePrice(p.entry+t1d);
      if(MathAbs(p.tp1-p.entry)>=MathAbs(p.tp2-p.entry))
         p.tp1=0.0;                     // partial off — TP2 lebih dekat dari TP1
     }
   p.rrFinal=dist/slDist;
   p.note+=" | TP=liq";
  }

//+------------------------------------------------------------------+
//| v1.09 AUTODST — aritmetika kalender TZ-immune (civil_from_days    |
//| Hinnant); 0=Minggu.                                                |
//+------------------------------------------------------------------+
int                 WeekdaySun(const int y,const int mo,const int d)
  {
   int yy=y-(mo<=2?1:0);
   int era=(yy>=0?yy:yy-399)/400;
   int yoe=yy-era*400;
   int doy=(153*(mo+(mo>2?-3:9))+2)/5+d-1;
   int doe=yoe*365+yoe/4-yoe/100+doy;
   long di=(long)era*146097+doe-719468;
   int wd=(int)((di+4)%7);
   if(wd<0)
      wd+=7;
   return(wd);
  }
//--- EU: aktif sejak Minggu-terakhir Maret s/d SEBELUM Minggu-terakhir
//--- Okt (switch-back 01:00 UTC, sesi hari itu sudah waktu standar).
bool                EuDstActive(const int y,const int mo,const int d)
  {
   if(mo<3 || mo>10)
      return(false);
   if(mo==3)
      return(d>=31-WeekdaySun(y,3,31));
   if(mo==10)
      return(d< 31-WeekdaySun(y,10,31));
   return(true);
  }
//--- US: aktif sejak Minggu-ke-2 Maret s/d SEBELUM Minggu-ke-1 Nov.
bool                UsDstActive(const int y,const int mo,const int d)
  {
   if(mo<3 || mo>11)
      return(false);
   if(mo==3)
     {
      int first=1+((7-WeekdaySun(y,3,1))%7);
      return(d>=first+7);
     }
   if(mo==11)
     {
      int first=1+((7-WeekdaySun(y,11,1))%7);
      return(d<first);
     }
   return(true);
  }
void                AutoDstBrokerDate(int &y,int &mo,int &d)
  {
   long off=(long)g_settings.gmtOffset*3600;
   long dayIdx=((long)g_sessions.CurrentDayUtc()+off)/86400;   // UTC midnight tgl broker
   long z=dayIdx+719468;
   long era=(z>=0?z:z-146096)/146097;
   long doe=z-era*146097;
   long yoe=(doe-doe/1460+doe/36524-doe/146096)/365;
   long yyyy=yoe+era*400;
   long doy=doe-(365*yoe+yoe/4-yoe/100);
   long mp=(5*doy+2)/153;
   d =(int)(doy-(153*mp+2)/5+1);
   mo=(int)(mp+(mp>9?-9:3));
   y =(int)(yyyy+(mo<=2?1:0));
  }
//+------------------------------------------------------------------+
//| v1.09: hitung jam sesi utk basis AUTODST — London/NY dari JAM     |
//| LOKAL bursa (input) minus offset zona (0/+1 UK; -5/-4 NY) sesuai   |
//| aturan DST legal → UTC → broker. Asia: input = UTC apa adanya     |
//| (anchor Tokyo/Sydney tidak bergeser utk jendela ini). SEMUA dihitung |
//| lokal/offline — tanpa sumber atau tabel pihak ketiga (v1.10).        |
//+------------------------------------------------------------------+
void                ApplyAutoDstWindows(void)
  {
   if(InpTimeBase!=HUNT_TIME_BASE_AUTODST)
      return;
   int y=0,mo=0,d=0;
   AutoDstBrokerDate(y,mo,d);
   bool euD=EuDstActive(y,mo,d),usD=UsDstActive(y,mo,d);
   int off=g_settings.gmtOffset;
   int sh[HUNT_SESSION_COUNT],eh[HUNT_SESSION_COUNT];
   sh[HUNT_SESSION_ASIA]  =((InpAsiaStart    +off)%24+24)%24;
   eh[HUNT_SESSION_ASIA]  =((InpAsiaEnd      +off)%24+24)%24;
   sh[HUNT_SESSION_LONDON]=(((InpLondonStart-(euD?1:0))+off)%24+24)%24;
   eh[HUNT_SESSION_LONDON]=(((InpLondonEnd  -(euD?1:0))+off)%24+24)%24;
   sh[HUNT_SESSION_NY]    =(((InpNYStart    +5-(usD?1:0))+off)%24+24)%24;
   eh[HUNT_SESSION_NY]    =(((InpNYEnd      +5-(usD?1:0))+off)%24+24)%24;
   g_sessions.ApplySessionHours(sh,eh);
   for(int i=0;i<HUNT_SESSION_COUNT;i++)
     {
      g_settings.startHourBrk[i]=sh[i];
      g_settings.endHourBrk[i]  =eh[i];
     }
   PrintFormat("%s | AUTO-DST %04d.%02d.%02d (EU:%s US:%s) → broker LON %02d-%02d NY %02d-%02d | UTC LON %02d-%02d NY %02d-%02d",
               HUNT_NAME,y,mo,d,(euD?"dst":"std"),(usD?"dst":"std"),
               sh[1],eh[1],sh[2],eh[2],
               ((sh[1]-off)%24+24)%24,((eh[1]-off)%24+24)%24,
               ((sh[2]-off)%24+24)%24,((eh[2]-off)%24+24)%24);
  }

//+------------------------------------------------------------------+
//| v1.12: ukur ulang offset broker−UTC + bangun ulang jam sesi tiap    |
//| ganti hari. Chart → auto (TimeGMT; broker yang server-nya geser     |
//| ikut ter-follow); tester → InpGMTOffset manual (TimeGMT di tester    |
//| == jam server simulasi, pengukuran selalu 0).                         |
//+------------------------------------------------------------------+
void                ReapplyTimeBaseWindows(void)
  {
   const bool tester=(bool)MQLInfoInteger(MQL_TESTER);
   int off=g_settings.gmtOffset;
   if(InpAutoGmt && !tester)
     {
      datetime gt=TimeGMT();
      int m=(gt>0) ? (int)MathRound((double)(TimeCurrent()-gt)/3600.0) : 99;
      if(m>=-12 && m<=14)
         off=m;
     }
   else
      off=InpGMTOffset;
   if(off!=g_settings.gmtOffset)
      PrintFormat("%s | offset GMT broker diperbarui %+d → %+d jam (server DST-shift?)",
                  HUNT_NAME,g_settings.gmtOffset,off);
   g_settings.gmtOffset=off;
   g_sessions.UpdateGmtOffset(off);
   g_news.UpdateGmtOffset(off);
   if(InpTimeBase==HUNT_TIME_BASE_AUTODST)
     {
      ApplyAutoDstWindows();                     // sudah sinkron sh/eh sendiri
      return;
     }
   int sh[HUNT_SESSION_COUNT],eh[HUNT_SESSION_COUNT];
   int inStart[HUNT_SESSION_COUNT]={InpAsiaStart,InpLondonStart,InpNYStart};
   int inEnd  [HUNT_SESSION_COUNT]={InpAsiaEnd,InpLondonEnd,InpNYEnd};
   for(int i=0;i<HUNT_SESSION_COUNT;i++)
     {
      int s0=inStart[i],e0=inEnd[i];
      if(InpTimeBase==HUNT_TIME_BASE_UTC)
        { s0+=off; e0+=off; }
      sh[i]=((s0%24)+24)%24;
      eh[i]=((e0%24)+24)%24;
     }
   g_sessions.ApplySessionHours(sh,eh);
   for(int i=0;i<HUNT_SESSION_COUNT;i++)
     {
      g_settings.startHourBrk[i]=sh[i];
      g_settings.endHourBrk[i]  =eh[i];
     }
  }

//+------------------------------------------------------------------+
//| Invalidasi setup sesi: batalkan pending, re-arm breakout berikutnya. |
//+------------------------------------------------------------------+
void InvalidateSetup(const int s,const string why)
  {
   if(s<0 || s>=HUNT_SESSION_COUNT)
      return;
   if(g_plan[s].pendingTicket!=0)
      g_exec.CancelOrder(g_plan[s].pendingTicket,"invalidasi: "+why);
   g_plan[s].Reset();
   g_sessions.SetOrStatus(s,ORB_STATUS_RANGING);
   g_orb.Reset(s);
   AdvanceState(s,HUNT_STATE_WAIT_BREAKOUT);
   PrintFormat("%s | %s: setup invalid (%s)",HUNT_NAME,CSessionManager::SessionName(s),why);
  }

//+------------------------------------------------------------------+
//| Tarik realized P/L dari history (deals OUT magic EA) tanpa          |
//| double-count (memo g_lastPnlScan per sesi). Update RiskManager.     |
//+------------------------------------------------------------------+
double CollectRealizedPnl(const int s)
  {
   if(s<0 || s>=HUNT_SESSION_COUNT)
      return(0.0);
   datetime t0=(g_lastPnlScan[s]>0 ? g_lastPnlScan[s]+1 : g_sessions.CurrentDayUtc());
   datetime t1=TimeCurrent()+60;
   if(!HistorySelect(t0,t1))
      return(0.0);
   double sum=0.0;
   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
     {
      ulong dt=HistoryDealGetTicket(i);
      if(dt==0)
         continue;
      if(HistoryDealGetInteger(dt,DEAL_MAGIC)!=(long)g_settings.magic)
         continue;
      if(HistoryDealGetString(dt,DEAL_SYMBOL)!=_Symbol)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt,DEAL_ENTRY)!=DEAL_ENTRY_OUT)
         continue;
      datetime td=(datetime)HistoryDealGetInteger(dt,DEAL_TIME);
      sum+=HistoryDealGetDouble(dt,DEAL_PROFIT)+HistoryDealGetDouble(dt,DEAL_SWAP);
      if(td>g_lastPnlScan[s])
         g_lastPnlScan[s]=td;
     }
   if(sum!=0.0)
     {
      g_risk.RegisterClosedTrade(sum);
      PrintFormat("%s | %s: realized P/L %+.2f (hari ini %+.2f)",HUNT_NAME,
                  CSessionManager::SessionName(s),sum,g_risk.DailyPnl());
     }
   return(sum);
  }

//+------------------------------------------------------------------+
//| Baris sinyal dashboard sesi.                                        |
//+------------------------------------------------------------------+
string BuildSignalLine(const int s)
  {
   if(s<0 || s>=HUNT_SESSION_COUNT || g_lastBo[s].time==0)
      return("Signal: waiting breakout");
   string dirTxt=(g_lastBo[s].dir==HUNT_DIR_BUY ? "BreakUp" : "BreakDn");
   return(StringFormat("Last %s | sweep %s | zona %s",
                       dirTxt,(g_lastCtx[s].sweptInDirection ? "yes" : "no"),
                       (g_lastCtx[s].zoneFound ? EnumToString(g_lastCtx[s].zoneType) : "none")));
  }

//+------------------------------------------------------------------+
//| Label fase siklus AMD utk dashboard (badge; warna = palet spec).   |
//+------------------------------------------------------------------+
void AmdPhaseLabel(const int session,const datetime nowBrk,string &lbl,color &col)
  {
   if(session<0)
     {
      lbl="AMD: —"; col=clrGray;
      return;
     }
   int st=(int)g_state[session];
   if(st==HUNT_STATE_BREAKOUT_CONFIRMED)
     {
      lbl="AMD: Manipulation"; col=HUNT_COL_AMD_MAN;
      return;
     }
   if(st==HUNT_STATE_WAIT_RETEST || st==HUNT_STATE_READY_ENTRY ||
      st==HUNT_STATE_MANAGING)
     {
      lbl="AMD: Distribution"; col=HUNT_COL_AMD_DIS;
      return;
     }
   if(st==HUNT_STATE_FORCE_CLOSED)
     {
      lbl="AMD: Selesai"; col=HUNT_COL_AMD_DONE;
      return;
     }
   //--- IDLE/RANGE_FORMING/WAIT_BREAKOUT → Accumulation; sesi selesai hari ini
   //--- dengan range terbentuk = siklus lengkap → Selesai.
   if(!g_sessions.IsSessionLive(session,nowBrk))
     {
      SOpenRange rr;
      if(g_sessions.GetRange(session,rr) && rr.formed)
        {
         lbl="AMD: Selesai"; col=HUNT_COL_AMD_DONE;
         return;
        }
     }
   lbl="AMD: Accumulation"; col=HUNT_COL_AMD_ACC;
  }

//+------------------------------------------------------------------+
//| Satu baris checklist: ✓/✗ + label; '·' bila belum ada setup arah.   |
//+------------------------------------------------------------------+
void DashChk(const int row,const string label,const bool hasDir,const bool ok)
  {
   g_dash.SetRow(row,(hasDir ? (ok ? "OK  " : "xx  ") : "..  ")+label,
                 CHunterDashboard::ChkColor(hasDir,ok));
  }

//+------------------------------------------------------------------+
//| Section Confluence Checklist — READ-ONLY, mencerminkan evaluasi     |
//| terakhir (g_lastBo/g_lastCtx/g_plan) + status berita live. Tidak     |
//| mengubah logika ConfluenceValidator.                                 |
//+------------------------------------------------------------------+
void UpdateChecklistRows(const int act,const datetime nowBrk)
  {
   if(!g_dash.IsActive())
      return;
   ENUM_HUNT_DIR dir=HUNT_DIR_NONE;
   if(act>=0)
     {
      if(g_plan[act].dir!=HUNT_DIR_NONE)
         dir=g_plan[act].dir;
      else if(g_lastBo[act].time!=0)
         dir=g_lastBo[act].dir;
     }
   bool  hd =(dir!=HUNT_DIR_NONE);
   int   met=0;
   //--- 1. HTF bias searah arah setup
   ENUM_HUNT_BIAS b=g_smc.HtfBias();
   bool c1=(hd && (!g_settings.requireHtfBias ||
                   (b==HUNT_BIAS_BULLISH && dir==HUNT_DIR_BUY) ||
                   (b==HUNT_BIAS_BEARISH && dir==HUNT_DIR_SELL)));
   if(c1)
      met++;
   DashChk(HUNT_DASH_CHK_BIAS,(g_settings.requireHtfBias ? "HTF bias searah" : "HTF bias (gate off)"),hd,c1);
   //--- 2. liquidity sweep searah terkonfirmasi
   bool c2=(hd && g_lastCtx[act].sweptInDirection);
   if(c2)
      met++;
   DashChk(HUNT_DASH_CHK_SWEEP,"Liquidity sweep terkonfirmasi",hd,c2);
   //--- 3. body close valid di luar range
   bool c3=(hd && (g_lastBo[act].bodyClose || !g_settings.requireBodyClose));
   if(c3)
      met++;
   DashChk(HUNT_DASH_CHK_BODY,"Body close valid di luar range",hd,c3);
   //--- 4. reaksi retest (execution) ATAU status pending (pending mode)
   bool   c4=(hd && !g_settings.requireRetest);
   string l4="Reaksi retest di OB/FVG";
   if(hd)
     {
      if(g_settings.entryMode==ENTRY_PENDING_ORDER)
        {
         if(g_plan[act].submitted)
           {
            l4="Pending order: filled"; c4=true;
           }
         else if(g_plan[act].pendingTicket!=0)
           {
            l4=StringFormat("Pending order: menunggu fill (exp %dbar)",
                            g_exec.PendingBarsLeft(g_plan[act],g_data));
            c4=true;
           }
         else
            l4="Pending order: belum terpasang";
        }
      else if(!g_settings.requireRetest)
         l4="Retest tidak diwajibkan (opt-in)";
      else
        {
         int st=(int)g_state[act];
         if(st==HUNT_STATE_READY_ENTRY || st==HUNT_STATE_MANAGING)
           {
            l4="Reaksi retest di OB/FVG: OK"; c4=true;
           }
         else if(st==HUNT_STATE_WAIT_RETEST)
            l4="Reaksi retest: menunggu";
        }
     }
   if(c4)
      met++;
   DashChk(HUNT_DASH_CHK_RETEST,l4,hd,c4);
   //--- 5. news window aman
   string nlab;
   bool   blocked=(g_settings.newsEnabled && g_news.IsEntryBlocked(nowBrk,nlab));
   bool   c5=!blocked;
   if(c5)
      met++;
   DashChk(HUNT_DASH_CHK_NEWS,
           (blocked ? "News window: BLOCK ("+nlab+")" : "News window aman"),hd,c5);
   g_dash.SetRow(HUNT_DASH_CHK_SUM,
                 StringFormat("Confluence: %d/5 syarat terpenuhi%s",met,
                              (hd ? "" : "  (belum ada setup)")),
                 (!hd ? clrGray :
                  (met>=4 ? clrLimeGreen : (met>=3 ? HUNT_COL_WAIT : clrIndianRed))));
  }

//+------------------------------------------------------------------+
//| Refresh baris berat-dashboard per bar closed (dipanggil juga pasca   |
//| CHoCH & saat init).                                                  |
//+------------------------------------------------------------------+
void UpdateBarDashboard(const datetime nowBrk)
  {
   if(!g_dash.IsActive())
      return;
   SOpenRange ra,rl,rn;
   g_sessions.GetRange(HUNT_SESSION_ASIA,ra);
   g_sessions.GetRange(HUNT_SESSION_LONDON,rl);
   g_sessions.GetRange(HUNT_SESSION_NY,rn);
   int act=g_sessions.ActiveSession(nowBrk);
   string sess="Session: none";
   if(act>=0)
     {
      int toEnd=g_sessions.SecondsToSessionEnd(act,nowBrk);
      sess=StringFormat("Session: %s | %.0f mnt lagi",
                         CSessionManager::SessionName(act),MathMax(0,toEnd)/60.0);
     }
   g_dash.SetRow(HUNT_DASH_SESSION_ACTIVE,sess);
   g_dash.SetRow(HUNT_DASH_RANGE_ASIA,
                 CHunterDashboard::FormatRangeLine("Asia",ra,g_data.PipSize(),g_data.Digits()),
                 CSessionManager::SessionColor(HUNT_SESSION_ASIA));
   g_dash.SetRow(HUNT_DASH_RANGE_LONDON,
                 CHunterDashboard::FormatRangeLine("London",rl,g_data.PipSize(),g_data.Digits()),
                 CSessionManager::SessionColor(HUNT_SESSION_LONDON));
   g_dash.SetRow(HUNT_DASH_RANGE_NY,
                 CHunterDashboard::FormatRangeLine("NY",rn,g_data.PipSize(),g_data.Digits()),
                 CSessionManager::SessionColor(HUNT_SESSION_NY));
   //--- badge fase AMD
   string amd;
   color  amdCol;
   AmdPhaseLabel(act,nowBrk,amd,amdCol);
   g_dash.SetRow(HUNT_DASH_AMD,amd,amdCol);
   //--- alert CHoCH HTF terbaru (hilang setelah chochAlertMin menit)
   string choch="--";
   color  ccol=clrGray;
   if(g_chochTime>0 && (nowBrk-g_chochTime)<=g_settings.chochAlertMin*60)
     {
      choch=StringFormat("! CHoCH: %s -> %s, %s",
                         (g_chochFrom==HUNT_DIR_BUY ? "Bullish" : "Bearish"),
                         (g_chochTo==HUNT_DIR_BUY ? "Bullish" : "Bearish"),
                         TimeToString(g_chochTime,TIME_DATE|TIME_MINUTES));
      ccol=clrOrange;
     }
   g_dash.SetRow(HUNT_DASH_CHOCH,choch,ccol);
   //--- bias + state teknis + sinyal + countdown retest
   g_dash.SetRow(HUNT_DASH_HTF_BIAS,
                 "HTF bias ("+EnumToString(g_settings.htf)+"): "+g_smc.HtfBiasText(),
                 CHunterDashboard::BiasColor(g_smc.HtfBias()));
   g_dash.SetRow(HUNT_DASH_STATE,"State: "+GetStateLabel(act),
                 CHunterDashboard::StateColor(act>=0 ? (int)g_state[act] : HUNT_STATE_IDLE));
   g_dash.SetRow(HUNT_DASH_SIGNAL,(act>=0 ? BuildSignalLine(act) : "Signal: --"));
   string cdLine="";
   if(act>=0 && g_state[act]==HUNT_STATE_WAIT_RETEST)
     {
      SOpenRange r;
      if(g_sessions.GetRange(act,r))
        {
         double px=(r.breakoutDir==HUNT_DIR_BUY ? g_data.Bid() : g_data.Ask());
         cdLine=StringFormat("Retest: %d bar sisa | ext %.0f%%",
                             MathMax(0,g_settings.retestMaxBars-r.barsSinceBreakout),
                             ExtensionPct(r,r.breakoutDir,px));
        }
     }
   g_dash.SetRow(HUNT_DASH_RETEST_CD,cdLine,(cdLine=="" ? clrGray : HUNT_COL_WAIT));
   g_dash.SetRow(HUNT_DASH_OBOS,
                 CHunterDashboard::FormatObos(g_data.Rsi(0),g_settings.obosUpper,
                                              g_settings.obosLower,g_settings.obosPeriod));
   UpdateChecklistRows(act,nowBrk);
  }

//+------------------------------------------------------------------+
//| Jurnal trade tertutup → MQL5\Files\HUNT_perf_<Symbol>.csv (kolom:  |
//| waktu;simbol;sesi;arah;R;pnl). R dihitung dari risiko plan asli —    |
//| riwayat akun tidak menyimpan SL posisi yang sudah closed.             |
//+------------------------------------------------------------------+
void JournalClosedTrade(const int session,const ENUM_HUNT_DIR dir,const double entry,
                        const double sl,const double lots,const double pnl)
  {
   if(pnl==0.0 || g_perfFile=="")
      return;
   double rm=0.0;
   double dist=MathAbs(entry-sl);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(ts>0.0 && tv>0.0 && lots>0.0 && dist>0.0)
     {
      double risk=lots*(dist/ts)*tv;
      if(risk>0.0)
         rm=pnl/risk;
     }
   int h=FileOpen(g_perfFile,FILE_CSV|FILE_READ|FILE_WRITE,';');
   if(h==INVALID_HANDLE)
     {
      PrintFormat("%s | perf: jurnal tidak dapat dibuka (err %d)",HUNT_NAME,GetLastError());
      return;
     }
   FileSeek(h,0,SEEK_END);
   FileWrite(h,TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES),_Symbol,
             CSessionManager::SessionCode(session),
             (dir==HUNT_DIR_BUY ? "BUY" : "SELL"),
             DoubleToString(rm,2),DoubleToString(pnl,2));
   FileClose(h);
   UpdatePerformanceSection();
  }

//+------------------------------------------------------------------+
//| Section Performa: hitung dari account history (magic+symbol) utk     |
//| jumlah/win-rate/PnL; avg R + 3 trade terakhir dari jurnal internal.  |
//| Refresh: init, awal hari, dan tiap posisi ditutup (BUKAN per tick).   |
//+------------------------------------------------------------------+
void UpdatePerformanceSection(void)
  {
   if(!g_dash.IsActive())
      return;
   datetime from=TimeCurrent()-(datetime)g_settings.perfLookbackDays*86400;
   int    trades=0,wins=0;
   double pnlSum=0.0;
   if(HistorySelect(from,TimeCurrent()+60))
     {
      int n=HistoryDealsTotal();
      for(int i=0;i<n;i++)
        {
         ulong dt=HistoryDealGetTicket(i);
         if(dt==0)
            continue;
         if(HistoryDealGetInteger(dt,DEAL_MAGIC)!=(long)g_settings.magic)
            continue;
         if(HistoryDealGetString(dt,DEAL_SYMBOL)!=_Symbol)
            continue;
         ENUM_DEAL_ENTRY en=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt,DEAL_ENTRY);
         if(en!=DEAL_ENTRY_OUT && en!=DEAL_ENTRY_OUT_BY)
            continue;
         double p=HistoryDealGetDouble(dt,DEAL_PROFIT)+HistoryDealGetDouble(dt,DEAL_SWAP)
                  +HistoryDealGetDouble(dt,DEAL_COMMISSION);
         trades++;
         pnlSum+=p;
         if(p>0.0)
            wins++;
        }
     }
   //--- R + 3 trade terakhir dari jurnal (file kecil; scan sekuensial)
   double rSum=0.0;
   int    rN=0,cnt=0;
   string jT[3],jL[3];
   double jR[3];
   int    h=FileOpen(g_perfFile,FILE_CSV|FILE_READ,';');
   if(h!=INVALID_HANDLE)
     {
      while(!FileIsEnding(h))
        {
         string dtime=FileReadString(h);
         if(dtime=="")
            break;
         string sym=FileReadString(h);
         if(sym=="" || sym!=_Symbol)
            break;
         string sessC=FileReadString(h);
         string dirlab=FileReadString(h);
         string rtxt=FileReadString(h);
         string ptxt=FileReadString(h);
         datetime tt=StringToTime(dtime);
         if(tt<from || tt<=0)
            continue;
         double rr=StringToDouble(rtxt);
         double pp=StringToDouble(ptxt);
         rSum+=rr;
         rN++;
         int slot=cnt%3;
         jT[slot]=TimeToString(tt,TIME_DATE|TIME_MINUTES);
         jL[slot]=StringFormat("%s | %s | %+.2fR (%+.2f)",sessC,dirlab,rr,pp);
         jR[slot]=rr;
         cnt++;
        }
      FileClose(h);
     }
   g_dash.SetRow(HUNT_DASH_PERF_SUMMARY,
                 StringFormat("Perf %dd: %d trade | win %s | P/L %+.2f%s",
                              g_settings.perfLookbackDays,trades,
                              (trades>0 ? StringFormat("%.0f%%",wins*100.0/trades) : "--"),
                              pnlSum,
                              (rN>0 ? StringFormat(" | avgR %+.2f",rSum/rN) : " | avgR n/a")),
                 (trades==0 ? clrGray : (pnlSum>=0.0 ? clrLimeGreen : clrIndianRed)));
   int rows[3];
   rows[0]=HUNT_DASH_PERF_T3;
   rows[1]=HUNT_DASH_PERF_T2;
   rows[2]=HUNT_DASH_PERF_T1;
   for(int q=0;q<3;q++)
     {
      if(q>=cnt)
        {
         g_dash.SetRow(rows[q],"—",clrGray);
         continue;
        }
      int slot=(cnt-q-1)%3;
      g_dash.SetRow(rows[q],"  "+jL[slot],
                    (jR[slot]>=0.0 ? HUNT_COL_BULL : HUNT_COL_BEAR));
     }
  }

//+------------------------------------------------------------------+
//| Render layer statis (dipanggil per bar baru & saat init).           |
//+------------------------------------------------------------------+
void RenderAllStaticLayers(const datetime nowBrk)
  {
   g_visual.RenderSessionBands(g_sessions,g_data,nowBrk);
   g_visual.RenderOpeningRanges(g_sessions,g_data,nowBrk);
   g_visual.RenderZones(g_smc,nowBrk);
   g_visual.RenderStructure(g_smc);
   g_visual.RenderSweeps(g_smc);
   g_visual.RenderVolumeProfile(g_sessions,g_data,nowBrk);
   g_visual.Finish();
  }

//+------------------------------------------------------------------+
//| Pipeline per bar closed.                                           |
//+------------------------------------------------------------------+
void PipelineOnNewBar()
  {
   const datetime nowBrk=TimeCurrent();
   if(g_sessions.CheckDailyRolloverRequired(nowBrk))
     {
      g_sessions.ResetDaily(nowBrk);              // v1.09 FIX: rebuild jendela sesi per hari
      ReapplyTimeBaseWindows();                   // v1.12: re-ukur offset + jam sesi
      g_risk.OnNewDay(g_sessions.CurrentDayUtc(),AccountInfoDouble(ACCOUNT_BALANCE));
      g_smc.ResetDaily(g_sessions.GetDayStartUtc());
      g_orb.ResetAll();
      g_visual.OnNewDay();
      for(int s=0;s<HUNT_SESSION_COUNT;s++)
        {
         g_lastPnlScan[s]=0;
         //--- v1.02: posisi/pending HIDUP tidak di-clobber rollover (SWING
         //--- carry overnight; dulu bisa jadi yatim saat force-close off)
         if(g_state[s]==HUNT_STATE_MANAGING || g_plan[s].pendingTicket!=0)
           {
            g_lastBo[s].time=0;
            continue;
           }
         g_state[s]=HUNT_STATE_IDLE;
         g_plan[s].Reset();
         g_lastBo[s].time=0;
        }
      g_visual.RenderPivots(g_data,g_sessions.GetDayStartUtc());
      g_visual.RenderNews(g_news,nowBrk);
      UpdatePerformanceSection();
     }
   g_sessions.Update(g_data,nowBrk);
   g_smc.Update(g_data);
   //--- HTF CHoCH (bias reversal): batalkan setup searah bias lama. Posisi
   //--- terbuka TIDAK disentuh (SL/TP/trailing lanjut — sesuai spesifikasi).
   SChochEvent cev;
   if(g_smc.TakeHtfChoch(cev))
     {
      g_chochTime=cev.time;
      g_chochFrom=cev.fromDir;
      g_chochTo=cev.toDir;
      PrintFormat("%s | HTF CHoCH: %s -> %s @ %s (bar %s)",HUNT_NAME,
                  (cev.fromDir==HUNT_DIR_BUY ? "Bullish" : "Bearish"),
                  (cev.toDir==HUNT_DIR_BUY ? "Bullish" : "Bearish"),
                  DoubleToString(cev.price,g_data.Digits()),
                  TimeToString(cev.time,TIME_DATE|TIME_MINUTES));
      g_visual.RenderHtfChoch(cev.time,cev.price,cev.toDir);
      g_visual.Finish();
      for(int sc=0;sc<HUNT_SESSION_COUNT;sc++)
        {
         int st=(int)g_state[sc];
         bool mg=(st==HUNT_STATE_MANAGING);
         if(!mg && st!=HUNT_STATE_BREAKOUT_CONFIRMED && st!=HUNT_STATE_WAIT_RETEST &&
            st!=HUNT_STATE_READY_ENTRY)
            continue;
         ENUM_HUNT_DIR setupDir=(g_plan[sc].dir!=HUNT_DIR_NONE ? g_plan[sc].dir
                                 : g_lastBo[sc].dir);
         if(setupDir!=cev.fromDir)
            continue;                        // setup tidak searah bias lama
         if(mg)
           {
            //--- SWING ONLY (v1.02): bias berbalik melawan posisi = exit.
            //--- INTRADAY tetap sesuai spesifikasi: CHoCH tak menyentuh posisi.
            if(g_settings.mode!=HUNT_MODE_SWING || !g_settings.swingCloseOnOppChoch)
               continue;
            int nP=0,nQ=0,nF=0;
            g_exec.CloseSessionPositions(sc,nP,nQ,nF);
            if(nF>0)
               g_exec.CloseSessionPositions(sc,nP,nQ,nF);    // upaya ke-2 (requote)
            if(nF>0)
              {
               PrintFormat("%s | %s: CHoCH-exit tertunda (%d order tertahan) — SL/TP tetap bekerja",
                           HUNT_NAME,CSessionManager::SessionName(sc),nF);
               continue;
              }
            double pnlFc=CollectRealizedPnl(sc);
            if(nP>0 || nQ>0 || pnlFc!=0.0)
               JournalClosedTrade(sc,g_plan[sc].dir,g_plan[sc].entry,g_plan[sc].sl,
                                  g_plan[sc].lots,pnlFc);
            PrintFormat("%s | %s: SWING exit — HTF CHoCH berlawanan (%d posisi, P/L %+.2f)",
                        HUNT_NAME,CSessionManager::SessionName(sc),nP,pnlFc);
            g_plan[sc].Reset();
            g_lastBo[sc].time=0;
            g_sessions.SetOrStatus(sc,ORB_STATUS_RANGING);
            g_orb.Reset(sc);
            AdvanceState(sc,HUNT_STATE_FORCE_CLOSED);
            continue;
           }
         if(g_plan[sc].pendingTicket!=0)
            g_exec.CancelOrder(g_plan[sc].pendingTicket,"HTF CHoCH reversal");
         g_plan[sc].Reset();
         g_lastBo[sc].time=0;
         g_sessions.SetOrStatus(sc,ORB_STATUS_RANGING);
         g_orb.Reset(sc);
         if(g_sessions.IsSessionLive(sc,nowBrk))
            AdvanceState(sc,(g_sessions.IsRangeForming(sc,nowBrk)
                             ? HUNT_STATE_RANGE_FORMING : HUNT_STATE_WAIT_BREAKOUT));
         else
            AdvanceState(sc,HUNT_STATE_IDLE);
         PrintFormat("%s | %s: setup dibatalkan (CHoCH HTF berlawanan)",HUNT_NAME,
                     CSessionManager::SessionName(sc));
        }
      UpdateBarDashboard(nowBrk);            // badge AMD + baris bias segera
     }
   for(int s=0;s<HUNT_SESSION_COUNT;s++)
      ProcessSession(s,nowBrk);
   RenderAllStaticLayers(nowBrk);
   UpdateBarDashboard(nowBrk);
  }

//+------------------------------------------------------------------+
//| Mesin state SATU sesi — hanya dipanggil saat bar closed baru.      |
//+------------------------------------------------------------------+
void ProcessSession(const int s,const datetime nowBrk)
  {
   if(!g_settings.enableSession[s])
      return;
   SOpenRange r;
   if(!g_sessions.GetRange(s,r))
      return;

   switch(g_state[s])
     {
      case HUNT_STATE_IDLE:
         if(g_sessions.IsSessionLive(s,nowBrk))
           {
            if(g_sessions.IsRangeForming(s,nowBrk))
               AdvanceState(s,HUNT_STATE_RANGE_FORMING);
            else if(r.formed && r.sizeOk)
               AdvanceState(s,HUNT_STATE_WAIT_BREAKOUT);
           }
         break;

      case HUNT_STATE_RANGE_FORMING:
         if(!g_sessions.IsSessionLive(s,nowBrk))
            AdvanceState(s,HUNT_STATE_IDLE);
         else if(r.formed)
            AdvanceState(s,(r.sizeOk ? HUNT_STATE_WAIT_BREAKOUT : HUNT_STATE_IDLE));
         break;

      case HUNT_STATE_WAIT_BREAKOUT:
        {
         if(!g_sessions.IsSessionLive(s,nowBrk))
           {
            AdvanceState(s,HUNT_STATE_IDLE);
            break;
           }
         g_orb.RefreshStatus(s,r,g_data);
         if(r.status==ORB_STATUS_INVALIDATED)
           {
            //--- v1.04: false-break selesai diproses → re-arm (satu kali per
            //--- invalidasi; batasnya tetap akhir sesi & filter size hari itu)
            g_sessions.SetOrStatus(s,ORB_STATUS_RANGING);
            g_orb.Reset(s);
            break;
           }
         SBreakout bo;
         if(!g_orb.Assess(s,r,g_data,nowBrk,bo))
            break;
         g_lastBo[s]=bo;
         g_sessions.MarkBreakout(s,bo.dir,bo.time,bo.closePrice);
         AdvanceState(s,HUNT_STATE_BREAKOUT_CONFIRMED);
         //--- konfluensi pada bar yang sama
         SSMCContext ctx;
         FillSmcContext(s,r,bo.dir,bo.closePrice,ctx);
         string riskNote;
         bool riskOk=g_risk.CanOpenNewTrade(riskNote);
         string newsLabel;
         bool blocked=g_news.IsEntryBlocked(nowBrk,newsLabel);
         SConfluenceReport rep=g_conf.Review(bo,ctx,blocked,g_data.SpreadPips(),riskOk,riskNote);
         g_lastCtx[s]=ctx;
         if(!rep.passed)
           {
            string why="confluence reject";
            if(rep.reasonCount>0)
               why+=" ("+rep.reasons[0]+")";
            PrintFormat("%s | %s: %s | skor %d",HUNT_NAME,
                        CSessionManager::SessionName(s),why,rep.score);
            AdvanceState(s,HUNT_STATE_WAIT_BREAKOUT);   // event sama tidak diulang
            break;
           }
         //--- susun plan
         SSignalPlan plan;
         plan.Reset();
         plan.planId=(ulong)(TimeCurrent()*10+(long)s);
         plan.session=(ENUM_HUNT_SESSION)s;
         plan.dir=bo.dir;
         plan.mode=g_settings.entryMode;
         plan.breakoutTime=bo.time;
         plan.score=rep.score;
         plan.zoneId=ctx.zoneId;
         plan.zoneTopSnap=ctx.zoneTop;
         plan.zoneBottomSnap=ctx.zoneBottom;
         double entry=(bo.dir==HUNT_DIR_BUY ? g_data.Ask() : g_data.Bid());
         if(g_settings.entryMode==ENTRY_PENDING_ORDER && ctx.zoneFound)
            entry=(bo.dir==HUNT_DIR_BUY ? ctx.zoneTop : ctx.zoneBottom);
         plan.entry=g_data.NormalizePrice(entry);
         double structLevel=0.0;
         if(ctx.zoneFound)
            structLevel=(bo.dir==HUNT_DIR_BUY ? ctx.zoneBottom : ctx.zoneTop);
         else
           {
            MqlRates brk;
            int sh=iBarShift(_Symbol,_Period,bo.time,true);
            if(sh<1)
               sh=1;
            if(g_data.GetClosedBar(sh-1,brk))
               structLevel=(bo.dir==HUNT_DIR_BUY ? brk.low : brk.high);
            else
               structLevel=bo.closePrice;
           }
         if(!g_risk.BuildPlan(plan,g_data,structLevel))
           {
            PrintFormat("%s | %s: plan ditolak (%s)",HUNT_NAME,
                        CSessionManager::SessionName(s),plan.note);
            AdvanceState(s,HUNT_STATE_WAIT_BREAKOUT);
            break;
           }
         if(g_settings.tpUseLiquidity)
            ApplyLiquidityTp(plan);
         if(g_settings.entryMode==ENTRY_PENDING_ORDER && ctx.zoneFound)
           {
            if(!g_exec.PlacePending(plan,g_data))
              {
               g_sessions.SetOrStatus(s,ORB_STATUS_RANGING);
               g_orb.Reset(s);
               AdvanceState(s,HUNT_STATE_WAIT_BREAKOUT);
               break;
              }
            g_plan[s]=plan;
            AdvanceState(s,HUNT_STATE_WAIT_RETEST);
           }
         else
           {
            g_plan[s]=plan;
            if(g_settings.requireRetest)
               AdvanceState(s,HUNT_STATE_WAIT_RETEST);
            else
               AdvanceState(s,HUNT_STATE_READY_ENTRY);   // opt-in entry langsung
           }
        }
         break;

      case HUNT_STATE_WAIT_RETEST:
        {
         g_orb.RefreshStatus(s,r,g_data);
         double px=(r.breakoutDir==HUNT_DIR_BUY ? g_data.Bid() : g_data.Ask());
         double ext=ExtensionPct(r,r.breakoutDir,px);
         //--- v1.06: cek ZONA MILIK PLAN SENDIRI (bukan proxy 'ada zona
         //--- ACTIVE apa pun' — dulu itu membunuh retest di bar sentuh yg
         //--- justru mengubah zona jadi MITIGATED, mematikan mode EXECUTION)
         bool zoneGone=(g_plan[s].zoneTopSnap>0.0 &&
                        !g_smc.ZoneStillActive(r.breakoutDir,g_plan[s].zoneBottomSnap,
                                               g_plan[s].zoneTopSnap));
         if(r.status==ORB_STATUS_INVALIDATED ||
            r.barsSinceBreakout>g_settings.retestMaxBars ||
            ext>g_settings.maxExtensionPct ||
            zoneGone)
           {
            string whyS="retest timeout/extension";
            if(r.status==ORB_STATUS_INVALIDATED)
               whyS="false breakout";
            else if(zoneGone)
               whyS="zona OB/FVG mati pra-fill";
            InvalidateSetup(s,whyS);
            break;
           }
         if(g_settings.entryMode==ENTRY_EXECUTION)
           {
            if(g_plan[s].zoneTopSnap>0.0 && RetestReaction(s,g_plan[s]))
               AdvanceState(s,HUNT_STATE_READY_ENTRY);
           }
         else if(g_plan[s].pendingTicket!=0)
           {
            int evt=g_exec.Manage(g_data,g_plan[s]);
            if((evt & HUNT_EVT_PENDING_FILLED)!=0)
              {
               g_risk.RegisterOpenedTrade();
               g_smc.MarkZoneUsed(g_plan[s].zoneId);
               double fillPx=g_plan[s].entry;
               ulong tk0;
               double v0,px0,sl0,tp0,pl0;
               ENUM_HUNT_DIR d0;
               int ss0;
               if(g_exec.PositionSnapshot(tk0,v0,px0,sl0,tp0,pl0,d0,ss0))
                  fillPx=px0;
               g_visual.RenderEntryMarker(g_plan[s],TimeCurrent(),fillPx,g_data);
               g_visual.Finish();
               AdvanceState(s,HUNT_STATE_MANAGING);
              }
            if((evt & HUNT_EVT_PENDING_EXPIRED)!=0)
              {
               g_plan[s].Reset();
               g_sessions.SetOrStatus(s,ORB_STATUS_RANGING);
               g_orb.Reset(s);
               AdvanceState(s,HUNT_STATE_WAIT_BREAKOUT);
              }
           }
        }
         break;

      case HUNT_STATE_READY_ENTRY:
        {
         string note;
         if(!g_risk.LastMomentCheck(g_data.SpreadPips(),note))
           {
            PrintFormat("%s | %s: entry ditahan (%s)",HUNT_NAME,
                        CSessionManager::SessionName(s),note);
            if(r.barsSinceBreakout>g_settings.retestMaxBars ||
               ExtensionPct(r,r.breakoutDir,g_data.Bid())>g_settings.maxExtensionPct)
               InvalidateSetup(s,"ditahan terlalu lama");
            break;
           }
         if(g_plan[s].zoneId!=0)
           {
            //--- reprice utk mode EXECUTION: level dihitung ulang di harga kini
            g_plan[s].entry=(g_plan[s].dir==HUNT_DIR_BUY ? g_data.Ask() : g_data.Bid());
            double slv=(g_plan[s].dir==HUNT_DIR_BUY ? g_plan[s].zoneBottomSnap
                        : g_plan[s].zoneTopSnap);
            if(!g_risk.BuildPlan(g_plan[s],g_data,slv))
              {
               InvalidateSetup(s,"reprice invalid: "+g_plan[s].note);
               break;
              }
           }
         if(g_settings.tpUseLiquidity)
            ApplyLiquidityTp(g_plan[s]);
         if(g_exec.OpenMarket(g_plan[s],g_data))
           {
            g_risk.RegisterOpenedTrade();
            g_smc.MarkZoneUsed(g_plan[s].zoneId);
            g_visual.RenderEntryMarker(g_plan[s],TimeCurrent(),g_plan[s].entry,g_data);
            g_visual.Finish();
            AdvanceState(s,HUNT_STATE_MANAGING);
           }
         else
           {
            g_plan[s].Reset();
            AdvanceState(s,HUNT_STATE_WAIT_BREAKOUT);
           }
        }
         break;

      case HUNT_STATE_MANAGING:
        {
         //--- snapshot risiko plan (Manage() me-reset plan saat POS_CLOSED)
         double jEntry=g_plan[s].entry,jSl=g_plan[s].sl,jLots=g_plan[s].lots;
         ENUM_HUNT_DIR jDir=g_plan[s].dir;
         int evt=g_exec.Manage(g_data,g_plan[s]);
         if((evt & HUNT_EVT_POS_CLOSED)!=0)
           {
            double pnlJ=CollectRealizedPnl(s);
            JournalClosedTrade(s,jDir,jEntry,jSl,jLots,pnlJ);
            AdvanceState(s,HUNT_STATE_WAIT_BREAKOUT);
           }
        }
         break;

      case HUNT_STATE_BREAKOUT_CONFIRMED:
         AdvanceState(s,HUNT_STATE_WAIT_BREAKOUT);    // transient guard
         break;

      case HUNT_STATE_FORCE_CLOSED:
         if(!g_sessions.IsSessionLive(s,nowBrk))
            AdvanceState(s,HUNT_STATE_IDLE);
         break;
     }
  }

//+------------------------------------------------------------------+
//| Real-time tiap tick (ringan, diff-only): partial TP1, trailing,     |
//| baris kritis dashboard. Force-close presisi detik ada di OnTimer.   |
//+------------------------------------------------------------------+
void RealtimeTick()
  {
   if(!g_data.HasBars(2))
      return;
   const datetime nowBrk=TimeCurrent();
   for(int s=0;s<HUNT_SESSION_COUNT;s++)
     {
      if(g_state[s]!=HUNT_STATE_MANAGING)
         continue;
      ulong tk;
      double vol,px,sl,tp,pl;
      ENUM_HUNT_DIR dir;
      int sess;
      if(!g_exec.PositionSnapshot(tk,vol,px,sl,tp,pl,dir,sess))
        {
         double pnlX=CollectRealizedPnl(s);
         JournalClosedTrade(s,g_plan[s].dir,g_plan[s].entry,g_plan[s].sl,
                            g_plan[s].lots,pnlX);
         g_plan[s].Reset();
         AdvanceState(s,HUNT_STATE_WAIT_BREAKOUT);
         continue;
        }
      //--- partial TP1 (sekali) + SL→breakeven+biaya
      if(g_settings.tp1RR>0.0 && !g_plan[s].partialDone && g_plan[s].tp1>0.0)
        {
         bool hit=(dir==HUNT_DIR_BUY ? g_data.Bid()>=g_plan[s].tp1
                    : g_data.Ask()<=g_plan[s].tp1);
         if(hit)
           {
            double part=g_risk.PartialCloseVolume(vol,g_data);
            //--- FIXED lot kecil: part bisa 0 (< VolumeMin) — partial SKIP,
            //--- tapi BE tetap dipasang (jangan menggantung tiap tick)
            if(part<=0.0 || g_exec.ClosePosition(tk,part,"TP1 partial"))
              {
               g_plan[s].partialDone=true;
               //--- buffer BE: maks(2 point, stops-level+1) → valid utk
               //--- broker ber-stops-level besar (Gold/Indeks umum)
               double beBuf=MathMax(2.0*g_settings.point,
                                    ((double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)
                                     +1.0)*g_settings.point);
               double be=g_data.NormalizePrice(g_plan[s].entry+
                           (dir==HUNT_DIR_BUY ? beBuf : -beBuf));
               g_exec.ModifySl(tk,be,tp);
               string pTxt=(part>0.0 ? StringFormat("partial %.2f lot",part)
                                     : "partial skip (<= VolumeMin)");
               PrintFormat("%s | %s: TP1 %s, SL -> %s",HUNT_NAME,
                           CSessionManager::SessionName(s),pTxt,
                           DoubleToString(be,g_data.Digits()));
              }
           }
        }
      //--- trailing berbasis struktur (ref = swing closed; non-repaint)
      if(g_plan[s].partialDone && g_settings.trailAfterTp1)
        {
         datetime t0=0;
         double ref=0.0;
         bool ok=(dir==HUNT_DIR_BUY ? g_smc.LastSwingBelow(px,t0,ref)
                    : g_smc.LastSwingAbove(px,t0,ref));
         if(ok)
           {
            double cand=g_risk.ProposeTrailingSl(dir,sl,ref,px,g_data);
            if(cand>0.0 && MathAbs(cand-sl)>=g_settings.point)
              {
               if(g_exec.ModifySl(tk,cand,tp))
                 {
                  PrintFormat("%s | %s: trailing SL -> %s",HUNT_NAME,
                              CSessionManager::SessionName(s),DoubleToString(cand,g_data.Digits()));
                  g_plan[s].sl=cand;
                 }
              }
           }
        }
     }
   //--- dash per-tick (kritis: posisi, OB/OS, news, checklist)
   if(g_dash.IsActive())
     {
      ulong tk;
      double vol,px,sl,tp,pl;
      ENUM_HUNT_DIR dir;
      int sess;
      string posLine="Position: none",pendLine="Pending: none";
      bool havePos=g_exec.PositionSnapshot(tk,vol,px,sl,tp,pl,dir,sess);
      if(havePos)
        {
         double pctBal=(AccountInfoDouble(ACCOUNT_BALANCE)>0.0 ?
                        pl/AccountInfoDouble(ACCOUNT_BALANCE)*100.0 : 0.0);
         posLine=StringFormat("Position: %s %.2f @ %s | SL %s TP %s | %+.2f (%+.2f%%)",
                              (dir==HUNT_DIR_BUY ? "BUY" : "SELL"),vol,
                              DoubleToString(px,g_data.Digits()),DoubleToString(sl,g_data.Digits()),
                              DoubleToString(tp,g_data.Digits()),pl,pctBal);
        }
      for(int sp=0;sp<HUNT_SESSION_COUNT;sp++)
         if(g_plan[sp].pendingTicket!=0)
           {
            pendLine=StringFormat("Pending: %s @ %s | exp %d bar",
                                  CSessionManager::SessionName(sp),
                                  DoubleToString(g_plan[sp].entry,g_data.Digits()),
                                  g_exec.PendingBarsLeft(g_plan[sp],g_data));
            break;
           }
      g_dash.SetRow(HUNT_DASH_POSITION,posLine,
                    (havePos ? (dir==HUNT_DIR_BUY ? HUNT_COL_BULL : HUNT_COL_BEAR) : clrGray));
      g_dash.SetRow(HUNT_DASH_PENDING,pendLine,
                    (pendLine=="Pending: none" ? clrGray : clrDeepSkyBlue));
      string obos=CHunterDashboard::FormatObos(g_data.Rsi(0),g_settings.obosUpper,
                                               g_settings.obosLower,g_settings.obosPeriod);
      g_dash.SetRow(HUNT_DASH_OBOS,obos,
                    (StringFind(obos,"Overbought")>=0 ||
                     StringFind(obos,"Oversold")>=0 ? clrOrange : HUNT_COL_TEXT));
      SNewsStatus ns=g_news.Status(TimeCurrent());
      string newsLine="News: OFF";
      if(g_settings.newsEnabled)
        {
         if(!ns.hasData)
            newsLine=(ns.err!="" ? "News: NO DATA — "+ns.err : "News: NO DATA");
         else if(ns.stale)
            newsLine=(ns.err!="" ? "News: STALE — "+ns.err : "News: STALE (fetch gagal)");
         else if(ns.blockedNow)
            newsLine="News: BLOCK — "+ns.blockedEvent;
         else if(ns.nextEventUtc>0)
            newsLine=StringFormat("News: ok | event dlm %dm",
                                  (int)((ns.nextEventUtc-TimeCurrent())/60));
         else
            newsLine="News: ok (tanpa event)";
        }
      g_dash.SetRow(HUNT_DASH_NEWS_STATE,newsLine,
                    (StringFind(newsLine,"BLOCK")>=0 ? clrRed :
                     (StringFind(newsLine,"STALE")>=0 ||
                      StringFind(newsLine,"NO DATA")>=0 ? clrOrange : clrGray)));
      string descLine="Desk: news filter OFF";
      if(g_settings.newsEnabled)
        {
         if(ns.nextInfo!="")
            descLine="Desk: "+ns.nextInfo;
         else if(!ns.hasData)
            descLine="Desk: data belum tersedia";
         else
            descLine="Desk: bersih — tanpa event terjadwal";
        }
      g_dash.SetRow(HUNT_DASH_NEWS_DESC,descLine,
                    (ns.blockedNow ? clrOrange : (descLine=="Desk: news filter OFF" ? clrGray : clrSilver)));
      string today=StringFormat("Today: %d/%d trades | P/L %+.2f (%.1f%% vs -%.1f%%)",
                                g_risk.TradesToday(),g_risk.MaxTrades(),g_risk.DailyPnl(),
                                g_risk.DailyPnlPct(),g_risk.MaxDailyLossPct());
      if(g_risk.IsHalted())
         today+=" HALTED";
      g_dash.SetRow(HUNT_DASH_TODAY,today,(g_risk.IsHalted() ? clrOrangeRed : HUNT_COL_TEXT));
      UpdateChecklistRows(g_sessions.ActiveSession(TimeCurrent()),TimeCurrent());
     }
  }

//+------------------------------------------------------------------+
//| OnTick.                                                            |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_data.RefreshQuotes())
      return;
   if(g_data.UpdateOnBar(600,150))
      PipelineOnNewBar();
   RealtimeTick();
  }

//+------------------------------------------------------------------+
//| OnTimer(1s): countdown candle & force-close (BUKAN dari OnTick),   |
//| refresh news terjadwal, cleanup objek expired.                     |
//+------------------------------------------------------------------+
void OnTimer()
  {
   const datetime nowBrk=TimeCurrent();
   int act=g_sessions.ActiveSession(nowBrk);
   int secBar=0;
   datetime barT=g_data.CurrentBarTime();
   if(barT>0)
      secBar=MathMax(0,PeriodSeconds(_Period)-((int)(nowBrk-barT)));
   int secFc=0;
   string fcLabel="";
   if(act>=0 && g_settings.forceCloseMinBefore>0)
     {
      secFc=MathMax(0,g_sessions.SecondsToForceClose(act,nowBrk));
      fcLabel="Force-close "+CSessionManager::SessionName(act)+":";
     }
   if(g_dash.IsActive())
     {
      g_dash.UpdateOnTimer(secBar,PeriodSeconds(_Period),secFc,fcLabel);
      if(g_settings.mode==HUNT_MODE_SWING)
         g_dash.SetRow(HUNT_DASH_FORCECLOSE,"Force-close: SWING hold",clrGray);
      SNewsStatus ns=g_news.Status(nowBrk);
      g_dash.SetNewsTime(StringFormat("News data: %s %s",
                                      TimeToString(ns.lastFetchUtc,TIME_DATE|TIME_MINUTES),
                                      (ns.stale ? "(STALE)" : "")));
     }
   if(g_news.RefreshIfNeeded(nowBrk))
     {
      if(g_settings.showNewsMarkers)
        {
         g_visual.RenderNews(g_news,nowBrk);
         g_visual.Finish();
        }
     }
   //--- force-close sweep (presisi detik; operasi trade tetap via CTrade)
   for(int s=0;s<HUNT_SESSION_COUNT;s++)
     {
      if(g_state[s]==HUNT_STATE_IDLE || g_state[s]==HUNT_STATE_RANGE_FORMING ||
         g_state[s]==HUNT_STATE_WAIT_BREAKOUT || g_state[s]==HUNT_STATE_FORCE_CLOSED)
         continue;
      if(!g_sessions.InForceCloseWindow(s,nowBrk) && !g_fcResidue[s])
         continue;
      int nPos=0,nPend=0,nFail=0;
      g_exec.CloseSessionPositions(s,nPos,nPend,nFail);
      if(nFail>0)                                        // sisa belum tertutup
        {
         g_fcResidue[s]=true;
         if(nowBrk-g_fcResidueLog[s]>=30)
           {
            g_fcResidueLog[s]=nowBrk;
            PrintFormat("%s | force-close %s: %d order tertahan (market closed/disabled) — retry tiap timer",
                        HUNT_NAME,CSessionManager::SessionName(s),nFail);
           }
         continue;
        }
      if(nPos>0 || nPend>0)
        {
         double pnlFc=CollectRealizedPnl(s);
         JournalClosedTrade(s,g_plan[s].dir,g_plan[s].entry,g_plan[s].sl,
                            g_plan[s].lots,pnlFc);
         string msg=StringFormat("%s | FORCE-CLOSE %s: %d posisi ditutup, %d pending dihapus",
                                HUNT_NAME,CSessionManager::SessionName(s),nPos,nPend);
         Print(msg);
         Alert(msg);
        }
      g_fcResidue[s]=false;
      g_plan[s].Reset();
      AdvanceState(s,HUNT_STATE_FORCE_CLOSED);
     }
   //--- alert CHoCH kedaluwarsa: hilang tanpa menunggu bar baru
   if(g_chochTime>0 && (nowBrk-g_chochTime)>g_settings.chochAlertMin*60)
      g_dash.SetRow(HUNT_DASH_CHOCH,"--",clrGray);
   g_visual.CleanupExpired(nowBrk);
   g_visual.Finish();
  }

//+------------------------------------------------------------------+
//| OnInit — validasi, handle, init modul (early-return jelas per      |
//| kegagalan sesuai standar MQL5).                                     |
//+------------------------------------------------------------------+
int OnInit()
  {
   for(int i=0;i<HUNT_SESSION_COUNT;i++)
     {
      g_state[i]=HUNT_STATE_IDLE;
      g_plan[i].Reset();
      g_lastBo[i].time=0;
      g_lastBo[i].dir=HUNT_DIR_NONE;
      g_lastPnlScan[i]=0;
     }
   if(!SnapshotSettings(g_settings))
      return(INIT_PARAMETERS_INCORRECT);
   if(!g_data.Init(g_settings))
     {
      PrintFormat("%s | Init data gagal (indikator/simbol) — INIT_FAILED",HUNT_NAME);
      return(INIT_FAILED);
     }
   g_sessions.Init(g_settings,TimeCurrent());
   ReapplyTimeBaseWindows();
   g_orb.Init(g_settings);
   g_smc.Init(g_settings,g_sessions.GetDayStartUtc());
   g_conf.Init(g_settings);
   g_risk.Init(g_settings);
   g_risk.OnNewDay(g_sessions.CurrentDayUtc(),AccountInfoDouble(ACCOUNT_BALANCE));
   if(!g_exec.Init(g_settings))
      return(INIT_FAILED);
   g_visual.Init(g_settings);
   g_perfFile="HUNT_perf_"+_Symbol+".csv";
   g_dash.BuildLayout(g_settings);
   UpdatePerformanceSection();
   if(!g_news.Init(g_settings))
      PrintFormat("%s | NewsFilter init gagal — TANPA filter news (fail-safe)",HUNT_NAME);
   if(g_settings.newsEnabled && !MQLInfoInteger(MQL_TESTER))
     {
      if(g_news.Refresh(TimeCurrent()) && g_settings.showNewsMarkers)
        {
         g_visual.RenderNews(g_news,TimeCurrent());
         g_visual.Finish();
        }
      else
         PrintFormat("%s | NEWS BELUM TERSEDIA — cek 1) '%s' terdaftar di Tools>Options>Expert Advisors>Allow WebRequest, 2) koneksi internet terminal. Retry otomatis tiap %d jam; status live ada di baris NEWS dashboard.",
                     HUNT_NAME,g_settings.newsUrlBase,g_settings.newsRefreshHours);
     }
   else if(g_settings.newsEnabled)
      PrintFormat("%s | news filter TANPA DATA di tester — entry tidak diblokir kalender",
                  HUNT_NAME);
   EventSetTimer(1);
   g_timerOn=true;
   g_smc.Update(g_data);
   PipelineOnNewBar();
   g_visual.RenderPivots(g_data,g_sessions.GetDayStartUtc());
   g_visual.Finish();
   RealtimeTick();
   PrintFormat("%s v%s init OK | TF=%s magic=%I64d pip=%.5f",HUNT_NAME,HUNT_VERSION,
               EnumToString(_Period),g_settings.magic,g_settings.pipSize);
   if(g_settings.lotMode==HUNT_LOT_FIXED)
      PrintFormat("%s | LOT=FIXED %.3f per trade (InpRiskPercent diabaikan; daily-limit, margin check & RR-min tetap aktif)",
                  HUNT_NAME,g_settings.fixedLots);
   else
      PrintFormat("%s | LOT=ADAPTIVE %.2f%% risiko per trade",HUNT_NAME,g_settings.riskPercent);
   for(int sidx=0;sidx<HUNT_SESSION_COUNT;sidx++)
     {
      int ush=((g_settings.startHourBrk[sidx]-g_settings.gmtOffset)%24+24)%24;
      int ueh=((g_settings.endHourBrk[sidx]-g_settings.gmtOffset)%24+24)%24;
      PrintFormat("%s | SESI %s: %02d:00-%02d:00 broker = UTC %02d:00-%02d:00%s",HUNT_NAME,
                  CSessionManager::SessionName(sidx),g_settings.startHourBrk[sidx],
                  g_settings.endHourBrk[sidx],ush,ueh,
                  (g_settings.enableSession[sidx]?"":" (OFF)"));
     }
   if(g_settings.mode==HUNT_MODE_SWING)
      PrintFormat("%s | MODE=SWING: force-close OFF, retest>=40 bar, SL buffer>=0.5xAtr, minRR>=2.5, TP1>=1.5R, pending-exp>=48 jam. Posisi CARRY overnight — perhitungkan SWAP. Chart disarankan H1/H4.",HUNT_NAME);
   //--- v1.16: sapu sisa objek band lama lintas-versi (nama lama
   //--- HUNT_SESS_<s>_<t> dari v1.13) yg bisa tersimpan di template
   //--- chart — prefix-targeted, BUKAN ObjectsDeleteAll global.
   for(int oi=ObjectsTotal(0)-1;oi>=0;oi--)
     {
      string onm=ObjectName(0,oi);
      if(StringFind(onm,HUNT_PREFIX_SESS)==0)
         ObjectDelete(0,onm);
     }
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit — cleanup per prefix (BUKAN ObjectsDeleteAll global),     |
//| release handle, matikan timer; log sesuai reason.                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_timerOn)
     {
      EventKillTimer();
      g_timerOn=false;
     }
   g_visual.ClearAllOwned();
   g_dash.Destroy();
   g_data.Release();
   switch(reason)
     {
      case REASON_REMOVE:
         PrintFormat("%s: dilepas dari chart",HUNT_NAME);
         break;
      case REASON_PARAMETERS:
         PrintFormat("%s: reinit karena input diganti",HUNT_NAME);
         break;
      case REASON_CHARTCLOSE:
         PrintFormat("%s: chart ditutup",HUNT_NAME);
         break;
      case REASON_RECOMPILE:
         PrintFormat("%s: dikompilasi ulang",HUNT_NAME);
         break;
      default:
         break;
     }
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction — sinkronisasi tag saja (BUKAN trading logic).   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type==TRADE_TRANSACTION_ORDER_DELETE ||
      trans.type==TRADE_TRANSACTION_ORDER_ADD ||
      trans.type==TRADE_TRANSACTION_DEAL_ADD ||
      trans.type==TRADE_TRANSACTION_POSITION)
      g_exec.ReconcileTags();
  }
//+------------------------------------------------------------------+
