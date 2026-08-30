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
//| WAKTU: jam sesi = waktu BROKER chart (InpTimeBase bisa diubah ke     |
//|   UTC). InpGMTOffset = broker − UTC (jam) utk konversi jam news &    |
//|   display. Pip otomatis dari digits (5/3/2 → 10×point; lain → point).|
//|                                                                    |
//| ANTI-REPAINT/LOOKAHEAD: keputusan sinyal HANYA pada CLOSED bar       |
//|   (back=0 = shift 1). Bar berjalan hanya utk monitoring real-time     |
//|   (partial TP1, trailing, force-close, dashboard).                    |
//+------------------------------------------------------------------+
#property copyright   "ORB SMC Hunter"
#property link        ""
#property version     "0.90"
#property description "ORB+SMC modular EA | retest-only entry | per-session force-close | news fail-safe"

#include <ORB_SMC_Hunter\HunterDefines.mqh>
#include <ORB_SMC_Hunter\HunterSettings.mqh>

//===================================================================
// INPUT — divalidasi & dibekukan ke SHunterSettings di OnInit;
// modul hanya membaca snapshot (lihat HunterSettings.mqh).
//===================================================================
input group "=== Session Settings ==="
input bool                InpEnableAsia      = true;            // Aktifkan sesi Asia
input int                 InpAsiaStart       = 2;               // Asia mulai (jam)
input int                 InpAsiaEnd         = 8;               // Asia selesai (jam)
input bool                InpEnableLondon    = true;            // Aktifkan sesi London
input int                 InpLondonStart     = 14;              // London mulai (jam)
input int                 InpLondonEnd       = 22;              // London selesai (jam)
input bool                InpEnableNY        = true;            // Aktifkan sesi New York
input int                 InpNYStart         = 19;              // NY mulai (jam)
input int                 InpNYEnd           = 3;               // NY selesai (jam; <mulai = lintas tengah malam)
input ENUM_HUNT_TIME_BASE InpTimeBase        = HUNT_TIME_BASE_BROKER; // Basis jam input sesi
input int                 InpGMTOffset       = 2;               // Offset broker − UTC (jam)

input group "=== ORB Settings ==="
input int                 InpRangeMinutes    = 30;              // Durasi Opening Range (menit pertama sesi)
input double              InpMinRangePips    = 0.0;             // Ukuran minimum OR (pips; 0=off)
input double              InpBreakoutBufferPips = 0.0;          // Buffer close di luar level OR (pips)
input bool                InpRequireBodyClose = true;           // Wajib body-close (wick-only ditolak)

input group "=== SMC Settings ==="
input int                 InpSwingLookback   = 3;               // Swing lookback kiri/kanan (bar closed)
input bool                InpRequireLiquiditySweep = true;      // Wajib sweep pool searah breakout
input bool                InpRequireFVGRetest = true;          // Wajib retest OB/FVG (false=opt-in entry langsung!)
input int                 InpRetestMaxBars   = 10;              // Maks bar menunggu retest (invalidasi/expiry)
input double              InpMaxExtensionBeforeRetest = 50.0;   // Ekstensi maks sebelum retest (% dari OR)
input double              InpLiqTolerancePips = 2.0;            // Toleransi equal highs/lows (pips)
input bool                InpUseFVGAsZone    = true;            // FVG boleh jadi zona retest
input double              InpOBDisplacementAtr = 1.0;           // Displacement OB minimum (×ATR)
input double              InpSLBufferAtrMult = 0.2;             // Buffer SL melampaui struktur (×ATR)
input int                 InpATRPeriod       = 14;              // Periode ATR (buffer SL & volatilitas)
input ENUM_TIMEFRAMES     InpHTFTimeframe    = PERIOD_H4;       // Timeframe bias struktur (HTF)

input group "=== Confluence Settings ==="
input int                 InpMinConfluenceScore = 60;           // Skor confluence minimum 0..100

input group "=== Entry Mode ==="
input ENUM_ENTRY_MODE     InpEntryMode = ENTRY_PENDING_ORDER;  // 0=Execution(market) 1=Pending(limit@zona)

input group "=== Risk Settings ==="
input double              InpRiskPercent     = 0.5;             // Risiko per trade (% dari basis)
input ENUM_HUNT_RISK_BASE InpRiskBase      = HUNT_RISK_BASE_BALANCE; // Basis risiko
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
SBreakout            g_lastBo[HUNT_SESSION_COUNT];   // info utk dashboard
SSMCContext          g_lastCtx[HUNT_SESSION_COUNT];  // info utk dashboard
datetime             g_lastPnlScan[HUNT_SESSION_COUNT]; // anti double-count P/L
bool                 g_timerOn=false;

//--- prototipe helper lokal ----------------------------------------
bool     SnapshotSettings(SHunterSettings &s);
void     StateToString(const ENUM_HUNT_STATE st,string &dst);
void     AdvanceState(const int session,const ENUM_HUNT_STATE to);
string   GetStateLabel(const int s);
double   ExtensionPct(const SOpenRange &r,const ENUM_HUNT_DIR dir,const double price);
void     FillSmcContext(const int s,const SOpenRange &r,const ENUM_HUNT_DIR dir,
                        const double price,SSMCContext &ctx);
bool     RetestReaction(const int s,const SSignalPlan &plan);
void     InvalidateSetup(const int s,const string why);
void     CollectRealizedPnl(const int s);
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
   s.swingLookback        =InpSwingLookback;
   s.requireLiquiditySweep=InpRequireLiquiditySweep;
   s.requireRetest        =InpRequireFVGRetest;
   s.retestMaxBars        =InpRetestMaxBars;
   s.maxExtensionPct      =InpMaxExtensionBeforeRetest;
   s.liqTolPips           =InpLiqTolerancePips;
   s.useFvgAsZone         =InpUseFVGAsZone;
   s.slAtrMult            =InpSLBufferAtrMult;
   s.obDisplacementAtr    =InpOBDisplacementAtr;
   s.atrPeriod            =InpATRPeriod;
   s.htf                  =InpHTFTimeframe;
   s.minScore             =InpMinConfluenceScore;
   s.entryMode            =InpEntryMode;
   s.riskPercent          =InpRiskPercent;
   s.riskBase             =InpRiskBase;
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
   else if(s.swingLookback<2 || s.swingLookback>50)
      err="InpSwingLookback harus 2..50";
   else if(s.retestMaxBars<1 || s.retestMaxBars>100)
      err="InpRetestMaxBars harus 1..100";
   else if(s.maxExtensionPct<5.0 || s.maxExtensionPct>500.0)
      err="InpMaxExtensionBeforeRetest harus 5..500 (%)";
   else if(s.riskPercent<0.01 || s.riskPercent>10.0)
      err="InpRiskPercent harus 0.01..10";
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
   if(s.digits==5 || s.digits==3 || s.digits==2)
      s.pipSize=s.point*10.0;
   else
      s.pipSize=s.point;
   //--- jam sesi → ruang BROKER ------------------------------------------------
   int inStart[HUNT_SESSION_COUNT]={InpAsiaStart,InpLondonStart,InpNYStart};
   int inEnd  [HUNT_SESSION_COUNT]={InpAsiaEnd,InpLondonEnd,InpNYEnd};
   for(int i=0;i<HUNT_SESSION_COUNT;i++)
     {
      int sh=inStart[i],eh=inEnd[i];
      if(InpTimeBase==HUNT_TIME_BASE_UTC)
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
   datetime since=r.sessionStart;
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
void CollectRealizedPnl(const int s)
  {
   if(s<0 || s>=HUNT_SESSION_COUNT)
      return;
   datetime t0=(g_lastPnlScan[s]>0 ? g_lastPnlScan[s]+1 : g_sessions.CurrentDayUtc());
   datetime t1=TimeCurrent()+60;
   if(!HistorySelect(t0,t1))
      return;
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
//| Render layer statis (dipanggil per bar baru & saat init).           |
//+------------------------------------------------------------------+
void RenderAllStaticLayers(const datetime nowBrk)
  {
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
      g_risk.OnNewDay(g_sessions.CurrentDayUtc(),AccountInfoDouble(ACCOUNT_BALANCE));
      g_smc.ResetDaily(g_sessions.GetDayStartUtc());
      g_orb.ResetAll();
      g_visual.OnNewDay();
      for(int s=0;s<HUNT_SESSION_COUNT;s++)
        {
         g_lastPnlScan[s]=0;
         g_state[s]=HUNT_STATE_IDLE;
         g_plan[s].Reset();
         g_lastBo[s].time=0;
        }
      g_visual.RenderPivots(g_data,g_sessions.GetDayStartUtc());
      g_visual.RenderNews(g_news,nowBrk);
     }
   g_sessions.Update(g_data,nowBrk);
   g_smc.Update(g_data);
   for(int s=0;s<HUNT_SESSION_COUNT;s++)
      ProcessSession(s,nowBrk);
   RenderAllStaticLayers(nowBrk);
   //--- dash per-bar (ringkas; data berat sudah di-cache modul)
   if(g_dash.IsActive())
     {
      SOpenRange ra,rl,rn;
      g_sessions.GetRange(HUNT_SESSION_ASIA,ra);
      g_sessions.GetRange(HUNT_SESSION_LONDON,rl);
      g_sessions.GetRange(HUNT_SESSION_NY,rn);
      int act=g_sessions.ActiveSession(nowBrk);
      string sess="Session: none";
      if(act>=0)
        {
         int toEnd=g_sessions.SecondsToSessionEnd(act,nowBrk);
         sess=StringFormat("Session: %s | %.0f mnt lagi",CSessionManager::SessionName(act),
                           MathMax(0,toEnd)/60.0);
        }
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
      g_dash.UpdateOnBar(sess,
                         CHunterDashboard::FormatRangeLine("Asia",ra,g_data.PipSize(),g_data.Digits()),
                         CHunterDashboard::FormatRangeLine("London",rl,g_data.PipSize(),g_data.Digits()),
                         CHunterDashboard::FormatRangeLine("NY",rn,g_data.PipSize(),g_data.Digits()),
                         "HTF bias ("+EnumToString(g_settings.htf)+"): "+g_smc.HtfBiasText(),
                         "State: "+GetStateLabel(act),(act>=0 ? (int)g_state[act] : 0),
                         (act>=0 ? BuildSignalLine(act) : "Signal: --"),cdLine);
     }
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
         SBreakout bo;
         if(!g_orb.Assess(s,r,g_data,nowBrk,bo))
            break;
         g_lastBo[s]=bo;
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
         SSMCContext ctx2;
         FillSmcContext(s,r,r.breakoutDir,px,ctx2);
         if(r.status==ORB_STATUS_INVALIDATED ||
            r.barsSinceBreakout>g_settings.retestMaxBars ||
            ext>g_settings.maxExtensionPct ||
            !g_conf.StillValid(g_plan[s],ctx2))
           {
            InvalidateSetup(s,(r.status==ORB_STATUS_INVALIDATED ? "false breakout" :
                               "retest timeout/extension"));
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
         int evt=g_exec.Manage(g_data,g_plan[s]);
         if((evt & HUNT_EVT_POS_CLOSED)!=0)
           {
            CollectRealizedPnl(s);
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
         CollectRealizedPnl(s);
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
            if(part>0.0 && g_exec.ClosePosition(tk,part,"TP1 partial"))
              {
               g_plan[s].partialDone=true;
               double be=g_data.NormalizePrice(g_plan[s].entry+
                           (dir==HUNT_DIR_BUY ? 2.0*g_settings.point : -2.0*g_settings.point));
               g_exec.ModifySl(tk,be,tp);
               PrintFormat("%s | %s: TP1 partial %.2f lot, SL -> %s",HUNT_NAME,
                           CSessionManager::SessionName(s),part,
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
   //--- dash per-tick
   if(g_dash.IsActive())
     {
      ulong tk;
      double vol,px,sl,tp,pl;
      ENUM_HUNT_DIR dir;
      int sess;
      string posLine="Position: none",pendLine="Pending: none";
      if(g_exec.PositionSnapshot(tk,vol,px,sl,tp,pl,dir,sess))
        {
         double pctBal=(AccountInfoDouble(ACCOUNT_BALANCE)>0.0 ?
                        pl/AccountInfoDouble(ACCOUNT_BALANCE)*100.0 : 0.0);
         posLine=StringFormat("Position: %s %.2f @ %s | SL %s TP %s | %+.2f (%+.2f%%)",
                              (dir==HUNT_DIR_BUY ? "BUY" : "SELL"),vol,
                              DoubleToString(px,g_data.Digits()),DoubleToString(sl,g_data.Digits()),
                              DoubleToString(tp,g_data.Digits()),pl,pctBal);
        }
      for(int s=0;s<HUNT_SESSION_COUNT;s++)
         if(g_plan[s].pendingTicket!=0)
           {
            pendLine=StringFormat("Pending: %s @ %s | exp %d bar",
                                  CSessionManager::SessionName(s),
                                  DoubleToString(g_plan[s].entry,g_data.Digits()),
                                  g_exec.PendingBarsLeft(g_plan[s],g_data));
            break;
           }
      string obos=CHunterDashboard::FormatObos(g_data.Rsi(0),g_settings.obosUpper,
                                               g_settings.obosLower,g_settings.obosPeriod);
      SNewsStatus ns=g_news.Status(nowBrk);
      string newsLine="News: OFF";
      if(g_settings.newsEnabled)
        {
         if(!ns.hasData)
            newsLine="News: NO DATA (filter nonaktif!)";
         else if(ns.stale)
            newsLine="News: STALE (fetch gagal)";
         else if(ns.blockedNow)
            newsLine="News: BLOCK — "+ns.blockedEvent;
         else if(ns.nextEventUtc>0)
            newsLine=StringFormat("News: ok | event dlm %dm",(int)((ns.nextEventUtc-nowBrk)/60));
         else
            newsLine="News: ok (tanpa event)";
        }
      string today=StringFormat("Today: %d/%d trades | P/L %+.2f (%.1f%% vs -%.1f%%)",
                                g_risk.TradesToday(),g_risk.MaxTrades(),g_risk.DailyPnl(),
                                g_risk.DailyPnlPct(),g_risk.MaxDailyLossPct());
      if(g_risk.IsHalted())
         today+=" HALTED";
      g_dash.UpdateOnTick(posLine,pendLine,obos,newsLine,today);
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
   if(act>=0)
     {
      secFc=MathMax(0,g_sessions.SecondsToForceClose(act,nowBrk));
      fcLabel="Force-close "+CSessionManager::SessionName(act)+":";
     }
   if(g_dash.IsActive())
     {
      g_dash.UpdateOnTimer(secBar,secFc,fcLabel);
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
      if(!g_sessions.InForceCloseWindow(s,nowBrk))
         continue;
      int nPos=0,nPend=0;
      g_exec.CloseSessionPositions(s,nPos,nPend);
      if(nPos>0 || nPend>0)
        {
         CollectRealizedPnl(s);
         string msg=StringFormat("%s | FORCE-CLOSE %s: %d posisi ditutup, %d pending dihapus",
                                HUNT_NAME,CSessionManager::SessionName(s),nPos,nPend);
         Print(msg);
         Alert(msg);
        }
      g_plan[s].Reset();
      AdvanceState(s,HUNT_STATE_FORCE_CLOSED);
     }
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
   g_orb.Init(g_settings);
   g_smc.Init(g_settings,g_sessions.GetDayStartUtc());
   g_conf.Init(g_settings);
   g_risk.Init(g_settings);
   g_risk.OnNewDay(g_sessions.CurrentDayUtc(),AccountInfoDouble(ACCOUNT_BALANCE));
   if(!g_exec.Init(g_settings))
      return(INIT_FAILED);
   g_visual.Init(g_settings);
   g_dash.BuildLayout(g_settings);
   if(!g_news.Init(g_settings))
      PrintFormat("%s | NewsFilter init gagal — TANPA filter news (fail-safe)",HUNT_NAME);
   if(g_settings.newsEnabled && !MQLInfoInteger(MQL_TESTER))
     {
      if(g_news.Refresh(TimeCurrent()) && g_settings.showNewsMarkers)
        {
         g_visual.RenderNews(g_news,TimeCurrent());
         g_visual.Finish();
        }
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
