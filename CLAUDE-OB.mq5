//+------------------------------------------------------------------+
//|                        CLAUDE-OB.mq5                             |
//|   PROFESSIONAL SMC + OPEN RANGE BREAKOUT (ORB) EA              |
//|   Version : 6.25 — Professional SMC Pipeline & ORB Session EA   |
//|                                                                  |
//|  BUG FIXES v5.10:                                               |
//|  · dispBar index-shift → dispTime (datetime-based lookup)       |
//|  · SMC_DISPLACED state now properly used in state machine       |
//|  · ApplyTrailingStop: guard against sess=-1 crash               |
//|  · CanEnterSession: ORB window end check added                  |
//|  · BuildSessionRangesUTC: normalize -DBL_MAX → 0               |
//|  · UpdateHTFBias: only on new HTF bar (not every M5 bar)        |
//|  · EQH/EQL: deduplication prevents MAX_LIQ overflow            |
//|  · Time filter blocks re-entry after expiry in SMC_LOCKED       |
//|  · SMC_PriceInZone: separate bid/ask logic for buy vs sell      |
//|  · SMC_ZoneInvalidated: checks FVG as fallback when OB missing  |
//|  · FVG C-candle: guards against using forming candle (idx 0)    |
//|  · DrawAll: static layers only on newBar for performance        |
//|  ORB LOGIC CORRECTIONS v5.20:                                    |
//|  · SL_OR_LEVEL: SL placed at OR Low/High (true ORB standard)      |
//|  · TP_RANGE_MULT: TP = range × multiplier (true ORB projection)   |
//|  · InpBrkBuffer: breakout confirmation buffer (default 0.10 ATR)  |
//|  · gRequireImpulse: impulsive filter now optional                |
//|  · HTF bias checked in both SMC AND pure ORB mode                 |
//|  · NY Stock Mode: uses 14:30 UTC for index CFDs (NYSE open)       |
//|  · London default: 08:00 UTC (LSE official open)                  |
//|  · gMinORBRange: raised to 50 pts (was 10)                      |
//|  ADDED:                                                            |
//|  · Daily Pivot Points (R1/R2/R3, PP, S1/S2/S3)                 |
//|  · Volume Profile (POC, VAH, VAL, Value Area)                   |
//|  BACKTEST-DERIVED UPGRADES v6.10 (FBS broker, 5000 M15 bars):   |
//|  · [F1] Signal-bar volume filter: skip bars >= session tick avg  |
//|  · [F2] Auto-disable London session for XAU/GOLD symbols        |
//|  · [F3] OR range upper cap: InpMaxORBRange (0=off)              |
//|  · [F4] Entry timing cap: InpMaxBarsAfterOR bars after OR close |
//|  · [F5] Day-of-week skip: InpSkipFriday, InpSkipWednXAU        |
//|  · [F6] XAU-specific TP multiplier: InpXAU_TPRangeMult         |
//|  · [F7] Daily loss streak guard: InpMaxDailyLosses              |
//+------------------------------------------------------------------+
#property copyright "ORB SMC PRO System"
#property version "6.25"
#property description "Full ORB + SMC 9-Step | Pivot | Volume Profile | All Pairs"

#define EA_VERSION "6.25" // single source of truth — keep in sync with #property version above

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

#define SESS_ASIA 0
#define SESS_LONDON 1
#define SESS_NY 2
#define SESS_COUNT 3
#define MAX_LIQ 8

enum ENUM_BIAS
  {
   BIAS_NEUTRAL = 0,
   BIAS_BULLISH = 1,
   BIAS_BEARISH = -1
  };
enum ENUM_SMC_STATE
  {
   SMC_IDLE = 0,
   SMC_LOCKED = 1,
   SMC_SWEPT = 2,
   SMC_STRUCTURE = 3,
   SMC_DISPLACED = 4,
   SMC_ZONE = 5,
   SMC_RETRACE = 6,
   SMC_CONFIRMED = 7,
   SMC_TRADED = 8
  };
enum ENUM_BREAK_MODE
  {
   BREAK_CLOSE = 0,
   BREAK_CANDLE = 1
  };
enum ENUM_SPREAD_MODE
  {
   SPREAD_POINTS = 0,
   SPREAD_ATR = 1
  };
enum ENUM_SL_MODE
  {
   SL_FIXED = 0,
   SL_ATR = 1,
   SL_OR_LEVEL = 2
  }; // SL_OR_LEVEL = standar ORB
enum ENUM_TP_MODE
  {
   TP_FIXED = 0,
   TP_ATR = 1,
   TP_RANGE_MULT = 2
  }; // TP_RANGE_MULT = proyeksi range
enum ENUM_CONFIRM_MODE
  {
   CONFIRM_STRICT = 0,
   CONFIRM_BALANCED = 1,
   CONFIRM_LOOSE = 2
  }; // Entry confirmation strictness
enum ENUM_ORB_ENTRY_MODE
  {
   ORB_CONSERVATIVE = 0,
   ORB_BALANCED = 1,
   ORB_AGGRESSIVE = 2
  }; // Entry style: conservative pullback confirmation, balanced, or aggressive breakout
enum ENUM_VOL_REGIME
  {
   VOL_CALM = 0,
   VOL_NORMAL = 1,
   VOL_EXPLOSIVE = 2,
   VOL_HIGH = 3
  }; // Volatility regime
enum ENUM_AMD_PHASE
  {
   AMD_NONE = 0,          // no qualifying range currently tracked
   AMD_CONSOLIDATION = 1, // range with no clear prior trend context
   AMD_ACCUMULATION = 2,  // range formed after a prior downtrend (htfBias was BEARISH)
   AMD_DISTRIBUTION = 3,  // range formed after a prior uptrend (htfBias was BULLISH)
   AMD_MANIPULATION = 4   // transient: a sweep of the range boundary was just detected,
// pending next-bar confirmation of reabsorption vs breakout
  };
enum ENUM_PRICE_POS
  {
   PP_PREMIUM = 0,
   PP_EQUILIBRIUM = 1,
   PP_DISCOUNT = 2
  }; // Phase 4: Dealing Range position
enum ENUM_BE_MODE
  {
   BE_ATR = 0, // Use ATR as volatility measure
   BE_CMR = 1  // Use Cumulative Mean Range (avg high-low of N bars)
  };
enum ENUM_PENDING_ORDER
  {

   PENDING_LIMIT = 0, // Use Limit Order
   PENDING_STOP = 1,
  };
struct SOrderBlock
  {
   double            high, low;
   datetime          time;
   bool              valid, bullish, mitigated;
   int               touchCount; // Phase 13: times price entered this zone
  };
struct SFVG
  {
   double            high, low;
   datetime          time;
   bool              valid, bullish, mitigated;
   int               touchCount; // Phase 13: times price entered this zone
  };
struct SDealingRange
  {
   double            high, low, mid;
   double            premLine, discLine; // boundary of premium/discount zones
   datetime          updated;
  };
struct SLiqLevel
  {
   double            price;
   bool              isHigh, swept;
   string            label;
  };

#define MAX_EQ 10 // max total EQH+EQL stored for drawing (5 each)
struct SEqLevel
  {
   double            price;
   datetime          t1; // time of the older equal swing (line left anchor)
   datetime          t2; // time of the more recent equal swing
   bool              isHigh;
  };

//+------------------------------------------------------------------+
//| INPUTS                                                            |
//+------------------------------------------------------------------+
enum ENUM_TRADE_MODE
  {
   MODE_INTRADAY = 0,
   MODE_SWING = 1
  };
input group "━━━━━━━━━ TRADE MODE ━━━━━━━━━" input ENUM_TRADE_MODE InpTradeMode = MODE_INTRADAY; // INTRADAY=M15/H4 scalp-swing | SWING=H1/D1 multi-day
input group "━━━━━━━━━ TRADE EXECUTION ━━━━━━━━━" input double InpLotSize = 0.01;                // Lot size (fixed — used when InpAutoLot=false)
input bool InpAutoLot = false;                                                                   // Auto-size lot based on risk % per trade
input double InpRiskPct = 1.0;                                                                   // Risk per trade (%) — used when InpAutoLot=true
input ENUM_SL_MODE InpSLMode = SL_OR_LEVEL;                                                      // SL mode (SL_OR_LEVEL = standar ORB)
input ENUM_TP_MODE InpTPMode = TP_RANGE_MULT;                                                    // TP mode (TP_RANGE_MULT = standar ORB)
input double InpSL_Points = 150.0;                                                               // [SL_FIXED] Stop Loss points
input double InpTP_Points = 300.0;                                                               // [TP_FIXED] Take Profit points
input double InpSwing_ATR_SL = 2.0;                                                              // [SL_ATR/SWING] ATR multiplier SL
input double InpSwing_ATR_TP = 5.0;                                                              // [TP_ATR/SWING] ATR multiplier TP
input double InpSwing_TPRangeMult = 3.0;                                                         // [TP_RANGE_MULT/SWING] Range × multiplier
input double InpSL_OBBuffer = 0.15;                                                              // [SL_OR_LEVEL] buffer beyond OR (× ATR)
input int InpATR_Period = 14;                                                                    // ATR period
input double InpSwing_MinRR = 2.5;                                                               // Minimum RR accepted [SWING]
input double InpRiskWarnPct = 2.0;                                                               // Risk warning threshold (%) — RISK row turns orange above this

input group "━━━━━━━━━ SESSION ENABLE ━━━━━━━━━" input bool InpEnableAsia = true;
input bool InpEnableLondon = true;
input bool InpEnableNY = true;
input bool InpAutoDisableLondonXAU = true; // [F2] Auto-disable London for XAU/GOLD — London ORB structurally weak on Gold
input bool InpSkipFriday = false;          // [F5] Skip all sessions on Fridays — position squaring kills OR follow-through
input bool InpSkipWednXAU = false;         // [F5] Skip Wednesdays for XAU/GOLD — mid-week whipsaw pattern confirmed by backtest

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "━━━━━━━━━ ASIA SESSION (UTC) ━━━━━━━━━" input int InpAsiaH_Start = 0; // Standard Asia/FX session window (00:00-06:00 UTC)
input int InpAsiaM_Start = 0;
input int InpAsiaH_End = 6;
input int InpAsiaM_End = 0;
input int InpAsiaCutH = 4;
input int InpAsiaCutM = 30;

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "━━━━━━━━━ LONDON SESSION (UTC) ━━━━━━━━━" input int InpLondonH_S = 8; // London open (08:00 UTC)
input int InpLondonM_S = 0;                                                        // London Start Min
input int InpLondonH_E = 16;
input int InpLondonM_E = 0;
input int InpLondonCutH = 14;
input int InpLondonCutM = 30;

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "━━━━━━━━━ NEW YORK SESSION (UTC) ━━━━━━━━━" input bool InpNY_StockMode = false; // Stock mode: 14:30 UTC (NYSE/NASDAQ open)
input int InpNYH_S = 13;                                                                     // NY start for FX (13:30 UTC)
input int InpNYM_S = 30;                                                                     // NY Start Min
input int InpNYH_E = 20;
input int InpNYM_E = 0;
input int InpNYCutH = 18;
input int InpNYCutM = 30;

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "━━━━━━━━━ ORB SETTINGS ━━━━━━━━━" input int InpSwing_ORBMins = 60; // ORB window minutes [SWING: 60 = first H1 bar]
input ENUM_TIMEFRAMES InpSwing_ORBTF = PERIOD_H1;                               // ORB timeframe [SWING]
input ENUM_BREAK_MODE InpBreakMode = BREAK_CANDLE;                               // Breakout confirmation mode
input double InpSwing_MinORBRange = 200.0;                                      // Min ORB range points [SWING: 200=20pip]
input double InpSwing_MaxORBRange = 0;                                          // [F3] Max OR range points — skip over-extended ORs (0=off)
input int InpSwing_MaxBarsAfterOR = 0;                                          // [F4] Max bars after OR close to enter (0=off, recommended: 2)
input double InpBrkBuffer = 0.15;                                               // Breakout ATR buffer — wider for swing quality confirmation
input ENUM_ORB_ENTRY_MODE InpORBEntryMode = ORB_BALANCED;                      // Conservative = breakout + retest + order-flow confirmation | Balanced = breakout + retest/continuation | Aggressive = breakout-only
input double InpORBRetestBuffer = 0.20;                                         // Pullback tolerance around the broken OR level (× ATR)
input bool InpSwing_RequireImpulse = true;                                      // Require impulse candle [SWING]
input double InpSwing_BrkVolMin = 1.3;                                          // Breakout volume min × MA [SWING]
input double InpSwing_BrkCloseQuality = 0.55;                                   // Breakout close quality [SWING]

input group "━━━━━━━━━ HTF BIAS ━━━━━━━━━" input ENUM_TIMEFRAMES InpSwing_HTFTF = PERIOD_D1;
input int InpSwing_HTFLookback = 60; // HTF lookback bars [SWING: D1×60 = 3 months]
input int InpSwingPivot = 3;
input bool InpBiasRequired = true;
input bool InpUseDailyBias = true;    // Daily Bias filter: block entries opposing PDM direction
input double InpDailyBiasZone = 0.15; // Neutral band around PDM — wider for swing to avoid over-filtering

input group "━━━━━━━━━ SMC PIPELINE ━━━━━━━━━" input bool InpUseSMC = true;
input bool InpAutoMode = true; // Auto-detect mode: score market each bar, choose SMC or ORB
input double InpSweepBuffer = 0.02;
input double InpSweepBodyMin = 0.15; // [QUALITY] Min sweep rejection body (× ATR) — stricter for swing quality
input double InpDispATR = 0.60;      // Displacement body requirement (ATR multiplier)
input double InpDispBodyMin = 0.40;  // Min body/range ratio for displacement (alternative to strict 60%)
input double InpOBMitigation = 50.0;
input double InpOBBodyMin = 0.25; // [QUALITY] Min OB candle body (× ATR) — stricter OB quality for swing
input bool InpUseFVG = true;
input bool InpUseOB = true;
input int InpSwing_SweepLookback = 20; // Sweep lookback bars [SWING: 20 H1 bars ≈ 1 day]
input int InpSwing_TimeFilter = 240;   // SMC timeout minutes [SWING: 4h window]
input bool InpSMCFallback = true;      // ORB fallback if no SMC sweep within time window

input group "━━━━━━━━━ LTF CONFIRMATION ━━━━━━━━━" input bool InpLTFConfirm = true;
input ENUM_TIMEFRAMES InpSwing_LTFTF = PERIOD_M15; // LTF confirmation TF [SWING]
input bool InpLTFEngulf = true;
input bool InpLTFPinbar = true;
input double InpPinbarRatio = 2.5; // Stricter pinbar — swing entries need clear wick rejection

input group "━━━━━━━━━ LTF SUGGESTION ENGINE ━━━━━━━━━" input bool InpEnableLTFSuggestEngine = true; // Independent LTF-timeframe SMC signal engine (separate from the main ORBTF SMC pipeline)

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "━━━━━━━━━ AMD PHASE DETECTION ━━━━━━━━━" input bool InpEnableAMDDetection = true; // Consolidation/Accumulation/Manipulation/Distribution overlay (visual only, HTF, session-independent)
input int InpAMD_RangeLookback = 20;   // Bars scanned for a qualifying tight range
input double InpAMD_MaxRangeATR = 2.0; // Range must be <= this many HTF-ATR to qualify as tight

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "━━━━━━━━━ ADVANCED ENTRY FILTERS ━━━━━━━━━" input ENUM_CONFIRM_MODE InpSwing_ConfirmMode = CONFIRM_BALANCED; // Confirmation strictness [SWING]
input bool InpBOSConfirm = true;                                                                                        // BOS confirmation before entry
input bool InpWickReject = true;                                                                                        // Wick rejection from zone
input double InpWickRatio = 2.0;                                                                                        // Wick/Body ratio — 2.0 for clear swing rejection candles
input bool InpHTFMomentum = true;                                                                                       // HTF momentum confirmation
input bool InpDynamicNewsReset = true;                                                                                  // Reset state on high-impact news

input group "━━━━━━━━━ VOLATILITY REGIME ━━━━━━━━━" input bool InpVolFilter = true; // Enable volatility regime filtering
input double InpVolMin = 0.4;                                                       // Min ATR ratio — swing can trade at lower relative volatility
input double InpVolMax = 3.0;                                                       // Max ATR ratio — wider ceiling; swing survives higher volatility spikes
input bool InpVolSignalFilter = true;                                               // [F1] Block signal bars with tick volume >= session avg — high-vol candles are traps

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "━━━━━━━━━ PENDING ORDER ON OR LOCK ━━━━━━━━━" input bool InpUsePendingOR = true; // Place a Buy/Sell Stop the instant OR locks, direction = Daily/HTF Bias (skips if neutral) — applies to ORB-mode sessions and SMC sessions that fell back to ORB, not to sessions actively running the SMC pipeline
input double InpPendingOR_Buffer = 0.10;                                                                                                                                                                                                                                                                    // Stop entry buffer beyond OR High/Low (x ATR)
input ENUM_PENDING_ORDER InpPendingType = PENDING_LIMIT;
input group "━━━━━━━━━ RISK MANAGEMENT ━━━━━━━━━" input int InpMaxTrades = 3;
input int InpMaxDailyLosses = 0; // [F7] Pause new entries after N losing trades today (0=off, recommended: 3)
input ENUM_SPREAD_MODE InpSpreadMode = SPREAD_ATR;
input double InpMaxSpread = 20.0;
input double InpMaxSpreadATR = 0.40; // Tolerate wider spreads — swing is less execution-sensitive
input bool InpBreakeven = true;
input ENUM_BE_MODE InpBE_Mode = BE_ATR; // Breakeven measure: ATR or Cumulative Mean Range
input double InpSwing_BETrigger = 2.0;  // BE trigger × ATR [SWING: 2.0 = room before lock]
input double InpBE_Offset = 0.30;       // SL offset above/below open after BE (× ATR/CMR)
input bool InpPartialTP = true;
input bool InpTrailingStop = true;
input double InpSwing_TrailATR = 2.0; // Trail distance × ATR [SWING: wide for multi-day]
input bool InpDynTP = true;           // Dynamic TP: adjust target based on volume/liquidity
input double InpDynTP_Surge = 1.8;    // Volume ratio to trigger extension (× vol MA)
input double InpDynTP_Exhaust = 0.55; // Volume ratio to trigger tightening (× vol MA)
input double InpDynTP_MaxRR = 8.0;    // Max RR on surge — swing can ride extended trend legs
input int InpDynTP_VMA = 20;          // Volume MA period (bars)

input group "━━━━━━━━━ NEWS FILTER ━━━━━━━━━" input bool InpNewsFilter = true;
input int InpNewsBefore = 30;
input int InpNewsAfter = 30;

input group "━━━━━━━━━ DAILY PIVOTS ━━━━━━━━━" input bool InpDrawPivots = true;
input bool InpPivotR3S3 = true;
input bool InpPivotLabel = true; // Show price labels on pivot lines
input color InpClrPivot = C'170,170,170';
input color InpClrResist = C'210,65,65';
input color InpClrSupport = C'65,165,85';

input group "━━━━━━━━━ VOLUME PROFILE ━━━━━━━━━" input bool InpDrawVP = true;
input int InpVP_Bars = 100; // H1 ORBTf: 100 bars ≈ 4 trading days (24 bars/day) — relevant VP context for swing setups
input int InpVP_Bins = 40;
input int InpVP_Width = 14;
input double InpVP_VA_Pct = 70.0;
input color InpVP_POC_Clr = C'230,160,0';
input color InpVP_VA_Clr = C'30,110,60';
input color InpVP_Out_Clr = C'30,60,90';

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "━━━━━━━━━ INTRADAY PRESET (active when MODE_INTRADAY) ━━━━━━━━━" input ENUM_TIMEFRAMES InpIntra_ORBTF = PERIOD_M15; // ORB TF [INTRADAY]
input int InpIntra_ORBMins = 30;                                                                                                 // ORB window [INTRADAY: 30min = 2 M15 bars]
input double InpIntra_MinORBRange = 50.0;                                                                                        // Min ORB range [INTRADAY: 50=5pip EURUSD]
input double InpIntra_MaxORBRange = 0;                                                                                           // [F3] Max OR range points — skip over-extended ORs (0=off)
input int InpIntra_MaxBarsAfterOR = 0;                                                                                           // [F4] Max bars after OR close to enter (0=off, recommended: 2)
input bool InpIntra_RequireImpulse = false;                                                                                      // Impulse filter [INTRADAY: off for frequency]
input double InpIntra_BrkVolMin = 0.0;                                                                                           // Breakout vol min [INTRADAY: 0=off]
input double InpIntra_BrkCloseQuality = 0.0;                                                                                     // Close quality [INTRADAY: 0=off]
input ENUM_TIMEFRAMES InpIntra_HTFTF = PERIOD_H4;                                                                                // HTF bias TF [INTRADAY]
input int InpIntra_HTFLookback = 80;                                                                                             // HTF lookback [INTRADAY: H4×80 ≈ 13 days]
input ENUM_TIMEFRAMES InpIntra_LTFTF = PERIOD_M15;                                                                                // LTF confirm TF [INTRADAY]
input ENUM_TIMEFRAMES InpIntra_DRTF = PERIOD_H4;                                                                                 // DR TF [INTRADAY]
input int InpIntra_SweepLookback = 12;                                                                                           // Sweep lookback [INTRADAY: 12 M15 bars = 3h]
input int InpIntra_TimeFilter = 90;                                                                                              // SMC timeout [INTRADAY: 90min]
input ENUM_CONFIRM_MODE InpIntra_ConfirmMode = CONFIRM_BALANCED;                                                                 // Confirm mode [INTRADAY: BALANCED]
input double InpIntra_ATR_SL = 1.5;                                                                                              // SL × ATR [INTRADAY]
input double InpIntra_ATR_TP = 3.0;                                                                                              // TP × ATR [INTRADAY]
input double InpIntra_TPRangeMult = 2.0;                                                                                         // TP range × [INTRADAY]
input double InpXAU_TPRangeMult = 1.3;                                                                                           // [F6] TP range mult override for XAU/GOLD — tighter target (0=use InpIntra value)
input double InpIntra_MinRR = 2.0;                                                                                               // Min RR [INTRADAY]
input double InpIntra_BETrigger = 1.0;                                                                                           // BE trigger × ATR [INTRADAY]
input double InpIntra_TrailATR = 1.0;                                                                                            // Trail × ATR [INTRADAY]

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "━━━━━━━━━ DEALING RANGE (Phase 4) ━━━━━━━━━" input bool InpUseDealingRange = true; // Premium/Discount/Equilibrium filter
input ENUM_TIMEFRAMES InpSwing_DRTF = PERIOD_D1;                                                // DR timeframe [SWING]
input int InpDR_Bars = 20;                                                                      // Bars for DR swing H/L — D1×20=1 month (SWING) or H4×20=1 week (INTRADAY) when DR_TF changed
input double InpDR_ZoneSize = 0.30;                                                             // Premium/Discount zone size — 30% top/bottom zones on monthly range

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "━━━━━━━━━ EXTERNAL LIQUIDITY (Phase 5) ━━━━━━━━━" input bool InpDrawWeeklyLiq = true; // Draw previous week high/low
input bool InpDrawMonthlyLiq = true;                                                               // Draw previous month high/low
input color InpClrWeeklyLiq = C'160,140,0';                                                       // Weekly liquidity line color
input color InpClrMonthlyLiq = C'140,50,180';                                                     // Monthly liquidity line color

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input group "━━━━━━━━━ PROBABILITY ENGINE (Phase 15/16) ━━━━━━━━━" input bool InpUseProbScore = true; // Enable probability score gate
input int InpMinProbScore = 65;                                                                       // Minimum score — recalibrated: daily bias removed from score (still enforced as hard gate)
input bool InpFreshZoneOnly = true;                                                                   // Phase 13: only trade Fresh zones (0 touches)
input bool InpUseVPFilter = true;                                                                     // Phase 9: use VP VAH/VAL as entry filter

input group "━━━━━━━━━ VISUAL ━━━━━━━━━" input bool InpDrawObjects = true;
input bool InpDrawKZ = true;
input bool InpDrawOB = true;
input bool InpDrawFVG = true;
input bool InpDrawLabels = true;
input bool InpDrawPanel = true;
input int InpPanelX = 15;
input int InpPanelY = 28;
// Visual-only Fibonacci retracement drawn off the breakout leg (OR level -> breakout extreme).
// Not used as an entry filter yet — purely for observing whether price tends to pull back
// into the golden zone before continuing, so that can be decided on later with real data.
input bool InpDrawFibo = true;      // Draw Fibonacci retracement on breakout
input double InpFiboGoldLo = 0.618; // Golden zone start (retracement ratio)
input double InpFiboGoldHi = 0.786; // Golden zone end (retracement ratio)
// Quick-trade defaults for panel confirmations
input double InpQuickLot = 0.01; // 0 = use InpLotSize / AutoLot calc
input int InpQuickSL_Pips = 0;   // 0 = let EA compute SL
input int InpQuickTP_Pips = 0;   // 0 = let EA compute TP

input group "━━━━━━━━━ EQ LEVELS ━━━━━━━━━" input bool InpDrawEQHL = true; // Draw Equal High / Equal Low lines on chart
input int InpEQSwingStrength = 2;                                          // Swing confirmation: bars each side must be lower/higher (1-4)
input double InpEQTolerance = 0.10;                                        // Equal tolerance as ATR fraction (0.05 = tight, 0.15 = loose)
input int InpEQMaxLevels = 3;                                              // Max EQH levels + max EQL levels to detect (each)
input int InpEQLookback = 100;                                             // Bars to scan back for equal swing pairs
input color InpClrEQH = C'220,140,0';                                     // EQH line color
input color InpClrEQL = C'0,170,220';                                     // EQL line color

input group "━━━━━━━━━ EA CONFIG ━━━━━━━━━" input long InpMagic = 109823;
input bool InpAlerts = true;
input bool InpPush = false;
input bool InpLogging = true;

//+------------------------------------------------------------------+
//| GLOBALS                                                           |
//+------------------------------------------------------------------+
CTrade Trade;
CPositionInfo PosInfo;
CSymbolInfo SymInfo;

ENUM_TIMEFRAMES ORBTF;

// Effective parameters — populated by ApplyPreset() from SWING or INTRADAY inputs based on InpTradeMode
ENUM_TIMEFRAMES gHTFTF;
ENUM_TIMEFRAMES gLTFTF;
ENUM_TIMEFRAMES gDR_TF;
int gHTFLookback;
int gORBMins;
int gTimeFilter;
int gSweepLookback;
double gMinORBRange;
double gMaxORBRange;
int gMaxBarsAfterOR;
double gATR_SL;
double gATR_TP;
double gTPRangeMult;
double gMinRR;
double gTrailATR;
double gBETrigger;
bool gRequireImpulse;
double gBrkVolMin;
double gBrkCloseQuality;
ENUM_CONFIRM_MODE gConfirmMode;

int hATR = INVALID_HANDLE, hATR_LTF = INVALID_HANDLE, hATR_HTF = INVALID_HANDLE;

MqlRates ratesORB[], ratesHTF[], ratesLTF[];
MqlTick lastTick;

datetime lastBarORB = 0, lastBarHTF = 0;
bool newBarORB = false, newBarHTF = false;

// Session datetimes (server time)
datetime asiaStart, asiaEnd, asiaORStart, asiaOREnd, asiaKZEnd;
datetime londonStart, londonEnd, londonORStart, londonOREnd, londonKZEnd;
datetime nyStart, nyEnd, nyORStart, nyOREnd, nyKZEnd;

// Session flags
bool asiaSession = false, londonSession = false, nySession = false;
bool asiaKZ = false, londonKZ = false, nyKZ = false, londonNYOverlap = false;

// Session H/L
double asiaHigh = 0, asiaLow = 0, londonHigh = 0, londonLow = 0, nyHigh = 0, nyLow = 0;

// ORB levels
double asiaORHigh = 0, asiaORLow = 0, londonORHigh = 0, londonORLow = 0, nyORHigh = 0, nyORLow = 0;

// Basic ORB signals
bool asiaBreakoutUp = false, asiaBreakoutDown = false;
bool londonBreakoutUp = false, londonBreakoutDown = false;
bool nyBreakoutUp = false, nyBreakoutDown = false;
bool asiaRejectHigh = false, asiaRejectLow = false;
bool londonRejectHigh = false, londonRejectLow = false;
bool nyRejectHigh = false, nyRejectLow = false;
bool asiaFBH = false, asiaFBL = false, londonFBH = false, londonFBL = false, nyFBH = false, nyFBL = false;

// Breakout-leg Fibonacci tracking (visual only, see InpDrawFibo)
int fiboDir[SESS_COUNT] = {0, 0, 0};             // 0=none, 1=bull leg tracked, -1=bear leg tracked
double fiboA[SESS_COUNT] = {0, 0, 0};            // swing origin (OR low for bull / OR high for bear)
double fiboB[SESS_COUNT] = {0, 0, 0};            // running extreme reached since breakout
datetime fiboAnchorT[SESS_COUNT] = {0, 0, 0};    // breakout bar time (fixed leg start)

// HTF Bias
ENUM_BIAS htfBias = BIAS_NEUTRAL;
ENUM_BIAS htfBiasConfirmed = BIAS_NEUTRAL; // last confirmed directional bias (CHoCH memory)
double htfBosLevel = 0.0;                  // key level broken on last CHoCH confirmation
bool htfChoCh = false;                     // true on the bar CHoCH was confirmed (one-bar event)
double htfSwingH[3] = {0, 0, 0}, htfSwingL[3] = {0, 0, 0};
int htfSwingHCnt = 0, htfSwingLCnt = 0;

// Daily Bias (PDM method)
ENUM_BIAS dailyBias = BIAS_NEUTRAL;
double pdHigh = 0.0; // previous day high
double pdLow = 0.0;  // previous day low
double pdMid = 0.0;  // previous day midpoint = (PDH+PDL)/2

// SMC state [per session]
ENUM_SMC_STATE smcState[SESS_COUNT] = {SMC_IDLE, SMC_IDLE, SMC_IDLE};
bool setupBull[SESS_COUNT] = {false, false, false};
double sweepLvl[SESS_COUNT] = {0, 0, 0};
double bosLvl[SESS_COUNT] = {0, 0, 0};
datetime sweepTime[SESS_COUNT] = {0, 0, 0};
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime dispTime[SESS_COUNT] = {0, 0, 0}; // FIX: was int dispBar (index-shifting bug)
SOrderBlock ob[SESS_COUNT];
SFVG fvg[SESS_COUNT];
bool priceInZone[SESS_COUNT] = {false, false, false};
bool ltfConfirmed[SESS_COUNT] = {false, false, false};

// Liquidity
SLiqLevel liqLevels[SESS_COUNT][MAX_LIQ];
int liqCount[SESS_COUNT] = {0, 0, 0};

// Equal High / Equal Low levels (for drawing + sweep detection)
SEqLevel eqLevels[MAX_EQ];
int eqCount = 0;

// Trade state
bool tradeBuyDone[SESS_COUNT] = {false, false, false};
bool tradeSellDone[SESS_COUNT] = {false, false, false};
int sessTradeCount[SESS_COUNT] = {0, 0, 0};
bool partialTaken[SESS_COUNT] = {false, false, false};
// ── LTF Suggestion Engine — fully independent state, never read/written by the main SMC engine ──
ENUM_SMC_STATE ltfSuggState[SESS_COUNT] = {SMC_IDLE, SMC_IDLE, SMC_IDLE};
bool           ltfSuggBull[SESS_COUNT] = {false, false, false};
double         ltfSweepLvl[SESS_COUNT] = {0, 0, 0};
double         ltfBosLvl[SESS_COUNT] = {0, 0, 0};
datetime       ltfSweepTime[SESS_COUNT] = {0, 0, 0};
datetime       ltfDispTime[SESS_COUNT] = {0, 0, 0};
SOrderBlock    ltfSuggOB[SESS_COUNT];
SFVG           ltfSuggFVG[SESS_COUNT];
double         ltfSuggScore[SESS_COUNT] = {0, 0, 0};
bool           ltfSuggActed[SESS_COUNT] = {false, false, false};
MqlRates       ratesLTFSuggest[];
bool gJustPartialed[SESS_COUNT] = {false, false, false}; // true if partial TP fired this tick — clears at next tick start
double tp1Level[SESS_COUNT] = {0, 0, 0};
ulong sessTicket[SESS_COUNT] = {0, 0, 0};
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ulong pendingORTicket[SESS_COUNT] = {0, 0, 0}; // OR-lock pending Buy/Sell Stop ticket (InpUsePendingOR)
datetime lastSurgeBar[SESS_COUNT] = {0, 0, 0}; // time of last SURGE bar per session
int gDynTPState[SESS_COUNT] = {0, 0, 0};       // 1=SURGE extended, -1=EXHAUST tightened, 0=normal

// News cache
bool newsBlocked = false;
datetime newsLastCheck = 0;
datetime newsEventTime = 0;                                  // UTC time of the current blocking event
datetime newsNextTime = 0;                                   // UTC time of the next upcoming high-impact event (lookahead 4h)
bool newsEventTriggered[SESS_COUNT] = {false, false, false}; // Track news-triggered resets

// ── AMD Phase Detection — global, session-independent state ────────────
ENUM_AMD_PHASE amdPhase = AMD_NONE;
double         amdRangeHigh = 0, amdRangeLow = 0;
datetime       amdRangeStart = 0;
ENUM_BIAS      amdPriorTrendBias = BIAS_NEUTRAL;
MqlRates       ratesAMD[];

// Daily reset
datetime lastResetDay = 0;

// Volatility tracking
double dailyATR_Array[20] = {0}; // Last 20 days M15 ATR values for regime detection (same scale as ratio comparison)
double dailyATRAvg = 0;
ENUM_VOL_REGIME volRegime = VOL_NORMAL;
datetime lastVolatilityDay = 0; // FIX: gate vol regime update to once per D1 bar

// SMC locked timer — tracks when LOCKED state was entered (not session open)
datetime smcLockedTime[SESS_COUNT] = {0, 0, 0};
bool orbFallbackActive[SESS_COUNT] = {false, false, false}; // ORB fallback armed after SMC timeout
bool gReconstructing = false;                               // true during OnInit startup scan — bypasses timeLimitReached

// Alert flags
bool alertBuy[SESS_COUNT] = {false, false, false};
bool alertSell[SESS_COUNT] = {false, false, false};
bool alertSweep[SESS_COUNT] = {false, false, false};
bool alertBOS[SESS_COUNT] = {false, false, false};
bool alertOB[SESS_COUNT] = {false, false, false};
bool alertReady[SESS_COUNT] = {false, false, false};
bool alertRjH[SESS_COUNT] = {false, false, false};
bool alertRjL[SESS_COUNT] = {false, false, false};

// Session meta
string SESS_NAME[SESS_COUNT] = {"ASIA", "LONDON", "NEW YORK"};
color SESS_ZONE_CLR[SESS_COUNT] = {C'18,45,110', C'90,50,8', C'100,18,18'};
color SESS_KZ_CLR[SESS_COUNT] = {C'28,70,165', C'150,78,12', C'160,28,28'};
color SESS_LINE_CLR[SESS_COUNT] = {clrDodgerBlue, clrOrange, clrTomato};
color SESS_ORB_CLR[SESS_COUNT] = {C'0,90,185', C'185,110,0', C'185,45,45'};
// Bright near-white tinted per session — high contrast on dark zone backgrounds.
color SESS_TXT_CLR[SESS_COUNT] = {C'190,225,255', C'255,235,140', C'255,200,170'};

// Pivot points
double ppPP = 0, ppR1 = 0, ppR2 = 0, ppR3 = 0, ppS1 = 0, ppS2 = 0, ppS3 = 0;
datetime ppDayStart = 0;

// Volume Profile
double vpVolArr[];
double vpRangeL = 0, vpBinSize = 0, vpPOC = 0, vpVAH = 0, vpVAL = 0;
double vpMaxVol = 0;
bool vpReady = false;

// Phase 4: Dealing Range
SDealingRange dealingRange;
datetime lastDRBar = 0;

// Phase 15: Probability Score (per session)
double probScore[SESS_COUNT] = {0, 0, 0};

// Auto market-character detection
int gMarketCharScore[SESS_COUNT] = {50, 50, 50}; // 0=pure ORB, 100=pure SMC
bool gAutoSMC[SESS_COUNT] = {true, true, true};  // resolved per session when InpAutoMode

//+------------------------------------------------------------------+
//| ON INIT                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpLotSize <= 0)
     {
      Print("[ORB]ERR:Lot>0");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpSLMode == SL_FIXED && InpSL_Points <= 0)
     {
      Print("[ORB]ERR:SL_Points>0 when SL_FIXED mode");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpTPMode == TP_FIXED && InpTP_Points <= 0)
     {
      Print("[ORB]ERR:TP_Points>0 when TP_FIXED mode");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpAutoLot && (InpRiskPct <= 0 || InpRiskPct > 10))
     {
      Print("[ORB]ERR:RiskPct must be 0.1-10 when AutoLot=true");
      return INIT_PARAMETERS_INCORRECT;
     }
   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(20);
   Trade.SetTypeFilling(GetFillingMode());
   Trade.LogLevel(LOG_LEVEL_ERRORS);
   ApplyPreset();
   ArraySetAsSeries(ratesORB, true);
   ArraySetAsSeries(ratesHTF, true);
   ArraySetAsSeries(ratesLTF, true);
   ArraySetAsSeries(ratesLTFSuggest, true);
   ArraySetAsSeries(ratesAMD, true);
   for(int ps = 0; ps < SESS_COUNT; ps++)
      HidePositionTool(ps);
   hATR = iATR(_Symbol, ORBTF, InpATR_Period);
   hATR_LTF = iATR(_Symbol, gLTFTF, InpATR_Period);
   hATR_HTF = iATR(_Symbol, gHTFTF, InpATR_Period);
   if(hATR == INVALID_HANDLE || hATR_LTF == INVALID_HANDLE || hATR_HTF == INVALID_HANDLE)
     {
      Print("[ORB]ERR:ATR handle");
      return INIT_FAILED;
     }
   SymInfo.Name(_Symbol);
   SymInfo.Refresh();
   for(int s = 0; s < SESS_COUNT; s++)
     {
      ob[s].valid = false;
      ob[s].touchCount = 0;
      fvg[s].valid = false;
      fvg[s].touchCount = 0;
      probScore[s] = 0;
     }
   ZeroMemory(dealingRange);
   CopyRates(_Symbol, ORBTF, 0, 500, ratesORB);
   CopyRates(_Symbol, gHTFTF, 0, gHTFLookback + 20, ratesHTF);
   DetectSessionsUTC();
   BuildSessionRanges();
   BuildOpeningRange();
   UpdateHTFBias(true);
   UpdateDailyBias();
   UpdateDealingRange();   // Phase 4: initial dealing range calculation
   if(!RestoreSMCState())  // false = no saved state (fresh terminal) → scan history
      ReconstructSMCState();
// Ensure sessTradeCount reflects any live positions/orders present before EA start
   ReconcileSessTradeCount();
// initialize per-session quick params
   for(int si = 0; si < SESS_COUNT; si++)
     {
      gQuickLotSess[si] = (InpQuickLot > 0) ? InpQuickLot : InpLotSize;
      gQuickSL_pipsSess[si] = InpQuickSL_Pips;
      gQuickTP_pipsSess[si] = InpQuickTP_Pips;
     }
   if(InpDrawObjects)
      DrawAll(true);
   LogMsg(StringFormat("STARTED v6.00 | %s | Magic:%d | ORB:%s/%dmin | HTF:%s | LTF:%s | SMC:%s | SL:%s | TP:%s | London:%02d:00 UTC | NY:%s",
                       _Symbol, InpMagic, EnumToString(ORBTF), gORBMins,
                       EnumToString(gHTFTF), EnumToString(gLTFTF), InpAutoMode ? "AUTO" : (InpUseSMC ? "SMC" : "ORB"),
                       EnumToString(InpSLMode), EnumToString(InpTPMode),
                       InpLondonH_S,
                       InpNY_StockMode ? "14:30 UTC (NYSE)" : "13:30 UTC (Forex)"));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ApplyPreset()
  {
   bool sw = (InpTradeMode == MODE_SWING);
   ORBTF = sw ? InpSwing_ORBTF : InpIntra_ORBTF;
   gHTFTF = sw ? InpSwing_HTFTF : InpIntra_HTFTF;
   gLTFTF = sw ? InpSwing_LTFTF : InpIntra_LTFTF;
   gDR_TF = sw ? InpSwing_DRTF : InpIntra_DRTF;
   gORBMins = sw ? InpSwing_ORBMins : InpIntra_ORBMins;
   gHTFLookback = sw ? InpSwing_HTFLookback : InpIntra_HTFLookback;
   gTimeFilter = sw ? InpSwing_TimeFilter : InpIntra_TimeFilter;
   gSweepLookback = sw ? InpSwing_SweepLookback : InpIntra_SweepLookback;
   gMinORBRange = sw ? InpSwing_MinORBRange : InpIntra_MinORBRange;
   gMaxORBRange = sw ? InpSwing_MaxORBRange : InpIntra_MaxORBRange;
   gMaxBarsAfterOR = sw ? InpSwing_MaxBarsAfterOR : InpIntra_MaxBarsAfterOR;
   gATR_SL = sw ? InpSwing_ATR_SL : InpIntra_ATR_SL;
   gATR_TP = sw ? InpSwing_ATR_TP : InpIntra_ATR_TP;
   gTPRangeMult = sw ? InpSwing_TPRangeMult : InpIntra_TPRangeMult;
   gMinRR = sw ? InpSwing_MinRR : InpIntra_MinRR;
   gTrailATR = sw ? InpSwing_TrailATR : InpIntra_TrailATR;
   gBETrigger = sw ? InpSwing_BETrigger : InpIntra_BETrigger;
   gRequireImpulse = sw ? InpSwing_RequireImpulse : InpIntra_RequireImpulse;
   gBrkVolMin = sw ? InpSwing_BrkVolMin : InpIntra_BrkVolMin;
   gBrkCloseQuality = sw ? InpSwing_BrkCloseQuality : InpIntra_BrkCloseQuality;
   gConfirmMode = sw ? InpSwing_ConfirmMode : InpIntra_ConfirmMode;
  }

// Returns the effective InpUseSMC for a specific session.
// When InpAutoMode is true, returns the auto-detected value; otherwise returns the global input.
bool UsesSMC(int sess) { return InpAutoMode ? gAutoSMC[sess] : InpUseSMC; }

// Scores market character for a session: 0 = pure ORB, 100 = pure SMC/AMD.
// Combines OR-range/ATR ratio, vol regime, HTF bias, sweep presence, OR position in PDR.
int CalcMarketCharScore(int sess)
  {
   int score = 50;
   double atr = GetATR(1);
   double orH = GetSessORH(sess), orL = GetSessORL(sess);
// Factor 1: OR range vs ATR — compact range = AMD consolidation; wide range = momentum
   if(atr > 0 && orH > orL)
     {
      double ratio = (orH - orL) / atr;
      if(ratio < 0.30)
         score += 22;
      else
         if(ratio < 0.55)
            score += 8;
         else
            if(ratio > 0.80)
               score -= 22;
            else
               if(ratio > 0.55)
                  score -= 8;
     }
// Factor 2: Volatility regime (already computed each bar)
   if(volRegime == VOL_CALM)
      score += 15;
   else
      if(volRegime == VOL_HIGH || volRegime == VOL_EXPLOSIVE)
         score -= 15;
// Factor 3: HTF bias — neutral HTF = ranging market = AMD likely
   if(htfBias == BIAS_NEUTRAL)
      score += 10;
   else
      score -= 10;
// Factor 4: Sweep already confirmed this session
   for(int k = 0; k < liqCount[sess]; k++)
      if(liqLevels[sess][k].swept)
        {
         score += 25;
         break;
        }
// Factor 5: OR midpoint position within previous day's range
   if(pdHigh > pdLow && orH > orL)
     {
      double orMid = (orH + orL) * 0.5;
      double distFrac = MathAbs(orMid - pdMid) / (pdHigh - pdLow);
      if(distFrac < 0.20)
         score += 15; // OR centered near PDM → accumulation
      else
         if(distFrac > 0.45)
            score -= 15; // OR at PDH/PDL extreme → momentum breakout
     }
   return MathMax(0, MathMin(100, score));
  }

// Re-scores all sessions and updates gAutoSMC[]. Called on each new ORB bar.
// F-04 FIX: mode is locked once session progresses past LOCKED (OR closed).
//           Prevents mid-session flip where SMC zones built under one mode are
//           evaluated under the other when market character score changes.
void UpdateAutoMode()
  {
   if(!InpAutoMode)
      return;
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(!IsSessEnabled(s))
         continue;
      if(smcState[s] > SMC_LOCKED)
         continue; // mode locked — session is already active, do not re-score
      gMarketCharScore[s] = CalcMarketCharScore(s);
      bool wasSMC = gAutoSMC[s];
      gAutoSMC[s] = (gMarketCharScore[s] >= 55);
      if(gAutoSMC[s] != wasSMC)
         LogMsg(SESS_NAME[s] + StringFormat(" AUTO MODE → %s (score:%d)",
                                            gAutoSMC[s] ? "SMC" : "ORB", gMarketCharScore[s]));
     }
  }

// Persist full SMC + trade execution state to GlobalVariables on timeframe change
void SaveSMCState()
  {
   string sym = StringSubstr(_Symbol, 0, 8);
// Freshness marker — checked on restore to avoid cross-day stale data
   GlobalVariableSet("ORB_" + sym + "_ts", (double)TimeCurrent());
   for(int s = 0; s < SESS_COUNT; s++)
     {
      string k = "ORB_" + sym + "_S" + string(s) + "_";
      // ── SMC pipeline state ────────────────────────────────────────────
      GlobalVariableSet(k + "st", (double)smcState[s]);
      GlobalVariableSet(k + "sbul", setupBull[s] ? 1.0 : 0.0);
      GlobalVariableSet(k + "swL", sweepLvl[s]);
      GlobalVariableSet(k + "bosL", bosLvl[s]);
      GlobalVariableSet(k + "swT", (double)sweepTime[s]);
      GlobalVariableSet(k + "dT", (double)dispTime[s]);
      GlobalVariableSet(k + "lkT", (double)smcLockedTime[s]);
      GlobalVariableSet(k + "orFB", orbFallbackActive[s] ? 1.0 : 0.0);
      // ── Order Block ───────────────────────────────────────────────────
      GlobalVariableSet(k + "obV", ob[s].valid ? 1.0 : 0.0);
      GlobalVariableSet(k + "obH", ob[s].high);
      GlobalVariableSet(k + "obL", ob[s].low);
      GlobalVariableSet(k + "obT", (double)ob[s].time);
      GlobalVariableSet(k + "obBul", ob[s].bullish ? 1.0 : 0.0);
      GlobalVariableSet(k + "obTC", (double)ob[s].touchCount);
      // ── Fair Value Gap ────────────────────────────────────────────────
      GlobalVariableSet(k + "fgV", fvg[s].valid ? 1.0 : 0.0);
      GlobalVariableSet(k + "fgH", fvg[s].high);
      GlobalVariableSet(k + "fgL", fvg[s].low);
      GlobalVariableSet(k + "fgT", (double)fvg[s].time);
      GlobalVariableSet(k + "fgBul", fvg[s].bullish ? 1.0 : 0.0);
      GlobalVariableSet(k + "fgTC", (double)fvg[s].touchCount);
      // ── Trade execution state — prevents double entry after TF switch ─
      GlobalVariableSet(k + "tBuy", tradeBuyDone[s] ? 1.0 : 0.0);
      GlobalVariableSet(k + "tSel", tradeSellDone[s] ? 1.0 : 0.0);
      GlobalVariableSet(k + "tCnt", (double)sessTradeCount[s]);
      GlobalVariableSet(k + "tTkt", (double)sessTicket[s]);
      GlobalVariableSet(k + "pOrT", (double)pendingORTicket[s]);
      GlobalVariableSet(k + "tPar", partialTaken[s] ? 1.0 : 0.0);
      GlobalVariableSet(k + "tTP1", tp1Level[s]);
      GlobalVariableSet(k + "dtpSt", (double)gDynTPState[s]);
      // ── Auto-mode market character ────────────────────────────────────
      GlobalVariableSet(k + "amSMC", gAutoSMC[s] ? 1.0 : 0.0);
      GlobalVariableSet(k + "amScr", (double)gMarketCharScore[s]);
     }
   LogMsg("SMC state saved (TF change)");
  }

// Restore full SMC + trade execution state from GlobalVariables after timeframe change.
// Returns true if state was actually restored, false if no valid saved state found.
bool RestoreSMCState()
  {
   string sym = StringSubstr(_Symbol, 0, 8);
   string tsKey = "ORB_" + sym + "_ts";
   if(!GlobalVariableCheck(tsKey))
      return false;
   datetime saved = (datetime)GlobalVariableGet(tsKey);
   datetime today = StringToTime(TimeToString(TimeGMT(), TIME_DATE));
   if(saved < today)
      return false; // stale — different day, don't restore
   for(int s = 0; s < SESS_COUNT; s++)
     {
      string k = "ORB_" + sym + "_S" + string(s) + "_";
      // ── SMC pipeline state ────────────────────────────────────────────
      smcState[s] = (ENUM_SMC_STATE)(int)GlobalVariableGet(k + "st");
      setupBull[s] = GlobalVariableGet(k + "sbul") > 0.5;
      sweepLvl[s] = GlobalVariableGet(k + "swL");
      bosLvl[s] = GlobalVariableGet(k + "bosL");
      sweepTime[s] = (datetime)GlobalVariableGet(k + "swT");
      dispTime[s] = (datetime)GlobalVariableGet(k + "dT");
      smcLockedTime[s] = (datetime)GlobalVariableGet(k + "lkT");
      orbFallbackActive[s] = GlobalVariableGet(k + "orFB") > 0.5;
      // ── Order Block ───────────────────────────────────────────────────
      ob[s].valid = GlobalVariableGet(k + "obV") > 0.5;
      ob[s].high = GlobalVariableGet(k + "obH");
      ob[s].low = GlobalVariableGet(k + "obL");
      ob[s].time = (datetime)GlobalVariableGet(k + "obT");
      ob[s].bullish = GlobalVariableGet(k + "obBul") > 0.5;
      ob[s].touchCount = (int)GlobalVariableGet(k + "obTC");
      // ── Fair Value Gap ────────────────────────────────────────────────
      fvg[s].valid = GlobalVariableGet(k + "fgV") > 0.5;
      fvg[s].high = GlobalVariableGet(k + "fgH");
      fvg[s].low = GlobalVariableGet(k + "fgL");
      fvg[s].time = (datetime)GlobalVariableGet(k + "fgT");
      fvg[s].bullish = GlobalVariableGet(k + "fgBul") > 0.5;
      fvg[s].touchCount = (int)GlobalVariableGet(k + "fgTC");
      // ── Trade execution state ─────────────────────────────────────────
      tradeBuyDone[s] = GlobalVariableGet(k + "tBuy") > 0.5;
      tradeSellDone[s] = GlobalVariableGet(k + "tSel") > 0.5;
      sessTradeCount[s] = (int)GlobalVariableGet(k + "tCnt");
      sessTicket[s] = (ulong)GlobalVariableGet(k + "tTkt");
      pendingORTicket[s] = (ulong)GlobalVariableGet(k + "pOrT"); // 0 if key absent (pre-existing saved state)
      partialTaken[s] = GlobalVariableGet(k + "tPar") > 0.5;
      tp1Level[s] = GlobalVariableGet(k + "tTP1");
      gDynTPState[s] = (int)GlobalVariableGet(k + "dtpSt");
      // ── Auto-mode market character ────────────────────────────────────
      gAutoSMC[s] = GlobalVariableGet(k + "amSMC") > 0.5;
      gMarketCharScore[s] = (int)GlobalVariableGet(k + "amScr");
     }
   LogMsg("SMC state restored (TF change)");
   return true;
  }

// Reconstruct SMC pipeline state from historical bars on fresh terminal start.
// Called when RestoreSMCState() finds no saved GlobalVariables (EA never ran today).
// Uses gReconstructing flag to bypass timeLimitReached so the state machine can
// fast-forward through history up to the current bar.
void ReconstructSMCState()
  {
   if(!InpUseSMC && !InpAutoMode)
      return;
   gReconstructing = true;
   LogMsg("RECONSTRUCT START: max passes=20");
   int passesDone = 0;
   for(int pass = 0; pass < 20; pass++)
     {
      bool anyChanged = false;
      for(int s = 0; s < SESS_COUNT; s++)
        {
         ENUM_SMC_STATE before = smcState[s];
         UpdateSMCSession(s);
         if(smcState[s] != before)
            anyChanged = true;
        }
      passesDone++;
      if(!anyChanged)
         break; // all sessions stable — no further advancement possible
     }
   gReconstructing = false;
   for(int s = 0; s < SESS_COUNT; s++)
      LogMsg("RECONSTRUCT " + SESS_NAME[s] + " → " + EnumToString(smcState[s]));
   LogMsg(StringFormat("RECONSTRUCT DONE: passes=%d", passesDone));
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hATR != INVALID_HANDLE)
      IndicatorRelease(hATR);
   if(hATR_LTF != INVALID_HANDLE)
      IndicatorRelease(hATR_LTF);
   if(hATR_HTF != INVALID_HANDLE)
      IndicatorRelease(hATR_HTF);
// Save state on TF switch, recompile, and terminal close so RestoreSMCState()
// can recover the pipeline on the next OnInit(). REASON_REMOVE / REASON_PARAMETERS
// / REASON_TEMPLATE intentionally skip the save — those are deliberate resets.
   if(reason == REASON_CHARTCHANGE ||
      reason == REASON_RECOMPILE ||
      reason == REASON_CLOSE)
      SaveSMCState();
// Clean chart objects on everything except TF switch (TF switch keeps objects visible)
   if(reason != REASON_CHARTCHANGE)
      CleanAll();
   LogMsg("REMOVED|Code:" + string(reason));
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsNewLTFBar()
  {
   static datetime lastBar = 0;
   datetime current =
      iTime(
         _Symbol,
         gLTFTF,
         0);
   if(current != lastBar)
     {
      lastBar = current;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| ON TICK                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   ArrayInitialize(gJustPartialed, false); // reset per-tick partial flag
   CheckDailyReset();
   UpdateMarketData();
   newBarORB = IsNewBarORB();
   newBarHTF = IsNewBarHTF();
   DetectSessionsUTC();
   BuildSessionRanges();
   BuildOpeningRange();
   if(newBarHTF)
     {
      UpdateHTFBias(false);
      UpdateDailyBias();
      UpdateDealingRange(); // Phase 4: refresh dealing range on new HTF bar
      if(InpEnableAMDDetection)
         UpdateAMDPhase();
     }
   bool needSignalRefresh = newBarORB;
   if(needSignalRefresh)
     {
      BuildLiquidityLevels();
      DetectBasicSignals();
      UpdateFiboLegs();
      UpdateVolatilityRegime();
      UpdateAutoMode();
      CalcDailyPivots();
      // AUDIT FIX: was only built inside DrawAll() (gated by InpDrawObjects), so
      // InpUseVPFilter and the CalcProbScore VP component silently went inert whenever
      // chart drawing was disabled. Must run regardless of visual settings.
      BuildVolumeProfile();
     }
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(smcState[s] >= SMC_ZONE && SMC_ZoneInvalidated(s))
        {
         LogMsg(SESS_NAME[s] + " INTRA-BAR ZONE INVALIDATED - State reset");
         ResetSMCState(s);
        }
     }
   if(needSignalRefresh || newBarHTF)
     {
      if(InpUseSMC || InpAutoMode)
         for(int s = 0; s < SESS_COUNT; s++)
            UpdateSMCSession(s);
     }
   if(needSignalRefresh && (InpDrawOB || InpDrawFVG))
     {
      for(int s = 0; s < SESS_COUNT; s++)
         if(smcState[s] < SMC_ZONE)
            ScanOBFVGSession(s);
     }

// TradeEngine runs every tick (not gated to LTF bar close): the underlying breakout/SMC
// signals are already bar-close confirmed and don't change intrabar, but CanEnter's
// fast-moving filters (spread, HasOpenOrPendingTrade) do — checking them only once per
// LTF bar close adds up to a full LTF-bar's latency before a transient block clears.
   TradeEngine();
// Per-tick, same reasoning as TradeEngine(): the whole point of a pending stop is to fill
// the instant price reaches it rather than waiting for a bar close, so placement/fill
// detection can't be gated to LTF bar boundaries either.

   if(!IsNewLTFBar())
      return;
   ManagePositions(); // per-tick: partial TP + BE
   ManagePositions_Bar(); // per-bar: trailing + dynamic TP
   for(int s = 0; s < SESS_COUNT; s++)
      UpdateLTFSuggestSession(s);
   if(InpDrawObjects)
      DrawAll(newBarORB);
   ORBAlertEngine();
   if(InpUsePendingOR)
      for(int s = 0; s < SESS_COUNT; s++)
         ManagePendingOR(s);
  }

//============================================================
// MODULE: MARKET DATA
//============================================================
void UpdateMarketData()
  {
   CopyRates(_Symbol, ORBTF, 0, 500, ratesORB);
   CopyRates(_Symbol, gLTFTF, 0, 30, ratesLTF);
   SymbolInfoTick(_Symbol, lastTick);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsNewBarORB()
  {
   if(ArraySize(ratesORB) < 1)
      return false;
   if(ratesORB[0].time == lastBarORB)
      return false;
   lastBarORB = ratesORB[0].time;
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsNewBarHTF()
  {
   MqlRates tmp[1];
   ArraySetAsSeries(tmp, true);
   if(CopyRates(_Symbol, gHTFTF, 0, 1, tmp) < 1)
      return false;
   if(tmp[0].time == lastBarHTF)
      return false;
   lastBarHTF = tmp[0].time;
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetATR(int shift = 1)
  {
   if(hATR == INVALID_HANDLE)
      return 0;
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(hATR, 0, 0, shift + 2, b) < shift + 2)
      return 0;
   return MathMax(b[shift], 0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetATRLTF(int shift = 1)
  {
   if(hATR_LTF == INVALID_HANDLE)
      return 0;
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(hATR_LTF, 0, 0, shift + 2, b) < shift + 2)
      return 0;
   return MathMax(b[shift], 0);
  }

//+------------------------------------------------------------------+
//| HTF ATR accessor — hATR_HTF was created in OnInit (and released in |
//| OnDeinit) but had no reader anywhere in the file before this. Same  |
//| pattern as GetATR/GetATRLTF.                                       |
//+------------------------------------------------------------------+
double GetATRHTF(int shift = 1)
  {
   if(hATR_HTF == INVALID_HANDLE)
      return 0.0;
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(hATR_HTF, 0, 0, shift + 2, b) < shift + 2)
      return 0;
   return MathMax(b[shift], 0);
  }

//+------------------------------------------------------------------+
//| AMD Phase Detection — driver, called once per new HTF bar.        |
//+------------------------------------------------------------------+
void UpdateAMDPhase()
  {
   if(CopyRates(_Symbol, gHTFTF, 0, InpAMD_RangeLookback + 5, ratesAMD) < InpAMD_RangeLookback + 1)
      return;
   double atr = GetATRHTF(1);
   if(atr <= 0)
      return;

   if(amdPhase == AMD_NONE)
     {
      double hi = ratesAMD[1].high, lo = ratesAMD[1].low;
      for(int i = 2; i <= InpAMD_RangeLookback; i++)
        {
         hi = MathMax(hi, ratesAMD[i].high);
         lo = MathMin(lo, ratesAMD[i].low);
        }
      if((hi - lo) <= atr * InpAMD_MaxRangeATR)
        {
         amdRangeHigh = hi;
         amdRangeLow = lo;
         amdRangeStart = ratesAMD[InpAMD_RangeLookback].time;
         amdPriorTrendBias = htfBias;
         amdPhase = (amdPriorTrendBias == BIAS_BEARISH) ? AMD_ACCUMULATION
                    : (amdPriorTrendBias == BIAS_BULLISH) ? AMD_DISTRIBUTION
                    : AMD_CONSOLIDATION;
         LogMsg(StringFormat("[AMD] Range detected %.5f-%.5f -> %s", lo, hi, EnumToString(amdPhase)));
        }
      return;
     }

   double c1 = ratesAMD[1].close, h1 = ratesAMD[1].high, l1 = ratesAMD[1].low;
   double buf = atr * InpSweepBuffer;

   if(amdPhase == AMD_MANIPULATION)
     {
      bool backInside = (c1 <= amdRangeHigh && c1 >= amdRangeLow);
      if(backInside)
        {
         amdPhase = (amdPriorTrendBias == BIAS_BEARISH) ? AMD_ACCUMULATION
                    : (amdPriorTrendBias == BIAS_BULLISH) ? AMD_DISTRIBUTION
                    : AMD_CONSOLIDATION;
         LogMsg("[AMD] Sweep reabsorbed — range continues as " + EnumToString(amdPhase));
        }
      else
        {
         LogMsg("[AMD] Breakout confirmed — range concluded");
         amdPhase = AMD_NONE;
         amdRangeHigh = amdRangeLow = 0;
         amdRangeStart = 0;
        }
      return;
     }

// Direct breakout: price closed decisively beyond a boundary without first
// showing a sweep-and-reject wick (the common case for a clean trend
// continuation, as opposed to a manipulation/stop-hunt reversal). Without
// this check the only exit from an active range was via AMD_MANIPULATION,
// which requires the close to come back INSIDE the range — so a genuine
// breakout that never wicks back in would leave the range stuck forever.
   if(c1 > amdRangeHigh + buf || c1 < amdRangeLow - buf)
     {
      LogMsg("[AMD] Direct breakout (no manipulation wick) — range concluded");
      amdPhase = AMD_NONE;
      amdRangeHigh = amdRangeLow = 0;
      amdRangeStart = 0;
      return;
     }
   bool sweptHigh = (h1 > amdRangeHigh + buf && c1 < amdRangeHigh - buf);
   bool sweptLow = (l1 < amdRangeLow - buf && c1 > amdRangeLow + buf);
   if(sweptHigh || sweptLow)
     {
      amdPhase = AMD_MANIPULATION;
      LogMsg("[AMD] Sweep of range boundary detected — MANIPULATION");
     }
  }

// Returns simple mean of (high-low) over InpATR_Period bars — no gap adjustment.
double GetCumMeanRange(int shift = 1)
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int need = InpATR_Period + shift;
   if(CopyRates(_Symbol, ORBTF, shift, need, r) < need)
      return 0;
   double sum = 0;
   for(int i = 0; i < InpATR_Period; i++)
      sum += r[i].high - r[i].low;
   return MathMax(sum / InpATR_Period, 0);
  }

// Returns the active volatility measure for BE calculations (ATR or CMR).
double GetBEMeasure()
  {
   return (InpBE_Mode == BE_CMR) ? GetCumMeanRange(1) : GetATR(1);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode()
  {
   uint f = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((f & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((f & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(mn, MathMin(mx, lot));
// Pair compat: derive decimal precision from volume step
   int prec = (int)MathMax(0, -MathFloor(MathLog10(st + 1e-10)));
   return NormalizeDouble(MathRound(lot / st) * st, MathMin(prec, 4));
  }

// Calculate lot size to risk exactly InpRiskPct% of account balance on slDist.
// Falls back to InpLotSize if account/symbol info is unavailable.
double CalcRiskLot(double slDist)
  {
   if(!InpAutoLot || slDist <= 0)
      return NormalizeLot(InpLotSize);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tSz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(bal <= 0 || tick <= 0 || tSz <= 0)
      return NormalizeLot(InpLotSize);
   double riskAmt = bal * InpRiskPct / 100.0;
   double lot = riskAmt / ((slDist / tSz) * tick);
   return NormalizeLot(lot);
  }

// FIX: Find bar index by exact time match
int FindBarByTime(datetime t)
  {
   int sz = ArraySize(ratesORB);
   if(sz <= 0)
      return -1;
// Exact match first
   for(int i = 0; i < sz; i++)
      if(ratesORB[i].time == t)
         return i;
// Fallback: return nearest bar within one ORB timeframe (tolerance = PeriodSeconds(ORBTF))
   int bestIdx = -1;
   long bestDiff = LONG_MAX;
   long tol = PeriodSeconds(ORBTF);
   for(int i = 0; i < sz; i++)
     {
      long diff = MathAbs((long)(ratesORB[i].time - t));
      if(diff < bestDiff)
        {
         bestDiff = diff;
         bestIdx = i;
        }
     }
   if(bestIdx >= 0 && bestDiff <= tol)
      return bestIdx;
   return -1;
  }

//============================================================
// MODULE: DAILY RESET
//============================================================
void CheckDailyReset()
  {
   datetime mid = StringToTime(TimeToString(TimeGMT(), TIME_DATE));
   if(lastResetDay == mid)
      return;
   lastResetDay = mid;
   for(int s = 0; s < SESS_COUNT; s++)
     {
      tradeBuyDone[s] = tradeSellDone[s] = false;
      sessTradeCount[s] = 0;
      partialTaken[s] = false;
      tp1Level[s] = 0;
      sessTicket[s] = 0;
      lastSurgeBar[s] = 0;
      gDynTPState[s] = 0;
      alertBuy[s] = alertSell[s] = alertSweep[s] = false;
      alertBOS[s] = alertOB[s] = alertReady[s] = false;
      alertRjH[s] = alertRjL[s] = false;
      fiboDir[s] = 0;
      ResetSMCState(s);
      ltfSuggActed[s] = false;
      ResetLTFSuggestState(s);
     }
   htfBias = BIAS_NEUTRAL;
   htfBiasConfirmed = BIAS_NEUTRAL;
   htfBosLevel = 0.0;
   htfChoCh = false;
   dailyBias = BIAS_NEUTRAL;
   pdHigh = pdLow = pdMid = 0.0;
   newsBlocked = false;
   newsLastCheck = 0;
   for(int i = 0; i < SESS_COUNT; i++)
      newsEventTriggered[i] = false;
   lastBarORB = 0;
   lastVolatilityDay = 0; // force volatility array refresh on first bar of new day
   vpReady = false;
   UpdateDealingRange(); // refresh dealing range on daily reset
   LogMsg("━━━ DAILY RESET | " + TimeToString(mid, TIME_DATE) + " ━━━");
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CleanSMCObjects(int sess)
  {
   string p = SESS_NAME[sess];
   ObjectsDeleteAll(0, "SMC_" + p + "_");
   ObjectsDeleteAll(0, "ERD_" + p + "_");
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ResetSMCState(int sess)
  {
   CleanSMCObjects(sess);
// Covers daily reset, news-triggered reset, and zone invalidation (ResetSMCState is called
// from all three) — a stale OR-lock pending stop from before the reset must not survive it.
   if(InpUsePendingOR)
      CancelPendingOR(sess, "SMC state reset");
   smcState[sess] = SMC_IDLE;
   setupBull[sess] = false;
   sweepLvl[sess] = bosLvl[sess] = 0;
   sweepTime[sess] = dispTime[sess] = 0;
   smcLockedTime[sess] = 0;
   orbFallbackActive[sess] = false;
   ob[sess].valid = fvg[sess].valid = false;
   ob[sess].touchCount = fvg[sess].touchCount = 0;
   priceInZone[sess] = ltfConfirmed[sess] = false;
   probScore[sess] = 0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ResetLTFSuggestState(int sess)
  {
   ltfSuggState[sess] = SMC_IDLE;
   ltfSuggBull[sess] = false;
   ltfSweepLvl[sess] = ltfBosLvl[sess] = 0;
   ltfSweepTime[sess] = ltfDispTime[sess] = 0;
   ltfSuggOB[sess].valid = ltfSuggFVG[sess].valid = false;
   ltfSuggScore[sess] = 0;
  }

//============================================================
// MODULE: SESSION ENGINE
//============================================================
void DetectSessionsUTC()
  {
   asiaSession = londonSession = nySession = false;
   asiaKZ = londonKZ = nyKZ = londonNYOverlap = false;
   MqlDateTime tm;
   TimeToStruct(TimeGMT(), tm);
   int min = tm.hour * 60 + tm.min;
   int asS = InpAsiaH_Start * 60 + InpAsiaM_Start, asE = InpAsiaH_End * 60 + InpAsiaM_End;
   int lnS = InpLondonH_S * 60 + InpLondonM_S, lnE = InpLondonH_E * 60 + InpLondonM_E;
// FIX 6: NY stock mode uses 14:30 UTC (NYSE/NASDAQ open) instead of 13:30
   int nyStartH = (InpNY_StockMode ? 14 : InpNYH_S), nyStartM = (InpNY_StockMode ? 30 : InpNYM_S);
   int nyS = nyStartH * 60 + nyStartM, nyE = InpNYH_E * 60 + InpNYM_E;
   if(IsMinuteInWindow(min, asS, asE))
      asiaSession = true;
   if(IsMinuteInWindow(min, lnS, lnE))
      londonSession = true;
   if(IsMinuteInWindow(min, nyS, nyE))
      nySession = true;
   if(asiaSession && min < asS + 120)
      asiaKZ = true;
   if(londonSession && min < lnS + 150)
      londonKZ = true;
   if(nySession && min < nyS + 150)
      nyKZ = true;
   londonNYOverlap = (londonSession && nySession);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void BuildSessionRanges()
  {
// FIX: initialize properly so normalize below sets 0 when no bars found
   asiaHigh = -DBL_MAX;
   asiaLow = DBL_MAX;
   londonHigh = -DBL_MAX;
   londonLow = DBL_MAX;
   nyHigh = -DBL_MAX;
   nyLow = DBL_MAX;
   datetime utcNow = TimeGMT();
   datetime dayUTC = StringToTime(TimeToString(utcNow, TIME_DATE));
   int off = (int)(TimeCurrent() - utcNow);
   asiaStart = dayUTC + InpAsiaH_Start * 3600 + InpAsiaM_Start * 60 + off;
   asiaEnd = dayUTC + InpAsiaH_End * 3600 + InpAsiaM_End * 60 + off;
   londonStart = dayUTC + InpLondonH_S * 3600 + InpLondonM_S * 60 + off;
   londonEnd = dayUTC + InpLondonH_E * 3600 + InpLondonM_E * 60 + off;
// FIX 6: Stock mode → 14:30 UTC for NYSE/NASDAQ ORB
   int nyOpenH = (InpNY_StockMode ? 14 : InpNYH_S), nyOpenM = (InpNY_StockMode ? 30 : InpNYM_S);
   nyStart = dayUTC + nyOpenH * 3600 + nyOpenM * 60 + off;
   nyEnd = dayUTC + InpNYH_E * 3600 + InpNYM_E * 60 + off;
   if(asiaEnd <= asiaStart)
      asiaEnd += 24 * 3600;
   if(londonEnd <= londonStart)
      londonEnd += 24 * 3600;
   if(nyEnd <= nyStart)
      nyEnd += 24 * 3600;
   asiaKZEnd = asiaStart + 2 * 3600;
   londonKZEnd = londonStart + (long)(2.5 * 3600);
   nyKZEnd = nyStart + (long)(2.5 * 3600);
   int bars = ArraySize(ratesORB);
   for(int i = 0; i < bars; i++)
     {
      datetime t = ratesORB[i].time;
      double h = ratesORB[i].high, l = ratesORB[i].low;
      if(IsTimeInWindow(t, asiaStart, asiaEnd))
        {
         if(h > asiaHigh)
            asiaHigh = h;
         if(l < asiaLow)
            asiaLow = l;
        }
      if(IsTimeInWindow(t, londonStart, londonEnd))
        {
         if(h > londonHigh)
            londonHigh = h;
         if(l < londonLow)
            londonLow = l;
        }
      if(IsTimeInWindow(t, nyStart, nyEnd))
        {
         if(h > nyHigh)
            nyHigh = h;
         if(l < nyLow)
            nyLow = l;
        }
     }
// FIX: normalize no-data case
   if(asiaHigh == -DBL_MAX)
     {
      asiaHigh = 0;
      asiaLow = 0;
     }
   if(londonHigh == -DBL_MAX)
     {
      londonHigh = 0;
      londonLow = 0;
     }
   if(nyHigh == -DBL_MAX)
     {
      nyHigh = 0;
      nyLow = 0;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void BuildOpeningRange()
  {
   asiaORHigh = -DBL_MAX;
   asiaORLow = DBL_MAX;
   londonORHigh = -DBL_MAX;
   londonORLow = DBL_MAX;
   nyORHigh = -DBL_MAX;
   nyORLow = DBL_MAX;
   int orbSec = gORBMins * 60;
   asiaORStart = asiaStart;
   asiaOREnd = asiaStart + orbSec;
   londonORStart = londonStart;
   londonOREnd = londonStart + orbSec;
   nyORStart = nyStart;
   nyOREnd = nyStart + orbSec;
   if(asiaOREnd <= asiaORStart)
      asiaOREnd += 24 * 3600;
   if(londonOREnd <= londonORStart)
      londonOREnd += 24 * 3600;
   if(nyOREnd <= nyORStart)
      nyOREnd += 24 * 3600;
   int bars = ArraySize(ratesORB);
// Start from i=1 to skip the live (incomplete) bar at index 0 — prevents the ORB
// high/low from repainting on every tick while the ORB window is still forming.
// IsORBLocked gates trading until TimeCurrent() >= OREnd so only closed bars matter.
   for(int i = 1; i < bars; i++)
     {
      datetime t = ratesORB[i].time;
      double h = ratesORB[i].high, l = ratesORB[i].low;
      if(IsTimeInWindow(t, asiaORStart, asiaOREnd))
        {
         if(h > asiaORHigh)
            asiaORHigh = h;
         if(l < asiaORLow)
            asiaORLow = l;
        }
      if(IsTimeInWindow(t, londonORStart, londonOREnd))
        {
         if(h > londonORHigh)
            londonORHigh = h;
         if(l < londonORLow)
            londonORLow = l;
        }
      if(IsTimeInWindow(t, nyORStart, nyOREnd))
        {
         if(h > nyORHigh)
            nyORHigh = h;
         if(l < nyORLow)
            nyORLow = l;
        }
     }
   if(asiaORHigh == -DBL_MAX)
     {
      asiaORHigh = 0;
      asiaORLow = 0;
     }
   if(londonORHigh == -DBL_MAX)
     {
      londonORHigh = 0;
      londonORLow = 0;
     }
   if(nyORHigh == -DBL_MAX)
     {
      nyORHigh = 0;
      nyORLow = 0;
     }
  }

//============================================================
// MODULE: HTF BIAS  — only runs on new HTF bar
//============================================================
void UpdateHTFBias(bool force)
  {
   if(!force && !newBarHTF)
      return; // FIX: skip if not new H1/H4 bar
   int copied = CopyRates(_Symbol, gHTFTF, 0, gHTFLookback + 10, ratesHTF);
   if(copied < gHTFLookback)
     {
      htfBias = BIAS_NEUTRAL;
      htfBiasConfirmed = BIAS_NEUTRAL;
      htfBosLevel = 0.0;
      htfChoCh = false;
      return;
     }
   htfSwingHCnt = 0;
   htfSwingLCnt = 0;
   int piv = MathMin(InpSwingPivot, 3);
   for(int i = 1; i < copied - 1 && (htfSwingHCnt < 3 || htfSwingLCnt < 3); i++)
     {
      if(htfSwingHCnt < 3 && IsSwingH(ratesHTF, i, piv, copied))
        {
         htfSwingH[htfSwingHCnt] = ratesHTF[i].high;
         htfSwingHCnt++;
        }
      if(htfSwingLCnt < 3 && IsSwingL(ratesHTF, i, piv, copied))
        {
         htfSwingL[htfSwingLCnt] = ratesHTF[i].low;
         htfSwingLCnt++;
        }
     }
   if(htfSwingHCnt < 2 || htfSwingLCnt < 2)
     {
      htfBias = BIAS_NEUTRAL;
      htfBiasConfirmed = BIAS_NEUTRAL;
      htfBosLevel = 0.0;
      htfChoCh = false;
      return;
     }
   bool hh = (htfSwingH[0] > htfSwingH[1]), hl = (htfSwingL[0] > htfSwingL[1]);
   bool lh = (htfSwingH[0] < htfSwingH[1]), ll = (htfSwingL[0] < htfSwingL[1]);
   ENUM_BIAS rawBias;
   if(hh && hl)
      rawBias = BIAS_BULLISH;
   else
      if(lh && ll)
         rawBias = BIAS_BEARISH;
      else
         rawBias = BIAS_NEUTRAL;
   htfChoCh = false;
   double cls = ratesHTF[0].close;
   double prevCls = (copied > 1) ? ratesHTF[1].close : cls;
   if(htfBiasConfirmed != BIAS_NEUTRAL && rawBias != BIAS_NEUTRAL && rawBias != htfBiasConfirmed)
     {
      // Potential reversal — accept the flip once the latest candles have actually broken the
      // candidate swing level, while still avoiding noise from a single wick or micro-structure bar.
      bool confirmBreak = (rawBias == BIAS_BEARISH && (cls < htfSwingL[1] || prevCls < htfSwingL[1])) ||
                          (rawBias == BIAS_BULLISH && (cls > htfSwingH[1] || prevCls > htfSwingH[1]));
      if(confirmBreak)
        {
         htfBias = rawBias;
         htfBiasConfirmed = rawBias;
         htfBosLevel = (rawBias == BIAS_BEARISH) ? htfSwingL[1] : htfSwingH[1];
         htfChoCh = true;
         LogMsg(StringFormat("HTF CHoCH %s — close %.5f / prev %.5f vs level %.5f",
                             rawBias == BIAS_BEARISH ? "BEARISH" : "BULLISH",
                             cls, prevCls, (rawBias == BIAS_BEARISH) ? htfSwingL[1] : htfSwingH[1]));
        }
      else
        {
         // Swings flipping but the recent closes have not confirmed the break yet — hold neutral
         // and preserve the previous trend memory for the next bar check.
         htfBias = BIAS_NEUTRAL;
         double pendingLvl = (rawBias == BIAS_BEARISH) ? htfSwingL[1] : htfSwingH[1];
         LogMsg(StringFormat("HTF structure weakening (%s) — awaiting confirmation beyond %.5f",
                             rawBias == BIAS_BEARISH ? "BULL→BEAR" : "BEAR→BULL",
                             pendingLvl));
        }
     }
   else
     {
      // No reversal scenario: fresh trend establishment, continuation, or neutral — accept directly
      htfBias = rawBias;
      if(rawBias != BIAS_NEUTRAL)
         htfBiasConfirmed = rawBias;
     }
  }

//============================================================
// MODULE: DAILY BIAS (PDM method)
//============================================================
void UpdateDailyBias()
  {
   if(!InpUseDailyBias)
     {
      dailyBias = BIAS_NEUTRAL;
      return;
     }
   MqlRates daily[];
   int n = CopyRates(_Symbol, PERIOD_D1, 0, 3, daily);
   if(n < 2)
     {
      dailyBias = BIAS_NEUTRAL;
      pdHigh = pdLow = pdMid = 0.0;
      return;
     }
// daily[0] = current (incomplete) day, daily[1] = previous completed day
   pdHigh = daily[1].high;
   pdLow = daily[1].low;
   double range = pdHigh - pdLow;
   if(range <= 0)
     {
      dailyBias = BIAS_NEUTRAL;
      return;
     }
   pdMid = (pdHigh + pdLow) / 2.0;
   double atr = GetATR(1);
   double band = MathMax(range * InpDailyBiasZone, atr > 0 ? atr * 0.75 : range * 0.10);
   double refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ref = (refPrice + daily[0].close) / 2.0;
   double dist = ref - pdMid;
   if(dist > band)
      dailyBias = BIAS_BULLISH;
   else
      if(dist < -band)
         dailyBias = BIAS_BEARISH;
      else
         dailyBias = BIAS_NEUTRAL;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsSwingH(MqlRates &r[], int i, int piv, int total)
  {
   if(i < piv || i > total - 1 - piv)
      return false;
   double h = r[i].high;
   for(int j = 1; j <= piv; j++)
      if(r[i - j].high >= h || r[i + j].high >= h)
         return false;
   return true;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsSwingL(MqlRates &r[], int i, int piv, int total)
  {
   if(i < piv || i > total - 1 - piv)
      return false;
   double l = r[i].low;
   for(int j = 1; j <= piv; j++)
      if(r[i - j].low <= l || r[i + j].low <= l)
         return false;
   return true;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsSwingHORB(int i, int piv)
  {
   return IsSwingH(ratesORB, i, piv, ArraySize(ratesORB));
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsSwingLORB(int i, int piv)
  {
   return IsSwingL(ratesORB, i, piv, ArraySize(ratesORB));
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double FindSwingHigh(int from, int to)
  {
   int sz = ArraySize(ratesORB);
   to = MathMin(to, sz - 2);
   for(int i = from; i <= to; i++)
      if(IsSwingHORB(i, 2))
         return ratesORB[i].high;
   return 0; // no qualifying swing — bosLvl stays 0 so SMC_Structure guard catches it
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double FindSwingLow(int from, int to)
  {
   int sz = ArraySize(ratesORB);
   to = MathMin(to, sz - 2);
   for(int i = from; i <= to; i++)
      if(IsSwingLORB(i, 2))
         return ratesORB[i].low;
   return 0; // no qualifying swing — bosLvl stays 0 so SMC_Structure guard catches it
  }

//+------------------------------------------------------------------+
//| LTF Suggestion Engine — swing-point finders on ratesLTFSuggest    |
//+------------------------------------------------------------------+
double FindSwingHighLTF(int from, int to)
  {
   int sz = ArraySize(ratesLTFSuggest);
   to = MathMin(to, sz - 2);
   for(int i = from; i <= to; i++)
      if(IsSwingH(ratesLTFSuggest, i, 2, sz))
         return ratesLTFSuggest[i].high;
   return 0;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double FindSwingLowLTF(int from, int to)
  {
   int sz = ArraySize(ratesLTFSuggest);
   to = MathMin(to, sz - 2);
   for(int i = from; i <= to; i++)
      if(IsSwingL(ratesLTFSuggest, i, 2, sz))
         return ratesLTFSuggest[i].low;
   return 0;
  }

// LTF Suggestion Engine — Step: liquidity sweep of the session's OR high/low, detected on ratesLTFSuggest
bool LTFSweep(int sess)
  {
   double atr = GetATRLTF(1);
   if(atr <= 0)
      return false;
   int sz = ArraySize(ratesLTFSuggest);
   if(sz < 6 || sess < 0 || sess >= SESS_COUNT)
      return false;
   double orH = GetSessORH(sess), orL = GetSessORL(sess);
   if(orH <= 0 || orL <= 0 || orH <= orL)
      return false;
   double buf = atr * InpSweepBuffer;
   int look = MathMin(gSweepLookback, sz - 3);
   for(int i = 1; i <= look; i++)
     {
      double hi = ratesLTFSuggest[i].high, lo = ratesLTFSuggest[i].low, cls = ratesLTFSuggest[i].close;
      double swBody = MathAbs(ratesLTFSuggest[i].close - ratesLTFSuggest[i].open);
      bool sweepBodyOK = (InpSweepBodyMin <= 0 || atr <= 0 || swBody >= atr * InpSweepBodyMin);
      // Sweep of OR high — bearish rejection
      if(hi > orH + buf && cls < orH - buf)
        {
         if(InpUseDailyBias && dailyBias == BIAS_BULLISH)
            continue;
         bool sweepDirOK = (ratesLTFSuggest[i].close <= ratesLTFSuggest[i].open);
         if(!sweepBodyOK || !sweepDirOK)
            continue;
         ltfSweepLvl[sess] = orH;
         ltfSuggBull[sess] = false;
         ltfBosLvl[sess] = FindSwingLowLTF(i + 1, i + 12);
         LogMsg(SESS_NAME[sess] + StringFormat(" [LTF-SUGGEST] SWEEP↑ @%.5f Body:%.2fATR", orH, swBody / atr));
         return true;
        }
      // Sweep of OR low — bullish rejection
      if(lo < orL - buf && cls > orL + buf)
        {
         if(InpUseDailyBias && dailyBias == BIAS_BEARISH)
            continue;
         bool sweepDirOK = (ratesLTFSuggest[i].close >= ratesLTFSuggest[i].open);
         if(!sweepBodyOK || !sweepDirOK)
            continue;
         ltfSweepLvl[sess] = orL;
         ltfSuggBull[sess] = true;
         ltfBosLvl[sess] = FindSwingHighLTF(i + 1, i + 12);
         LogMsg(SESS_NAME[sess] + StringFormat(" [LTF-SUGGEST] SWEEP↓ @%.5f Body:%.2fATR", orL, swBody / atr));
         return true;
        }
     }
   return false;
  }

// LTF Suggestion Engine — Step: BOS/CHoCH confirmation on ratesLTFSuggest
bool LTFStructure(int sess)
  {
   if(ltfBosLvl[sess] <= 0)
      return false;
   datetime sessStart = GetSessStart(sess);
   int look = MathMin(gSweepLookback, ArraySize(ratesLTFSuggest) - 2);
   for(int i = 1; i <= look; i++)
     {
      if(sessStart > 0 && ratesLTFSuggest[i].time < sessStart)
         break;
      double cls = ratesLTFSuggest[i].close;
      if(ltfSuggBull[sess] ? (cls > ltfBosLvl[sess]) : (cls < ltfBosLvl[sess]))
         return true;
     }
   return false;
  }

// LTF Suggestion Engine — Step: displacement confirmation on ratesLTFSuggest
bool LTFDisplacement(int sess)
  {
   double atr = GetATRLTF(1);
   if(atr <= 0)
      return false;
   int sz = ArraySize(ratesLTFSuggest);
   if(sz < 4 || sess < 0 || sess >= SESS_COUNT)
      return false;
   datetime sessStart = GetSessStart(sess);
   int look = MathMin(gSweepLookback, sz - 2);
   for(int i = 1; i <= look; i++)
     {
      if(sessStart > 0 && ratesLTFSuggest[i].time < sessStart)
         break;
      double cls = ratesLTFSuggest[i].close, opn = ratesLTFSuggest[i].open;
      double hi = ratesLTFSuggest[i].high, lo = ratesLTFSuggest[i].low;
      double body = MathAbs(cls - opn), range = hi - lo;
      bool bigBody = (body >= atr * InpDispATR);
      bool closedH = (range > 0) && ((cls - lo) / range > InpDispBodyMin);
      bool closedL = (range > 0) && ((hi - cls) / range > InpDispBodyMin);
      if(ltfSuggBull[sess] && cls > opn && bigBody && closedH)
        {
         ltfDispTime[sess] = ratesLTFSuggest[i].time;
         LogMsg(SESS_NAME[sess] + StringFormat(" [LTF-SUGGEST] DISPLACE↑ [Body:%.2f ATR]", body / atr));
         return true;
        }
      if(!ltfSuggBull[sess] && cls < opn && bigBody && closedL)
        {
         ltfDispTime[sess] = ratesLTFSuggest[i].time;
         LogMsg(SESS_NAME[sess] + StringFormat(" [LTF-SUGGEST] DISPLACE↓ [Body:%.2f ATR]", body / atr));
         return true;
        }
     }
   return false;
  }

// LTF Suggestion Engine — locate a ratesLTFSuggest bar index by exact/near time match
int FindBarByTimeLTF(datetime t)
  {
   int sz = ArraySize(ratesLTFSuggest);
   if(sz <= 0)
      return -1;
   for(int i = 0; i < sz; i++)
      if(ratesLTFSuggest[i].time == t)
         return i;
   int bestIdx = -1;
   long bestDiff = LONG_MAX;
   long tol = PeriodSeconds(gLTFTF);
   for(int i = 0; i < sz; i++)
     {
      long diff = MathAbs((long)(ratesLTFSuggest[i].time - t));
      if(diff < bestDiff)
        {
         bestDiff = diff;
         bestIdx = i;
        }
     }
   if(bestIdx >= 0 && bestDiff <= tol)
      return bestIdx;
   return -1;
  }

// LTF Suggestion Engine — Step: build OB/FVG zones from ltfDispTime, on ratesLTFSuggest
void LTFBuildZones(int sess)
  {
   ltfSuggOB[sess].valid = ltfSuggFVG[sess].valid = false;
   int sz = ArraySize(ratesLTFSuggest);
   if(sz < 4 || sess < 0 || sess >= SESS_COUNT)
      return;
   int d = FindBarByTimeLTF(ltfDispTime[sess]);
   if(d < 0)
      return;
   double obAtr = GetATRLTF(1);
   for(int i = d + 1; i < d + 10 && i < sz; i++)
     {
      bool bear = (ratesLTFSuggest[i].close < ratesLTFSuggest[i].open);
      bool bull = (ratesLTFSuggest[i].close > ratesLTFSuggest[i].open);
      double obBody = MathAbs(ratesLTFSuggest[i].close - ratesLTFSuggest[i].open);
      bool bodyOK = (InpOBBodyMin <= 0 || obAtr <= 0 || obBody >= obAtr * InpOBBodyMin);
      if(ltfSuggBull[sess] && bear && bodyOK)
        {
         ltfSuggOB[sess].high = ratesLTFSuggest[i].high;
         ltfSuggOB[sess].low = ratesLTFSuggest[i].low;
         ltfSuggOB[sess].time = ratesLTFSuggest[i].time;
         ltfSuggOB[sess].bullish = true;
         ltfSuggOB[sess].valid = true;
         ltfSuggOB[sess].mitigated = false;
         ltfSuggOB[sess].touchCount = 0;
         break;
        }
      if(!ltfSuggBull[sess] && bull && bodyOK)
        {
         ltfSuggOB[sess].high = ratesLTFSuggest[i].high;
         ltfSuggOB[sess].low = ratesLTFSuggest[i].low;
         ltfSuggOB[sess].time = ratesLTFSuggest[i].time;
         ltfSuggOB[sess].bullish = false;
         ltfSuggOB[sess].valid = true;
         ltfSuggOB[sess].mitigated = false;
         ltfSuggOB[sess].touchCount = 0;
         break;
        }
     }
   if(d >= 2 && d + 1 < sz)
     {
      if(ltfSuggBull[sess])
        {
         double fgLo = ratesLTFSuggest[d + 1].high;
         double fgHi = ratesLTFSuggest[d - 1].low;
         if(fgHi > fgLo)
           {
            ltfSuggFVG[sess].high = fgHi;
            ltfSuggFVG[sess].low = fgLo;
            ltfSuggFVG[sess].time = ratesLTFSuggest[d].time;
            ltfSuggFVG[sess].bullish = true;
            ltfSuggFVG[sess].valid = true;
            ltfSuggFVG[sess].mitigated = false;
            ltfSuggFVG[sess].touchCount = 0;
           }
        }
      else
        {
         double fgHi = ratesLTFSuggest[d + 1].low;
         double fgLo = ratesLTFSuggest[d - 1].high;
         if(fgHi > fgLo)
           {
            ltfSuggFVG[sess].high = fgHi;
            ltfSuggFVG[sess].low = fgLo;
            ltfSuggFVG[sess].time = ratesLTFSuggest[d].time;
            ltfSuggFVG[sess].bullish = false;
            ltfSuggFVG[sess].valid = true;
            ltfSuggFVG[sess].mitigated = false;
            ltfSuggFVG[sess].touchCount = 0;
           }
        }
     }
  }

// LTF Suggestion Engine — zone invalidation check on ratesLTFSuggest
bool LTFZoneInvalidated(int sess)
  {
   if(ArraySize(ratesLTFSuggest) < 2)
      return false;
   double cls = ratesLTFSuggest[1].close;
   if(ltfSuggOB[sess].valid)
     {
      if(ltfSuggBull[sess] && cls < ltfSuggOB[sess].low)
         ltfSuggOB[sess].valid = false;
      else
         if(!ltfSuggBull[sess] && cls > ltfSuggOB[sess].high)
            ltfSuggOB[sess].valid = false;
     }
   if(ltfSuggFVG[sess].valid)
     {
      if(ltfSuggBull[sess] && cls < ltfSuggFVG[sess].low)
         ltfSuggFVG[sess].valid = false;
      else
         if(!ltfSuggBull[sess] && cls > ltfSuggFVG[sess].high)
            ltfSuggFVG[sess].valid = false;
     }
   return (!ltfSuggOB[sess].valid && !ltfSuggFVG[sess].valid);
  }

// LTF Suggestion Engine — Step: price retraced back into the OB/FVG zone
bool LTFPriceInZone(int sess)
  {
   if(ArraySize(ratesLTFSuggest) < 2)
      return false;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = ltfSuggBull[sess] ? ask : bid;
   if(InpUseOB && ltfSuggOB[sess].valid && price >= ltfSuggOB[sess].low && price <= ltfSuggOB[sess].high)
      return true;
   if(InpUseFVG && ltfSuggFVG[sess].valid && price >= ltfSuggFVG[sess].low && price <= ltfSuggFVG[sess].high)
      return true;
   return false;
  }

//============================================================
// MODULE: LIQUIDITY LEVELS
//============================================================
void BuildLiquidityLevels()
  {
   for(int s = 0; s < SESS_COUNT; s++)
      liqCount[s] = 0;
   AddLiq(SESS_ASIA, asiaORHigh, true, "AsiaORH");
   AddLiq(SESS_ASIA, asiaORLow, false, "AsiaORL");
   if(asiaHigh > 0)
     {
      AddLiq(SESS_LONDON, asiaHigh, true, "AsiaH");
      AddLiq(SESS_LONDON, asiaLow, false, "AsiaL");
      AddLiq(SESS_NY, asiaHigh, true, "AsiaH");
      AddLiq(SESS_NY, asiaLow, false, "AsiaL");
     }
   AddLiq(SESS_LONDON, londonORHigh, true, "LdnORH");
   AddLiq(SESS_LONDON, londonORLow, false, "LdnORL");
// London OR added to NY: AMD pattern where NY sweeps London range before its real move
   AddLiq(SESS_NY, londonORHigh, true, "LdnORH");
   AddLiq(SESS_NY, londonORLow, false, "LdnORL");
   AddLiq(SESS_NY, nyORHigh, true, "NYORH");
   AddLiq(SESS_NY, nyORLow, false, "NYORL");
   FindEQHL();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void AddLiq(int sess, double price, bool isHigh, string lbl)
  {
   if(price <= 0 || price >= DBL_MAX / 2)
      return;
   if(liqCount[sess] >= MAX_LIQ)
      return;
// FIX: deduplication check
   double tol = GetATR(1) * 0.05;
   for(int k = 0; k < liqCount[sess]; k++)
      if(MathAbs(liqLevels[sess][k].price - price) < tol)
         return;
   liqLevels[sess][liqCount[sess]].price = price;
   liqLevels[sess][liqCount[sess]].isHigh = isHigh;
   liqLevels[sess][liqCount[sess]].swept = false;
   liqLevels[sess][liqCount[sess]].label = lbl;
   liqCount[sess]++;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void FindEQHL()
  {
   eqCount = 0;
   int sz = ArraySize(ratesORB);
   double tol = GetATR(1) * InpEQTolerance;
   if(tol <= 0 || sz < 10)
      return;
   int str = MathMax(1, InpEQSwingStrength);
   int look = MathMin(InpEQLookback, sz - str - 2);
   int maxL = MathMin(InpEQMaxLevels, MAX_EQ / 2); // cap per direction at half of MAX_EQ
   int eqhN = 0, eqlN = 0;
// ratesORB is ArraySetAsSeries=true: index 0=current bar, 1=most-recent-closed, higher=older.
// Swing high at index i: high[i] > high[i-k] (more recent) AND high[i] > high[i+k] (older) for k=1..str.
// We iterate i from (str+1) to (look-str) so there are str bars available on both sides.
   for(int i = str + 1; i <= look - str && (eqhN < maxL || eqlN < maxL); i++)
     {
      // ── SWING HIGH CHECK ──
      if(eqhN < maxL)
        {
         bool swH = true;
         for(int k = 1; k <= str; k++)
           {
            if(ratesORB[i - k].high >= ratesORB[i].high ||
               ratesORB[i + k].high >= ratesORB[i].high)
              {
               swH = false;
               break;
              }
           }
         if(swH)
           {
            // Search for an older swing high at the same level (j > i, meaning older bar)
            int jLook = MathMin(look, sz - str - 2);
            for(int j = i + str + 1; j <= jLook; j++)
              {
               if(MathAbs(ratesORB[j].high - ratesORB[i].high) >= tol)
                  continue;
               // Verify j is also a swing high
               bool jSwH = true;
               for(int k = 1; k <= str; k++)
                 {
                  if(j - k < 0 || j + k >= sz)
                    {
                     jSwH = false;
                     break;
                    }
                  if(ratesORB[j - k].high >= ratesORB[j].high ||
                     ratesORB[j + k].high >= ratesORB[j].high)
                    {
                     jSwH = false;
                     break;
                    }
                 }
               if(!jSwH)
                  continue;
               if(eqCount < MAX_EQ)
                 {
                  eqLevels[eqCount].price = ratesORB[i].high;
                  eqLevels[eqCount].t1 = ratesORB[j].time; // older swing (line left anchor)
                  eqLevels[eqCount].t2 = ratesORB[i].time; // more recent swing
                  eqLevels[eqCount].isHigh = true;
                  eqCount++;
                 }
               if(InpEnableAsia)
                  AddLiq(SESS_ASIA, ratesORB[i].high, true, "EQH");
               AddLiq(SESS_LONDON, ratesORB[i].high, true, "EQH");
               AddLiq(SESS_NY, ratesORB[i].high, true, "EQH");
               eqhN++;
               break;
              }
           }
        }
      // ── SWING LOW CHECK ──
      if(eqlN < maxL)
        {
         bool swL = true;
         for(int k = 1; k <= str; k++)
           {
            if(ratesORB[i - k].low <= ratesORB[i].low ||
               ratesORB[i + k].low <= ratesORB[i].low)
              {
               swL = false;
               break;
              }
           }
         if(swL)
           {
            int jLook = MathMin(look, sz - str - 2);
            for(int j = i + str + 1; j <= jLook; j++)
              {
               if(MathAbs(ratesORB[j].low - ratesORB[i].low) >= tol)
                  continue;
               bool jSwL = true;
               for(int k = 1; k <= str; k++)
                 {
                  if(j - k < 0 || j + k >= sz)
                    {
                     jSwL = false;
                     break;
                    }
                  if(ratesORB[j - k].low <= ratesORB[j].low ||
                     ratesORB[j + k].low <= ratesORB[j].low)
                    {
                     jSwL = false;
                     break;
                    }
                 }
               if(!jSwL)
                  continue;
               if(eqCount < MAX_EQ)
                 {
                  eqLevels[eqCount].price = ratesORB[i].low;
                  eqLevels[eqCount].t1 = ratesORB[j].time;
                  eqLevels[eqCount].t2 = ratesORB[i].time;
                  eqLevels[eqCount].isHigh = false;
                  eqCount++;
                 }
               if(InpEnableAsia)
                  AddLiq(SESS_ASIA, ratesORB[i].low, false, "EQL");
               AddLiq(SESS_LONDON, ratesORB[i].low, false, "EQL");
               AddLiq(SESS_NY, ratesORB[i].low, false, "EQL");
               eqlN++;
               break;
              }
           }
        }
     }
  }

//============================================================
// MODULE: BASIC ORB SIGNALS (bar-close confirmed, shift=1)
//============================================================
void DetectBasicSignals()
  {
   asiaBreakoutUp = asiaBreakoutDown = londonBreakoutUp = londonBreakoutDown = false;
   nyBreakoutUp = nyBreakoutDown = false;
   asiaRejectHigh = asiaRejectLow = londonRejectHigh = londonRejectLow = false;
   nyRejectHigh = nyRejectLow = false;
   asiaFBH = asiaFBL = londonFBH = londonFBL = nyFBH = nyFBL = false;
   if(ArraySize(ratesORB) < 3)
      return;
   double atr = GetATR(1);
   if(atr <= 0)
      return;
   double cls = ratesORB[1].close, opn = ratesORB[1].open;
   double hi = ratesORB[1].high, lo = ratesORB[1].low, pcls = ratesORB[2].close;
   double body = MathAbs(cls - opn), range = hi - lo;
// FIX 5: impulsive is now optional (gRequireImpulse), buffer configurable (InpBrkBuffer)
   bool imp = (gRequireImpulse)
              ? (body > atr * 0.15 && (range > 0 ? body / range > 0.35 : false))
              : (body > 0); // when not required, any candle with a body qualifies
// BUG2 FIX: when body=0 (doji) the wick condition was always true; require body>0
   double atrMin = atr * 0.01;  // minimum body threshold (1% ATR)
   bool suR = (body > atrMin) && (hi - MathMax(opn, cls)) > body * 1.1;
   bool slR = (body > atrMin) && (MathMin(opn, cls) - lo) > body * 1.1;
   double buf = atr * InpBrkBuffer; // FIX 5: was hardcoded 0.03, now configurable (default 0.10)
   double brH = (InpBreakMode == BREAK_CLOSE) ? cls : hi;
   double brL = (InpBreakMode == BREAK_CLOSE) ? cls : lo;
// Volume surge filter: breakout bar volume must be >= gBrkVolMin × MA
// Uses a 20-bar lookback (independent of InpDynTP_VMA — that parameter controls dynamic
// TP exhaustion logic and has nothing to do with breakout volume qualification).
   bool volOK = true;
   if(gBrkVolMin > 0.0)
     {
      const int BRK_VOL_MA = 20;
      int sz = ArraySize(ratesORB);
      if(sz >= BRK_VOL_MA + 2)
        {
         double volSum = 0;
         for(int i = 2; i <= BRK_VOL_MA + 1; i++)
            volSum += (double)ratesORB[i].tick_volume;
         double volMA = volSum / BRK_VOL_MA;
         if(volMA > 0)
            volOK = ((double)ratesORB[1].tick_volume / volMA >= gBrkVolMin);
        }
     }
// Close quality filter: close must be in top/bottom gBrkCloseQuality of bar range
// Bull: (close-low)/(high-low) >= threshold  Bear: (high-close)/(high-low) >= threshold
   bool cqBull = true, cqBear = true;
   if(gBrkCloseQuality > 0.0 && range > 0)
     {
      cqBull = ((cls - lo) / range >= gBrkCloseQuality);
      cqBear = ((hi - cls) / range >= gBrkCloseQuality);
     }
// F1: Per-session signal-bar volume filter
// Signal bars with tick volume >= session avg have 0% WR on both EURUSD and XAUUSD.
// Below-avg volume (quiet signal bar) = 15-27% WR. Compute session avg from ratesORB history.
   bool asiaVolLow = true, londonVolLow = true, nyVolLow = true;
   if(InpVolSignalFilter)
     {
      double sigVol = (double)ratesORB[1].tick_volume;
      int vSz = ArraySize(ratesORB);
      double asiaSum = 0, asiaCount = 0;
      double lonSum = 0, lonCount = 0;
      double nySum = 0, nyCount = 0;
      for(int vi = 2; vi < vSz; vi++)  // skip vi=0 (forming bar), vi=1 (signal bar itself)
        {
         datetime bt = ratesORB[vi].time;
         if(bt >= asiaStart && bt < asiaEnd)
           {
            asiaSum += (double)ratesORB[vi].tick_volume;
            asiaCount++;
           }
         if(bt >= londonStart && bt < londonEnd)
           {
            lonSum += (double)ratesORB[vi].tick_volume;
            lonCount++;
           }
         if(bt >= nyStart && bt < nyEnd)
           {
            nySum += (double)ratesORB[vi].tick_volume;
            nyCount++;
           }
        }
      // Use <= so that bars with exactly session-average volume pass.
      // In strategy tester modes (open-prices-only, 1-min OHLC), all bars have identical
      // tick_volume (artifact), making sigVol == sessAvg always → strict < blocks everything.
      if(asiaCount >= 3)
         asiaVolLow = (sigVol <= (asiaSum / asiaCount));
      if(lonCount >= 3)
         londonVolLow = (sigVol <= (lonSum / lonCount));
      if(nyCount >= 3)
         nyVolLow = (sigVol <= (nySum / nyCount));
     }
   DetectORSignals(asiaORHigh, asiaORLow, brH, brL, cls, opn, hi, lo, pcls, buf, imp, suR, slR,
                   volOK, cqBull, cqBear, asiaVolLow,
                   asiaBreakoutUp, asiaBreakoutDown, asiaRejectHigh, asiaRejectLow, asiaFBH, asiaFBL);
   DetectORSignals(londonORHigh, londonORLow, brH, brL, cls, opn, hi, lo, pcls, buf, imp, suR, slR,
                   volOK, cqBull, cqBear, londonVolLow,
                   londonBreakoutUp, londonBreakoutDown, londonRejectHigh, londonRejectLow, londonFBH, londonFBL);
   DetectORSignals(nyORHigh, nyORLow, brH, brL, cls, opn, hi, lo, pcls, buf, imp, suR, slR,
                   volOK, cqBull, cqBear, nyVolLow,
                   nyBreakoutUp, nyBreakoutDown, nyRejectHigh, nyRejectLow, nyFBH, nyFBL);
  }

//+------------------------------------------------------------------+
//| Helper: require a clear momentum continuation after the ORB break |
//| to avoid reacting to wick-only spikes and fake breakouts.        |
//+------------------------------------------------------------------+
bool IsORBTrendConfirmation(double close, double prevClose, double open, double orLevel, double buf, bool bullish)
  {
   if(bullish)
      return (close > prevClose) && (close > open) && (close > orLevel + buf);
   return (close < prevClose) && (close < open) && (close < orLevel - buf);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DetectORSignals(double orH, double orL, double brH, double brL,
                     double cls, double opn, double hi, double lo, double pcls,
                     double buf, bool imp, bool suR, bool slR,
                     bool volOK, bool cqBull, bool cqBear, bool volLow,
                     bool &bkU, bool &bkD, bool &rjH, bool &rjL, bool &fbH, bool &fbL)
  {
   if(orH <= 0 || orL <= 0 || orH <= orL)
      return;
// F1: volLow — signal bar tick volume < session avg. High-vol signal bars = institutional trap (0% WR in backtest)
// AUDIT FIX: with InpBreakMode=BREAK_CANDLE (the default), brH/brL are the bar's wick
// (hi/lo), not its close — so a bar that pokes above orH+buf but then closes back below
// orH (a textbook rejection candle) previously satisfied bkU with no close-side check at
// all (cqBull is bypassed entirely in the default INTRADAY preset, InpIntra_BrkCloseQuality=0).
// That let the exact same candle simultaneously qualify as bkU (breakout) AND rjH/fbH
// (rejection / false break) below — the chart would show a green BUY breakout arrow and a
// yellow REJECT arrow on the same bar, and TradeEngine would fire a real BUY on what price
// action actually rejected. Requiring cls > orH (resp. cls < orL) keeps BREAK_CANDLE's
// faster wick-trigger for BREAK_CLOSE mode is a no-op change (brH already equals cls there)
// but makes bkU/bkD mutually exclusive with rjH/rjL/fbH/fbL by construction.
   bool trendUpConfirm = IsORBTrendConfirmation(cls, pcls, opn, orH, buf, true);
   bool trendDownConfirm = IsORBTrendConfirmation(cls, pcls, opn, orL, buf, false);
   if(brH > orH + buf && trendUpConfirm && imp && volOK && cqBull && volLow)
      bkU = true;
   if(brL < orL - buf && trendDownConfirm && imp && volOK && cqBear && volLow)
      bkD = true;
   if(hi > orH && cls < orH && suR && volLow)
      rjH = true;
   if(lo < orL && cls > orL && slR && volLow)
      rjL = true;
   if(pcls > orH && cls < orH && cls < opn && imp && volLow)
      fbH = true;
   if(pcls < orL && cls > orL && cls > opn && imp && volLow)
      fbL = true;
  }

// Order-flow style ORB gate: require a genuine breakout, a pullback/retest into the
// breakout zone, and then continuation momentum before allowing entries. A simple sweep/
// rejection check is added to filter fake breakouts.
bool IsORBEntryQualified(int sess, bool isBuy)
  {
   if(ArraySize(ratesORB) < 4)
      return false;
   double orH = GetSessORH(sess), orL = GetSessORL(sess);
   if(orH <= 0 || orL <= 0 || orH <= orL)
      return false;
   double atr = GetATR(1);
   double buf = (atr > 0) ? atr * InpBrkBuffer : _Point * 10;
   double retestBuf = (atr > 0) ? atr * InpORBRetestBuffer : _Point * 10;
   MqlRates r1 = ratesORB[1]; // latest closed bar
   MqlRates r2 = ratesORB[2]; // previous bar
   if(InpORBEntryMode == ORB_AGGRESSIVE)
     {
      if(isBuy)
         return (r2.close > orH + buf) && (r2.close > r2.open);
      return (r2.close < orL - buf) && (r2.close < r2.open);
     }
   if(isBuy)
     {
      bool breakoutBar = (r2.close > orH + buf) && (r2.close > r2.open);
      bool pullbackRetest = (r1.low <= orH + retestBuf) && (r1.close >= orH - retestBuf) && (r1.close > r1.open);
      bool continuation = (r1.close > r2.close) && (r1.close > r2.open) && (r1.close > orH + retestBuf);
      bool sweepReject = (r1.high > orH + retestBuf) && (r1.close <= orH + retestBuf);
      if(InpORBEntryMode == ORB_CONSERVATIVE)
         return breakoutBar && pullbackRetest && continuation && (sweepReject || (r1.close > r2.close));
      return breakoutBar && (pullbackRetest || continuation) && (sweepReject || continuation);
     }
   bool breakoutBar = (r2.close < orL - buf) && (r2.close < r2.open);
   bool pullbackRetest = (r1.high >= orL - retestBuf) && (r1.close <= orL + retestBuf) && (r1.close < r1.open);
   bool continuation = (r1.close < r2.close) && (r1.close < r2.open) && (r1.close < orL - retestBuf);
   bool sweepReject = (r1.low < orL - retestBuf) && (r1.close >= orL - retestBuf);
   if(InpORBEntryMode == ORB_CONSERVATIVE)
      return breakoutBar && pullbackRetest && continuation && (sweepReject || (r1.close < r2.close));
   return breakoutBar && (pullbackRetest || continuation) && (sweepReject || continuation);
  }

// Tracks the breakout-leg swing (OR level -> post-breakout extreme) per session, purely so
// DrawFiboZone() has something to plot. Visual-only: does not feed into CanEnter/TradeEngine.
// Origin (fiboA) is fixed at the moment the leg starts; the extreme (fiboB) ratchets further
// out while the same-direction breakout keeps re-confirming on new bars.
void UpdateFiboLegs()
  {
   for(int s = 0; s < SESS_COUNT; s++)
     {
      double orH = GetSessORH(s), orL = GetSessORL(s);
      if(orH <= 0 || orL <= 0 || ArraySize(ratesORB) < 2)
         continue;
      bool bU = GetBkUp(s), bD = GetBkDn(s);
      if(bU)
        {
         if(fiboDir[s] != 1)
           {
            fiboDir[s] = 1;
            fiboA[s] = orL;
            fiboB[s] = ratesORB[1].high;
            fiboAnchorT[s] = ratesORB[1].time;
           }
         else
            fiboB[s] = MathMax(fiboB[s], ratesORB[1].high);
        }
      else
         if(bD)
           {
            if(fiboDir[s] != -1)
              {
               fiboDir[s] = -1;
               fiboA[s] = orH;
               fiboB[s] = ratesORB[1].low;
               fiboAnchorT[s] = ratesORB[1].time;
              }
            else
               fiboB[s] = MathMin(fiboB[s], ratesORB[1].low);
           }
      // Once a trade fires in that direction the leg has served its purpose as a "should we
      // have waited for the golden zone" reference — clear it so it doesn't linger forever.
      if(fiboDir[s] == 1 && tradeBuyDone[s])
         fiboDir[s] = 0;
      if(fiboDir[s] == -1 && tradeSellDone[s])
         fiboDir[s] = 0;
     }
  }

//============================================================
// MODULE: SMC STATE MACHINE  (Fixed)
//============================================================
void UpdateSMCSession(int sess)
  {
   if(!IsSessEnabled(sess))
      return;
   datetime sessOpen = GetSessStart(sess);
   bool timeLimitReached = (sessOpen > 0 && TimeCurrent() - sessOpen > (datetime)(gTimeFilter * 60));
   if(timeLimitReached && !gReconstructing)
     {
      if(smcState[sess] >= SMC_SWEPT)
         return; // Sweep already confirmed — let setup complete naturally (zone invalidation handles cleanup)
      // No sweep found within time limit — arm ORB fallback once (if enabled and no trade yet).
      // Arm fallback if at least one direction is still available (OR, not AND).
      if(InpSMCFallback && (!tradeBuyDone[sess] || !tradeSellDone[sess]) && !orbFallbackActive[sess])
        {
         orbFallbackActive[sess] = true;
         LogMsg(SESS_NAME[sess] + " SMC timeout — ORB fallback armed");
        }
      return;
     }
   switch(smcState[sess])
     {
      case SMC_IDLE:
         if(IsORBLocked(sess))
            smcState[sess] = SMC_LOCKED;
         break;
      case SMC_LOCKED:
         if(SMC_Sweep(sess))
           {
            smcState[sess] = SMC_SWEPT;
            sweepTime[sess] = ratesORB[1].time;
            smcLockedTime[sess] = ratesORB[1].time; // record when sweep confirmed
           }
         break;
      case SMC_SWEPT:
         if(SMC_Structure(sess))
            smcState[sess] = SMC_STRUCTURE;
         break;
      case SMC_STRUCTURE:
         if(SMC_Displacement(sess))
            smcState[sess] = SMC_DISPLACED; // FIX: use DISPLACED state
         break;
      case SMC_DISPLACED: // FIX: was never entered before
         SMC_BuildZones(sess);
         if(ob[sess].valid || fvg[sess].valid)
            smcState[sess] = SMC_ZONE;
         else
           {
            LogMsg(SESS_NAME[sess] + " ZONE BUILD FAILED — no OB/FVG qualified, resetting");
            ResetSMCState(sess);
           }
         break;
      case SMC_ZONE:
         if(SMC_ZoneInvalidated(sess))
           {
            ResetSMCState(sess);
            break;
           }
         if(SMC_PriceInZone(sess))
           {
            // Phase 13: count touch only for the zone actually entered
            // SMC_PriceInZone prioritizes OB over FVG — mirror that priority here
            double zonePrice = setupBull[sess] ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                               : SymbolInfoDouble(_Symbol, SYMBOL_BID);
            if(InpUseOB && ob[sess].valid && zonePrice >= ob[sess].low && zonePrice <= ob[sess].high)
              {
               if(ob[sess].touchCount < 3)
                  ob[sess].touchCount++;
               ob[sess].mitigated = true; // price has entered this zone — mark as mitigated
              }
            else
               if(InpUseFVG && fvg[sess].valid)
                 {
                  if(fvg[sess].touchCount < 3)
                     fvg[sess].touchCount++;
                  fvg[sess].mitigated = true;
                 }
            smcState[sess] = SMC_RETRACE;
           }
         break;
      case SMC_RETRACE:
         if(SMC_ZoneInvalidated(sess))
           {
            ResetSMCState(sess);
            break;
           }
         if(!SMC_PriceInZone(sess))
           {
            // BUG4 FIX: reset LTF confirmation when price leaves zone
            ltfConfirmed[sess] = false;
            // touchCount is NOT decremented here — it must accumulate across all zone entries
            // so the freshness filter (touchCount > 1 in CanEnter) can detect second touches.
            // Decrementing would reset touchCount to 0 on every exit, making freshness never fire.
            smcState[sess] = SMC_ZONE;
            break;
           }
         if(!InpLTFConfirm)
           {
            smcState[sess] = SMC_CONFIRMED;
            break;
           }
         // Fast-confirm using HTF bias alignment: if HTF bias strongly aligns with setup,
         // accept a quick confirmation to speed up LTF confirmation when HTF and setup agree.
         if(htfBias != BIAS_NEUTRAL && ((setupBull[sess] && htfBias == BIAS_BULLISH) || (!setupBull[sess] && htfBias == BIAS_BEARISH)))
           {
            ltfConfirmed[sess] = true;
            LogMsg(SESS_NAME[sess] + " FAST HTF-LTF CONFIRM (HTF bias alignment)");
            smcState[sess] = SMC_CONFIRMED;
            break;
           }
         if(SMC_LTFConfirm(sess))
            smcState[sess] = SMC_CONFIRMED;
         break;
      case SMC_CONFIRMED:
         if(SMC_ZoneInvalidated(sess))
           {
            ResetSMCState(sess);
            break;
           }
         if(!SMC_PriceInZone(sess))
           {
            ltfConfirmed[sess] = false; // symmetric with RETRACE→ZONE path (line 1592)
            smcState[sess] = SMC_ZONE;
           }
         break;
      case SMC_TRADED:
         break;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| LTF Suggestion Engine — independent state machine driver.        |
//| Never reads/writes smcState[]/ob[]/fvg[]/setupBull[] (the main    |
//| engine's state) — see Global Constraints in the implementation   |
//| plan for why these two engines must stay fully separate.         |
//+------------------------------------------------------------------+
void UpdateLTFSuggestSession(int sess)
  {
   if(!InpEnableLTFSuggestEngine || !IsSessEnabled(sess))
      return;
   if(CopyRates(_Symbol, gLTFTF, 0, 300, ratesLTFSuggest) < 6)
      return;
   switch(ltfSuggState[sess])
     {
      case SMC_IDLE:
         if(IsORBLocked(sess))
            ltfSuggState[sess] = SMC_LOCKED;
         break;
      case SMC_LOCKED:
         if(LTFSweep(sess))
           {
            ltfSuggState[sess] = SMC_SWEPT;
            ltfSweepTime[sess] = ratesLTFSuggest[1].time;
           }
         break;
      case SMC_SWEPT:
         if(LTFStructure(sess))
            ltfSuggState[sess] = SMC_STRUCTURE;
         break;
      case SMC_STRUCTURE:
         if(LTFDisplacement(sess))
            ltfSuggState[sess] = SMC_DISPLACED;
         break;
      case SMC_DISPLACED:
         LTFBuildZones(sess);
         if(ltfSuggOB[sess].valid || ltfSuggFVG[sess].valid)
            ltfSuggState[sess] = SMC_ZONE;
         else
           {
            LogMsg(SESS_NAME[sess] + " [LTF-SUGGEST] ZONE BUILD FAILED — resetting");
            ResetLTFSuggestState(sess);
           }
         break;
      case SMC_ZONE:
         if(LTFZoneInvalidated(sess))
           {
            ResetLTFSuggestState(sess);
            break;
           }
         if(LTFPriceInZone(sess))
            ltfSuggState[sess] = SMC_RETRACE;
         break;
      case SMC_RETRACE:
         if(LTFZoneInvalidated(sess))
           {
            ResetLTFSuggestState(sess);
            break;
           }
         if(!LTFPriceInZone(sess))
           {
            ltfSuggState[sess] = SMC_ZONE;
            break;
           }
         ltfSuggState[sess] = SMC_CONFIRMED;
         break;
      case SMC_CONFIRMED:
         if(ltfSuggActed[sess])
           {
            ltfSuggState[sess] = SMC_TRADED;
            break;
           }
         ltfSuggScore[sess] = CalcLTFSuggestScore(sess);
         LogMsg(SESS_NAME[sess] + StringFormat(" [LTF-SUGGEST] CONFIRMED %s Score:%.0f",
                                               ltfSuggBull[sess] ? "BUY" : "SELL", ltfSuggScore[sess]));
         ExecuteLTFSuggestion(sess);
         ltfSuggActed[sess] = true;
         ltfSuggState[sess] = SMC_TRADED;
         break;
      case SMC_TRADED:
         break;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsORBLocked(int sess)
  {
   double orH = GetSessORH(sess), orL = GetSessORL(sess);
   if(orH <= 0 || orL <= 0 || orH <= orL)
      return false;
// BUG6 FIX: dual check — points (for relative scale) AND ATR fraction (universal)
   double rng = orH - orL;
   if(gMinORBRange > 0 && rng / _Point < gMinORBRange)
      return false;
   double atr = GetATR(1);
   if(atr > 0 && rng < atr * 0.20)
      return false; // range must be ≥20% of ATR (all-pairs universal)
   return (TimeCurrent() >= GetSessOREnd(sess));
  }

// Step 5: Liquidity Sweep
bool SMC_Sweep(int sess)
  {
   double atr = GetATR(1);
   if(atr <= 0)
      return false;
   int sz = ArraySize(ratesORB);
// Require a minimum amount of history to evaluate sweeps and at least one liquidity level
   if(sz < 6 || sess < 0 || sess >= SESS_COUNT)
      return false;
   if(liqCount[sess] <= 0)
      return false;
   double buf = atr * InpSweepBuffer; // sweep buffer (separate from breakout buffer)
   int look = MathMin(gSweepLookback, sz - 3);
   for(int i = 1; i <= look; i++)
     {
      double hi = ratesORB[i].high, lo = ratesORB[i].low, cls = ratesORB[i].close;
      double swBody = MathAbs(ratesORB[i].close - ratesORB[i].open);
      for(int k = 0; k < liqCount[sess]; k++)
        {
         double lv = liqLevels[sess][k].price;
         if(lv <= 0)
            continue;
         if(liqLevels[sess][k].isHigh && hi > lv + buf && cls < lv - buf)
           {
            // Daily Bias gate: skip bearish sweep when daily bias is bullish
            if(InpUseDailyBias && dailyBias == BIAS_BULLISH)
               continue;
            // STRATEGY: sweep quality — candle must close back below level AND show
            //           a minimum rejection body. Weak-body sweeps (doji spikes) filter out.
            bool sweepBodyOK = (InpSweepBodyMin <= 0 || atr <= 0 || swBody >= atr * InpSweepBodyMin);
            // For a high-sweep (bearish rejection): candle body should be bearish
            bool sweepDirOK = (ratesORB[i].close <= ratesORB[i].open); // bearish close
            if(!sweepBodyOK || !sweepDirOK)
               continue;
            sweepLvl[sess] = lv;
            setupBull[sess] = false;
            bosLvl[sess] = FindSwingLow(i + 1, i + 12);
            liqLevels[sess][k].swept = true;
            LogMsg(SESS_NAME[sess] + StringFormat(" SWEEP↑ @%.5f Body:%.2fATR", lv, swBody / atr));
            return true;
           }
         if(!liqLevels[sess][k].isHigh && lo < lv - buf && cls > lv + buf)
           {
            // Daily Bias gate: skip bullish sweep when daily bias is bearish
            if(InpUseDailyBias && dailyBias == BIAS_BEARISH)
               continue;
            bool sweepBodyOK = (InpSweepBodyMin <= 0 || atr <= 0 || swBody >= atr * InpSweepBodyMin);
            // For a low-sweep (bullish rejection): candle body should be bullish
            bool sweepDirOK = (ratesORB[i].close >= ratesORB[i].open); // bullish close
            if(!sweepBodyOK || !sweepDirOK)
               continue;
            sweepLvl[sess] = lv;
            setupBull[sess] = true;
            bosLvl[sess] = FindSwingHigh(i + 1, i + 12);
            liqLevels[sess][k].swept = true;
            LogMsg(SESS_NAME[sess] + StringFormat(" SWEEP↓ @%.5f Body:%.2fATR", lv, swBody / atr));
            return true;
           }
        }
     }
   return false;
  }

// Step 6: CHoCH / BOS
// Scans back gSweepLookback bars so historical BOS is found during startup reconstruction.
bool SMC_Structure(int sess)
  {
   if(bosLvl[sess] <= 0)
      return false;
   datetime sessStart = GetSessStart(sess);
   int look = MathMin(gSweepLookback, ArraySize(ratesORB) - 2);
   for(int i = 1; i <= look; i++)
     {
      if(sessStart > 0 && ratesORB[i].time < sessStart)
         break;
      double cls = ratesORB[i].close;
      if(setupBull[sess] ? (cls > bosLvl[sess]) : (cls < bosLvl[sess]))
         return true;
     }
   return false;
  }

// Step 7: Displacement
// Scans back gSweepLookback bars so historical displacement is found during startup reconstruction.
bool SMC_Displacement(int sess)
  {
   double atr = GetATR(1);
   if(atr <= 0)
      return false;
   int sz = ArraySize(ratesORB);
// Need some history to detect displacement
   if(sz < 4 || sess < 0 || sess >= SESS_COUNT)
      return false;
// If there are no liquidity levels for this session, displacement is unlikely to be meaningful
   if(liqCount[sess] <= 0)
      return false;
   datetime sessStart = GetSessStart(sess);
   int look = MathMin(gSweepLookback, sz - 2);
   for(int i = 1; i <= look; i++)
     {
      if(sessStart > 0 && ratesORB[i].time < sessStart)
         break;
      double cls = ratesORB[i].close, opn = ratesORB[i].open;
      double hi = ratesORB[i].high, lo = ratesORB[i].low;
      double body = MathAbs(cls - opn), range = hi - lo;
      bool bigBody = (body >= atr * InpDispATR);
      double closeWeightThreshold = InpDispBodyMin;
      bool closedH = (range > 0) && ((cls - lo) / range > closeWeightThreshold);
      bool closedL = (range > 0) && ((hi - cls) / range > closeWeightThreshold);
      if(setupBull[sess] && cls > opn && bigBody && closedH)
        {
         dispTime[sess] = ratesORB[i].time;
         LogMsg(SESS_NAME[sess] + StringFormat(" DISPLACE↑ [Body:%.2f ATR Range:%.1f%%]", body / atr, (cls - lo) / range * 100));
         return true;
        }
      if(!setupBull[sess] && cls < opn && bigBody && closedL)
        {
         dispTime[sess] = ratesORB[i].time;
         LogMsg(SESS_NAME[sess] + StringFormat(" DISPLACE↓ [Body:%.2f ATR Range:%.1f%%]", body / atr, (hi - cls) / range * 100));
         return true;
        }
     }
   return false;
  }

// Standalone OB/FVG scanner — populates ob[sess]/fvg[sess] for VISUAL display
// independent of the full 7-step SMC pipeline. Only fills what is missing;
// does not overwrite zones already set by SMC_BuildZones.
void ScanOBFVGSession(int sess)
  {
   bool needOB = InpDrawOB && InpUseOB && !ob[sess].valid;
   bool needFVG = InpDrawFVG && InpUseFVG && !fvg[sess].valid;
   if(!needOB && !needFVG)
      return;
   int sz = ArraySize(ratesORB);
   if(sz < 6)
      return;
   double atr = GetATR(1);
   if(atr <= 0)
      return;
// Threshold: 70% of displacement ATR multiplier so more moves qualify
   double dispThresh = atr * InpDispATR * 0.70;
   datetime sessStart = GetSessStart(sess); // only scan bars within current session
   for(int d = 1; d < MathMin(sz - 3, 60); d++)
     {
      if(sessStart > 0 && ratesORB[d].time < sessStart)
         break;
      double body = MathAbs(ratesORB[d].close - ratesORB[d].open);
      if(body < dispThresh)
         continue;
      bool dispUp = (ratesORB[d].close > ratesORB[d].open);
      // When SMC pipeline has already established direction via sweep, only accept
      // displacements that match setupBull to prevent wrong-polarity zone population.
      if(smcState[sess] >= SMC_SWEPT && dispUp != setupBull[sess])
         continue;
      // OB: last opposite candle before this displacement
      if(needOB)
        {
         for(int i = d + 1; i < d + 10 && i < sz; i++)
           {
            double bodyI = MathAbs(ratesORB[i].close - ratesORB[i].open);
            if(InpOBBodyMin > 0 && atr > 0 && bodyI < atr * InpOBBodyMin)
               continue;
            bool isBear = (ratesORB[i].close < ratesORB[i].open);
            bool isBull = (ratesORB[i].close > ratesORB[i].open);
            if((dispUp && isBear) || (!dispUp && isBull))
              {
               ob[sess].high = ratesORB[i].high;
               ob[sess].low = ratesORB[i].low;
               ob[sess].time = ratesORB[i].time;
               // Use setupBull when direction is known; fall back to dispUp for visual-only scan
               ob[sess].bullish = (smcState[sess] >= SMC_SWEPT) ? setupBull[sess] : dispUp;
               ob[sess].valid = true;
               ob[sess].mitigated = false;
               ob[sess].touchCount = 0;
               needOB = false;
               break;
              }
           }
        }
      // FVG: 3-candle gap — only when C candle (d-1) is a completed bar (d>=2)
      if(needFVG && d >= 2 && d + 1 < sz)
        {
         double fgLo, fgHi;
         if(dispUp)
           {
            fgLo = ratesORB[d + 1].high;
            fgHi = ratesORB[d - 1].low;
           }
         else
           {
            fgHi = ratesORB[d + 1].low;
            fgLo = ratesORB[d - 1].high;
           }
         if(fgHi > fgLo)
           {
            fvg[sess].high = fgHi;
            fvg[sess].low = fgLo;
            fvg[sess].time = ratesORB[d].time;
            fvg[sess].bullish = dispUp;
            fvg[sess].valid = true;
            fvg[sess].mitigated = false;
            fvg[sess].touchCount = 0;
            needFVG = false;
           }
        }
      if(!needOB && !needFVG)
         break;
     }
  }

// Step 8: Build OB + FVG using stored dispTime (FIX: no index-shift bug)
void SMC_BuildZones(int sess)
  {
   ob[sess].valid = fvg[sess].valid = false;
// Guards: require history and liquidity context
   int sz = ArraySize(ratesORB);
   if(sz < 4 || sess < 0 || sess >= SESS_COUNT)
      return;
   if(liqCount[sess] <= 0)
      return;
   int d = FindBarByTime(dispTime[sess]);
   if(d < 0)
      return;
// Order Block: last opposite candle before displacement with minimum body quality
   double obAtr = GetATR(1);
   for(int i = d + 1; i < d + 10 && i < sz; i++)
     {
      bool bear = (ratesORB[i].close < ratesORB[i].open);
      bool bull = (ratesORB[i].close > ratesORB[i].open);
      // STRATEGY: OB quality filter — candle must have minimum body size to be a valid OB.
      //           Tiny-body doji/spinning-top candles produce unreliable OB zones.
      double obBody = MathAbs(ratesORB[i].close - ratesORB[i].open);
      bool bodyOK = (InpOBBodyMin <= 0 || obAtr <= 0 || obBody >= obAtr * InpOBBodyMin);
      if(setupBull[sess] && bear && bodyOK)
        {
         ob[sess].high = ratesORB[i].high;
         ob[sess].low = ratesORB[i].low;
         ob[sess].time = ratesORB[i].time;
         ob[sess].bullish = true;
         ob[sess].valid = true;
         ob[sess].mitigated = false;
         ob[sess].touchCount = 0;
         break;
        }
      if(!setupBull[sess] && bull && bodyOK)
        {
         ob[sess].high = ratesORB[i].high;
         ob[sess].low = ratesORB[i].low;
         ob[sess].time = ratesORB[i].time;
         ob[sess].bullish = false;
         ob[sess].valid = true;
         ob[sess].mitigated = false;
         ob[sess].touchCount = 0;
         break;
        }
     }
// FVG: 3-candle gap — C candle (d-1) must be a completed bar (d>=2 ensures d-1>=1)
// A=ratesORB[d+1], B=ratesORB[d], C=ratesORB[d-1]
   if(d == 1)
      LogMsg(SESS_NAME[sess] + " FVG skipped: displacement at d=1 (C-candle not yet complete)");
   if(d >= 2 && d + 1 < sz)
     {
      if(setupBull[sess])
        {
         double fgLo = ratesORB[d + 1].high;
         double fgHi = ratesORB[d - 1].low; // d-1 is completed (d>=2 so d-1>=1)
         if(fgHi > fgLo)
           {
            fvg[sess].high = fgHi;
            fvg[sess].low = fgLo;
            fvg[sess].time = ratesORB[d].time;
            fvg[sess].bullish = true;
            fvg[sess].valid = true;
            fvg[sess].mitigated = false;
            fvg[sess].touchCount = 0;
           }
        }
      else
        {
         double fgHi = ratesORB[d + 1].low;
         double fgLo = ratesORB[d - 1].high;
         if(fgHi > fgLo)
           {
            fvg[sess].high = fgHi;
            fvg[sess].low = fgLo;
            fvg[sess].time = ratesORB[d].time;
            fvg[sess].bullish = false;
            fvg[sess].valid = true;
            fvg[sess].mitigated = false;
            fvg[sess].touchCount = 0;
           }
        }
     }
  }

// Step 9a: Price in OB/FVG (FIX: separate bid/ask logic + momentum + BOS + wick rejection + HTF momentum)
bool IsZoneRetestConfirmed(int sess, bool bullish)
  {
   double zoneMid = 0.0;
   if(InpUseOB && ob[sess].valid)
      zoneMid = (ob[sess].high + ob[sess].low) / 2.0;
   else
      if(InpUseFVG && fvg[sess].valid)
         zoneMid = (fvg[sess].high + fvg[sess].low) / 2.0;
   if(zoneMid <= 0.0)
      return true;
   double close = ratesORB[1].close;
   double atr = GetATR(1);
   double minBody = (atr > 0) ? atr * 0.03 : 0.0;
   if(bullish)
      return (close > zoneMid + minBody);
   return (close < zoneMid - minBody);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool SMC_PriceInZone(int sess)
  {
// Safety: require enough ORB bars to perform checks (ratesORB is series: 0=live,1=last closed,...)
   if(ArraySize(ratesORB) < 3)
      return false;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double atr = GetATR(1);
   bool inOB = false, inFVG = false;
   bool useOB = false; // track which zone is used
// Check OB first (prioritize over FVG if both exist)
   if(InpUseOB && ob[sess].valid)
     {
      if(setupBull[sess])
        {
         double mitL = ob[sess].low + (ob[sess].high - ob[sess].low) * (1.0 - InpOBMitigation / 100.0);
         inOB = (ask >= mitL && ask <= ob[sess].high); // Buy: use ASK
         // Added: require close above OB level (not just touch)
         if(inOB && ratesORB[1].close > ob[sess].low + atr * 0.05)
            useOB = true;
        }
      else
        {
         double mitH = ob[sess].high - (ob[sess].high - ob[sess].low) * (1.0 - InpOBMitigation / 100.0);
         inOB = (bid <= mitH && bid >= ob[sess].low); // Sell: use BID
         // Added: require close below OB level (not just touch)
         if(inOB && ratesORB[1].close < ob[sess].high - atr * 0.05)
            useOB = true;
        }
     }
// Check FVG only if OB not triggered or OB not enabled
   if(!useOB && InpUseFVG && fvg[sess].valid)
     {
      if(setupBull[sess])
         inFVG = (ask >= fvg[sess].low && ask <= fvg[sess].high);
      else
         inFVG = (bid >= fvg[sess].low && bid <= fvg[sess].high);
     }
// LTF Momentum: at least one sign of reversal momentum at the zone touch.
// "c1 > o1" clause requires minimum body (>=10% ATR) to prevent tiny inside
// bars during impulse moves from satisfying the directional condition alone.
   bool momentumOK = false;
   if(inOB || inFVG)
     {
      double c1 = ratesORB[1].close;
      double c2 = ratesORB[2].close;
      double o1 = ratesORB[1].open;
      double body1 = MathAbs(c1 - o1);
      double minMomBody = atr * 0.10; // 10% ATR floor on the directional-close clause
      if(setupBull[sess])
         momentumOK = (c1 > c2 || (c1 > o1 && body1 >= minMomBody));
      else
         momentumOK = (c1 < c2 || (c1 < o1 && body1 >= minMomBody));
     }
// BOS check REMOVED from zone detector — BOS was already confirmed by SMC_Structure state.
// During retrace into OB/FVG, price is EXPECTED to be below/above the BOS level.
// Keeping bosOK here blocked all retrace entries (the intended SMC entry scenario).
// Wick rejection REMOVED from zone detector — belongs in SMC_LTFConfirm (engulf/pinbar check).
// Zone touch may be a strong trend candle (no wick yet); wick forms during the bounce.
// HTF Momentum confirmation: check higher timeframe bias alignment
   bool htfMomentumOK = true;
   if(InpHTFMomentum)
     {
      if(setupBull[sess])
         htfMomentumOK = (htfBias == BIAS_BULLISH || htfBias == BIAS_NEUTRAL);
      else
         htfMomentumOK = (htfBias == BIAS_BEARISH || htfBias == BIAS_NEUTRAL);
     }
// Quality gate: require a clear directional retest into the zone, not just a shallow touch.
   bool retestOK = IsZoneRetestConfirmed(sess, setupBull[sess]);
   priceInZone[sess] = (inOB || inFVG) && momentumOK && htfMomentumOK && retestOK;
   return priceInZone[sess];
  }

// Check OB and FVG independently — a close-through FVG while OB is intact is still invalid
bool SMC_ZoneInvalidated(int sess)
  {
   double cls = ratesORB[1].close;
   if(ob[sess].valid)
     {
      if(setupBull[sess] && cls < ob[sess].low)
         ob[sess].valid = false;
      else
         if(!setupBull[sess] && cls > ob[sess].high)
            ob[sess].valid = false;
     }
   if(fvg[sess].valid)
     {
      if(setupBull[sess] && cls < fvg[sess].low)
         fvg[sess].valid = false;
      else
         if(!setupBull[sess] && cls > fvg[sess].high)
            fvg[sess].valid = false;
     }
   return (!ob[sess].valid && !fvg[sess].valid);
  }

// Step 9b: LTF confirmation
bool SMC_LTFConfirm(int sess)
  {
   int n = CopyRates(_Symbol, gLTFTF, 0, 20, ratesLTF);
   if(n < 4)
      return false;
   double ltfAtr = GetATRLTF(1);
   if(ltfAtr <= 0)
      return false;
   double c1 = ratesLTF[1].close, o1 = ratesLTF[1].open, h1 = ratesLTF[1].high, l1 = ratesLTF[1].low;
   double c2 = ratesLTF[2].close, o2 = ratesLTF[2].open;
   double body1 = MathAbs(c1 - o1);
   double body2 = MathAbs(c2 - o2);
   double lw = MathMin(c1, o1) - l1, uw = h1 - MathMax(c1, o1);
// Minimum body/wick floors: 5% ATR prevents noise candles (doji spikes, 1-pip engulfs)
// from triggering LTF confirmation during low-volatility Asian session hours.
   double minBody = ltfAtr * 0.05;
   double minWick = ltfAtr * 0.10; // wick must also clear a meaningful threshold
   bool res = false;
   if(setupBull[sess])
     {
      if(InpLTFEngulf)
         res = res || (c1 > o1 && c2 < o2 && c1 > o2 && o1 < c2 && body1 >= minBody && body2 >= minBody);
      if(InpLTFPinbar && body1 >= minBody)
         res = res || (lw >= body1 * InpPinbarRatio && lw >= minWick && c1 >= o1);
     }
   else
     {
      if(InpLTFEngulf)
         res = res || (c1 < o1 && c2 > o2 && c1 < o2 && o1 > c2 && body1 >= minBody && body2 >= minBody);
      if(InpLTFPinbar && body1 >= minBody)
         res = res || (uw >= body1 * InpPinbarRatio && uw >= minWick && c1 <= o1);
     }
   if(res)
     {
      ltfConfirmed[sess] = true;
      LogMsg(SESS_NAME[sess] + " LTF CONFIRMED");
     }
   return res;
  }

//============================================================
// MODULE: TRADE ENGINE
//============================================================
ENUM_BIAS GetEntryBiasForLogic()
  {
   if(InpUseDailyBias && dailyBias != BIAS_NEUTRAL)
      return dailyBias;
   return htfBias;
  }

//+------------------------------------------------------------------+
//| Shared conflict-check for CanEnter's two bias gates — extracted   |
//| because both previously repeated this smcConfirmed/breakout logic |
//| verbatim, differing only in which ENUM_BIAS value they tested.    |
//+------------------------------------------------------------------+
bool DirectionConflictsWithBias(int sess, ENUM_BIAS bias, string gateLabel)
  {
   bool smcConfirmed = UsesSMC(sess) && smcState[sess] == SMC_CONFIRMED;
   if(smcConfirmed)
     {
      if(setupBull[sess] && bias == BIAS_BEARISH)
        {
         LogMsg(SESS_NAME[sess] + " SKIP — " + gateLabel + " bias BEARISH conflicts BUY setup");
         return true;
        }
      if(!setupBull[sess] && bias == BIAS_BULLISH)
        {
         LogMsg(SESS_NAME[sess] + " SKIP — " + gateLabel + " bias BULLISH conflicts SELL setup");
         return true;
        }
     }
   else
     {
      bool bkU = GetBkUp(sess), bkD = GetBkDn(sess);
      if(bkU && !bkD && bias == BIAS_BEARISH)
        {
         LogMsg(SESS_NAME[sess] + " SKIP — " + gateLabel + " bias BEARISH conflicts BUY breakout");
         return true;
        }
      if(bkD && !bkU && bias == BIAS_BULLISH)
        {
         LogMsg(SESS_NAME[sess] + " SKIP — " + gateLabel + " bias BULLISH conflicts SELL breakout");
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Shared directional gate used by CanEnter() and TradeEngine() so   |
//| the same criteria decide whether a BUY/SELL path is actually     |
//| allowed.                                                          |
//+------------------------------------------------------------------+
bool IsDirectionalGateAllowed(int sess, bool isBuy)
  {
   if(!IsSessEnabled(sess))
      return false;
   if(!UsesSMC(sess))
     {
      if(!IsORBEntryQualified(sess, isBuy))
         return false;
      return CheckConfirmationModeForDirection(sess, isBuy);
     }
   return CheckConfirmationModeForDirection(sess, isBuy);
  }

// Shared entry-pipeline gate used by CanEnter(), CheckEntryReadyVisual(), and the panel.
// This keeps readiness, visual state, and execution on the exact same decision path.
bool IsPipelineDirectionReady(int sess, bool isBuy)
  {
   if(!IsSessEnabled(sess))
      return false;
   double orH = GetSessORH(sess), orL = GetSessORL(sess);
   if(orH <= 0 || orL <= 0 || orH <= orL)
      return false;
   if(gMinORBRange > 0 && (orH - orL) / _Point < gMinORBRange)
      return false;
   if(gMaxORBRange > 0 && (orH - orL) / _Point > gMaxORBRange)
      return false;
   double atrC = GetATR(1);
   if(atrC > 0 && (orH - orL) < atrC * 0.20)
      return false;
   datetime orEnd = GetSessOREnd(sess);
   if(orEnd <= 0 || TimeCurrent() < orEnd)
      return false;
   if(gMaxBarsAfterOR > 0)
     {
      if(orEnd > 0 && TimeCurrent() > orEnd)
        {
         int barsElapsed = (int)((TimeCurrent() - orEnd) / MathMax(PeriodSeconds(ORBTF), 60));
         if(barsElapsed > gMaxBarsAfterOR)
            return false;
        }
     }
   if(!GetSessActive(sess))
      return false;
   MqlDateTime tm;
   TimeToStruct(TimeGMT(), tm);
   if(tm.hour * 60 + tm.min >= GetSessCutoff(sess))
      return false;
   if(sessTradeCount[sess] >= InpMaxTrades)
      return false;
   if(HasOpenOrPendingTrade())
      return false;
   double spd = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   double maxSpd = InpMaxSpread * _Point;
   if(InpSpreadMode == SPREAD_POINTS && spd > maxSpd)
      return false;
   if(InpSpreadMode == SPREAD_ATR)
     {
      double a = GetATR(1);
      if(a > 0 && spd > a * InpMaxSpreadATR)
         return false;
     }
   ENUM_BIAS trendBias = GetEntryBiasForLogic();
   if(InpUseDailyBias && trendBias == BIAS_NEUTRAL)
      return false;
   bool htfGateRan = false;
   if(InpBiasRequired && htfBias != BIAS_NEUTRAL)
     {
      htfGateRan = true;
      if(DirectionConflictsWithBias(sess, htfBias, "HTF"))
         return false;
     }
   if(InpUseDailyBias && pdHigh > pdLow && trendBias != BIAS_NEUTRAL)
     {
      bool alreadyTested = htfGateRan && (trendBias == htfBias);
      if(!alreadyTested && DirectionConflictsWithBias(sess, trendBias, "daily/HTF"))
         return false;
     }
   if(InpNewsFilter && IsHighImpactNews())
      return false;
   if(InpVolFilter)
     {
      if(volRegime == VOL_CALM || volRegime == VOL_EXPLOSIVE)
         return false;
     }
   if(!IsDirectionalGateAllowed(sess, isBuy))
      return false;
   if(InpUseDealingRange && dealingRange.high > dealingRange.low)
     {
      ENUM_PRICE_POS pp = GetPricePos();
      bool smcConfirmed = UsesSMC(sess) && smcState[sess] == SMC_CONFIRMED;
      if(smcConfirmed)
        {
         bool bul = setupBull[sess];
         if((bul && isBuy && pp == PP_PREMIUM) || (!bul && !isBuy && pp == PP_DISCOUNT))
            return false;
        }
      else
        {
         bool bkU = GetBkUp(sess), bkD = GetBkDn(sess);
         if(isBuy && bkU && !bkD && pp == PP_PREMIUM)
            return false;
         if(!isBuy && bkD && !bkU && pp == PP_DISCOUNT)
            return false;
        }
     }
   if(InpUseVPFilter && vpReady)
     {
      bool smcConfirmed = UsesSMC(sess) && smcState[sess] == SMC_CONFIRMED;
      if(smcConfirmed)
        {
         bool bul = setupBull[sess];
         double chkPrice = bul ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(isBuy && bul && chkPrice > vpVAH)
            return false;
         if(!isBuy && !bul && chkPrice < vpVAL)
            return false;
        }
      else
        {
         bool bkU = GetBkUp(sess), bkD = GetBkDn(sess);
         double askP = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double bidP = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(isBuy && bkU && !bkD && askP > vpVAH)
            return false;
         if(!isBuy && bkD && !bkU && bidP < vpVAL)
            return false;
        }
     }
   if(InpFreshZoneOnly && UsesSMC(sess))
     {
      bool obActive = InpUseOB && ob[sess].valid;
      bool fvgActive = InpUseFVG && fvg[sess].valid;
      bool obUsed = obActive && ob[sess].touchCount > 1;
      bool fvgUsed = fvgActive && fvg[sess].touchCount > 1;
      if((obActive && !fvgActive && obUsed) || (!obActive && fvgActive && fvgUsed) || (obActive && fvgActive && obUsed && fvgUsed))
         return false;
     }
   if(InpUseProbScore)
     {
      probScore[sess] = CalcProbScore(sess);
      if(probScore[sess] < (double)InpMinProbScore)
         return false;
     }
   if(InpMaxDailyLosses > 0)
     {
      datetime todayStart = lastResetDay > 0 ? lastResetDay : StringToTime(TimeToString(TimeGMT(), TIME_DATE));
      if(HistorySelect(todayStart, TimeCurrent() + 1))
        {
         int lossCount = 0;
         int dTotal = HistoryDealsTotal();
         for(int di = 0; di < dTotal; di++)
           {
            ulong dTkt = HistoryDealGetTicket(di);
            if(HistoryDealGetString(dTkt, DEAL_SYMBOL) != _Symbol)
               continue;
            if((long)HistoryDealGetInteger(dTkt, DEAL_MAGIC) != InpMagic)
               continue;
            if(HistoryDealGetInteger(dTkt, DEAL_ENTRY) != DEAL_ENTRY_OUT)
               continue;
            if(HistoryDealGetDouble(dTkt, DEAL_PROFIT) < 0)
               lossCount++;
           }
         if(lossCount >= InpMaxDailyLosses)
            return false;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void TradeEngine()
  {
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(!IsSessEnabled(s))
         continue;
      if(!CanEnter(s))
         continue;
      if(UsesSMC(s))
        {
         if(smcState[s] == SMC_CONFIRMED)
           {
            // FIX: call SMC_PriceInZone once here (sets priceInZone[s] for panel display),
            //      then ExecuteTrade does a lightweight non-mutating bid/ask zone re-check.
            //      Previous code called SMC_PriceInZone a second time inside ExecuteTrade,
            //      which could overwrite priceInZone[s]=false and corrupt the panel state.
            bool inZone = SMC_PriceInZone(s);
            bool dirAllowed = IsDirectionalGateAllowed(s, setupBull[s]);
            if(inZone && dirAllowed)
              {
               if(ExecuteTrade(setupBull[s] ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, s))
                 {
                  smcState[s] = SMC_TRADED;
                  orbFallbackActive[s] = false; // prevent fallback ORB firing after SMC trade
                  ob[s].valid = false;          // zone consumed — remove from chart immediately
                  fvg[s].valid = false;
                 }
               else
                 {
                  // Conservative re-entry handling: do not immediately recycle the same setup.
                  // Reset the zone state and wait for a fresh, stronger retest before trying again.
                  ltfConfirmed[s] = false;
                  ob[s].valid = false;
                  fvg[s].valid = false;
                  smcState[s] = SMC_ZONE;
                 }
              }
            else
              {
               ltfConfirmed[s] = false;
               smcState[s] = SMC_ZONE; // price left zone intra-bar — wait for re-entry
              }
           }
         else
            if(orbFallbackActive[s])
              {
               // ORB fallback: SMC window expired without a sweep — use plain ORB breakout direction
               // If daily bias is neutral, use HTF bias as the trend reference for entry direction.
               bool bU = GetBkUp(s), bD = GetBkDn(s), fH = GetFBH(s), fL = GetFBL(s);
               ENUM_BIAS trendBias = GetEntryBiasForLogic();
               bool biasAllowBuy = (trendBias != BIAS_BEARISH);
               bool biasAllowSell = (trendBias != BIAS_BULLISH);
               // Bias-aligned extra entry: false-break-low = bullish bounce (BULL bias), false-break-high = bearish fade (BEAR bias)
               bool biasBuyExt = (trendBias == BIAS_BULLISH && fL);
               bool biasSellExt = (trendBias == BIAS_BEARISH && fH);
               bool buySig = (bU || biasBuyExt || IsORBEntryQualified(s, true));
               bool sellSig = (bD || biasSellExt || IsORBEntryQualified(s, false));
               if(buySig && !tradeBuyDone[s] && !fH && !HasOpenOrPendingTrade() && biasAllowBuy && IsDirectionalGateAllowed(s, true))
                  ExecuteTrade(ORDER_TYPE_BUY, s);
               if(sellSig && !tradeSellDone[s] && !fL && !HasOpenOrPendingTrade() && biasAllowSell && IsDirectionalGateAllowed(s, false))
                  ExecuteTrade(ORDER_TYPE_SELL, s);
              }
        }
      else
        {
         bool bU = GetBkUp(s), bD = GetBkDn(s), fH = GetFBH(s), fL = GetFBL(s);
         // If daily bias is neutral, use HTF bias as the trend reference for entry direction.
         ENUM_BIAS trendBias = GetEntryBiasForLogic();
         bool biasAllowBuy = (trendBias != BIAS_BEARISH);
         bool biasAllowSell = (trendBias != BIAS_BULLISH);
         // Bias-aligned extra entry: false-break-low = bullish bounce (BULL bias), false-break-high = bearish fade (BEAR bias)
         bool biasBuyExt = (trendBias == BIAS_BULLISH && fL);
         bool biasSellExt = (trendBias == BIAS_BEARISH && fH);
         bool buySig = (bU || biasBuyExt || IsORBEntryQualified(s, true));
         bool sellSig = (bD || biasSellExt || IsORBEntryQualified(s, false));
         // SYNC FIX 3: re-check pending/open trades before SELL in case BUY just executed
         if(buySig && !tradeBuyDone[s] && !fH && !HasOpenOrPendingTrade() && biasAllowBuy && IsDirectionalGateAllowed(s, true))
            ExecuteTrade(ORDER_TYPE_BUY, s);
         if(sellSig && !tradeSellDone[s] && !fL && !HasOpenOrPendingTrade() && biasAllowSell && IsDirectionalGateAllowed(s, false))
            ExecuteTrade(ORDER_TYPE_SELL, s);
        }
     }
  }

// Visual indicator for HTF CHoCH / BOS structural break level
void DrawHTFStructure()
  {
   if(!InpDrawObjects)
     {
      ObjectDelete(0, "SMC_HTF_BOS");
      ObjectDelete(0, "SMC_HTF_BOSLBL");
      return;
     }
   if(htfBosLevel <= 0.0 || htfBias == BIAS_NEUTRAL)
     {
      ObjectDelete(0, "SMC_HTF_BOS");
      ObjectDelete(0, "SMC_HTF_BOSLBL");
      return;
     }
   datetime now = (ArraySize(ratesORB) > 0) ? ratesORB[0].time : TimeCurrent();
   int barSec = PeriodSeconds(ORBTF);
   datetime bS = now - (datetime)(barSec * 20);
   datetime bE = now + (datetime)(barSec * 12);
   color bC = (htfBias == BIAS_BULLISH) ? C'0,220,255' : C'255,100,100';
   string dirStr = (htfBias == BIAS_BULLISH) ? "▲ BULL" : "▼ BEAR";
   DrawHLine("SMC_HTF_BOS", bS, bE, htfBosLevel, bC, STYLE_DASHDOT, 2);
   DrawTextObj("SMC_HTF_BOSLBL", bS, htfBosLevel,
               "  HTF CHoCH/BOS " + dirStr + " @" + DoubleToString(htfBosLevel, _Digits),
               bC, 10);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool CanEnter(int sess)
  {
   return IsPipelineDirectionReady(sess, true) || IsPipelineDirectionReady(sess, false);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasOpenPos()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PosInfo.SelectByIndex(i))
         if(PosInfo.Symbol() == _Symbol && PosInfo.Magic() == InpMagic)
            return true;
   return false;
  }

//+------------------------------------------------------------------+
//| LTF Suggestion Engine — SL/TP anchored to the LTF engine's own   |
//| zone. Deliberately NOT CalcSLTPDist(): that function reads       |
//| ob[sess]/fvg[sess] (the main engine's zone), which would anchor  |
//| this suggestion's risk to the wrong, unrelated zone.             |
//+------------------------------------------------------------------+
void CalcLTFSuggestSLTP(int sess, ENUM_ORDER_TYPE type, double price, double atr, double &slDist, double &tpDist)
  {
   double orH = GetSessORH(sess), orL = GetSessORL(sess);
   if(InpUseOB && ltfSuggOB[sess].valid)
      slDist = (type == ORDER_TYPE_BUY) ? (price - ltfSuggOB[sess].low + atr * InpSL_OBBuffer)
               : (ltfSuggOB[sess].high - price + atr * InpSL_OBBuffer);
   else
      if(InpUseFVG && ltfSuggFVG[sess].valid)
         slDist = (type == ORDER_TYPE_BUY) ? (price - ltfSuggFVG[sess].low + atr * InpSL_OBBuffer)
                  : (ltfSuggFVG[sess].high - price + atr * InpSL_OBBuffer);
      else
         slDist = atr * gATR_SL;
   if(slDist <= 0 || !MathIsValidNumber(slDist))
      slDist = atr > 0 ? atr * 1.5 : _Point * 30;
   double orRange = MathMax(orH - orL, atr * 0.1);
   tpDist = (type == ORDER_TYPE_BUY) ? MathMax(orH - price, 0) : MathMax(price - orL, 0);
   if(tpDist <= 0)
      tpDist = orRange * gTPRangeMult;
   if(tpDist <= 0 || !MathIsValidNumber(tpDist))
      tpDist = slDist * gMinRR;
   double minStp = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   slDist = MathMax(slDist, minStp * 1.5);
   tpDist = MathMax(tpDist, slDist * gMinRR);
  }

//+------------------------------------------------------------------+
//| LTF Suggestion Engine — auto-execution. Does NOT call            |
//| ExecuteTrade(): that function re-checks price against             |
//| ob[sess]/fvg[sess] and smcState[sess] (the main engine's state)   |
//| at line ~3236, which could reject this suggestion based on        |
//| unrelated state. This function re-implements only the safe,      |
//| generic parts (spread check, order send, bookkeeping, log/alert). |
//+------------------------------------------------------------------+
bool ExecuteLTFSuggestion(int sess)
  {
   if(!IsSessEnabled(sess))
     {
      LogMsg(SESS_NAME[sess] + " [LTF-SUGGEST] SKIP EXEC - session disabled");
      return false;
     }
   if(sessTradeCount[sess] >= InpMaxTrades)
     {
      LogMsg(SESS_NAME[sess] + " [LTF-SUGGEST] SKIP EXEC - max trades reached");
      return false;
     }
   if(HasOpenOrPendingTrade())
     {
      LogMsg(SESS_NAME[sess] + " [LTF-SUGGEST] SKIP EXEC - position/order already open");
      return false;
     }
   double atr = GetATRLTF(1);
   double spd = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   double maxSpd = InpMaxSpread * _Point;
   if(InpSpreadMode == SPREAD_POINTS && spd > maxSpd)
     {
      LogMsg(SESS_NAME[sess] + " [LTF-SUGGEST] SKIP EXEC - spread too wide (points)");
      return false;
     }
   if(InpSpreadMode == SPREAD_ATR && atr > 0 && spd > atr * InpMaxSpreadATR)
     {
      LogMsg(SESS_NAME[sess] + " [LTF-SUGGEST] SKIP EXEC - spread too wide (ATR)");
      return false;
     }
   ENUM_ORDER_TYPE type = ltfSuggBull[sess] ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist, tpDist;
   CalcLTFSuggestSLTP(sess, type, price, atr, slDist, tpDist);
   double sl, tp;
   if(type == ORDER_TYPE_BUY)
     {
      sl = NormalizeDouble(price - slDist, digs);
      tp = NormalizeDouble(price + tpDist, digs);
     }
   else
     {
      sl = NormalizeDouble(price + slDist, digs);
      tp = NormalizeDouble(price - tpDist, digs);
     }
   double lot = CalcRiskLot(slDist);
   string dir = (type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   string cmt = "LTF_SUGGEST_" + SESS_NAME[sess] + "_" + dir;
   bool ok = (type == ORDER_TYPE_BUY) ? Trade.Buy(lot, _Symbol, price, sl, tp, cmt) : Trade.Sell(lot, _Symbol, price, sl, tp, cmt);
   if(ok)
     {
      sessTradeCount[sess]++;
      if(type == ORDER_TYPE_BUY)
         tp1Level[sess] = NormalizeDouble(price + slDist, digs);
      else
         tp1Level[sess] = NormalizeDouble(price - slDist, digs);
      sessTicket[sess] = Trade.ResultOrder();
      string msg = StringFormat("%s|LTF SUGGEST %s %s|Entry:%.5f SL:%.5f TP:%.5f Score:%.0f Lot:%.2f",
                                _Symbol, SESS_NAME[sess], dir, price, sl, tp, ltfSuggScore[sess], lot);
      LogMsg("LTF-SUGGEST-TRADE:" + msg);
      if(InpAlerts)
         Alert(msg);
      if(InpPush)
         SendNotification(msg);
     }
   else
      LogMsg(StringFormat("LTF-SUGGEST-FAIL|%s %s|%d|%s", SESS_NAME[sess], dir, Trade.ResultRetcode(), Trade.ResultRetcodeDescription()));
   return ok;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasOpenOrPendingTrade()
  {
//if(HasOpenPos())
// return true;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      return true;
     }
   return false;
  }

// Reconcile sessTradeCount[] with currently open positions and pending orders
// Ensures sessTradeCount reflects live trades after EA start or restore
void ReconcileSessTradeCount()
  {
// reset counts
   for(int s = 0; s < SESS_COUNT; s++)
      sessTradeCount[s] = 0;
// Scan open positions — derive session from position open time, fallback to comment
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PosInfo.SelectByIndex(i))
         continue;
      if(PosInfo.Symbol() != _Symbol)
         continue;
      if(PosInfo.Magic() != InpMagic)
         continue;
      datetime posTime = PosInfo.Time();
      int sess = GetSessFromCmt(posTime);
      if(sess < 0)
        {
         // fallback: parse comment
         string cm = PosInfo.Comment();
         if(StringFind(cm, "ORB_SMC_") >= 0)
           {
            for(int s = 0; s < SESS_COUNT; s++)
               if(StringFind(cm, SESS_NAME[s]) >= 0)
                 {
                  sess = s;
                  break;
                 }
           }
        }
      if(sess < 0)
         continue;
      // basic session mappings
      sessTradeCount[sess]++;
      ulong posTkt = PosInfo.Ticket();
      if(sessTicket[sess] == 0)
         sessTicket[sess] = posTkt;
      if(PosInfo.PositionType() == POSITION_TYPE_BUY)
         tradeBuyDone[sess] = true;
      else
         tradeSellDone[sess] = true;
      // Set tp1Level from SL distance if SL present (1R = open +/- SLdist)
      double opn = PosInfo.PriceOpen();
      double sl = PosInfo.StopLoss();
      int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      if(sl > 0)
        {
         double slDist = MathAbs(opn - sl);
         if(PosInfo.PositionType() == POSITION_TYPE_BUY)
            tp1Level[sess] = NormalizeDouble(opn + slDist, digs);
         else
            tp1Level[sess] = NormalizeDouble(opn - slDist, digs);
        }
      // Detect partial taken by scanning history deals linked to this position
      // If any DEAL_ENTRY_OUT exists for this position ticket while position remains open,
      // assume a partial close occurred.
      if(HistorySelect(TimeCurrent() - 30 * 24 * 3600, TimeCurrent() + 1))
        {
         int dTotal = HistoryDealsTotal();
         for(int di = 0; di < dTotal; di++)
           {
            ulong dTkt = HistoryDealGetTicket(di);
            if(dTkt == 0)
               continue;
            ulong linkedPos = (ulong)HistoryDealGetInteger(dTkt, DEAL_POSITION_ID);
            if(linkedPos != posTkt)
               continue;
            if(HistoryDealGetInteger(dTkt, DEAL_ENTRY) != DEAL_ENTRY_OUT)
               continue;
            // Found an exit deal tied to this position → partial (or full) close happened
            partialTaken[sess] = true;
            break;
           }
        }
     }
// Log reconciliation result
   string log = "Reconciled sessTradeCount: ";
   for(int k = 0; k < SESS_COUNT; k++)
      log += SESS_NAME[k] + "=" + IntegerToString(sessTradeCount[k]) + " ";
   LogMsg(log);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
// Shared SL/TP distance calculation — used by ExecuteTrade (market orders), ManagePendingOR
// (OR-lock pending stop orders) and PreviewEntryRisk (dashboard/entry-ready preview) so all
// three always agree on the exact same numbers. Previously each had its own copy-pasted
// version; they drifted out of sync at least once (see the XAU-cap history in the
// TP_RANGE_MULT branch below), which is exactly the failure mode a shared helper prevents.
void CalcSLTPDist(int sess, ENUM_ORDER_TYPE type, double price, double atr, double orH, double orL,
                  double &slDist, double &tpDist)
  {
   double minStp = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double orRange = MathMax(orH - orL, atr * 0.1);
// ── SL CALCULATION ──────────────────────────────────────────────
   switch(InpSLMode)
     {
      case SL_OR_LEVEL:
         if(UsesSMC(sess))
           {
            // SMC: SL anchored to zone boundary (OB preferred, FVG fallback, OR level last resort)
            if(InpUseOB && ob[sess].valid)
               slDist = (type == ORDER_TYPE_BUY) ? (price - ob[sess].low + atr * InpSL_OBBuffer)
                        : (ob[sess].high - price + atr * InpSL_OBBuffer);
            else
               if(InpUseFVG && fvg[sess].valid)
                  slDist = (type == ORDER_TYPE_BUY) ? (price - fvg[sess].low + atr * InpSL_OBBuffer)
                           : (fvg[sess].high - price + atr * InpSL_OBBuffer);
               else
                 {
                  double slLvl = (type == ORDER_TYPE_BUY) ? orL - atr * InpSL_OBBuffer
                                 : orH + atr * InpSL_OBBuffer;
                  slDist = (type == ORDER_TYPE_BUY) ? price - slLvl : slLvl - price;
                 }
           }
         else
           {
            // ORB: SL beyond OR boundary (absolute level to avoid slippage drift)
            double slLvl = (type == ORDER_TYPE_BUY) ? orL - atr * InpSL_OBBuffer
                           : orH + atr * InpSL_OBBuffer;
            slDist = (type == ORDER_TYPE_BUY) ? price - slLvl : slLvl - price;
           }
         if(slDist <= 0)
            slDist = atr * gATR_SL;
         break;
      case SL_ATR:
         slDist = atr * gATR_SL;
         break;
      default: // SL_FIXED
         slDist = InpSL_Points * _Point;
         break;
     }
// ── TP CALCULATION ──────────────────────────────────────────────
// F6: XAU/GOLD uses tighter TP multiplier — Gold rarely extends 2× OR range in one session
   bool isGold = (StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0);
   double effTPMult = (isGold && InpXAU_TPRangeMult > 0) ? InpXAU_TPRangeMult : gTPRangeMult;
   switch(InpTPMode)
     {
      case TP_RANGE_MULT:
         if(UsesSMC(sess) && orH > orL)
           {
            // SMC: target opposing OR boundary (AMD distribution zone)
            double smcTPDist = (type == ORDER_TYPE_BUY) ? (orH - price) : (price - orL);
            tpDist = (smcTPDist > 0) ? smcTPDist : orRange * effTPMult;
            // XAU cap: consulted even when the AMD target (smcTPDist) is used, not just the
            // fallback — gold commonly scores high on the AMD/SMC auto-mode character check, so
            // limiting this only to the fallback branch meant the cap almost never fired.
            if(isGold && InpXAU_TPRangeMult > 0)
               tpDist = MathMin(tpDist, orRange * effTPMult);
           }
         else
            tpDist = orRange * effTPMult;
         break;
      case TP_ATR:
         tpDist = atr * gATR_TP;
         break;
      default: // TP_FIXED
         tpDist = InpTP_Points * _Point;
         break;
     }
// Safety clamps
   if(slDist <= 0 || !MathIsValidNumber(slDist))
      slDist = atr > 0 ? atr * 1.5 : minStp * 3.0;
   if(tpDist <= 0 || !MathIsValidNumber(tpDist))
      tpDist = slDist * gMinRR;
   slDist = MathMax(slDist, minStp * 1.5);
   tpDist = MathMax(tpDist, slDist * gMinRR);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool ExecuteTrade(ENUM_ORDER_TYPE type, int sess)
  {
   double atr = GetATR(1);
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double orH = GetSessORH(sess), orL = GetSessORL(sess);
// FIX: single price read — SL calculation and order placement use the same value.
//      Previous code read price0 for SL calc then re-read for the order, causing SL
//      misalignment on fast markets (slippage between the two reads shifted SL level).
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
// Re-validate spread at execution time
   double spd = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   double maxSpd = InpMaxSpread * _Point;
   if(InpSpreadMode == SPREAD_POINTS && spd > maxSpd)
     {
      LogMsg(StringFormat("SKIP ENTRY %s - Spread %.2f > Max %.2f", SESS_NAME[sess], spd / _Point, maxSpd / _Point));
      return false;
     }
   if(InpSpreadMode == SPREAD_ATR && atr > 0 && spd > atr * InpMaxSpreadATR)
     {
      LogMsg(StringFormat("SKIP ENTRY %s - Spread %.4f > ATR*%.1f", SESS_NAME[sess], spd, InpMaxSpreadATR));
      return false;
     }
// Lightweight zone re-check at execution time (no side-effects on priceInZone[]).
// Only applies to the SMC_CONFIRMED path — fallback and non-SMC paths have no zones.
// (After ResetSMCState, ob.valid/fvg.valid = false; checking them here would reject all
//  fallback entries since zones are always invalid after SMC timeout.)
   if(UsesSMC(sess) && smcState[sess] == SMC_CONFIRMED)
     {
      bool inZone = false;
      if(InpUseOB && ob[sess].valid)
         inZone = (price >= ob[sess].low && price <= ob[sess].high);
      // Fallthrough: check FVG regardless of whether OB is valid (matches SMC_PriceInZone)
      if(!inZone && InpUseFVG && fvg[sess].valid)
         inZone = (price >= fvg[sess].low && price <= fvg[sess].high);
      if(!inZone)
        {
         LogMsg(SESS_NAME[sess] + " ENTRY SKIP - Price left zone before execution");
         return false;
        }
      // Additional quality gate: require a clear directional close relative to the zone midpoint.
      double zoneMid = 0.0;
      if(InpUseOB && ob[sess].valid)
         zoneMid = (ob[sess].high + ob[sess].low) / 2.0;
      else
         if(InpUseFVG && fvg[sess].valid)
            zoneMid = (fvg[sess].high + fvg[sess].low) / 2.0;
      if(zoneMid > 0.0)
        {
         double closeEdge = (type == ORDER_TYPE_BUY) ? (ratesORB[1].close - zoneMid) : (zoneMid - ratesORB[1].close);
         double minEdge = MathMax(atr * 0.02, _Point * 2.0);
         if(closeEdge < minEdge)
           {
            LogMsg(SESS_NAME[sess] + " ENTRY SKIP - Retest not strong enough for execution");
            return false;
           }
        }
     }
   double slDist, tpDist;
   CalcSLTPDist(sess, type, price, atr, orH, orL, slDist, tpDist);
   double sl, tp;
   if(type == ORDER_TYPE_BUY)
     {
      sl = NormalizeDouble(price - slDist, digs);
      tp = NormalizeDouble(price + tpDist, digs);
     }
   else
     {
      sl = NormalizeDouble(price + slDist, digs);
      tp = NormalizeDouble(price - tpDist, digs);
     }
   double lot = CalcRiskLot(slDist);
   string dir = (type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   string cmt = "ORB_SMC_" + SESS_NAME[sess] + "_" + dir;
// Quick-params override: if enabled, use gQuickLot/gQuickSL/gQuickTP (absolute prices)
   if(gUseQuickParams)
     {
      if(gQuickLot > 0)
         lot = gQuickLot;
      if(gQuickSL > 0)
         sl = gQuickSL;
      if(gQuickTP > 0)
         tp = gQuickTP;
      gUseQuickParams = false; // consume override
     }
   bool ok = (type == ORDER_TYPE_BUY) ? Trade.Buy(lot, _Symbol, price, sl, tp, cmt) : Trade.Sell(lot, _Symbol, price, sl, tp, cmt);
   if(ok)
     {
      sessTradeCount[sess]++;
      if(type == ORDER_TYPE_BUY)
        {
         tradeBuyDone[sess] = true;
         tp1Level[sess] = NormalizeDouble(price + slDist, digs);
        }
      else
        {
         tradeSellDone[sess] = true;
         tp1Level[sess] = NormalizeDouble(price - slDist, digs);
        }
      sessTicket[sess] = Trade.ResultOrder();
      string msg = StringFormat("%s|ORB SMC %s %s|Entry:%.5f SL:%.5f TP:%.5f RR:%.1f Lot:%.2f",
                                _Symbol, SESS_NAME[sess], dir, price, sl, tp, tpDist / slDist, lot);
      LogMsg("TRADE:" + msg);
      if(InpAlerts)
         Alert(msg);
      if(InpPush)
         SendNotification(msg);
     }
   else
      LogMsg(StringFormat("FAIL|%s %s|%d|%s", SESS_NAME[sess], dir, Trade.ResultRetcode(), Trade.ResultRetcodeDescription()));
   return ok;
  }

//============================================================
// MODULE: PENDING ORDER ON OR LOCK (optional, InpUsePendingOR)
//============================================================
// Cancels sess's OR-lock pending stop order, if any, and clears its ticket.
void CancelPendingOR(int sess, string reason)
  {
   if(pendingORTicket[sess] == 0)
      return;
   if(OrderSelect(pendingORTicket[sess]))
     {
      if(Trade.OrderDelete(pendingORTicket[sess]))
         LogMsg(SESS_NAME[sess] + " PENDING ORDER cancelled — " + reason);
     }
   pendingORTicket[sess] = 0;
  }

// Places (and maintains) a Buy/Sell Stop the instant a session's OR locks, in the direction of
// GetEntryBiasForLogic() (daily bias when InpUseDailyBias, else HTF bias) — skipped entirely
// while that bias is neutral. Only applies to sessions running plain ORB logic, or SMC sessions
// that already timed out into ORB fallback (UsesSMC(sess)==false || orbFallbackActive[sess]);
// sessions still working through the SMC sweep→structure→zone pipeline are left untouched.
//
// Unlike the existing breakout path (DetectBasicSignals -> TradeEngine market order), which
// waits for a confirmed bar close beyond the OR before entering, this places the stop order the
// moment OR locks so it fills the instant price actually reaches the level — faster, but more
// exposed to a false-break wick than the confirm-close path. That tradeoff is why this is opt-in
// (InpUsePendingOR=false by default) instead of replacing the existing entry logic outright.
void ManagePendingOR(int sess)
  {
   if(!InpUsePendingOR)
      return;
   if(!IsSessEnabled(sess))
      return;
// 1. Sync first: has our own tracked order left the book (filled, cancelled, or expired)?
//    ReconcileSessTradeCount() picks up a fill exactly like a market-order entry would — it
//    scans live positions and sets tradeBuyDone/tp1Level/sessTicket/sessTradeCount from
//    whatever is actually open, so BE/partial-TP/trailing management works the same either way.
   if(pendingORTicket[sess] != 0 && !OrderSelect(pendingORTicket[sess]))
     {
      pendingORTicket[sess] = 0;
      ReconcileSessTradeCount();
      LogMsg(SESS_NAME[sess] + " PENDING ORDER left the book (filled/expired) — state reconciled");
     }
   bool eligible = !UsesSMC(sess) || orbFallbackActive[sess];
   bool alreadyTraded = tradeBuyDone[sess] || tradeSellDone[sess] || sessTradeCount[sess] >= InpMaxTrades;
   if(!eligible || alreadyTraded)
     {
      CancelPendingOR(sess, !eligible ? "session now running SMC pipeline" : "session already traded");
      return;
     }
   if(!IsORBLocked(sess))
      return; // OR not closed/valid yet — nothing to place
   MqlDateTime tm;
   TimeToStruct(TimeGMT(), tm);
   if(tm.hour * 60 + tm.min >= GetSessCutoff(sess))
     {
      CancelPendingOR(sess, "session cutoff reached");
      return;
     }
   ENUM_BIAS trendBias = GetEntryBiasForLogic();
   double atr = GetATR(1);
   double orH = GetSessORH(sess), orL = GetSessORL(sess);
   double buf = atr * InpPendingOR_Buffer;

   ENUM_ORDER_TYPE wantType = WRONG_VALUE;
   bool isBuy = false;
   if(alertBuy[sess] || GetBkUp(sess) || (InpUseDailyBias && dailyBias == BIAS_BULLISH))
     {
      isBuy = true;
      wantType = (InpPendingType == PENDING_LIMIT) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_BUY_STOP;
     }
   else if(alertSell[sess] || GetBkDn(sess) || (InpUseDailyBias && dailyBias == BIAS_BEARISH))
     {
      isBuy = false;
      wantType = (InpPendingType == PENDING_LIMIT) ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_SELL_STOP;
     }
   else if(trendBias == BIAS_BULLISH)
     {
      isBuy = true;
      wantType = (InpPendingType == PENDING_LIMIT) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_BUY_STOP;
     }
   else if(trendBias == BIAS_BEARISH)
     {
      isBuy = false;
      wantType = (InpPendingType == PENDING_LIMIT) ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_SELL_STOP;
     }

   if(wantType == WRONG_VALUE)
      return;

// 2. Already have a live order for this session — confirm it still matches the wanted
//    direction (bias can flip on a new HTF/daily bar); otherwise cancel and re-place below.
   if(pendingORTicket[sess] != 0)
     {
      if(OrderSelect(pendingORTicket[sess]))
        {
         if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != wantType)
            CancelPendingOR(sess, "daily/HTF bias flipped direction");
         else
            return; // still valid — nothing to do this call
        }
     }
// 3. Nothing placed yet — respect the same single-trade-slot rule as every other entry path.
   if(HasOpenOrPendingTrade())
      return;

   if(atr <= 0 || orH <= 0 || orL <= 0 || orH <= orL)
      return;

   double price = (InpPendingType == PENDING_LIMIT) ? (isBuy ? orL + buf : orH - buf) : (isBuy ? orH + buf : orL - buf);
   double slDist, tpDist;
   CalcSLTPDist(sess, isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                price, atr, orH, orL, slDist, tpDist);
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl, tp;
   if(isBuy)
     {
      sl = NormalizeDouble(price - slDist, digs);
      tp = NormalizeDouble(price + tpDist, digs);
     }
   else
     {
      sl = NormalizeDouble(price + slDist, digs);
      tp = NormalizeDouble(price - tpDist, digs);
     }
   double lot = CalcRiskLot(slDist);
   string dir = isBuy ? "BUY_" + EnumToString(InpPendingType) : "SELL_" + EnumToString(InpPendingType);
   string cmt = "ORB_SMC_" + SESS_NAME[sess] + "_" + dir;
   bool ok = false;
   if(wantType == ORDER_TYPE_BUY_STOP)
      ok = Trade.BuyStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt);
   else if(wantType == ORDER_TYPE_BUY_LIMIT)
      ok = Trade.BuyLimit(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt);
   else if(wantType == ORDER_TYPE_SELL_LIMIT)
      ok = Trade.SellLimit(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt);
   else if(wantType == ORDER_TYPE_SELL_STOP)
      ok = Trade.SellStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt);

   if(ok)
     {
      pendingORTicket[sess] = Trade.ResultOrder();
      string msg = StringFormat("%s|OR-LOCK PENDING %s %s|Trigger:%.5f SL:%.5f TP:%.5f RR:%.1f Lot:%.2f",
                                _Symbol, SESS_NAME[sess], dir, price, sl, tp, tpDist / slDist, lot);
      LogMsg("PENDING:" + msg);
      if(InpAlerts)
         Alert(msg);
     }
   else
      LogMsg(StringFormat("PENDING FAIL|%s %s|%d|%s", SESS_NAME[sess], dir, Trade.ResultRetcode(), Trade.ResultRetcodeDescription()));
  }

//============================================================
// MODULE: RISK MANAGEMENT
//============================================================

// ── Per-tick: partial TP + BE ────────────────────────────────────────────────
// Runs on every tick for immediate protection.
// Trailing stop and Dynamic TP are intentionally excluded — see ManagePositions_Bar().
//
// Rationale: BE and partial TP must react within the current tick to prevent a
// profitable position from reversing into a loss within a single bar.
// Trailing stop runs per-bar to avoid being triggered by intra-bar wicks and
// pullbacks that are normal for ORB moves.
void ManagePositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PosInfo.SelectByIndex(i))
         continue;
      if(PosInfo.Symbol() != _Symbol)
         continue;
      ulong ticket = PosInfo.Ticket();
      int sess = GetSessFromCmt(PosInfo.Time());
      // Partial TP: close 50% at 1R; sets BE immediately after close.
      // gJustPartialed[sess] is set here and guards ManagePositions_Bar() on this tick.
      if(InpPartialTP && sess >= 0)
        {
         bool wasTaken = partialTaken[sess];
         ApplyPartialTP(ticket, sess);
         if(!wasTaken && partialTaken[sess])
            continue; // position data stale after PositionClosePartial — skip BE this tick
        }
      // BE only — trailing handled in ManagePositions_Bar()
      if(sess >= 0 && InpBreakeven)
        {
         if(!PosInfo.SelectByTicket(ticket))
            continue;
         bool isBuy = (PosInfo.PositionType() == POSITION_TYPE_BUY);
         double beSL = CalcBE_SL(ticket);
         if(beSL > 0 && PosInfo.SelectByTicket(ticket))
           {
            double curSL = PosInfo.StopLoss();
            bool regresses = isBuy ? (curSL > 0 && beSL <= curSL)
                             : (curSL > 0 && beSL >= curSL);
            if(!regresses)
               Trade.PositionModify(ticket, beSL, PosInfo.TakeProfit());
           }
        }
     }
  }

// ── Per-bar: trailing stop + dynamic TP ─────────────────────────────────────
// Runs only when a new LTF bar closes.
//
// Rationale: updating trail on every tick chases intra-bar wicks and normal
// pullbacks within an ORB move, causing premature exits before the full target
// is reached. Bar-close trail updates track CONFIRMED price progress only.
// Dynamic TP reads bars[1] (completed bar data) and produces identical results
// for all ticks in the same bar — per-bar execution avoids redundant broker calls.
void ManagePositions_Bar()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PosInfo.SelectByIndex(i))
         continue;
      if(PosInfo.Symbol() != _Symbol)
         continue;
      ulong ticket = PosInfo.Ticket();
      int sess = GetSessFromCmt(PosInfo.Time());
      if(sess < 0)
         continue;
      // Skip if partial TP fired this same tick — position data may be stale
      if(gJustPartialed[sess])
         continue;
      if(!PosInfo.SelectByTicket(ticket))
         continue;
      bool isBuy = (PosInfo.PositionType() == POSITION_TYPE_BUY);
      // Trailing stop
      if(InpTrailingStop)
        {
         double trailSL = CalcTrail_SL(ticket, sess);
         if(trailSL > 0 && PosInfo.SelectByTicket(ticket))
           {
            double curSL = PosInfo.StopLoss();
            bool regresses = isBuy ? (curSL > 0 && trailSL <= curSL)
                             : (curSL > 0 && trailSL >= curSL);
            if(!regresses)
               Trade.PositionModify(ticket, trailSL, PosInfo.TakeProfit());
           }
        }
      // Dynamic TP: volume surge (extend) / exhaust (tighten) — reads closed-bar data
      if(InpDynTP)
         AdjustDynamicTP(ticket, sess);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsTimeInWindow(datetime t, datetime start, datetime end)
  {
   if(start == end)
      return false;
   if(end > start)
      return t >= start && t < end;
   return t >= start || t < end;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsMinuteInWindow(int minute, int start, int end)
  {
   if(start == end)
      return false;
   if(end > start)
      return minute >= start && minute < end;
   return minute >= start || minute < end;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int GetSessFromCmt(datetime t)
  {
   if(t <= 0)
     {
      LogMsg("SESSION|invalid order time");
      return -1;
     }
   MqlDateTime tm;
   TimeToStruct(t, tm);
   int minute = tm.hour * 60 + tm.min;
   int asS = InpAsiaH_Start * 60 + InpAsiaM_Start, asE = InpAsiaH_End * 60 + InpAsiaM_End;
   int lnS = InpLondonH_S * 60 + InpLondonM_S, lnE = InpLondonH_E * 60 + InpLondonM_E;
   int nyStartH = (InpNY_StockMode ? 14 : InpNYH_S);
   int nyStartM = (InpNY_StockMode ? 30 : InpNYM_S);
   int nyS = nyStartH * 60 + nyStartM, nyE = InpNYH_E * 60 + InpNYM_E;
   int matchedCount = 0;
   int matchedSess = -1;
   if(IsMinuteInWindow(minute, asS, asE))
     {
      matchedCount++;
      matchedSess = SESS_ASIA;
     }
   if(IsMinuteInWindow(minute, lnS, lnE))
     {
      matchedCount++;
      if(matchedSess < 0)
         matchedSess = SESS_LONDON;
     }
   if(IsMinuteInWindow(minute, nyS, nyE))
     {
      matchedCount++;
      if(matchedSess < 0)
         matchedSess = SESS_NY;
     }
   if(matchedCount == 0)
     {
      LogMsg(StringFormat("SESSION|no match|time=%s|minute=%d", TimeToString(t, TIME_DATE | TIME_SECONDS), minute));
      return -1;
     }
   if(matchedCount > 1)
     {
      LogMsg(StringFormat("SESSION|overlap|time=%s|minute=%d|priority=%s",
                          TimeToString(t, TIME_DATE | TIME_SECONDS),
                          minute,
                          SESS_NAME[matchedSess]));
     }
   return matchedSess;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ApplyPartialTP(ulong ticket, int sess)
  {
   if(partialTaken[sess] || tp1Level[sess] <= 0)
      return;
   if(!PosInfo.SelectByTicket(ticket))
      return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool hit = (PosInfo.PositionType() == POSITION_TYPE_BUY && bid >= tp1Level[sess]) ||
              (PosInfo.PositionType() == POSITION_TYPE_SELL && ask <= tp1Level[sess]);
   if(!hit)
      return;
   double half = NormalizeLot(PosInfo.Volume() * 0.5);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(half < minLot)
      return; // position too small to split — skip partial
   if((PosInfo.Volume() - half) < minLot)
      return; // residual after partial close would be below broker minimum
   if(Trade.PositionClosePartial(ticket, half))
     {
      partialTaken[sess] = true;
      gJustPartialed[sess] = true; // guard ManagePositions_Bar() from running trail this same tick
      LogMsg(SESS_NAME[sess] + " PARTIAL TP@" + DoubleToString(tp1Level[sess], _Digits));
      // BUG3 FIX: re-select position after PositionClosePartial — the PosInfo cache is
      //           stale after partial close; some brokers reset SL/TP on partial close.
      //           Reading TakeProfit() from stale cache risks passing wrong value to Modify.
      if(!PosInfo.SelectByTicket(ticket))
         return;
      int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double pt = _Point;
      double measure = GetBEMeasure();
      double minStp = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * pt;
      double off = (measure > 0) ? MathMax(InpBE_Offset * measure, minStp) : minStp;
      bool isBuy = (PosInfo.PositionType() == POSITION_TYPE_BUY);
      // Set SL directly to open ± offset (skip the 0-pip interim step)
      double be = NormalizeDouble(PosInfo.PriceOpen() + (isBuy ? off : -off), digs);
      double tp = PosInfo.TakeProfit();
      Trade.PositionModify(ticket, be, tp);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
// Returns desired BE stop-loss level, or 0 if no change needed.
// gBETrigger / InpBE_Offset are ATR/CMR multipliers (not pips).
double CalcBE_SL(ulong ticket)
  {
   if(!PosInfo.SelectByTicket(ticket))
      return 0;
   double measure = GetBEMeasure();
   if(measure <= 0)
      return 0;
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pt = _Point;
   double opn = PosInfo.PriceOpen();
   double sl = PosInfo.StopLoss();
   double trig = gBETrigger * measure;
   double minStp = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * pt;
   double off = MathMax(InpBE_Offset * measure, minStp);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(PosInfo.PositionType() == POSITION_TYPE_BUY)
     {
      if(bid < opn + trig)
         return 0;
      double be = NormalizeDouble(opn + off, digs);
      double maxBE = NormalizeDouble(bid - minStp, digs);
      if(be > maxBE)
         be = maxBE;
      if(be <= opn || sl >= be)
         return 0;
      return be;
     }
   else
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask > opn - trig)
         return 0;
      double be = NormalizeDouble(opn - off, digs);
      double minBE = NormalizeDouble(ask + minStp, digs);
      if(be < minBE)
         be = minBE;
      if(be >= opn)
        {
         LogMsg("BE SELL skip: spread+stops prevent safe BE (ask=" + DoubleToString(ask, _Digits) + " opn=" + DoubleToString(opn, _Digits) + ")");
         return 0;
        }
      if(sl > 0 && sl <= be)
         return 0;
      return be;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
// Returns desired trailing stop-loss level, or 0 if no change needed.
// Trail activates after partial TP is taken — OR immediately if BE has
// already locked profit (SL is beyond open), preventing gaps in protection.
double CalcTrail_SL(ulong ticket, int sess)
  {
   if(sess < 0 || sess >= SESS_COUNT)
      return 0;
   if(!PosInfo.SelectByTicket(ticket))
      return 0;
   double measure = GetBEMeasure();
   if(measure <= 0)
      return 0;
   if(InpPartialTP && !partialTaken[sess])
     {
      double sl = PosInfo.StopLoss();
      double opn = PosInfo.PriceOpen();
      bool buy = (PosInfo.PositionType() == POSITION_TYPE_BUY);
      // Fallback 1: BE has already moved SL into profit territory
      bool beLocked = (buy && sl > opn) || (!buy && sl > 0 && sl < opn);
      // Fallback 2: profit has reached BE trigger distance (ATR/CMR)
      // Ensures trail activates even when BE is disabled or TP1 was never hit
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask2 = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitDist = buy ? (bid - opn) : (opn - ask2);
      bool profitSufficient = (profitDist >= gBETrigger * measure);
      if(!beLocked && !profitSufficient)
         return 0;
     }
   double pt = _Point;
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minStp = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * pt;
// Clamp to 1.5× broker minimum stop to prevent silent PositionModify failure
   double trail = MathMax(measure * gTrailATR, minStp * 1.5);
   if(PosInfo.PositionType() == POSITION_TYPE_BUY)
     {
      double nsl = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID) - trail, digs);
      if(nsl > PosInfo.StopLoss() && nsl > PosInfo.PriceOpen())
         return nsl;
     }
   else
     {
      double nsl = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK) + trail, digs);
      if((PosInfo.StopLoss() == 0 || nsl < PosInfo.StopLoss()) && nsl < PosInfo.PriceOpen())
         return nsl;
     }
   return 0;
  }

//============================================================
// MODULE: DYNAMIC TP
//============================================================
// Adjusts open position TP based on real-time volume strength and spread liquidity.
//
// SURGE  (volRatio >= InpDynTP_Surge  + tight spread):
//   Strong institutional flow detected — extend TP toward MaxRR to ride the move.
//
// EXHAUST (volRatio <= InpDynTP_Exhaust + partial taken + profit >= 1.5R):
//   Volume drying up after a push — tighten TP to lock remaining profit quickly.
//
// Both paths are ratchet-only: TP can only move in the profit direction, never retreat.
// oneR is derived from tp1Level[sess] set at trade entry (entry ± slDist).
void AdjustDynamicTP(ulong ticket, int sess)
  {
   if(!InpDynTP || sess < 0 || sess >= SESS_COUNT)
      return;
   if(tp1Level[sess] <= 0)
      return;
   if(!PosInfo.SelectByTicket(ticket))
      return;
   double opn = PosInfo.PriceOpen();
   double tp = PosInfo.TakeProfit();
   double sl = PosInfo.StopLoss();
   double oneR = MathAbs(tp1Level[sess] - opn);
   if(oneR <= 0)
      return;
   bool isBuy = (PosInfo.PositionType() == POSITION_TYPE_BUY);
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
// ── Volume ratio: last completed bar vs MA of previous VMA bars ──────────
// Use ORBTF — matches breakout execution context regardless of chart TF.
// FIX: loop starts at i=2 so bars[1] (comparison bar) is excluded from the MA;
//      self-inclusion suppresses surge/exhaust ratios by inflating the denominator.
   MqlRates bars[];
   ArraySetAsSeries(bars, true);
   int needed = InpDynTP_VMA + 2; // bars[0]=live, bars[1]=compare, bars[2..VMA+1]=MA period
   if(CopyRates(_Symbol, ORBTF, 0, needed, bars) < needed)
      return;
   double volSum = 0;
   for(int i = 2; i <= InpDynTP_VMA + 1; i++)
      volSum += (double)bars[i].tick_volume;
   double volMA = volSum / InpDynTP_VMA;
   if(volMA <= 0)
      return;
   double volRatio = (double)bars[1].tick_volume / volMA; // last completed bar vs prior MA
// ── Liquidity proxy: spread relative to ATR ──────────────────────────────
   double atr = GetATR(1);
   double spd = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   bool liquidOK = (atr > 0) ? (spd / atr < 0.20) : true; // spread < 20% of ATR
// ── Current profit in R-multiples ────────────────────────────────────────
// FIX: SELL closes at ASK — using BID over-estimates profit by one spread.
   double profitR = isBuy ? (bid - opn) / oneR : (opn - ask) / oneR;
// ── SURGE: extend TP ──────────────────────────────────────────────────────
// Directional filter: surge bar must close in the trade direction.
// A high-volume bar closing against the trade is a reversal signal, not continuation.
   bool surgeAligned = isBuy ? (bars[1].close >= bars[1].open)
                       : (bars[1].close <= bars[1].open);
   if(volRatio >= InpDynTP_Surge && liquidOK && surgeAligned)
     {
      double newTP = isBuy
                     ? NormalizeDouble(opn + oneR * InpDynTP_MaxRR, digs)
                     : NormalizeDouble(opn - oneR * InpDynTP_MaxRR, digs);
      // Ratchet: only move TP further out, never pull it back
      bool extend = isBuy ? (tp <= 0 || newTP > tp) : (tp <= 0 || newTP < tp);
      if(extend)
        {
         lastSurgeBar[sess] = bars[1].time; // start EXHAUST cooldown from this bar
         gDynTPState[sess] = 1;
         LogMsg(StringFormat("DynTP SURGE %s|VolR:%.2f|NewTP:%.5f → %.1fR (was %.5f)",
                             SESS_NAME[sess], volRatio, newTP, InpDynTP_MaxRR, tp));
         Trade.PositionModify(ticket, sl, newTP);
        }
      return; // surge and exhaust are mutually exclusive in one tick
     }
// ── EXHAUST: tighten TP to capture remaining profit ───────────────────────
// Only activate when: volume clearly exhausted + partial secured + trade well in profit
// COOLDOWN: block EXHAUST for VMA bars after SURGE — the bar immediately after a surge
// almost always has lower volume, which would instantly undo the surge TP extension.
   bool surgeRecent = (lastSurgeBar[sess] > 0 &&
                       (int)((TimeCurrent() - lastSurgeBar[sess]) / PeriodSeconds(ORBTF)) < InpDynTP_VMA);
   if(volRatio <= InpDynTP_Exhaust && partialTaken[sess] && profitR >= 1.5 && !surgeRecent)
     {
      // Set TP at current price + 0.3R in the trade direction (catch drift without giving back much)
      // AUDIT FIX: SELL positions close at ASK, not BID (profitR above already accounts for
      // this correctly) — anchoring the new TP off bid under-priced it relative to the real
      // exit price, risking a TP too close to Ask (broker rejects PositionModify) on
      // wide-spread symbols like XAU.
      double newTP = isBuy
                     ? NormalizeDouble(bid + oneR * 0.3, digs)
                     : NormalizeDouble(ask - oneR * 0.3, digs);
      // Ratchet: for BUY tighten means newTP < current tp but still above bid
      // For SELL tighten means newTP > current tp but still below ask
      bool tighten;
      if(isBuy)
         tighten = (tp <= 0 || newTP < tp) && newTP > bid;
      else
         tighten = (tp <= 0 || newTP > tp) && newTP < ask;
      if(tighten)
        {
         gDynTPState[sess] = -1;
         LogMsg(StringFormat("DynTP EXHAUST %s|VolR:%.2f|ProfitR:%.1f|NewTP:%.5f (was %.5f)",
                             SESS_NAME[sess], volRatio, profitR, newTP, tp));
         Trade.PositionModify(ticket, sl, newTP);
        }
     }
  }

//============================================================
// MODULE: VOLATILITY REGIME & ENHANCEMENT FUNCTIONS
//============================================================
void UpdateVolatilityRegime()
  {
   if(!newBarORB)
      return;
   MqlRates d1[2];
   ArraySetAsSeries(d1, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 2, d1) < 2)
      return;
// FIX 1: gate to once per D1 bar — previous code shifted every M15 bar,
//         flooding the 20-slot buffer with one day's range within hours
   if(d1[0].time == lastVolatilityDay)
     {
      // Array unchanged; still update regime ratio against current ATR
      double currentATR = GetATR(1);
      if(currentATR > 0 && dailyATRAvg > 0)
        {
         double ratio = currentATR / dailyATRAvg;
         if(ratio < InpVolMin)
            volRegime = VOL_CALM;
         else
            if(ratio >= InpVolMax)
               volRegime = VOL_EXPLOSIVE;
            else
               if(ratio >= InpVolMax * 0.70)
                  volRegime = VOL_HIGH;
               else
                  volRegime = VOL_NORMAL;
        }
      return;
     }
   lastVolatilityDay = d1[0].time;
// Shift history and store TODAY's M15 ATR (same scale as currentATR comparison below).
// BUG FIX: previous code stored D1 high-low range here but compared against M15 ATR,
// causing ratio ≈ 0.15-0.25 which is always below InpVolMin(0.5) → VOL_CALM → no entries.
   for(int i = 19; i > 0; i--)
      dailyATR_Array[i] = dailyATR_Array[i - 1];
   dailyATR_Array[0] = GetATR(1); // M15 ATR — same scale as ratio comparison
// Average only filled slots to avoid zero-inflation during EA startup period
   double sum = 0;
   int cnt = 0;
   for(int i = 0; i < 20; i++)
      if(dailyATR_Array[i] > 0)
        {
         sum += dailyATR_Array[i];
         cnt++;
        }
   dailyATRAvg = (cnt > 0) ? sum / cnt : 0;
// Detect regime
   double currentATR = GetATR(1);
   if(currentATR > 0 && dailyATRAvg > 0)
     {
      double ratio = currentATR / dailyATRAvg;
      if(ratio < InpVolMin)
         volRegime = VOL_CALM;
      else
         if(ratio >= InpVolMax)
            volRegime = VOL_EXPLOSIVE;
         else
            if(ratio >= InpVolMax * 0.70)
               volRegime = VOL_HIGH;
            else
               volRegime = VOL_NORMAL;
     }
  }

//+------------------------------------------------------------------+
// Count how many confirmations pass
//+------------------------------------------------------------------+
// smcConfirmed: true when this call is scoring a session where
// UsesSMC(sess) && smcState[sess]==SMC_CONFIRMED — i.e. SMC_PriceInZone's
// own momentumOK/htfMomentumOK already guaranteed sub-checks #1 and #4
// (SMC_PriceInZone's momentumOK is a strict superset of #1's condition;
// its htfMomentumOK is identical to #4's condition when InpHTFMomentum is
// on, and #4 trivially passes when it's off regardless). Counting them
// again would give SMC-confirmed entries a floor they didn't earn. BOS
// (#2) and wick (#3) are NOT pre-gated — SMC_PriceInZone deliberately
// removed those checks (see the comment inside SMC_PriceInZone) — so they
// still count in both modes. Defaults to false so CheckConfirmationMode's
// existing call (always for non-SMC entries) is unaffected.
int CountConfirmations(int sess, bool bul, bool smcConfirmed = false)
  {
// FIX: guard against fresh chart / daily-reset edge case where array has <3 bars
   if(ArraySize(ratesORB) < 3)
      return 0;
   int count = 0;
// 1. Momentum confirmation — skipped when smcConfirmed (see comment above)
   if(!smcConfirmed)
     {
      if((bul && ratesORB[1].close > ratesORB[2].close) ||
         (!bul && ratesORB[1].close < ratesORB[2].close) ||
         (bul && ratesORB[1].close > ratesORB[1].open) ||
         (!bul && ratesORB[1].close < ratesORB[1].open))
         count++;
     }
// 2. BOS confirmation — never redundant, still counts in both modes
   if(!InpBOSConfirm || (bul && ratesORB[1].close > bosLvl[sess]) || (!bul && ratesORB[1].close < bosLvl[sess]))
      count++;
// 3. Wick rejection — never redundant, still counts in both modes
   if(!InpWickReject)
      count++;
   else
     {
      double o1 = ratesORB[1].open, c1 = ratesORB[1].close;
      double body = MathAbs(c1 - o1);
      if(bul)
        {
         double lowerWick = MathMin(o1, c1) - ratesORB[1].low; // FIX: was open-low (wrong for bear body)
         if(body > 0 && lowerWick / body >= InpWickRatio - 1.0)
            count++;
        }
      else
        {
         double upperWick = ratesORB[1].high - MathMax(o1, c1); // FIX: was high-open (wrong for bull body)
         if(body > 0 && upperWick / body >= InpWickRatio - 1.0)
            count++;
        }
     }
// 4. HTF momentum — skipped when smcConfirmed (see comment above)
   if(!smcConfirmed)
     {
      if(!InpHTFMomentum)
         count++;
      else
        {
         if((bul && (htfBias == BIAS_BULLISH || htfBias == BIAS_NEUTRAL)) ||
            (!bul && (htfBias == BIAS_BEARISH || htfBias == BIAS_NEUTRAL)))
            count++;
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
// Check if a given direction meets the confirmation mode requirements
//+------------------------------------------------------------------+
bool CheckConfirmationModeForDirection(int sess, bool isBuy)
  {
   int confirmCount = CountConfirmations(sess, isBuy);
   switch(gConfirmMode)
     {
      case CONFIRM_STRICT:
         return (confirmCount >= 4); // All 4 confirmations
      case CONFIRM_BALANCED:
         return (confirmCount >= 2); // At least 2 of 4
      case CONFIRM_LOOSE:
         return (confirmCount >= 1); // At least 1 of 4
      default:
         return true;
     }
  }

//+------------------------------------------------------------------+
// Backward-compatible wrapper used by existing SMC/summary checks
//+------------------------------------------------------------------+
bool CheckConfirmationMode(int sess)
  {
   bool bul = UsesSMC(sess) ? setupBull[sess] : GetBkUp(sess);
   return CheckConfirmationModeForDirection(sess, bul);
  }

//+------------------------------------------------------------------+
//============================================================
// MODULE: NEWS FILTER with Dynamic State Reset
//============================================================
bool IsHighImpactNews()
  {
// Strategy tester: MqlCalendar data is often incomplete for historical dates,
// causing spurious blocks. Skip the news filter entirely when backtesting.
   if((bool)MQLInfoInteger(MQL_TESTER))
      return false;
   datetime now = TimeCurrent();
   if(now - newsLastCheck < 60)
      return newsBlocked;
   newsLastCheck = now;
   bool prevBlocked = newsBlocked;
   newsBlocked = false;
   newsEventTime = 0;
   newsNextTime = 0;
   datetime utcNow = TimeGMT();
   MqlCalendarValue vals[];
   int n = CalendarValueHistory(vals, utcNow - (datetime)(InpNewsBefore * 60), utcNow + (datetime)(InpNewsAfter * 60), NULL, NULL);
   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(CalendarEventById(vals[i].event_id, ev) && ev.importance == CALENDAR_IMPORTANCE_HIGH)
        {
         newsBlocked = true;
         newsEventTime = vals[i].time;
         // ENHANCEMENT: Dynamic state reset on high-impact news
         if(InpDynamicNewsReset && !prevBlocked)
           {
            for(int s = 0; s < SESS_COUNT; s++)
              {
               if(newsEventTriggered[s] == false)
                 {
                  ResetSMCState(s);
                  newsEventTriggered[s] = true; // Mark event triggered
                  LogMsg(SESS_NAME[s] + " STATE RESET: High-impact news detected!");
                 }
              }
           }
         break;
        }
     }
// When clear, scan ahead 4 hours for next upcoming high-impact event
   if(!newsBlocked)
     {
      MqlCalendarValue fwd[];
      int nf = CalendarValueHistory(fwd, utcNow, utcNow + (datetime)(4 * 3600), NULL, NULL);
      for(int i = 0; i < nf; i++)
        {
         MqlCalendarEvent ev;
         if(CalendarEventById(fwd[i].event_id, ev) && ev.importance == CALENDAR_IMPORTANCE_HIGH)
           {
            newsNextTime = fwd[i].time;
            break;
           }
        }
     }
// Clear news event flag when news window closes
   if(!newsBlocked)
     {
      for(int s = 0; s < SESS_COUNT; s++)
         newsEventTriggered[s] = false;
     }
   return newsBlocked;
  }

//============================================================
// MODULE: DAILY PIVOT POINTS
//============================================================
void CalcDailyPivots()
  {
// Reset first so stale values do not survive a failed or missing daily-bar read.
   ppPP = ppR1 = ppR2 = ppR3 = ppS1 = ppS2 = ppS3 = 0;
   ppDayStart = 0;
// Source: PREVIOUS completed daily candle (offset=1 skips the forming bar)
// d1[0] = yesterday closed bar — standard pivot source
   MqlRates d1[];
   ArraySetAsSeries(d1, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, d1) < 1)
      return;
   double H = d1[0].high, L = d1[0].low, C = d1[0].close;
   ppPP = NormalizeDouble((H + L + C) / 3.0, _Digits);
   ppR1 = NormalizeDouble(2 * ppPP - L, _Digits);
   ppR2 = NormalizeDouble(ppPP + (H - L), _Digits);
   ppR3 = NormalizeDouble(ppR1 + (H - L), _Digits);
   ppS1 = NormalizeDouble(2 * ppPP - H, _Digits);
   ppS2 = NormalizeDouble(ppPP - (H - L), _Digits);
   ppS3 = NormalizeDouble(ppS1 - (H - L), _Digits);
// Store today's server-day start for line anchoring.
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   tm.hour = 0;
   tm.min = 0;
   tm.sec = 0;
   ppDayStart = StructToTime(tm);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawPivotPoints()
  {
   ObjectsDeleteAll(0, "PP_");
   if(!InpDrawPivots || ppPP <= 0)
      return;
// Lines span from today midnight (server) to next day midnight (server)
// This keeps pivot lines cleanly bound to the current trading day
   datetime dayS = ppDayStart > 0 ? ppDayStart : TimeCurrent() - (datetime)(3600 * 12);
   datetime dayE = dayS + (datetime)(3600 * 24);
// Draw levels with increasing visual weight (R3/S3 lightest, Pivot thickest)
   if(InpPivotR3S3)
     {
      DrawPivotLine("PP_R3", ppR3, "R3", AdjustAlpha(InpClrResist, 140), STYLE_DOT, 1, dayS, dayE);
      DrawPivotLine("PP_S3", ppS3, "S3", AdjustAlpha(InpClrSupport, 140), STYLE_DOT, 1, dayS, dayE);
     }
   DrawPivotLine("PP_R2", ppR2, "R2", AdjustAlpha(InpClrResist, 180), STYLE_DASH, 1, dayS, dayE);
   DrawPivotLine("PP_S2", ppS2, "S2", AdjustAlpha(InpClrSupport, 180), STYLE_DASH, 1, dayS, dayE);
   DrawPivotLine("PP_R1", ppR1, "R1", InpClrResist, STYLE_DASH, 2, dayS, dayE);
   DrawPivotLine("PP_S1", ppS1, "S1", InpClrSupport, STYLE_DASH, 2, dayS, dayE);
   DrawPivotLine("PP_PP", ppPP, "P", InpClrPivot, STYLE_SOLID, 2, dayS, dayE);
  }

// Soften color for secondary levels (R2/S2, R3/S3)
color AdjustAlpha(color clr, int strength)
  {
   int r = (int)((clr >> 16) & 0xFF) * strength / 255;
   int g = (int)((clr >> 8) & 0xFF) * strength / 255;
   int b = (int)(clr & 0xFF) * strength / 255;
   return (color)((r << 16) | (g << 8) | b);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawPivotLine(string name, double price, string lbl, color clr, ENUM_LINE_STYLE style, int width, datetime t1, datetime t2)
  {
   if(price <= 0)
      return;
   DrawHLine(name, t1, t2, price, clr, style, width);
   if(InpPivotLabel)
     {
      // Label on the right side with R/S level badge style
      string badge = StringFormat(" %s  %s", lbl, DoubleToString(price, _Digits));
      DrawTextObj("PP_LBL_" + lbl, t2 - (datetime)(PeriodSeconds(ORBTF) * 4), price, badge, clr, 10);
     }
  }

//============================================================
// MODULE: EQ LEVELS DRAWING
//============================================================

// Returns true if price/isHigh combo is marked swept in any session's liqLevels[].
// Uses 3-point tolerance for float safety (prices come from the same ratesORB source).
bool IsEQLevelSwept(double price, bool isHigh)
  {
   double tol = _Point * 3;
   for(int s = 0; s < SESS_COUNT; s++)
      for(int k = 0; k < liqCount[s]; k++)
         if(liqLevels[s][k].isHigh == isHigh &&
            liqLevels[s][k].swept &&
            MathAbs(liqLevels[s][k].price - price) < tol)
            return true;
   return false;
  }

// Returns a dimmed version of color c at factor f (0.0 = black, 1.0 = original).
color DimColor(color c, double f = 0.42)
  {
   return (color)(((int)(((c >> 16) & 0xFF) * f) << 16) |
                  ((int)(((c >> 8) & 0xFF) * f) << 8) |
                  (int)((c & 0xFF) * f));
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawEQHL()
  {
   ObjectsDeleteAll(0, "EQ_");
   if(!InpDrawObjects || !InpDrawEQHL || eqCount == 0)
      return;
   datetime extEnd = TimeCurrent() + (datetime)(PeriodSeconds(ORBTF) * 6);
   for(int i = 0; i < eqCount; i++)
     {
      bool swept = IsEQLevelSwept(eqLevels[i].price, eqLevels[i].isHigh);
      color clrBase = eqLevels[i].isHigh ? InpClrEQH : InpClrEQL;
      color clr = swept ? DimColor(clrBase) : clrBase;
      string tag = eqLevels[i].isHigh ? "EQH" : "EQL";
      string pfx = "EQ_" + tag + "_" + string(i);
      ENUM_LINE_STYLE ls = swept ? STYLE_DOT : STYLE_DASH;
      // Line from older swing to right edge — dotted + dimmed when swept
      DrawHLine(pfx + "_L", eqLevels[i].t1, extEnd, eqLevels[i].price, clr, ls, 1);
      // Dot markers at each equal swing point
      DrawTextObj(pfx + "_D1", eqLevels[i].t1, eqLevels[i].price, "●", clr, 8);
      DrawTextObj(pfx + "_D2", eqLevels[i].t2, eqLevels[i].price, "●", clr, 8);
      // Label at right edge
      if(InpDrawLabels)
        {
         string badge = swept
                        ? StringFormat(" ≡%s  %s  ✓SWEPT", tag, DoubleToString(eqLevels[i].price, _Digits))
                        : StringFormat(" ≡%s  %s", tag, DoubleToString(eqLevels[i].price, _Digits));
         DrawTextObj(pfx + "_LBL", extEnd - (datetime)(PeriodSeconds(ORBTF) * 1), eqLevels[i].price, badge, clr, 9);
        }
     }
  }

//============================================================
// MODULE: VOLUME PROFILE
//============================================================
void BuildVolumeProfile()
  {
   vpReady = false;
   vpMaxVol = 0;
   vpPOC = vpVAH = vpVAL = 0;
   vpRangeL = 0;
   vpBinSize = 0;
   ArrayResize(vpVolArr, 0);
   int bars = MathMin(InpVP_Bars, ArraySize(ratesORB));
   if(bars < 5)
      return;
   int bins = MathMax(5, InpVP_Bins);
   double rH = -DBL_MAX, rL = DBL_MAX;
   for(int i = 0; i < bars; i++)
     {
      if(ratesORB[i].high > rH)
         rH = ratesORB[i].high;
      if(ratesORB[i].low < rL)
         rL = ratesORB[i].low;
     }
   if(rH <= rL)
      return;
   vpRangeL = rL;
   vpBinSize = (rH - rL) / bins;
   if(vpBinSize <= 0)
      return;
   ArrayResize(vpVolArr, bins);
   ArrayInitialize(vpVolArr, 0);
   for(int i = 0; i < bars; i++)
     {
      double h = ratesORB[i].high, l = ratesORB[i].low, v = (double)ratesORB[i].tick_volume;
      double r = h - l;
      if(r <= 0)
         continue;
      for(int k = 0; k < bins; k++)
        {
         double bL = rL + k * vpBinSize, bH = bL + vpBinSize;
         double ov = MathMin(h, bH) - MathMax(l, bL);
         if(ov > 0)
            vpVolArr[k] += v * (ov / r);
        }
     }
// Find POC
   vpMaxVol = 0;
   int pocIdx = 0;
   for(int k = 0; k < bins; k++)
      if(vpVolArr[k] > vpMaxVol)
        {
         vpMaxVol = vpVolArr[k];
         pocIdx = k;
        }
   if(vpMaxVol <= 0)
      return;
   vpPOC = rL + (pocIdx + 0.5) * vpBinSize;
// Value Area (InpVP_VA_Pct % of total volume)
   double totVol = 0;
   for(int k = 0; k < bins; k++)
      totVol += vpVolArr[k];
   if(totVol <= 0)
      return;
   double vaTarget = totVol * (InpVP_VA_Pct / 100.0);
   double vaVol = vpVolArr[pocIdx];
   int vaH = pocIdx, vaL = pocIdx;
   while(vaVol < vaTarget && (vaH < bins - 1 || vaL > 0))
     {
      double addH = (vaH < bins - 1) ? vpVolArr[vaH + 1] : 0;
      double addL = (vaL > 0) ? vpVolArr[vaL - 1] : 0;
      if(addH >= addL)
        {
         vaH++;
         vaVol += vpVolArr[vaH];
        }
      else
        {
         vaL--;
         vaVol += vpVolArr[vaL];
        }
     }
   if(vaH < 0 || vaL < 0 || vaH >= bins || vaL >= bins)
      return;
   vpVAH = rL + (vaH + 1) * vpBinSize;
   vpVAL = rL + vaL * vpBinSize;
   if(vpVAH <= vpVAL)
      return;
   vpReady = true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawVolumeProfile()
  {
   ObjectsDeleteAll(0, "VP_");
   if(!InpDrawVP || !vpReady || vpMaxVol <= 0)
      return;
   int bins = InpVP_Bins;
   int orbSec = PeriodSeconds(ORBTF);
   datetime anchor = TimeCurrent() + (datetime)(orbSec * 2); // 2 bars to the right
   for(int k = 0; k < bins; k++)
     {
      double vol = vpVolArr[k];
      if(vol <= 0)
         continue;
      int wBars = (int)MathMax(1, MathRound((vol / vpMaxVol) * InpVP_Width));
      double bLo = vpRangeL + k * vpBinSize;
      double bHi = bLo + vpBinSize;
      datetime t1 = anchor;
      datetime t2 = anchor + (datetime)(orbSec * wBars);
      double mid = (bLo + bHi) / 2.0;
      bool isPOC = (MathAbs(mid - vpPOC) < vpBinSize);
      bool isVA = (mid >= vpVAL && mid <= vpVAH);
      color barClr = isPOC ? InpVP_POC_Clr : (isVA ? InpVP_VA_Clr : InpVP_Out_Clr);
      DrawRect("VP_B" + string(k), t1, t2, bHi, bLo, barClr, true, false);
     }
// Key level lines
   datetime lnEnd = anchor + (datetime)(orbSec * (InpVP_Width + 4));
   DrawHLine("VP_POC", anchor, lnEnd, vpPOC, InpVP_POC_Clr, STYLE_SOLID, 2);
   DrawHLine("VP_VAH", anchor, lnEnd, vpVAH, InpVP_VA_Clr, STYLE_DOT, 1);
   DrawHLine("VP_VAL", anchor, lnEnd, vpVAL, InpVP_VA_Clr, STYLE_DOT, 1);
   DrawTextObj("VP_LBL_POC", lnEnd, vpPOC, " POC " + DoubleToString(vpPOC, _Digits), InpVP_POC_Clr, 10);
   DrawTextObj("VP_LBL_VAH", lnEnd, vpVAH, " VAH " + DoubleToString(vpVAH, _Digits), InpVP_VA_Clr, 9);
   DrawTextObj("VP_LBL_VAL", lnEnd, vpVAL, " VAL " + DoubleToString(vpVAL, _Digits), InpVP_VA_Clr, 9);
  }

//============================================================
// MODULE: DEALING RANGE  (Phase 4)
//============================================================
void UpdateDealingRange()
  {
   MqlRates dr[];
   ArraySetAsSeries(dr, true);
   int need = InpDR_Bars + 1;
   if(CopyRates(_Symbol, gDR_TF, 0, need, dr) < need)
      return;
// Use closed bars only (skip index 0 = forming bar)
   double hi = dr[1].high, lo = dr[1].low;
   for(int i = 2; i < need; i++)
     {
      if(dr[i].high > hi)
         hi = dr[i].high;
      if(dr[i].low < lo)
         lo = dr[i].low;
     }
   double rng = hi - lo;
   if(rng <= 0)
      return;
   dealingRange.high = hi;
   dealingRange.low = lo;
   dealingRange.mid = (hi + lo) / 2.0;
   dealingRange.premLine = hi - rng * InpDR_ZoneSize;
   dealingRange.discLine = lo + rng * InpDR_ZoneSize;
   dealingRange.updated = TimeCurrent();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ENUM_PRICE_POS GetPricePos()
  {
   if(dealingRange.high <= dealingRange.low)
      return PP_EQUILIBRIUM;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price >= dealingRange.premLine)
      return PP_PREMIUM;
   if(price <= dealingRange.discLine)
      return PP_DISCOUNT;
   return PP_EQUILIBRIUM;
  }

//+------------------------------------------------------------------+
//| LTF Suggestion Engine — confidence score (0-100)                 |
//| Mirrors CalcProbScore's methodology but scores the LTF engine's  |
//| own zone/direction, and adds a daily-bias alignment bonus since  |
//| — unlike CalcProbScore — this engine has no separate hard daily- |
//| bias block elsewhere, so the bonus is a real discriminator here. |
//+------------------------------------------------------------------+
double CalcLTFSuggestScore(int sess)
  {
   bool bul = ltfSuggBull[sess];
   double unusedMax = 0;
   double score = CalcCommonSetupScore(bul,
                                       InpUseOB && ltfSuggOB[sess].valid, ltfSuggOB[sess].touchCount,
                                       InpUseFVG && ltfSuggFVG[sess].valid, ltfSuggFVG[sess].touchCount,
                                       true, // the LTF engine always builds its own zones
                                       false, false, false, false, // none of these are hard-gated in ExecuteLTFSuggestion's own guard set
                                       unusedMax);
// Daily bias aligned (15 pts) — unique to this engine, kept as-is; not part of
// CalcCommonSetupScore since CalcProbScore has no equivalent component (daily
// bias is a hard block there per the existing F-05 fix, not a score input)
   if(InpUseDailyBias && dailyBias != BIAS_NEUTRAL)
     {
      if((bul && dailyBias == BIAS_BULLISH) || (!bul && dailyBias == BIAS_BEARISH))
         score += 15;
     }
   else
      score += 5;
// Volatility regime (10 pts) — unchanged, out of scope for this fix
   if(volRegime == VOL_NORMAL)
      score += 10;
   else
      if(volRegime == VOL_EXPLOSIVE)
         score += 5;
   return MathMin(100.0, score);
  }

//+------------------------------------------------------------------+
//| Shared setup-quality scorer used by CalcProbScore (main ORBTF     |
//| engine) and CalcLTFSuggestScore (LTF suggestion engine). Each     |
//| gate-coupled component takes an explicit "already hard-gated"     |
//| flag from the caller rather than reading Inp* globals directly,   |
//| because the two engines are gated by entirely different pipelines |
//| (CanEnter() vs ExecuteLTFSuggestion()'s own guards) — the same     |
//| Inp* flag can be meaningful for one caller and irrelevant to the   |
//| other.                                                             |
//+------------------------------------------------------------------+
double CalcCommonSetupScore(bool bul, bool obValid, int obTouch, bool fvgValid, int fvgTouch,
                            bool zonesApplicable,
                            bool htfGated, bool drGated, bool vpGated, bool freshGated,
                            double &achievableMax)
  {
   double score = 0;
   achievableMax = 0;
// HTF Bias (20 pts max; half-credit 10 when already hard-gated, e.g. CanEnter's InpBiasRequired)
   if(htfGated)
     {
      score += 10;
      achievableMax += 10;
     }
   else
     {
      achievableMax += 20;
      if(htfBias == BIAS_NEUTRAL)
         score += 10;
      else
         if((bul && htfBias == BIAS_BULLISH) || (!bul && htfBias == BIAS_BEARISH))
            score += 20;
     }
// Dealing Range (15 pts max; half-credit 7 when already hard-gated, e.g. InpUseDealingRange)
   if(drGated)
     {
      score += 7;
      achievableMax += 7;
     }
   else
     {
      achievableMax += 15;
      if(dealingRange.high > dealingRange.low)
        {
         ENUM_PRICE_POS pp = GetPricePos();
         if((bul && pp == PP_DISCOUNT) || (!bul && pp == PP_PREMIUM))
            score += 15;
         else
            if(pp == PP_EQUILIBRIUM)
               score += 7;
        }
     }
// Volume Profile (10 pts max; half-credit 5 when already hard-gated, e.g. InpUseVPFilter)
   if(vpGated)
     {
      score += 5;
      achievableMax += 5;
     }
   else
     {
      achievableMax += 10;
      if(vpReady)
        {
         double vpPrice = bul ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if((bul && vpPrice <= vpVAL) || (!bul && vpPrice >= vpVAH))
            score += 10;
         else
            if(vpPrice >= vpVAL && vpPrice <= vpVAH)
               score += 5;
        }
      else
         score += 5;
     }
// Zone freshness (10 pts max; half-credit 5 when zones don't apply to this mode,
// or already hard-gated, e.g. CanEnter's InpFreshZoneOnly)
   if(!zonesApplicable || freshGated)
     {
      score += 5;
      achievableMax += 5;
     }
   else
     {
      achievableMax += 10;
      bool hasFresh = (InpUseOB && obValid && obTouch <= 1) || (InpUseFVG && fvgValid && fvgTouch <= 1);
      if(hasFresh)
         score += 10;
     }
   return score; // raw sum — callers add their own remaining components; achievableMax carries the
// true ceiling for this call's gate configuration, for normalization
  }

//============================================================
// MODULE: PROBABILITY SCORE  (Phase 15/16)
//============================================================
double CalcProbScore(int sess)
  {
   bool bul = UsesSMC(sess) ? setupBull[sess] : GetBkUp(sess);
   double commonMax = 0;
   double score = CalcCommonSetupScore(bul,
                                       InpUseOB && ob[sess].valid, ob[sess].touchCount,
                                       InpUseFVG && fvg[sess].valid, fvg[sess].touchCount,
                                       UsesSMC(sess),
                                       InpBiasRequired,
                                       InpUseDealingRange && dealingRange.high > dealingRange.low,
                                       InpUseVPFilter,
                                       InpFreshZoneOnly && UsesSMC(sess) && (ob[sess].valid || fvg[sess].valid),
                                       commonMax);
// Volatility regime (10 pts) — unchanged, out of scope for this fix
   if(volRegime == VOL_NORMAL)
      score += 10;
   else
      if(volRegime == VOL_EXPLOSIVE)
         score += 5;
// Kill-zone timing (10 pts) — unchanged
   if(GetSessKZ(sess))
      score += 10;
// LTF confirmation count (15 pts) — SMC-aware: momentum + HTF-momentum
// sub-checks are pre-guaranteed once a session is SMC_CONFIRMED, so only
// BOS + wick (max 2) count there; non-confirmed/non-SMC entries still get
// all 4 sub-checks (max 4), unchanged from before.
   bool smcConfirmedNow = UsesSMC(sess) && smcState[sess] == SMC_CONFIRMED;
   int conf = CountConfirmations(sess, bul, smcConfirmedNow);
   score += smcConfirmedNow ? MathMin(15.0, conf * 7.5) : MathMin(15.0, conf * 5.0);
// LTF confirmation quality bonus (10 pts) — unchanged
   if(!UsesSMC(sess) || !InpLTFConfirm || ltfConfirmed[sess])
      score += 10;
// Normalize onto a true 0-100 scale relative to what's actually achievable given the
// current gate configuration, so InpMinProbScore keeps the same meaning regardless of
// which CanEnter filters happen to be enabled (see final-review finding: without this,
// the shipped defaults capped the raw score at ~72 against a 65 threshold, leaving only
// 7 points of slack and making entries nearly impossible).
   double achievableMax = commonMax + 45.0; // +10 vol +10 killzone +15 confirmations +10 bonus, all ungated
   if(achievableMax <= 0)
      return 0;
   return MathMin(100.0, (score / achievableMax) * 100.0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string GetProbGrade(double sc)
  {
   if(sc >= 90)
      return "A+";
   if(sc >= 80)
      return "A";
   if(sc >= 70)
      return "B";
   if(sc >= 60)
      return "C";
   return "SKIP";
  }

//============================================================
// MODULE: EXTERNAL LIQUIDITY DRAW  (Phase 5)
//============================================================
void DrawHLineFull(string n, double p, color c, ENUM_LINE_STYLE sty, int w)
  {
   if(ObjectFind(0, n) < 0)
     {
      if(!ObjectCreate(0, n, OBJ_HLINE, 0, 0, p))
         return;
      ObjectSetInteger(0, n, OBJPROP_BACK, true);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
     }
   ObjectSetDouble(0, n, OBJPROP_PRICE, p);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_STYLE, sty);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, w);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawExternalLiquidity()
  {
// AUDIT FIX: previously these objects were only ever created, never deleted — toggling
// InpDrawWeeklyLiq/InpDrawMonthlyLiq/InpDrawLabels off mid-session left stale lines/labels
// on the chart until the EA was removed (CleanAll() was the only place that cleared them).
   if(!InpDrawWeeklyLiq)
     {
      ObjectDelete(0, "EXT_WH");
      ObjectDelete(0, "EXT_WL");
      ObjectDelete(0, "EXT_WH_L");
      ObjectDelete(0, "EXT_WL_L");
     }
   else
     {
      MqlRates w[2];
      ArraySetAsSeries(w, true);
      if(CopyRates(_Symbol, PERIOD_W1, 1, 2, w) >= 1)
        {
         DrawHLineFull("EXT_WH", w[0].high, InpClrWeeklyLiq, STYLE_DOT, 1);
         DrawHLineFull("EXT_WL", w[0].low, InpClrWeeklyLiq, STYLE_DOT, 1);
         if(InpDrawLabels)
           {
            datetime tNow = TimeCurrent();
            DrawTextObj("EXT_WH_L", tNow, w[0].high, "  WH " + DoubleToString(w[0].high, _Digits), InpClrWeeklyLiq, 9);
            DrawTextObj("EXT_WL_L", tNow, w[0].low, "  WL " + DoubleToString(w[0].low, _Digits), InpClrWeeklyLiq, 9);
           }
         else
           {
            ObjectDelete(0, "EXT_WH_L");
            ObjectDelete(0, "EXT_WL_L");
           }
        }
     }
   if(!InpDrawMonthlyLiq)
     {
      ObjectDelete(0, "EXT_MH");
      ObjectDelete(0, "EXT_ML");
      ObjectDelete(0, "EXT_MH_L");
      ObjectDelete(0, "EXT_ML_L");
     }
   else
     {
      MqlRates m[2];
      ArraySetAsSeries(m, true);
      if(CopyRates(_Symbol, PERIOD_MN1, 1, 2, m) >= 1)
        {
         DrawHLineFull("EXT_MH", m[0].high, InpClrMonthlyLiq, STYLE_DOT, 1);
         DrawHLineFull("EXT_ML", m[0].low, InpClrMonthlyLiq, STYLE_DOT, 1);
         if(InpDrawLabels)
           {
            datetime tNow = TimeCurrent();
            DrawTextObj("EXT_MH_L", tNow, m[0].high, "  MH " + DoubleToString(m[0].high, _Digits), InpClrMonthlyLiq, 9);
            DrawTextObj("EXT_ML_L", tNow, m[0].low, "  ML " + DoubleToString(m[0].low, _Digits), InpClrMonthlyLiq, 9);
           }
         else
           {
            ObjectDelete(0, "EXT_MH_L");
            ObjectDelete(0, "EXT_ML_L");
           }
        }
     }
  }

//============================================================
// MODULE: ENTRY READY VISUAL
//============================================================
// Lightweight gate — checks main conditions without logging or scoring side-effects.
bool CheckEntryReadyVisual(int sess, bool &isBuy)
  {
   isBuy = false;
   bool buyReady = IsPipelineDirectionReady(sess, true);
   bool sellReady = IsPipelineDirectionReady(sess, false);
   if(!buyReady && !sellReady)
      return false;
   if(UsesSMC(sess))
     {
      isBuy = setupBull[sess];
      return true;
     }
   bool bU = GetBkUp(sess), bD = GetBkDn(sess);
   if(bU && !bD)
      isBuy = true;
   else
      if(bD && !bU)
         isBuy = false;
      else
         if(buyReady && !sellReady)
            isBuy = true;
         else
            if(!buyReady && sellReady)
               isBuy = false;
            else
               isBuy = (GetEntryBiasForLogic() != BIAS_BEARISH);
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawEntryReadySignal(int sess)
  {
   string pfx = "ERD_" + SESS_NAME[sess] + "_";
// ANTI-REPAINT: only delete ERD objects when signal disappears (not every bar)
   static bool erdActive[SESS_COUNT] = {false, false, false};
   bool isBuy;
   if(!CheckEntryReadyVisual(sess, isBuy))
     {
      if(erdActive[sess])
        {
         ObjectsDeleteAll(0, pfx);
         erdActive[sess] = false;
        }
      return;
     }
   erdActive[sess] = true;
   double entryPx, slPx, tpPx, slPips, tpPips, rrRatio, riskAmt, riskPct;
   PreviewEntryRisk(sess, isBuy, entryPx, slPx, tpPx, slPips, tpPips, rrRatio, riskAmt, riskPct);
   if(entryPx <= 0 || slPx <= 0 || tpPx <= 0)
      return;
   int barSec = PeriodSeconds(ORBTF);
// ANTI-REPAINT FIX: use bar open time — stable for the full bar, not TimeCurrent()
   datetime now = (ArraySize(ratesORB) > 0) ? ratesORB[0].time : TimeCurrent();
   datetime lineEnd = now + (datetime)(barSec * 30);
   datetime lblT = now + (datetime)(barSec * 2);
   color sigC = isBuy ? C'0,230,100' : C'255,60,60';
   color entC = C'255,220,0';
   color slC = C'255,60,60';
   color tpC = C'0,220,110';
   color boxC = isBuy ? C'0,55,25' : C'60,8,8';
// ── 1. RR filled box (entry → TP zone) ──────────────────────────
   DrawRect(pfx + "BOX", now, lineEnd,
            isBuy ? tpPx : entryPx,
            isBuy ? entryPx : tpPx,
            boxC, true, false);
// ── 2. Level lines ───────────────────────────────────────────────
   DrawHLine(pfx + "ENTRY", now, lineEnd, entryPx, entC, STYLE_DASH, 2);
   DrawHLine(pfx + "SL", now, lineEnd, slPx, slC, STYLE_DASH, 2);
   DrawHLine(pfx + "TP", now, lineEnd, tpPx, tpC, STYLE_DASH, 2);
// ── 3. Big entry arrow ───────────────────────────────────────────
   DrawArrow(pfx + "ARR", now, entryPx, sigC, isBuy ? 233 : 234, 7);
// ── 4. Main ENTRY READY banner ───────────────────────────────────
   string dir = isBuy ? "BUY  ▲" : "SELL  ▼";
   string modeName = (InpORBEntryMode == ORB_CONSERVATIVE) ? "CONS" : ((InpORBEntryMode == ORB_BALANCED) ? "BAL" : "AGG");
   string quality = (InpORBEntryMode == ORB_CONSERVATIVE) ? "HIGH" : ((InpORBEntryMode == ORB_BALANCED) ? "MID" : "LOW");
   string rr = StringFormat("1:%.1f", rrRatio);
   string main = StringFormat("  ⚡ ORDER-FLOW READY  |  %s  %s  |  MODE %s/%s  |  RR %s  |  SL %.0fp  TP %.0fp",
                              SESS_NAME[sess], dir, modeName, quality, rr, slPips, tpPips);
   DrawTextObj(pfx + "LBL", lblT, entryPx, main, sigC, 12);
// ── 5. Individual price labels at line ends ───────────────────────
   DrawTextObj(pfx + "ENTRY_L", lineEnd, entryPx,
               "  ENTRY  " + DoubleToString(entryPx, _Digits), entC, 9);
   DrawTextObj(pfx + "SL_L", lineEnd, slPx,
               "  SL  " + DoubleToString(slPx, _Digits), slC, 9);
   DrawTextObj(pfx + "TP_L", lineEnd, tpPx,
               "  TP  " + DoubleToString(tpPx, _Digits), tpC, 9);
// ── 6. Entry zone (mode-specific) ────────────────────────────────
   double orH = GetSessORH(sess), orL = GetSessORL(sess);
   datetime zoneBack = now - (datetime)(barSec * 3);
   if(UsesSMC(sess))
     {
      // SMC: highlight the active OB/FVG zone as the entry zone
      bool hasZone = false;
      double zoneHi = 0, zoneLo = 0;
      string zoneLbl = "";
      color zFill, zBrd;
      if(InpUseOB && ob[sess].valid)
        {
         zoneHi = ob[sess].high;
         zoneLo = ob[sess].low;
         zoneLbl = isBuy ? "◉ OB ENTRY ZONE  ▲" : "◉ OB ENTRY ZONE  ▼";
         zFill = isBuy ? C'0,85,38' : C'85,5,5';
         zBrd = isBuy ? C'0,245,115' : C'255,65,65';
         hasZone = true;
        }
      else
         if(InpUseFVG && fvg[sess].valid)
           {
            zoneHi = fvg[sess].high;
            zoneLo = fvg[sess].low;
            zoneLbl = isBuy ? "◉ FVG ENTRY ZONE  ▲" : "◉ FVG ENTRY ZONE  ▼";
            zFill = isBuy ? C'0,75,70' : C'75,22,0';
            zBrd = isBuy ? C'0,240,205' : C'255,135,35';
            hasZone = true;
           }
      if(hasZone && zoneHi > zoneLo)
        {
         DrawRect(pfx + "ZONE", zoneBack, lineEnd, zoneHi, zoneLo, zFill, true, false);
         DrawHLine(pfx + "ZONE_H", zoneBack, lineEnd, zoneHi, zBrd, STYLE_SOLID, 2);
         DrawHLine(pfx + "ZONE_L", zoneBack, lineEnd, zoneLo, zBrd, STYLE_SOLID, 2);
         DrawTextObj(pfx + "ZONE_LBL", now + (datetime)(barSec * 2),
                     isBuy ? zoneLo : zoneHi, "  " + zoneLbl, zBrd, 10);
        }
     }
   else
     {
      // ORB mode: highlight the OR boundary being traded as the entry zone
      double atr = GetATR(1);
      double aBand = (atr > 0) ? atr * 0.6 : _Point * 20;
      double refLvl = isBuy ? orH : orL;
      if(refLvl > 0 && aBand > 0)
        {
         double bandH = refLvl + (isBuy ? aBand : 0);
         double bandL = refLvl - (isBuy ? 0 : aBand);
         color bFill = isBuy ? C'0,52,22' : C'58,5,5';
         color bBrd = isBuy ? C'0,215,100' : C'230,55,55';
         string bLbl = isBuy ? "◉ ORB ENTRY ZONE  ▲  H " + DoubleToString(orH, _Digits)
                       : "◉ ORB ENTRY ZONE  ▼  L " + DoubleToString(orL, _Digits);
         DrawRect(pfx + "ZONE", zoneBack, lineEnd, bandH, bandL, bFill, true, false);
         DrawHLine(pfx + "ZONE_H", zoneBack, lineEnd, refLvl, bBrd, STYLE_SOLID, 2);
         DrawTextObj(pfx + "ZONE_LBL", now + (datetime)(barSec * 2),
                     refLvl, "  " + bLbl, bBrd, 10);
        }
     }
  }

//============================================================
// MODULE: VISUAL ENGINE
//============================================================
void DrawAll(bool fullRedraw)
  {
// Pivot + VP: only recalculate on new bar
   if(fullRedraw)
     {
      CalcDailyPivots();
      DrawAMDZone();
      // BuildVolumeProfile() moved to OnTick's needSignalRefresh block so it runs
      // regardless of InpDrawObjects — see that call site for rationale.
      DrawSessionZones();
      if(InpDrawKZ)
         DrawKillzones();
      DrawORBZones();
      DrawORBLevelLines();
     }
// BUG3 FIX: move static visuals inside fullRedraw — pivots/VP don't change tick-by-tick
   if(fullRedraw)
     {
      if(InpDrawPivots)
         DrawPivotPoints();
      if(InpDrawVP)
         DrawVolumeProfile();
      // Phase 5: External liquidity levels (weekly/monthly H/L)
      if(InpDrawWeeklyLiq || InpDrawMonthlyLiq)
         DrawExternalLiquidity();
      // EQ High / EQ Low levels
      DrawEQHL();
     }
   if(InpDrawLabels)
      DrawPriceLabels();
   DrawSignalArrows();
   for(int s = 0; s < SESS_COUNT; s++)
     {
      DrawOrderFlowOverlay(s, GetSessORH(s), GetSessORL(s));
      DrawFiboZone(s);
     }
   for(int s = 0; s < SESS_COUNT; s++)
      DrawSMCObjects(s);
   DrawHTFStructure();
// Entry-ready visual: updates every bar so arrow/RR box tracks live price
   for(int s = 0; s < SESS_COUNT; s++)
      DrawEntryReadySignal(s);
   DrawHTFBiasBar();
   DrawNoEntryOverlay();
   if(InpDrawPanel)
      DrawStatusPanel();
   DrawPositionLevels();
   if(InpUsePendingOR)
      DrawPendingORLevels();
   ChartRedraw();
   WriteWebData();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawSessionZones()
  {
   datetime ss[SESS_COUNT] = {asiaStart, londonStart, nyStart};
   datetime se_[SESS_COUNT] = {asiaEnd, londonEnd, nyEnd};
   double sh[SESS_COUNT] = {asiaHigh, londonHigh, nyHigh};
   double sl_[SESS_COUNT] = {asiaLow, londonLow, nyLow};
   string pfx[SESS_COUNT] = {"A", "L", "NY"};
   for(int s = 0; s < SESS_COUNT; s++)
     {
      // Session open — solid vline (cleaner than dot)
      DrawVLine("VL_" + pfx[s] + "_O", ss[s], SESS_LINE_CLR[s], STYLE_SOLID, 1);
      if(sh[s] <= 0)
         continue;
      // Background fill (in background layer)
      DrawRect("SZ_" + pfx[s], ss[s], se_[s], sh[s], sl_[s], SESS_ZONE_CLR[s], true, true);
      // Top + bottom border lines — give the zone a clean frame
      DrawHLine("SZ_" + pfx[s] + "_H", ss[s], se_[s], sh[s], SESS_LINE_CLR[s], STYLE_SOLID, 1);
      DrawHLine("SZ_" + pfx[s] + "_L", ss[s], se_[s], sl_[s], SESS_TXT_CLR[s], STYLE_SOLID, 1);
      // Label: session name + pip range — white for maximum contrast on any dark box
      string rng = DoubleToString((sh[s] - sl_[s]) / _Point, 0);
      DrawTextObj("LBL_" + pfx[s], ss[s] + (datetime)90, sh[s],
                  "  " + SESS_NAME[s] + "  " + rng + "p", clrWhite, 10);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawKillzones()
  {
   if(asiaHigh > 0)
     {
      DrawRect("KZ_A", asiaStart, asiaKZEnd, asiaHigh, asiaLow, SESS_KZ_CLR[SESS_ASIA], true, true);
      DrawTextObj("KZ_A_L", asiaStart + 30, asiaLow, " KZ", SESS_TXT_CLR[SESS_ASIA], 9);
     }
   if(londonHigh > 0)
     {
      DrawRect("KZ_L", londonStart, londonKZEnd, londonHigh, londonLow, SESS_KZ_CLR[SESS_LONDON], true, true);
      DrawTextObj("KZ_L_L", londonStart + 30, londonLow, " KZ", SESS_TXT_CLR[SESS_LONDON], 9);
     }
   if(nyHigh > 0)
     {
      DrawRect("KZ_NY", nyStart, nyKZEnd, nyHigh, nyLow, SESS_KZ_CLR[SESS_NY], true, true);
      DrawTextObj("KZ_NY_L", nyStart + 30, nyLow, " KZ", SESS_TXT_CLR[SESS_NY], 9);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawORBZones()
  {
   ObjectsDeleteAll(0, "ORB_BOX_");
   double orH[SESS_COUNT] = {asiaORHigh, londonORHigh, nyORHigh};
   double orL[SESS_COUNT] = {asiaORLow, londonORLow, nyORLow};
   datetime orS_[SESS_COUNT] = {asiaORStart, londonORStart, nyORStart};
   datetime orE_[SESS_COUNT] = {asiaOREnd, londonOREnd, nyOREnd};
   string pfx[SESS_COUNT] = {"A", "L", "NY"};
// Very subtle dark-tinted fill (barely visible — pure color reference for zone)
   color fillC[SESS_COUNT] = {C'5,12,28', C'22,12,4', C'22,5,5'};
   int bs = PeriodSeconds(ORBTF);
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(orH[s] <= 0)
         continue;
      double mid = (orH[s] + orL[s]) * 0.5;
      int rngPts = (int)MathRound((orH[s] - orL[s]) / _Point);
      // Subtle tinted fill
      DrawRect("ORB_BOX_" + pfx[s], orS_[s], orE_[s], orH[s], orL[s], fillC[s], true, true);
      // Top/bottom border — solid weight 2 (bold frame, easy to identify OR boundaries)
      DrawHLine("ORB_BOX_" + pfx[s] + "_H", orS_[s], orE_[s], orH[s], SESS_LINE_CLR[s], STYLE_SOLID, 2);
      DrawHLine("ORB_BOX_" + pfx[s] + "_L", orS_[s], orE_[s], orL[s], SESS_TXT_CLR[s], STYLE_SOLID, 2);
      // EQ midline (dotted, subtle)
      DrawHLine("ORB_BOX_" + pfx[s] + "_M", orS_[s], orE_[s], mid, SESS_TXT_CLR[s], STYLE_DOT, 1);
      // "OR  45p" label inside the box
      DrawTextObj("ORB_BOX_" + pfx[s] + "_T", orS_[s] + (datetime)bs, mid,
                  "  OR  " + string(rngPts) + "p", SESS_TXT_CLR[s], 9);
      // ORB close marker — DASH (clean, distinct from session vline)
      DrawVLine("VL_" + pfx[s] + "_OE", orE_[s], SESS_LINE_CLR[s], STYLE_DASH, 1);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawORBLevelLines()
  {
   ObjectsDeleteAll(0, "ORL_");
   double orH[SESS_COUNT] = {asiaORHigh, londonORHigh, nyORHigh};
   double orL[SESS_COUNT] = {asiaORLow, londonORLow, nyORLow};
   datetime orE_[SESS_COUNT] = {asiaOREnd, londonOREnd, nyOREnd};
   datetime seE[SESS_COUNT] = {asiaEnd, londonEnd, nyEnd};
   string pfx[SESS_COUNT] = {"A", "L", "NY"};
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(orH[s] <= 0)
         continue;
      double mid = (orH[s] + orL[s]) * 0.5;
      // H/L lines — solid weight 2 for all sessions (consistent visibility)
      DrawHLine("ORL_" + pfx[s] + "_H", orE_[s], seE[s], orH[s], SESS_LINE_CLR[s], STYLE_SOLID, 2);
      DrawHLine("ORL_" + pfx[s] + "_L", orE_[s], seE[s], orL[s], SESS_TXT_CLR[s], STYLE_SOLID, 2);
      // EQ midline (dotted, 1px — subtle reference)
      DrawHLine("ORL_" + pfx[s] + "_M", orE_[s], seE[s], mid, SESS_TXT_CLR[s], STYLE_DOT, 1);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawPriceLabels()
  {
   datetime off = (datetime)(3 * PeriodSeconds(ORBTF));
   double orH[SESS_COUNT] = {asiaORHigh, londonORHigh, nyORHigh};
   double orL[SESS_COUNT] = {asiaORLow, londonORLow, nyORLow};
   datetime orS[SESS_COUNT] = {asiaORStart, londonORStart, nyORStart};
   datetime orE_[SESS_COUNT] = {asiaOREnd, londonOREnd, nyOREnd};
   string pfx[SESS_COUNT] = {"A", "L", "NY"};
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(orH[s] <= 0 || orL[s] <= 0)
         continue;
      double mid = (orH[s] + orL[s]) * 0.5;
      int rngPts = (int)MathRound((orH[s] - orL[s]) / _Point);
      // H label: "▲ 1.23456"
      DrawTextObj("PTAG_" + pfx[s] + "_H", orE_[s] + off, orH[s],
                  "  ▲ " + DoubleToString(orH[s], _Digits), SESS_LINE_CLR[s], 10);
      // L label: "▼ 1.23400"
      DrawTextObj("PTAG_" + pfx[s] + "_L", orE_[s] + off, orL[s],
                  "  ▼ " + DoubleToString(orL[s], _Digits), SESS_TXT_CLR[s], 10);
      // Center: session name + range
      DrawTextObj("PTAG_" + pfx[s] + "_R", orS[s] + off, mid,
                  "  " + SESS_NAME[s] + "  OR  " + string(rngPts) + "p", SESS_TXT_CLR[s], 9);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawSignalArrows()
  {
   DrawSessArrows(SESS_ASIA, asiaORHigh, asiaORLow, asiaBreakoutUp, asiaBreakoutDown, asiaRejectHigh, asiaRejectLow, asiaFBH, asiaFBL);
   DrawSessArrows(SESS_LONDON, londonORHigh, londonORLow, londonBreakoutUp, londonBreakoutDown, londonRejectHigh, londonRejectLow, londonFBH, londonFBL);
   DrawSessArrows(SESS_NY, nyORHigh, nyORLow, nyBreakoutUp, nyBreakoutDown, nyRejectHigh, nyRejectLow, nyFBH, nyFBL);
  }

// Lightweight order-flow overlay for the latest closed bar.
void DrawOrderFlowOverlay(int s, double orH, double orL)
  {
   if(orH <= 0 || orL <= 0 || ArraySize(ratesORB) < 3)
      return;
   double atr = GetATR(1);
   double gap = (atr > 0) ? atr * 0.35 : (orH - orL) * 0.20;
   datetime t = ratesORB[1].time;
   string p = SESS_NAME[s] + "_";
   MqlRates r1 = ratesORB[1];
   MqlRates r2 = ratesORB[2];
   double retestBuf = (atr > 0) ? atr * InpORBRetestBuffer : _Point * 10;

   bool buyRetest = (r1.low <= orH + retestBuf) && (r1.close >= orH - retestBuf) && (r1.close > r1.open);
   bool buyCont = (r1.close > r2.close) && (r1.close > r2.open) && (r1.close > orH + retestBuf);
   bool buySweep = (r1.high > orH + retestBuf) && (r1.close <= orH + retestBuf);
   bool sellRetest = (r1.high >= orL - retestBuf) && (r1.close <= orL + retestBuf) && (r1.close < r1.open);
   bool sellCont = (r1.close < r2.close) && (r1.close < r2.open) && (r1.close < orL - retestBuf);
   bool sellSweep = (r1.low < orL - retestBuf) && (r1.close >= orL - retestBuf);

   if(buyRetest)
     {
      DrawArrow("OF_" + p + "RETU", t, orH + gap * 0.8, C'255,190,0', 225, 3);
      DrawTextObj("OFL_" + p + "RETU", t, orH + gap * 0.8, "  RETEST", C'255,190,0', 9);
     }
   else
     {
      ObjectDelete(0, "OF_" + p + "RETU");
      ObjectDelete(0, "OFL_" + p + "RETU");
     }

   if(buyCont)
     {
      DrawArrow("OF_" + p + "CONU", t, orH + gap * 1.6, C'0,220,120', 233, 3);
      DrawTextObj("OFL_" + p + "CONU", t, orH + gap * 1.6, "  CONT", C'0,220,120', 9);
     }
   else
     {
      ObjectDelete(0, "OF_" + p + "CONU");
      ObjectDelete(0, "OFL_" + p + "CONU");
     }

   if(buySweep)
     {
      DrawArrow("OF_" + p + "SWPU", t, orH + gap * 2.4, C'255,90,90', 232, 3);
      DrawTextObj("OFL_" + p + "SWPU", t, orH + gap * 2.4, "  SWEEP", C'255,90,90', 9);
     }
   else
     {
      ObjectDelete(0, "OF_" + p + "SWPU");
      ObjectDelete(0, "OFL_" + p + "SWPU");
     }

   if(sellRetest)
     {
      DrawArrow("OF_" + p + "RETD", t, orL - gap * 0.8, C'255,190,0', 226, 3);
      DrawTextObj("OFL_" + p + "RETD", t, orL - gap * 0.8, "  RETEST", C'255,190,0', 9);
     }
   else
     {
      ObjectDelete(0, "OF_" + p + "RETD");
      ObjectDelete(0, "OFL_" + p + "RETD");
     }

   if(sellCont)
     {
      DrawArrow("OF_" + p + "COND", t, orL - gap * 1.6, C'255,70,70', 234, 3);
      DrawTextObj("OFL_" + p + "COND", t, orL - gap * 1.6, "  CONT", C'255,70,70', 9);
     }
   else
     {
      ObjectDelete(0, "OF_" + p + "COND");
      ObjectDelete(0, "OFL_" + p + "COND");
     }

   if(sellSweep)
     {
      DrawArrow("OF_" + p + "SWPD", t, orL - gap * 2.4, C'255,90,90', 231, 3);
      DrawTextObj("OFL_" + p + "SWPD", t, orL - gap * 2.4, "  SWEEP", C'255,90,90', 9);
     }
   else
     {
      ObjectDelete(0, "OF_" + p + "SWPD");
      ObjectDelete(0, "OFL_" + p + "SWPD");
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
// Deletes the arrow+label pair for one signal type when it's no longer active, so a stale
// signal from an earlier bar doesn't keep sitting on the chart looking like it's still live.
void DeleteSessArrow(string key)
  {
   ObjectDelete(0, "SIG_" + key);
   ObjectDelete(0, "SIGL_" + key);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawSessArrows(int s, double orH, double orL, bool bU, bool bD, bool rH, bool rL, bool fH, bool fL)
  {
   if(orH <= 0 || orL <= 0 || ArraySize(ratesORB) < 2)
      return;
   double atr = GetATR(1);
   double gap = (atr > 0) ? atr * 0.4 : (orH - orL) * 0.25;
   datetime t = ratesORB[1].time;
   string p = SESS_NAME[s] + "_";
// BUY breakout: large UP arrow above OR High — prominent green signal
   if(bU)
     {
      DrawArrow("SIG_" + p + "BU", t, orH + gap * 0.4, C'0,230,85', 233, 5);
      DrawTextObj("SIGL_" + p + "BU", t, orH + gap * 0.4,
                  "  ▲  BUY  " + DoubleToString(orH, _Digits), C'0,230,85', 11);
     }
   else
      DeleteSessArrow(p + "BU");
// SELL breakout: large DOWN arrow below OR Low — prominent red signal
   if(bD)
     {
      DrawArrow("SIG_" + p + "BD", t, orL - gap * 0.4, C'235,50,50', 234, 5);
      DrawTextObj("SIGL_" + p + "BD", t, orL - gap * 0.4,
                  "  ▼  SELL  " + DoubleToString(orL, _Digits), C'235,50,50', 11);
     }
   else
      DeleteSessArrow(p + "BD");
// Reject High: price wicked above OR H and closed back — yellow warning
   if(rH)
     {
      DrawArrow("SIG_" + p + "RH", t, orH + gap * 1.2, C'215,185,0', 218, 3);
      DrawTextObj("SIGL_" + p + "RH", t, orH + gap * 1.2, "  ↓ REJECT", C'215,185,0', 10);
     }
   else
      DeleteSessArrow(p + "RH");
// Reject Low: price wicked below OR L and closed back — cyan warning
   if(rL)
     {
      DrawArrow("SIG_" + p + "RL", t, orL - gap * 1.2, C'0,195,195', 217, 3);
      DrawTextObj("SIGL_" + p + "RL", t, orL - gap * 1.2, "  ↑ REJECT", C'0,195,195', 10);
     }
   else
      DeleteSessArrow(p + "RL");
// False Break High: prev closed above, this bar reversed — magenta caution
   if(fH)
     {
      DrawArrow("SIG_" + p + "FH", t, orH + gap * 2.0, C'205,55,205', 218, 3);
      DrawTextObj("SIGL_" + p + "FH", t, orH + gap * 2.0, "  ↓ FALSE BREAK", C'205,55,205', 10);
     }
   else
      DeleteSessArrow(p + "FH");
// False Break Low: prev closed below, this bar reversed — deep sky blue caution
   if(fL)
     {
      DrawArrow("SIG_" + p + "FL", t, orL - gap * 2.0, C'30,170,225', 217, 3);
      DrawTextObj("SIGL_" + p + "FL", t, orL - gap * 2.0, "  ↑ FALSE BREAK", C'30,170,225', 10);
     }
   else
      DeleteSessArrow(p + "FL");
  }

// Visual-only Fibonacci retracement of the breakout leg (see UpdateFiboLegs / InpDrawFibo).
// Levels are drawn as a bounded segment from the breakout bar to "now"; the golden zone
// (InpFiboGoldLo..InpFiboGoldHi) is highlighted with a shaded band. Not read by CanEnter —
// purely so the pattern can be eyeballed on chart before deciding whether to use it as a filter.
void DrawFiboZone(int s)
  {
   string p = "FIB_" + SESS_NAME[s] + "_";
   static string tags[7] = {"000", "236", "382", "500", "618", "786", "100"};
   if(!InpDrawFibo || fiboDir[s] == 0)
     {
      for(int i = 0; i < 7; i++)
        {
         ObjectDelete(0, p + "L" + tags[i]);
         ObjectDelete(0, p + "T" + tags[i]);
        }
      ObjectDelete(0, p + "GOLD");
      ObjectDelete(0, p + "GLBL");
      return;
     }
   double range = MathAbs(fiboB[s] - fiboA[s]);
   if(range <= 0)
      return;
   bool bull = (fiboDir[s] == 1);
   datetime t1 = fiboAnchorT[s];
   datetime t2 = ((ArraySize(ratesORB) > 0) ? ratesORB[0].time : TimeCurrent()) + (datetime)(PeriodSeconds(ORBTF) * 3);
   color baseClr = bull ? C'0,200,140' : C'220,90,90';
   double ratios[7] = {0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0};
   for(int i = 0; i < 7; i++)
     {
      double lvl = bull ? (fiboB[s] - range * ratios[i]) : (fiboB[s] + range * ratios[i]);
      ENUM_LINE_STYLE sty = (ratios[i] <= 0.0001 || ratios[i] >= 0.9999) ? STYLE_SOLID : STYLE_DOT;
      DrawHLine(p + "L" + tags[i], t1, t2, lvl, baseClr, sty, 1);
      DrawTextObj(p + "T" + tags[i], t2, lvl, "  " + DoubleToString(ratios[i] * 100.0, 1) + "%", baseClr, 8);
     }
   double goldEdgeNear = bull ? (fiboB[s] - range * InpFiboGoldLo) : (fiboB[s] + range * InpFiboGoldLo);
   double goldEdgeFar = bull ? (fiboB[s] - range * InpFiboGoldHi) : (fiboB[s] + range * InpFiboGoldHi);
   double goldHi = MathMax(goldEdgeNear, goldEdgeFar), goldLo = MathMin(goldEdgeNear, goldEdgeFar);
   DrawRect(p + "GOLD", t1, t2, goldHi, goldLo, C'55,45,6', true, true);
   DrawTextObj(p + "GLBL", t2, (goldHi + goldLo) / 2.0, "  ◈ GOLDEN ZONE", C'255,215,0', 9);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawSMCObjects(int sess)
  {
   string p = SESS_NAME[sess];
// ANTI-REPAINT: targeted cleanup only — no bulk ObjectsDeleteAll which causes full flicker
// Remove OB when: drawing disabled, zone broken (valid=false), or trade executed on zone
   bool obGone = !InpDrawOB || !ob[sess].valid || (smcState[sess] == SMC_TRADED);
   if(obGone)
     {
      ObjectDelete(0, "SMC_" + p + "_OB");
      ObjectDelete(0, "SMC_" + p + "_OBH");
      ObjectDelete(0, "SMC_" + p + "_OBL");
      ObjectDelete(0, "SMC_" + p + "_OBM");
      ObjectDelete(0, "SMC_" + p + "_OBLBL");
      ObjectDelete(0, "SMC_" + p + "_OBRNG");
      ObjectDelete(0, "SMC_" + p + "_OBENTRY");
     }
// Remove FVG when: drawing disabled, zone broken (valid=false), or trade executed on zone
   bool fvgGone = !InpDrawFVG || !fvg[sess].valid || (smcState[sess] == SMC_TRADED);
   if(fvgGone)
     {
      ObjectDelete(0, "SMC_" + p + "_FVG");
      ObjectDelete(0, "SMC_" + p + "_FVGH");
      ObjectDelete(0, "SMC_" + p + "_FVGL");
      ObjectDelete(0, "SMC_" + p + "_FVGM");
      ObjectDelete(0, "SMC_" + p + "_FVGLBL");
      ObjectDelete(0, "SMC_" + p + "_FVGRNG");
      ObjectDelete(0, "SMC_" + p + "_FVGENTRY");
     }
// Clean up sweep/BOS/displacement markers when state rolled back
   if(smcState[sess] < SMC_SWEPT || sweepLvl[sess] <= 0)
     {
      ObjectDelete(0, "SMC_" + p + "_SW");
      ObjectDelete(0, "SMC_" + p + "_SWLBL");
     }
   if(smcState[sess] < SMC_STRUCTURE || bosLvl[sess] <= 0)
     {
      ObjectDelete(0, "SMC_" + p + "_BOS");
      ObjectDelete(0, "SMC_" + p + "_BOSLBL");
     }
   if(dispTime[sess] == 0)
     {
      ObjectDelete(0, "SMC_" + p + "_DISP");
      ObjectDelete(0, "SMC_" + p + "_DISPLBL");
     }
// ANTI-REPAINT FIX: anchor to bar open time (stable for the entire bar duration)
// TimeCurrent() advances every tick → zone right edges creep forward → visual repaint
   datetime now = (ArraySize(ratesORB) > 0) ? ratesORB[0].time : TimeCurrent();
   int barSec = PeriodSeconds(ORBTF);
   datetime extEnd = now + (datetime)(barSec * 8); // right edge: 8 bars past current bar open
   bool stateRetrace = (smcState[sess] == SMC_RETRACE);
   bool stateConfirmed = (smcState[sess] == SMC_CONFIRMED);
   bool priceActive = priceInZone[sess] && (stateRetrace || stateConfirmed);
// ── ORDER BLOCK ──────────────────────────────────────────────────
   if(InpDrawOB && ob[sess].valid && !obGone)
     {
      bool fresh = (ob[sess].touchCount <= 1);
      // Colors: in-zone = bright, fresh = normal, used = dimmed
      color obc, obBrd;
      if(priceActive)
        {
         obc = ob[sess].bullish ? C'0,90,45' : C'100,0,0';
         obBrd = ob[sess].bullish ? C'0,255,120' : C'255,55,55';
        }
      else
         if(fresh)
           {
            obc = ob[sess].bullish ? C'0,60,30' : C'70,0,0';
            obBrd = ob[sess].bullish ? C'0,185,95' : C'220,60,60';
           }
         else
           {
            obc = ob[sess].bullish ? C'5,25,14' : C'30,5,5';      // faded fill
            obBrd = ob[sess].bullish ? C'0,90,48' : C'110,30,30'; // faded border
           }
      // Main rectangle extends to current time
      DrawRect("SMC_" + p + "_OB", ob[sess].time, extEnd, ob[sess].high, ob[sess].low, obc, true, false);
      // Top/bottom border lines (solid, weight 2)
      DrawHLine("SMC_" + p + "_OBH", ob[sess].time, extEnd, ob[sess].high, obBrd, STYLE_SOLID, 2);
      DrawHLine("SMC_" + p + "_OBL", ob[sess].time, extEnd, ob[sess].low, obBrd, STYLE_SOLID, 2);
      // 50% equilibrium midline (dotted)
      double obMid = (ob[sess].high + ob[sess].low) / 2.0;
      DrawHLine("SMC_" + p + "_OBM", ob[sess].time, extEnd, obMid, obBrd, STYLE_DOT, 1);
      // Left-side label: "OB▲ ✦FRESH" or "OB▲ ×2"
      string frTag = fresh ? " \x2666FRESH" : " x" + string(ob[sess].touchCount);
      string obLbl = " OB" + (ob[sess].bullish ? "\x25B2" : "\x25BC") + frTag;
      DrawTextObj("SMC_" + p + "_OBLBL", ob[sess].time, ob[sess].high, obLbl, obBrd, 10);
      // Right-side price range label at right edge
      string priceRng = DoubleToString(ob[sess].low, _Digits) + "—" + DoubleToString(ob[sess].high, _Digits);
      DrawTextObj("SMC_" + p + "_OBRNG", extEnd, ob[sess].bullish ? ob[sess].low : ob[sess].high, " " + priceRng, obBrd, 9);
      // Active zone indicator (entry zone / in zone)
      if(priceActive)
        {
         string entLbl = stateConfirmed ? " \x25C9 ENTRY ZONE" : " \x25CF IN ZONE";
         color entClr = ob[sess].bullish ? C'0,255,128' : C'255,80,80';
         double entAnchor = ob[sess].bullish ? ob[sess].low : ob[sess].high;
         DrawTextObj("SMC_" + p + "_OBENTRY", extEnd - (datetime)(barSec * 5), entAnchor, entLbl, entClr, 11);
        }
     }
// ── FAIR VALUE GAP ───────────────────────────────────────────────
   if(InpDrawFVG && fvg[sess].valid && !fvgGone)
     {
      bool fresh = (fvg[sess].touchCount <= 1);
      color fgc, fgBrd;
      if(priceActive)
        {
         fgc = fvg[sess].bullish ? C'0,80,80' : C'80,25,0';
         fgBrd = fvg[sess].bullish ? C'0,255,210' : C'255,145,30';
        }
      else
         if(fresh)
           {
            fgc = fvg[sess].bullish ? C'0,45,45' : C'55,15,0';
            fgBrd = fvg[sess].bullish ? C'0,210,160' : C'225,100,30';
           }
         else
           {
            fgc = fvg[sess].bullish ? C'5,20,20' : C'28,10,0';      // faded
            fgBrd = fvg[sess].bullish ? C'0,100,78' : C'130,58,15'; // faded
           }
      DrawRect("SMC_" + p + "_FVG", fvg[sess].time, extEnd, fvg[sess].high, fvg[sess].low, fgc, true, false);
      DrawHLine("SMC_" + p + "_FVGH", fvg[sess].time, extEnd, fvg[sess].high, fgBrd, STYLE_DOT, 2);
      DrawHLine("SMC_" + p + "_FVGL", fvg[sess].time, extEnd, fvg[sess].low, fgBrd, STYLE_DOT, 2);
      // Equilibrium midline
      double fvgMid = (fvg[sess].high + fvg[sess].low) / 2.0;
      DrawHLine("SMC_" + p + "_FVGM", fvg[sess].time, extEnd, fvgMid, fgBrd, STYLE_DOT, 1);
      string frTag = fresh ? " \x2666FRESH" : " x" + string(fvg[sess].touchCount);
      string fvgLbl = " FVG" + (fvg[sess].bullish ? "\x25B2" : "\x25BC") + frTag;
      DrawTextObj("SMC_" + p + "_FVGLBL", fvg[sess].time, fvg[sess].high, fvgLbl, fgBrd, 10);
      string priceRng = DoubleToString(fvg[sess].low, _Digits) + "—" + DoubleToString(fvg[sess].high, _Digits);
      DrawTextObj("SMC_" + p + "_FVGRNG", extEnd, fvg[sess].bullish ? fvg[sess].low : fvg[sess].high, " " + priceRng, fgBrd, 9);
      if(priceActive)
        {
         string entLbl = stateConfirmed ? " \x25C9 ENTRY ZONE" : " \x25CF IN ZONE";
         color entClr = fvg[sess].bullish ? C'0,255,210' : C'255,145,30';
         double entAnchor = fvg[sess].bullish ? fvg[sess].low : fvg[sess].high;
         DrawTextObj("SMC_" + p + "_FVGENTRY", extEnd - (datetime)(barSec * 5), entAnchor, entLbl, entClr, 11);
        }
     }
// ── LIQUIDITY LEVELS ─────────────────────────────────────────────
// now already set to ratesORB[0].time above — reuse it (no TimeCurrent() drift)
   for(int k = 0; k < liqCount[sess]; k++)
     {
      double lv = liqLevels[sess][k].price;
      if(lv <= 0)
         continue;
      color lvC = liqLevels[sess][k].swept ? C'100,100,30' : (liqLevels[sess][k].isHigh ? C'220,210,50' : C'50,185,185');
      DrawHLine("SMC_" + p + "_LQ" + string(k), GetSessStart(sess), now + 3600, lv, lvC, STYLE_DOT, 1);
      DrawTextObj("SMC_" + p + "_LQLBL" + string(k), GetSessStart(sess), lv, " " + (liqLevels[sess][k].swept ? "✓" : "◈") + " " + liqLevels[sess][k].label, lvC, 9);
     }
// ── SWEEP MARKER ─────────────────────────────────────────────────
   if(smcState[sess] >= SMC_SWEPT && sweepLvl[sess] > 0)
     {
      color swC = C'255,208,0';
      string swDir = setupBull[sess] ? "▲" : "▼";
      DrawArrow("SMC_" + p + "_SW", sweepTime[sess], sweepLvl[sess], swC,
                setupBull[sess] ? 241 : 242, 5);
      DrawTextObj("SMC_" + p + "_SWLBL", sweepTime[sess], sweepLvl[sess],
                  "  SWEEP " + swDir + "  @" + DoubleToString(sweepLvl[sess], _Digits), swC, 11);
     }
// ── BOS / CHoCH LEVEL ────────────────────────────────────────────
   if(smcState[sess] >= SMC_STRUCTURE && bosLvl[sess] > 0)
     {
      datetime bS = (sweepTime[sess] > 0) ? sweepTime[sess] : GetSessStart(sess);
      datetime bE = bS + (datetime)(PeriodSeconds(ORBTF) * 30);
      color bC = setupBull[sess] ? C'150,195,255' : C'255,160,160';
      DrawHLine("SMC_" + p + "_BOS", bS, bE, bosLvl[sess], bC, STYLE_DASH, 2);
      DrawTextObj("SMC_" + p + "_BOSLBL", bS, bosLvl[sess],
                  "  BOS/CHoCH " + (setupBull[sess] ? "▲" : "▼") +
                  "  @" + DoubleToString(bosLvl[sess], _Digits),
                  bC, 10);
     }
// ── DISPLACEMENT MARKER ──────────────────────────────────────────
   if(dispTime[sess] > 0)
     {
      int d = FindBarByTime(dispTime[sess]);
      if(d >= 0 && d < ArraySize(ratesORB))
        {
         double atrD = GetATR(1);
         double body = MathAbs(ratesORB[d].close - ratesORB[d].open);
         color dC = setupBull[sess] ? C'0,235,115' : C'255,70,70';
         double dAnch = setupBull[sess] ? ratesORB[d].low : ratesORB[d].high;
         string atrLbl = (atrD > 0) ? StringFormat("%.1fxATR", body / atrD) : "";
         DrawArrow("SMC_" + p + "_DISP", ratesORB[d].time, dAnch, dC,
                   setupBull[sess] ? 233 : 234, 5);
         DrawTextObj("SMC_" + p + "_DISPLBL", ratesORB[d].time, dAnch,
                     "  DISP " + (setupBull[sess] ? "▲" : "▼") + "  " + atrLbl, dC, 10);
        }
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawNoEntryOverlay()
  {
   string txtName = "NO_ENTRY_TXT";
// AUDIT FIX: was `dailyBias==NEUTRAL && htfBias==NEUTRAL`, which doesn't match CanEnter()'s
// actual block condition (`InpUseDailyBias && trendBias==BIAS_NEUTRAL`). When
// InpUseDailyBias=false, that neutral-bias block never applies in CanEnter() at all, so this
// banner was showing a false "NO ENTRY" warning whenever htfBias happened to be neutral even
// though the EA could still enter trades. Mirror the real gate exactly.
   bool show = InpUseDailyBias && (GetEntryBiasForLogic() == BIAS_NEUTRAL) || (newsBlocked && newsEventTime > 0);
   if(!show)
     {
      ObjectDelete(0, txtName);
      return;
     }
// Anchored to the top-right corner (fixed margin) instead of chart-width/2 — the status
// panel occupies a large left-upper block (~620x520px), and centering this on narrower
// charts landed the banner right on top of it. Right-anchoring keeps it clear regardless
// of chart size.
   int margin = 24, boxW = 280, boxH = 48;

   if(ObjectFind(0, txtName) < 0)
     {
      if(!ObjectCreate(0, txtName, OBJ_LABEL, 0, 0, 0))
         return;
      ObjectSetInteger(0, txtName, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, txtName, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, txtName, OBJPROP_SELECTABLE, false);
     }
   ObjectSetInteger(0, txtName, OBJPROP_XDISTANCE, margin + 16);
   ObjectSetInteger(0, txtName, OBJPROP_YDISTANCE, margin + 8);
   ObjectSetInteger(0, txtName, OBJPROP_COLOR, C'255,90,90');
   ObjectSetInteger(0, txtName, OBJPROP_FONTSIZE, 28);
   ObjectSetString(0, txtName, OBJPROP_FONT, "Arial Bold");
   ObjectSetString(0, txtName, OBJPROP_TEXT, newsBlocked && newsEventTime > 0 ? "⚠ NEWS BLOCKED" : "⚠ NO ENTRY");
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawHTFBiasBar()
  {
   int pw = 400; // matches DrawStatusPanel's panel width
   int bh = 24;
// ── Bias colours ──────────────────────────────────────────────────
   string biasStr;
   color biasClr, bgClr, brClr;
   switch(htfBias)
     {
      case BIAS_BULLISH:
         biasStr = "▲ BULLISH";
         biasClr = C'0,235,100';
         bgClr = C'4,18,8';
         brClr = C'0,140,60';
         break;
      case BIAS_BEARISH:
         biasStr = "▼ BEARISH";
         biasClr = C'255,85,85';
         bgClr = C'20,5,5';
         brClr = C'175,38,38';
         break;
      default:
         biasStr = "─ NEUTRAL";
         biasClr = C'140,150,205';
         bgClr = C'12,14,32';
         brClr = C'45,50,80';
         break;
     }
// ── Vol regime ───────────────────────────────────────────────────
   string volStr;
   color volClr;
   switch(volRegime)
     {
      case VOL_CALM:
         volStr = "VOL: CALM";
         volClr = C'100,150,215';
         break;
      case VOL_EXPLOSIVE:
         volStr = "VOL: HOT";
         volClr = C'255,160,30';
         break;
      default:
         volStr = "VOL: NORM";
         volClr = C'140,155,180';
         break;
     }
// ── Dealing range ────────────────────────────────────────────────
   string drStr = "DR: ---";
   if(dealingRange.high > dealingRange.low)
     {
      ENUM_PRICE_POS pp = GetPricePos();
      drStr = (pp == PP_PREMIUM) ? "DR: PREM" : (pp == PP_DISCOUNT) ? "DR: DISC"
              : "DR: EQUI";
     }
// ── VP POC + news ─────────────────────────────────────────────────
   string vpStr = vpReady ? "VP: " + DoubleToString(vpPOC, _Digits) : "VP: ---";
   string nwStr;
   color nwClr;
   if(newsBlocked && newsEventTime > 0)
     {
      string wibT = StringSubstr(TimeToString(newsEventTime + (datetime)(7 * 3600), TIME_MINUTES), 11, 5);
      nwStr = "NEWS: ⚠ " + wibT;
      nwClr = C'255,175,50';
     }
   else
      if(!newsBlocked && newsNextTime > 0)
        {
         string wibT = StringSubstr(TimeToString(newsNextTime + (datetime)(7 * 3600), TIME_MINUTES), 11, 5);
         nwStr = "NEWS: ✓ " + wibT;
         nwClr = C'100,210,120';
        }
      else
        {
         nwStr = newsBlocked ? "NEWS: ⚠ BLOCK" : "NEWS: ✓ CLEAR";
         nwClr = newsBlocked ? C'255,175,50' : C'100,210,120';
        }
// ── Draw bar ──────────────────────────────────────────────────────
   PanelRect("HTF_BG", InpPanelX, InpPanelY - bh - 2, pw, bh, bgClr, brClr);
// Left: HTF timeframe + directional bias
   PanelText("HTF_TXTL", InpPanelX + 8, InpPanelY - bh + 1,
             "◈ HTF " + EnumToString(gHTFTF) + "   " + biasStr,
             biasClr, 7);
// Centre: vol regime + dealing range
   PanelText("HTF_TXTM", InpPanelX + 160, InpPanelY - bh + 1,
             volStr + " | " + drStr,
             volClr, 7);
// Right: VP POC + news status
   PanelText("HTF_TXTR", InpPanelX + 280, InpPanelY - bh + 1,
             vpStr + " | " + nwStr,
             nwClr, 7);
  }

//============================================================
// MODULE: ENTRY & RISK PREVIEW (for dashboard display)
//============================================================
void PreviewEntryRisk(int sess, bool isBuy,
                      double &entryPx, double &slPx, double &tpPx,
                      double &slPips, double &tpPips, double &rrRatio,
                      double &riskAmt, double &riskPct)
  {
   entryPx = slPx = tpPx = slPips = tpPips = rrRatio = riskAmt = riskPct = 0;
   double atr = GetATR(1);
   if(atr <= 0)
      return;
   double pt = _Point;
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double orH = GetSessORH(sess), orL = GetSessORL(sess);
   entryPx = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(entryPx <= 0)
      return;
// Shared with ExecuteTrade/ManagePendingOR — see CalcSLTPDist for why this used to be a
// separate (and once out-of-sync) copy of the same SL/TP logic.
   double slDist, tpDist;
   CalcSLTPDist(sess, isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, entryPx, atr, orH, orL, slDist, tpDist);
   if(isBuy)
     {
      slPx = NormalizeDouble(entryPx - slDist, digs);
      tpPx = NormalizeDouble(entryPx + tpDist, digs);
     }
   else
     {
      slPx = NormalizeDouble(entryPx + slDist, digs);
      tpPx = NormalizeDouble(entryPx - tpDist, digs);
     }
   double pip = (digs == 5 || digs == 3) ? pt * 10.0 : pt;
   slPips = pip > 0 ? slDist / pip : 0;
   tpPips = pip > 0 ? tpDist / pip : 0;
   rrRatio = slDist > 0 ? tpDist / slDist : 0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lot = CalcRiskLot(slDist); // mirrors ExecuteTrade — dashboard shows actual risk
   if(tickSz > 0)
      riskAmt = lot * (slDist / tickSz) * tickVal;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal > 0 && riskAmt > 0)
      riskPct = (riskAmt / bal) * 100.0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool GetOpenPosBySession(int sess, double &profit, double &entryPx, double &slCur, double &tpCur)
  {
   profit = entryPx = slCur = tpCur = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PosInfo.SelectByIndex(i))
         continue;
      if(PosInfo.Symbol() != _Symbol || PosInfo.Magic() != InpMagic)
         continue;
      if(GetSessFromCmt(PosInfo.Time()) != sess)
         continue;
      profit = PosInfo.Profit() + PosInfo.Swap();
      entryPx = PosInfo.PriceOpen();
      slCur = PosInfo.StopLoss();
      tpCur = PosInfo.TakeProfit();
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawStatusPanel()
  {
// Full delete + fresh redraw every call: the layout is now dynamic (cards can
// grow/shrink/reorder session-to-session), so this is simpler and more robust
// than tracking exactly what changed since the last redraw. This function runs
// once per new LTF bar (not every tick), so the cost is negligible.
   ObjectsDeleteAll(0, "PNL_");
   ObjectsDeleteAll(0, "TV_BTN_");
   ObjectsDeleteAll(0, "TV_QLOT_");
   ObjectsDeleteAll(0, "TV_QSL_");
   ObjectsDeleteAll(0, "TV_QTP_");

   int px = InpPanelX, py = InpPanelY, pw = 400;
   bool enA[SESS_COUNT] = {InpEnableAsia, InpEnableLondon, InpEnableNY};

// ── PASS 1: compute total height with no drawing side effects ──────────
   int hdrH = 24, accH = 18, chipH = 16, footH = 34;
   int totalH = hdrH + accH;
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(!enA[s] || !SessionQualifiesForBigCard(s))
         totalH += chipH;
      else
         totalH += BigCardHeight(s);
     }
   totalH += footH;

// ── Background frame, sized to the height just computed ────────────────
   PanelRect("PNL_FRM", px - 2, py - 2, pw + 4, totalH + 4, C'40,45,75', C'40,45,75');
   PanelRect("PNL_BG", px, py, pw, totalH, C'8,10,22', C'8,10,22');

// ── PASS 2: draw content on top of the now-correctly-sized background ──
   int y = py;
   PanelRect("PNL_HDR", px, y, pw, hdrH, C'14,18,46', C'14,18,46');
   MqlDateTime tm;
   TimeToStruct(TimeGMT(), tm);
   PanelText("PNL_HL", px + 8, y + 6, StringFormat("◈ ORB SMC v%s | %s", EA_VERSION, _Symbol), clrWhite, 9);
   PanelText("PNL_HR", px + pw - 46, y + 6, StringFormat("%02d:%02d", tm.hour, tm.min), C'140,215,140', 9);
   if(newsBlocked)
      PanelText("PNL_NEWS", px + pw - 150, y + 6, "⚠ NEWS NOW", C'255,90,90', 8);
   else
      if(newsNextTime > 0 && (newsNextTime - TimeGMT()) <= 3600 && (newsNextTime - TimeGMT()) > 0)
         PanelText("PNL_NEWS", px + pw - 150, y + 6,
                   "⚠ News in " + IntegerToString((int)((newsNextTime - TimeGMT()) / 60)) + "m",
                   C'230,200,80', 8);
   y += hdrH;

   double accBal = AccountInfoDouble(ACCOUNT_BALANCE);
   double accEq = AccountInfoDouble(ACCOUNT_EQUITY);
   color accEqCol = (accEq >= accBal) ? C'80,210,130' : C'210,80,80';
   PanelRect("PNL_ACC", px, y, pw, accH, C'10,13,32', C'22,28,58');
   PanelText("PNL_ACCT", px + 8, y + 3, StringFormat("BAL %.2f  EQ %.2f", accBal, accEq), accEqCol, 8);
   y += accH;

   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(!enA[s])
        {
         PanelRect("PNL_CHIP_" + string(s), px, y, pw, chipH, C'9,10,18', C'38,40,55');
         PanelText("PNL_CHIPT_" + string(s), px + 6, y + 2, "⊘ " + SESS_NAME[s] + " — disabled", C'60,63,80', 8);
         y += chipH;
         continue;
        }
      if(!SessionQualifiesForBigCard(s))
        {
         string scnT;
         color scnC, scnBg;
         GetScanLabel(s, scnT, scnC, scnBg);
         PanelRect("PNL_CHIP_" + string(s), px, y, pw, chipH, C'10,12,26', SESS_LINE_CLR[s]);
         PanelText("PNL_CHIPT_" + string(s), px + 6, y + 2, "○ " + SESS_NAME[s] + " — " + scnT, SESS_TXT_CLR[s], 8);
         y += chipH;
         continue;
        }
      y = DrawBigSessionCard(s, px, y, pw);
     }

// ── Footer — 2 rows, all 8 existing metrics, nothing removed ───────────
   double atr = GetATR(1), spd = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double dispLot = InpAutoLot ? CalcRiskLot(atr * gATR_SL) : InpLotSize;
   string volFStr = volRegime == VOL_CALM ? "CALM" : volRegime == VOL_EXPLOSIVE ? "HOT"
                    : volRegime == VOL_HIGH ? "HIGH" : "NORM";
   color volFClr = volRegime == VOL_CALM ? C'100,150,200' : volRegime == VOL_EXPLOSIVE ? C'210,80,80'
                   : volRegime == VOL_HIGH ? C'215,130,50' : C'85,92,128';
   string drInfo = (dealingRange.high > dealingRange.low)
                   ? ("DR:" + DoubleToString(dealingRange.low, _Digits) + "-" + DoubleToString(dealingRange.high, _Digits))
                   : "DR:---";
   PanelRect("PNL_FOOT", px, y, pw, footH, C'11,14,34', C'11,14,34');
   PanelText("PNL_FT1", px + 5, y + 2,
             StringFormat("ATR:%s  SL:%s  TP:%s  Lot:%.2f%s",
                          DoubleToString(atr, _Digits), EnumToString(InpSLMode), EnumToString(InpTPMode),
                          dispLot, InpAutoLot ? "R" : ""),
             C'150,155,180', 7);
   PanelText("PNL_FT2", px + 5, y + 17,
             StringFormat("SPD:%.0fp  VOL:%s  PP:%s  VP:%s  %s",
                          spd, volFStr,
                          ppPP > 0 ? DoubleToString(ppPP, _Digits) : "---",
                          vpReady ? "POC " + DoubleToString(vpPOC, _Digits) : "---", drInfo),
             volFClr, 7);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void GetSMCLabel(int sess, string &txt, color &col)
  {
   switch(smcState[sess])
     {
      case SMC_IDLE:
         txt = "⏸ WAIT OR";
         col = C'70,75,100';
         break;
      case SMC_LOCKED:
         txt = "🔒 OR LOCKED";
         col = C'180,180,70';
         break;
      case SMC_SWEPT:
         txt = "💧 SWEPT " + (setupBull[sess] ? "▲" : "▼");
         col = C'255,210,50';
         break;
      case SMC_STRUCTURE:
         txt = (setupBull[sess] ? "↑ BOS/CHoCH↑" : "↓ BOS/CHoCH↓");
         col = clrWhite;
         break;
      case SMC_DISPLACED:
         txt = (setupBull[sess] ? "⚡ DISPLACE↑" : "⚡ DISPLACE↓");
         col = C'100,220,255';
         break;
      case SMC_ZONE:
         txt = "🎯 OB/FVG ZONE";
         col = C'150,100,255';
         break;
      case SMC_RETRACE:
         txt = "↩ RETRACING";
         col = C'255,160,50';
         break;
      case SMC_CONFIRMED:
         txt = (setupBull[sess] ? "✅ READY BUY" : "✅ READY SELL");
         col = (setupBull[sess] ? C'80,210,130' : C'210,80,80');
         break;
      case SMC_TRADED:
         txt = "✓ TRADED";
         col = C'100,160,200';
         break;
      default:
         txt = "─";
         col = C'70,75,100';
         break;
     }
  }

//+------------------------------------------------------------------+
//| A session gets a full detail card once it has something concrete  |
//| to show: an SMC zone built (>= SMC_ZONE) or, in ORB/fallback mode, |
//| a live breakout. Mirrors the pvHasDir logic already used for the  |
//| entry-preview section (see the comment above PreviewEntryRisk's   |
//| caller) so "big card" and "entry preview shown" stay consistent.  |
//+------------------------------------------------------------------+
bool SessionQualifiesForBigCard(int sess)
  {
   if(!IsSessEnabled(sess))
      return false;
   bool hasDir = UsesSMC(sess) ? (smcState[sess] >= SMC_ZONE) : (GetBkUp(sess) || GetBkDn(sess));
   if(!hasDir && orbFallbackActive[sess])
      hasDir = GetBkUp(sess) || GetBkDn(sess);
   if(!hasDir)
     {
      double p = 0, e = 0, sl = 0, tp = 0;
      hasDir = GetOpenPosBySession(sess, p, e, sl, tp);
     }
   return hasDir;
  }

//+------------------------------------------------------------------+
//| Reason tags for the big-card display — independently re-derive    |
//| each CalcCommonSetupScore condition from the same globals, rather  |
//| than calling into scoring internals. This keeps the panel a pure   |
//| display concern: it reads the same source-of-truth state scoring   |
//| reads, but doesn't depend on scoring's internal point values.      |
//+------------------------------------------------------------------+
void GetHTFTag(bool bul, string &txt, color &col)
  {
   if(InpBiasRequired)
     {
      txt = "~ HTF (gated)";
      col = C'190,180,90';
      return;
     }
   if(htfBias == BIAS_NEUTRAL)
     {
      txt = "~ HTF neutral";
      col = C'190,180,90';
      return;
     }
   bool aligned = (bul && htfBias == BIAS_BULLISH) || (!bul && htfBias == BIAS_BEARISH);
   txt = aligned ? "✓ HTF align" : "✗ HTF conflict";
   col = aligned ? C'80,210,130' : C'210,90,90';
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void GetDRTag(bool bul, string &txt, color &col)
  {
   if(InpUseDealingRange)
     {
      txt = "~ DR (gated)";
      col = C'190,180,90';
      return;
     }
   if(dealingRange.high <= dealingRange.low)
     {
      txt = "~ DR n/a";
      col = C'120,128,165';
      return;
     }
   ENUM_PRICE_POS pp = GetPricePos();
   bool favorable = (bul && pp == PP_DISCOUNT) || (!bul && pp == PP_PREMIUM);
   bool eq = (pp == PP_EQUILIBRIUM);
   txt = favorable ? "✓ DR favorable" : eq ? "~ DR equilibrium" : "✗ DR against";
   col = favorable ? C'80,210,130' : eq ? C'190,180,90' : C'210,90,90';
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void GetVPTag(bool bul, string &txt, color &col)
  {
   if(InpUseVPFilter)
     {
      txt = "~ VP (gated)";
      col = C'190,180,90';
      return;
     }
   if(!vpReady)
     {
      txt = "~ VP n/a";
      col = C'120,128,165';
      return;
     }
   double vpPrice = bul ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool favorable = (bul && vpPrice <= vpVAL) || (!bul && vpPrice >= vpVAH);
   bool inside = (vpPrice >= vpVAL && vpPrice <= vpVAH);
   txt = favorable ? "✓ VP favorable" : inside ? "~ VP inside VA" : "✗ VP against";
   col = favorable ? C'80,210,130' : inside ? C'190,180,90' : C'210,90,90';
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void GetFreshTag(int sess, bool bul, string &txt, color &col)
  {
   if(!UsesSMC(sess))
     {
      txt = "~ zona n/a";
      col = C'120,128,165';
      return;
     }
   if(InpFreshZoneOnly)
     {
      txt = "~ zona (gated)";
      col = C'190,180,90';
      return;
     }
   bool hasFresh = (InpUseOB && ob[sess].valid && ob[sess].touchCount <= 1) ||
                   (InpUseFVG && fvg[sess].valid && fvg[sess].touchCount <= 1);
   txt = hasFresh ? "✓ zona fresh" : "✗ zona used";
   col = hasFresh ? C'80,210,130' : C'210,90,90';
  }

//+------------------------------------------------------------------+
//| Height (in pixels) a big card for this session will occupy, with   |
//| no drawing side effects. Called in the layout's first pass so the  |
//| panel's total height — and therefore the background frame's size — |
//| is known before any content is drawn (content must be drawn AFTER  |
//| the resized frame/background, or the frame would paint over it).   |
string GetSMCPipelineProgress(int sess)
  {
   if(!UsesSMC(sess))
      return "MODE: PURE ORB";
   switch(smcState[sess])
     {
      case SMC_IDLE: return "SMC [1/7]: AWAIT OR LOCK";
      case SMC_LOCKED: return "SMC [2/7]: OR LOCKED (SCAN SWEEP)";
      case SMC_SWEPT: return "SMC [3/7]: " + (setupBull[sess] ? "SWEEP LOW ▲" : "SWEEP HIGH ▼");
      case SMC_STRUCTURE: return "SMC [4/7]: BOS/CHoCH " + (setupBull[sess] ? "▲" : "▼");
      case SMC_DISPLACED: return "SMC [5/7]: DISPLACEMENT " + (setupBull[sess] ? "▲" : "▼");
      case SMC_ZONE: return "SMC [6/7]: OB/FVG ZONE FORMED";
      case SMC_RETRACE: return "SMC [6/7]: RETRACE IN ZONE";
      case SMC_CONFIRMED: return "SMC [7/7]: CONFIRMED READY " + (setupBull[sess] ? "BUY ▲" : "SELL ▼");
      case SMC_TRADED: return "SMC: EXECUTED TRADED";
      default: return "SMC: IDLE";
     }
  }

string GetSessORBMetricsStr(int sess)
  {
   double orH = GetSessORH(sess), orL = GetSessORL(sess);
   if(orH <= 0 || orL <= 0 || orH <= orL)
      return "ORB Range: Waiting OR...";
   int pips = (int)MathRound((orH - orL) / _Point);
   return StringFormat("ORB Range: %.5f - %.5f (%dp)", orL, orH, pips);
  }

//+------------------------------------------------------------------+
int BigCardHeight(int sess)
  {
   int h = 124; // header(16) + pipeline/orb(14) + score(14) + entry-risk(14) + tags(24) + buttons row(42) + padding
   double profit, entryPx, slCur, tpCur;
   if(GetOpenPosBySession(sess, profit, entryPx, slCur, tpCur))
      h += 14;
   if(InpEnableLTFSuggestEngine && ltfSuggState[sess] >= SMC_ZONE)
      h += 12;
   return h;
  }

//+------------------------------------------------------------------+
//| Draws one big session card at (px, y), width pw. Returns the Y     |
//| position immediately below the card, for the caller's running     |
//| Y-cursor. Must be called only after the background frame has       |
//| already been sized/drawn for this frame's total height (see        |
//| DrawStatusPanel's two-pass structure) so this content paints on    |
//| top of the background, not the other way around.                  |
//+------------------------------------------------------------------+
int DrawBigSessionCard(int sess, int px, int y, int pw)
  {
   string s = string(sess);
   bool bul;
   if(UsesSMC(sess))
      bul = setupBull[sess];
   else
     {
      bool bkU = GetBkUp(sess), bkD = GetBkDn(sess);
      bul = (bkU && bkD) ? (dailyBias != BIAS_BEARISH) : bkU;
     }

   PanelRect("PNL_CARD_" + s, px, y, pw, BigCardHeight(sess), C'13,16,35', SESS_LINE_CLR[sess]);

// Header line: status + session name + scan-banner text
   string scnT;
   color scnC, scnBg;
   GetScanLabel(sess, scnT, scnC, scnBg);
   PanelText("PNL_HDR_" + s, px + 6, y + 2, SESS_NAME[sess] + " — " + scnT, scnC, 9);
   string gateTxt;
   color gateCol;
   GetGateStatus(sess, gateTxt, gateCol);
   PanelText("PNL_GATE_" + s, px + pw - 110, y + 2, gateTxt, gateCol, 8);
   y += 16;

// Pipeline & ORB Metrics line
   string pipelineStr = GetSMCPipelineProgress(sess);
   string orbStr = GetSessORBMetricsStr(sess);
   PanelText("PNL_PIPE_" + s, px + 6, y, pipelineStr + " | " + orbStr, C'130,210,255', 8);
   y += 14;

// Score line — uses the cached probScore[] array (same value WriteWebData exports
// to the web dashboard) rather than recomputing CalcProbScore live, so the on-chart
// card and the web dashboard always agree. Shows "OFF" when the probability-score
// gate is disabled, since the score gates nothing in that case.
   double score = probScore[sess];
   string scoreStr = InpUseProbScore ? (DoubleToString(score, 0) + " (" + GetProbGrade(score) + ")") : "OFF";
   PanelText("PNL_SCORE_" + s, px + 6, y, "Score " + scoreStr, C'190,195,220', 8);
   y += 14;

// Entry/risk line
   double pvEntry = 0, pvSL = 0, pvTP = 0, pvSLp = 0, pvTPp = 0, pvRR = 0, pvRisk = 0, pvRiskPct = 0;
   if(GetSessORH(sess) > 0)
      PreviewEntryRisk(sess, bul, pvEntry, pvSL, pvTP, pvSLp, pvTPp, pvRR, pvRisk, pvRiskPct);
   string erLine = (pvEntry > 0)
                   ? StringFormat("Entry %s · SL %s · TP %s · RR 1:%.1f",
                                  DoubleToString(pvEntry, _Digits), DoubleToString(pvSL, _Digits),
                                  DoubleToString(pvTP, _Digits), pvRR)
                   : "Entry/SL/TP — belum tersedia";
   PanelText("PNL_ER_" + s, px + 6, y, erLine, C'170,200,230', 8);
   y += 14;

// Reason tags — one row, four short tags
   string tHTF, tDR, tVP, tFresh;
   color cHTF, cDR, cVP, cFresh;
   GetHTFTag(bul, tHTF, cHTF);
   GetDRTag(bul, tDR, cDR);
   GetVPTag(bul, tVP, cVP);
   GetFreshTag(sess, bul, tFresh, cFresh);
   PanelText("PNL_TAG1_" + s, px + 6, y, tHTF, cHTF, 7);
   PanelText("PNL_TAG2_" + s, px + 106, y, tDR, cDR, 7);
   PanelText("PNL_TAG3_" + s, px + 206, y, tVP, cVP, 7);
   PanelText("PNL_TAG4_" + s, px + 6, y + 10, tFresh, cFresh, 7);
   y += 24;

// Quick-trade buttons — recreated fresh every redraw (DrawStatusPanel already
// deleted all TV_BTN_/TV_QLOT_/TV_QSL_/TV_QTP_ objects at the top of this frame),
// so no stale-position risk even though the card's Y offset can change between
// redraws as other sessions grow/shrink.
   int bx = px + pw - 80, by = y;
   string bBuy = "TV_BTN_BUY_" + s, bSell = "TV_BTN_SELL_" + s, bClose = "TV_BTN_CLOSE_" + s;
   ObjectCreate(0, bBuy, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, bBuy, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bBuy, OBJPROP_XDISTANCE, bx);
   ObjectSetInteger(0, bBuy, OBJPROP_YDISTANCE, by);
   ObjectSetInteger(0, bBuy, OBJPROP_XSIZE, 70);
   ObjectSetInteger(0, bBuy, OBJPROP_YSIZE, 18);
   ObjectSetString(0, bBuy, OBJPROP_TEXT, "BUY");
   ObjectSetInteger(0, bBuy, OBJPROP_COLOR, C'20,20,20');
   ObjectSetInteger(0, bBuy, OBJPROP_BGCOLOR, C'20,140,200');
   ObjectCreate(0, bSell, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, bSell, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bSell, OBJPROP_XDISTANCE, bx);
   ObjectSetInteger(0, bSell, OBJPROP_YDISTANCE, by + 20);
   ObjectSetInteger(0, bSell, OBJPROP_XSIZE, 70);
   ObjectSetInteger(0, bSell, OBJPROP_YSIZE, 18);
   ObjectSetString(0, bSell, OBJPROP_TEXT, "SELL");
   ObjectSetInteger(0, bSell, OBJPROP_COLOR, C'20,20,20');
   ObjectSetInteger(0, bSell, OBJPROP_BGCOLOR, C'220,80,80');
   ObjectCreate(0, bClose, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, bClose, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bClose, OBJPROP_XDISTANCE, bx - 74);
   ObjectSetInteger(0, bClose, OBJPROP_YDISTANCE, by + 10);
   ObjectSetInteger(0, bClose, OBJPROP_XSIZE, 70);
   ObjectSetInteger(0, bClose, OBJPROP_YSIZE, 18);
   ObjectSetString(0, bClose, OBJPROP_TEXT, "CLOSE");
   ObjectSetInteger(0, bClose, OBJPROP_COLOR, C'20,20,20');
   ObjectSetInteger(0, bClose, OBJPROP_BGCOLOR, C'120,120,120');
   string qLot = "TV_QLOT_" + s, qSL = "TV_QSL_" + s, qTP = "TV_QTP_" + s;
   PanelText(qLot, px + 6, by, "L:" + DoubleToString(gQuickLotSess[sess], 2), C'200,200,220', 7);
   PanelText(qSL, px + 6, by + 12, "SL:" + string(gQuickSL_pipsSess[sess]) + "p", C'180,180,200', 7);
   PanelText(qTP, px + 56, by + 12, "TP:" + string(gQuickTP_pipsSess[sess]) + "p", C'180,180,200', 7);
   y += 42;

// P&L line (only if a position is open for this session)
   double profit, entryPx, slCur, tpCur;
   if(GetOpenPosBySession(sess, profit, entryPx, slCur, tpCur))
     {
      color pc = (profit >= 0) ? C'80,210,130' : C'210,80,80';
      string sign = (profit >= 0) ? "+" : "";
      PanelText("PNL_PNL_" + s, px + 6, y,
                "P&L " + sign + DoubleToString(profit, 2) + " · SL " + DoubleToString(slCur, _Digits) +
                " · TP " + DoubleToString(tpCur, _Digits),
                pc, 8);
      y += 14;
     }

// LTF Suggestion row — always its own line
   if(InpEnableLTFSuggestEngine && ltfSuggState[sess] >= SMC_ZONE)
     {
      string ltfTxt;
      color ltfCol;
      if(ltfSuggState[sess] == SMC_TRADED)
        {
         ltfTxt = (ltfSuggBull[sess] ? "▲ BUY" : "▼ SELL") + " " + DoubleToString(ltfSuggScore[sess], 0) +
                  "(" + GetProbGrade(ltfSuggScore[sess]) + ")" + (ltfSuggActed[sess] ? " [EXECUTED]" : "");
         ltfCol = ltfSuggBull[sess] ? C'80,210,130' : C'210,80,80';
        }
      else
        {
         ltfTxt = (ltfSuggBull[sess] ? "▲ building" : "▼ building") + " " + EnumToString(ltfSuggState[sess]);
         ltfCol = C'150,160,190';
        }
      PanelText("PNL_LTF_" + s, px + 6, y, "🎯 LTF " + ltfTxt, ltfCol, 7);
      y += 12;
     }

   return y;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void GetScanLabel(int sess, string &txt, color &col, color &bgCol)
  {
// Already traded this session
   if(smcState[sess] == SMC_TRADED || tradeBuyDone[sess] || tradeSellDone[sess])
     {
      txt = "✓  DONE";
      col = C'80,85,115';
      bgCol = C'12,14,28';
      return;
     }
   bool hasDir = false;
   bool bul = false;
   if(UsesSMC(sess))
     {
      hasDir = (smcState[sess] >= SMC_SWEPT);
      bul = setupBull[sess];
     }
   else
     {
      bool bU = GetBkUp(sess), bD = GetBkDn(sess);
      hasDir = (bU || bD);
      bul = bU;
     }
// Also show direction when ORB fallback is armed
   if(!hasDir && orbFallbackActive[sess])
     {
      bool bU = GetBkUp(sess), bD = GetBkDn(sess);
      hasDir = (bU || bD);
      bul = bU;
     }
   if(!hasDir)
     {
      // No sweep/breakout yet — show daily bias as scanning target
      if(InpUseDailyBias && dailyBias == BIAS_BULLISH)
        {
         txt = UsesSMC(sess) ? "▲ BUY: SWEEP LOWS" : "▲ BUY: BREAK-H | BOUNCE-L";
         col = C'0,210,110';
         bgCol = C'0,42,18';
        }
      else
         if(InpUseDailyBias && dailyBias == BIAS_BEARISH)
           {
            txt = UsesSMC(sess) ? "▼ SELL: SWEEP HIGHS" : "▼ SELL: BREAK-L | BOUNCE-H";
            col = C'210,80,80';
            bgCol = C'46,8,8';
           }
         else
           {
            txt = "─  SCANNING ...";
            col = C'65,70,95';
            bgCol = C'10,12,25';
           }
      return;
     }
   bool htfOK = !(htfBias == (bul ? BIAS_BEARISH : BIAS_BULLISH));
   bool dayOK = !(dailyBias == (bul ? BIAS_BEARISH : BIAS_BULLISH));
   string dir = bul ? "▲  BUY" : "▼  SELL";
   if(htfOK && dayOK)
     {
      txt = dir + "  ✓  READY";
      col = bul ? C'0,215,110' : C'210,80,80';
      bgCol = bul ? C'0,60,24' : C'62,8,8';
     }
   else
     {
      string blocker = (!htfOK && !dayOK) ? "HTF+DAY" : (!htfOK ? "HTF" : "DAY");
      txt = "⛔  " + dir + "  [" + blocker + "]";
      col = C'225,155,35';
      bgCol = C'58,38,0';
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void GetGateStatus(int sess, string &txt, color &col)
  {
   if(!IsSessEnabled(sess))
     {
      txt = "○ DISABLED";
      col = C'50,53,70';
      return;
     }
   double orH = GetSessORH(sess), orL = GetSessORL(sess);
   datetime orE = GetSessOREnd(sess);
   if(orH <= 0 || orL <= 0)
     {
      txt = "⏳ AWAIT OR";
      col = C'100,100,55';
      return;
     }
   if(gMinORBRange > 0 && (orH - orL) / _Point < gMinORBRange)
     {
      txt = "⚠ RANGE SMALL";
      col = C'215,130,50';
      return;
     }
   if(TimeCurrent() < orE)
     {
      txt = "⏳ IN RANGE";
      col = C'100,100,55';
      return;
     }
   if(!GetSessActive(sess))
     {
      txt = "○ OFF SESSION";
      col = C'55,60,85';
      return;
     }
   MqlDateTime tm;
   TimeToStruct(TimeGMT(), tm);
   if(tm.hour * 60 + tm.min >= GetSessCutoff(sess))
     {
      txt = "✗ CUTOFF";
      col = C'215,130,50';
      return;
     }
   if(sessTradeCount[sess] >= InpMaxTrades)
     {
      txt = "✗ MAX TRADES";
      col = C'215,130,50';
      return;
     }
   if(HasOpenOrPendingTrade())
     {
      txt = "● IN TRADE";
      col = C'0,195,215';
      return;
     }
   if(UsesSMC(sess) && smcState[sess] < SMC_CONFIRMED)
     {
      txt = "⏳ SMC STEP " + string((int)smcState[sess] + 1) + "/7";
      col = C'100,140,200';
      return;
     }
   if(newsBlocked)
     {
      txt = "⚠ NEWS";
      col = C'215,130,50';
      return;
     }
// AUDIT FIX: this used to fall straight through to "✓ READY" without checking the
// Probability Score gate or (for ORB-mode) Confirmation Mode — both are real hard-blocks
// in CanEnter(), so the panel could tell the trader "READY" on a setup that would not
// actually fire. Dealing Range / VP / zone-freshness are still not replicated here (they
// need a resolved trade direction, which this administrative gate doesn't track); SCORE
// row and SCAN banner remain the place to cross-check those.
   if(InpUseProbScore && probScore[sess] < (double)InpMinProbScore)
     {
      txt = "⚠ LOW SCORE";
      col = C'215,130,50';
      return;
     }
   bool buyReady = IsPipelineDirectionReady(sess, true);
   bool sellReady = IsPipelineDirectionReady(sess, false);
   if(!buyReady && !sellReady)
     {
      txt = UsesSMC(sess) ? "⚠ CONFIRM" : "⚠ ORB FILTER";
      col = C'215,130,50';
      return;
     }
   if(UsesSMC(sess) && !CheckConfirmationMode(sess))
     {
      txt = "⚠ CONFIRM";
      col = C'215,130,50';
      return;
     }
   txt = "✓ READY";
   col = C'80,210,130';
  }

//============================================================
// MODULE: ALERT ENGINE
//============================================================
void ORBAlertEngine()
  {
   for(int s = 0; s < SESS_COUNT; s++)
     {
      bool bU = GetBkUp(s), bD = GetBkDn(s);
      if(bU && !alertBuy[s])
        {
         SendAlt(SESS_NAME[s] + " BUY BREAKOUT↑");
         alertBuy[s] = true;
         alertSell[s] = false;
        }
      if(bD && !alertSell[s])
        {
         SendAlt(SESS_NAME[s] + " SELL BREAKOUT↓");
         alertSell[s] = true;
         alertBuy[s] = false;
        }
      if(smcState[s] == SMC_SWEPT && !alertSweep[s])
        {
         SendAlt(SESS_NAME[s] + " LIQ SWEEP " + (setupBull[s] ? "▲" : "▼"));
         alertSweep[s] = true;
        }
      if(smcState[s] == SMC_STRUCTURE && !alertBOS[s])
        {
         SendAlt(SESS_NAME[s] + " BOS/CHoCH CONFIRMED");
         alertBOS[s] = true;
        }
      if(smcState[s] == SMC_ZONE && !alertOB[s])
        {
         SendAlt(SESS_NAME[s] + " OB/FVG FORMED");
         alertOB[s] = true;
        }
      if(smcState[s] == SMC_CONFIRMED && !alertReady[s])
        {
         SendAlt(SESS_NAME[s] + " SETUP READY → ENTRY");
         alertReady[s] = true;
        }
      if(GetRjH(s) && !alertRjH[s])
        {
         SendAlt(SESS_NAME[s] + " REJECT HIGH");
         alertRjH[s] = true;
        }
      if(GetRjL(s) && !alertRjL[s])
        {
         SendAlt(SESS_NAME[s] + " REJECT LOW");
         alertRjL[s] = true;
        }
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void SendAlt(string msg)
  {
   if(InpAlerts)
      Alert(_Symbol + "|" + msg);
   if(InpPush)
      SendNotification(_Symbol + "|" + msg);
  }

//============================================================
// DRAW PRIMITIVES
//============================================================
// ANTI-REPAINT: all primitives use create-if-absent + update-in-place
// so objects are never deleted and recreated unnecessarily (eliminates flicker)
void DrawRect(string n, datetime t1, datetime t2, double hi, double lo, color c, bool fill, bool back)
  {
   if(ObjectFind(0, n) < 0)
     {
      if(!ObjectCreate(0, n, OBJ_RECTANGLE, 0, t1, hi, t2, lo))
         return;
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
     }
   else
     {
      ObjectMove(0, n, 0, t1, hi);
      ObjectMove(0, n, 1, t2, lo);
     }
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_FILL, fill);
   ObjectSetInteger(0, n, OBJPROP_BACK, back);
  }

//+------------------------------------------------------------------+
//| AMD Phase Detection — visual rendering.                           |
//+------------------------------------------------------------------+
void DrawAMDZone()
  {
   if(!InpEnableAMDDetection || amdPhase == AMD_NONE)
     {
      ObjectDelete(0, "AMD_ZONE");
      ObjectDelete(0, "AMD_LABEL");
      return;
     }
   color zoneColor;
   string label;
   switch(amdPhase)
     {
      case AMD_ACCUMULATION:
         zoneColor = C'40,140,80';
         label = "AKUMULASI";
         break;
      case AMD_DISTRIBUTION:
         zoneColor = C'170,80,30';
         label = "DISTRIBUSI";
         break;
      case AMD_MANIPULATION:
         zoneColor = C'230,210,40';
         label = "MANIPULASI";
         break;
      default:
         zoneColor = C'70,90,130';
         label = "KONSOLIDASI";
         break;
     }
   DrawRect("AMD_ZONE", amdRangeStart, TimeCurrent(), amdRangeHigh, amdRangeLow, zoneColor, false, false);
   DrawTextObj("AMD_LABEL", amdRangeStart, amdRangeHigh, label, zoneColor, 9);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawHLine(string n, datetime t1, datetime t2, double p, color c, ENUM_LINE_STYLE s, int w)
  {
   if(ObjectFind(0, n) < 0)
     {
      if(!ObjectCreate(0, n, OBJ_TREND, 0, t1, p, t2, p))
         return;
      ObjectSetInteger(0, n, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
     }
   else
     {
      ObjectMove(0, n, 0, t1, p);
      ObjectMove(0, n, 1, t2, p);
     }
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_STYLE, s);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, w);
   ObjectSetInteger(0, n, OBJPROP_BACK, false);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawVLine(string n, datetime t, color c, ENUM_LINE_STYLE s, int w)
  {
   if(ObjectFind(0, n) < 0)
     {
      if(!ObjectCreate(0, n, OBJ_VLINE, 0, t, 0))
         return;
      ObjectSetInteger(0, n, OBJPROP_BACK, true);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
     }
   else
     {
      ObjectMove(0, n, 0, t, 0);
     }
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_STYLE, s);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, w);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawArrow(string n, datetime t, double p, color c, int code, int w = 3)
  {
   if(ObjectFind(0, n) < 0)
     {
      if(!ObjectCreate(0, n, OBJ_ARROW, 0, t, p))
         return;
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
     }
   else
     {
      ObjectMove(0, n, 0, t, p);
     }
   ObjectSetInteger(0, n, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, w);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawTextObj(string n, datetime t, double p, string txt, color c, int sz)
  {
   if(ObjectFind(0, n) < 0)
     {
      if(!ObjectCreate(0, n, OBJ_TEXT, 0, t, p))
         return;
      ObjectSetString(0, n, OBJPROP_FONT, "Arial Bold");
      ObjectSetDouble(0, n, OBJPROP_ANGLE, 0);
      ObjectSetInteger(0, n, OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
     }
   else
     {
      ObjectMove(0, n, 0, t, p);
     }
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, sz);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void PanelRect(string n, int x, int y, int w, int h, color bg, color brd)
  {
   if(ObjectFind(0, n) < 0)
     {
      if(!ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0))
         return;
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_BACK, false);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
     }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, brd);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void PanelText(string n, int x, int y, string txt, color c, int sz)
  {
   if(ObjectFind(0, n) < 0)
     {
      if(!ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0))
         return;
      ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
     }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, sz);
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
//============================================================
// MODULE: POSITION LEVEL VISUALS
//============================================================
void PosHLine(string name, double price, color clr, ENUM_LINE_STYLE sty, int w)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, sty);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, w);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void PosTextLabel(string name, double price, string txt, color clr)
  {
// ANTI-REPAINT: anchor to bar open time, not TimeCurrent()
   datetime t = ((ArraySize(ratesORB) > 0) ? ratesORB[0].time : TimeCurrent()) + (datetime)(PeriodSeconds(ORBTF) * 3);
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, t);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
// Removes the Entry/TP1/SL/DynTP lines+labels drawn for one closed/replaced position,
// so a finished trade doesn't leave permanent orphaned objects on the chart.
void DeletePositionLevelObjs(ulong ticket)
  {
   string tk = string(ticket);
   ObjectDelete(0, "POS_ENT_" + tk);
   ObjectDelete(0, "POS_ENTL_" + tk);
   ObjectDelete(0, "POS_TP1_" + tk);
   ObjectDelete(0, "POS_TP1L_" + tk);
   ObjectDelete(0, "POS_SL_" + tk);
   ObjectDelete(0, "POS_SLL_" + tk);
   ObjectDelete(0, "POS_DTP_" + tk);
   ObjectDelete(0, "POS_DTPL_" + tk);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawPositionLevels()
  {
   static ulong lastDrawnTicket[SESS_COUNT] = {0, 0, 0};
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   color sessClr[SESS_COUNT] = {clrCornflowerBlue, clrDarkOrange, clrCrimson};
   for(int s = 0; s < SESS_COUNT; s++)
     {
      ulong ticket = sessTicket[s];
      bool positionLive = (ticket != 0 && PosInfo.SelectByTicket(ticket));
      if(!positionLive)
        {
         // Position closed (or session never traded / was reset) — clean up whatever this
         // session last drew so it doesn't linger on the chart after the trade is gone.
         if(lastDrawnTicket[s] != 0)
           {
            DeletePositionLevelObjs(lastDrawnTicket[s]);
            lastDrawnTicket[s] = 0;
           }
         continue;
        }
      if(lastDrawnTicket[s] != 0 && lastDrawnTicket[s] != ticket)
         DeletePositionLevelObjs(lastDrawnTicket[s]); // a new trade replaced the previous one
      lastDrawnTicket[s] = ticket;
      bool isBuy = (PosInfo.PositionType() == POSITION_TYPE_BUY);
      double opn = PosInfo.PriceOpen();
      double sl = PosInfo.StopLoss();
      double pnl = PosInfo.Profit() + PosInfo.Swap();
      string tk = string(ticket);
      string sname = SESS_NAME[s];
      color clrAcc = sessClr[s];
      color clrDir = isBuy ? clrDodgerBlue : clrOrangeRed;
      color clrOpp = isBuy ? clrOrangeRed : clrDodgerBlue;
      color clrPnL = (pnl >= 0) ? C'0,200,80' : clrTomato;
      string pnlStr = (pnl >= 0 ? "+" : "") + DoubleToString(pnl, 2) + " USD";
      string dir = isBuy ? "BUY" : "SELL";
      // --- Entry line + label ---
      PosHLine("POS_ENT_" + tk, opn, clrDir, STYLE_DOT, 1);
      PosTextLabel("POS_ENTL_" + tk, opn,
                   "[" + sname + "] " + dir + " #" + tk + "   @" + DoubleToString(opn, digs) + "   " + pnlStr,
                   clrPnL);
      // --- tp1Level line + label ---
      if(tp1Level[s] > 0)
        {
         bool taken = partialTaken[s];
         color tp1Clr = taken ? clrGray : clrAcc;
         ENUM_LINE_STYLE tp1Sty = taken ? STYLE_DOT : STYLE_DASH;
         string takenTag = taken ? "  [partial taken]" : "";
         PosHLine("POS_TP1_" + tk, tp1Level[s], tp1Clr, tp1Sty, 1);
         PosTextLabel("POS_TP1L_" + tk, tp1Level[s],
                      "[" + sname + "] TP1  #" + tk + "   " + DoubleToString(tp1Level[s], digs) + "   " + pnlStr + takenTag,
                      tp1Clr);
        }
      // --- SL line + label ---
      if(sl > 0)
        {
         PosHLine("POS_SL_" + tk, sl, clrOpp, STYLE_DOT, 1);
         PosTextLabel("POS_SLL_" + tk, sl,
                      "[" + sname + "] SL  #" + tk + "   " + DoubleToString(sl, digs),
                      clrOpp);
        }
      // --- Dynamic TP line + label ---
      double curTP = PosInfo.TakeProfit();
      if(curTP > 0)
        {
         double oneR = (tp1Level[s] > 0) ? MathAbs(tp1Level[s] - opn) : 0;
         string rTag = (oneR > 0) ? "   " + DoubleToString(MathAbs(curTP - opn) / oneR, 1) + "R" : "";
         color tpClr;
         ENUM_LINE_STYLE tpSty;
         string stateTag;
         if(gDynTPState[s] == 1)
           {
            tpClr = C'50,220,100';
            tpSty = STYLE_SOLID;
            stateTag = " [SURGE]";
           }
         else
            if(gDynTPState[s] == -1)
              {
               tpClr = C'220,170,30';
               tpSty = STYLE_SOLID;
               stateTag = " [EXHAUST]";
              }
            else
              {
               tpClr = C'130,130,130';
               tpSty = STYLE_DASH;
               stateTag = "";
              }
         string lbl = InpDynTP ? "DynTP" : "TP";
         PosHLine("POS_DTP_" + tk, curTP, tpClr, tpSty, 1);
         PosTextLabel("POS_DTPL_" + tk, curTP,
                      "[" + sname + "] " + lbl + rTag + "  #" + tk + "   " + DoubleToString(curTP, digs) + stateTag,
                      tpClr);
        }
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
// Removes the Trigger/SL/TP lines+labels drawn for one cancelled/filled/expired pending order.
void DeletePendingORObjs(ulong ticket)
  {
   string tk = string(ticket);
   ObjectDelete(0, "PO_TRG_" + tk);
   ObjectDelete(0, "PO_TRGL_" + tk);
   ObjectDelete(0, "PO_SL_" + tk);
   ObjectDelete(0, "PO_SLL_" + tk);
   ObjectDelete(0, "PO_TP_" + tk);
   ObjectDelete(0, "PO_TPL_" + tk);
  }

// Draws Trigger/SL/TP lines for an active OR-lock pending stop order (InpUsePendingOR), so it's
// visible on chart before it fills — same PosHLine/PosTextLabel primitives DrawPositionLevels()
// uses for live trades, with a dash-dot style on the trigger line to read as "not filled yet".
void DrawPendingORLevels()
  {
   static ulong lastDrawnPOrTicket[SESS_COUNT] = {0, 0, 0};
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   for(int s = 0; s < SESS_COUNT; s++)
     {
      ulong ticket = pendingORTicket[s];
      bool live = (ticket != 0 && OrderSelect(ticket));
      if(!live)
        {
         if(lastDrawnPOrTicket[s] != 0)
           {
            DeletePendingORObjs(lastDrawnPOrTicket[s]);
            lastDrawnPOrTicket[s] = 0;
           }
         continue;
        }
      if(lastDrawnPOrTicket[s] != 0 && lastDrawnPOrTicket[s] != ticket)
         DeletePendingORObjs(lastDrawnPOrTicket[s]); // a replaced order — clear the old one's objects
      lastDrawnPOrTicket[s] = ticket;
      string tk = string(ticket);
      string sname = SESS_NAME[s];
      bool isBuy = ((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_STOP);
      double trigPx = OrderGetDouble(ORDER_PRICE_OPEN);
      double slPx = OrderGetDouble(ORDER_SL);
      double tpPx = OrderGetDouble(ORDER_TP);
      color clrDir = isBuy ? clrDodgerBlue : clrOrangeRed;
      string dir = isBuy ? "BUY STOP" : "SELL STOP";
      PosHLine("PO_TRG_" + tk, trigPx, clrDir, STYLE_DASHDOT, 1);
      PosTextLabel("PO_TRGL_" + tk, trigPx,
                   "[" + sname + "] PENDING " + dir + " #" + tk + "   @" + DoubleToString(trigPx, digs), clrDir);
      if(slPx > 0)
        {
         PosHLine("PO_SL_" + tk, slPx, clrTomato, STYLE_DOT, 1);
         PosTextLabel("PO_SLL_" + tk, slPx,
                      "[" + sname + "] PENDING SL  #" + tk + "   " + DoubleToString(slPx, digs), clrTomato);
        }
      if(tpPx > 0)
        {
         PosHLine("PO_TP_" + tk, tpPx, C'0,200,80', STYLE_DOT, 1);
         PosTextLabel("PO_TPL_" + tk, tpPx,
                      "[" + sname + "] PENDING TP  #" + tk + "   " + DoubleToString(tpPx, digs), C'0,200,80');
        }
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CleanAll()
  {
   string pfx[] = {"SZ_", "KZ_", "VL_", "ORL_", "ORB_BOX_", "SIG", "FIB_", "SMC_", "HTF_", "PNL_", "PTAG_", "LBL_", "PP_", "VP_", "EXT_", "POS_", "PO_", "EQ_", "ERD_", "NO_ENTRY_", "AMD_", "TV_POS_"};
   for(int i = 0; i < ArraySize(pfx); i++)
      ObjectsDeleteAll(0, pfx[i]);
   ChartRedraw();
  }

//============================================================
// ACCESSORS
//============================================================
double GetSessORH(int s)
  {
   switch(s)
     {
      case SESS_ASIA:
         return asiaORHigh;
      case SESS_LONDON:
         return londonORHigh;
      default:
         return nyORHigh;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetSessORL(int s)
  {
   switch(s)
     {
      case SESS_ASIA:
         return asiaORLow;
      case SESS_LONDON:
         return londonORLow;
      default:
         return nyORLow;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime GetSessOREnd(int s)
  {
   switch(s)
     {
      case SESS_ASIA:
         return asiaOREnd;
      case SESS_LONDON:
         return londonOREnd;
      default:
         return nyOREnd;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool GetSessActive(int s)
  {
   switch(s)
     {
      case SESS_ASIA:
         return asiaSession;
      case SESS_LONDON:
         return londonSession;
      default:
         return nySession;
     }
  }

// Whether the session is still within its kill-zone (early, highest-participation window).
// Unlike GetSessActive(), this is NOT already hard-gated in CanEnter(), so it is safe to
// use as a genuinely discriminating CalcProbScore component (see AUDIT FIX there).
bool GetSessKZ(int s)
  {
   switch(s)
     {
      case SESS_ASIA:
         return asiaKZ;
      case SESS_LONDON:
         return londonKZ;
      default:
         return nyKZ;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsSessEnabled(int s)
  {
// F2: Auto-disable London for XAU/Gold — backtest shows London ORB on Gold loses -$2,086 (-4% WR)
   if(InpAutoDisableLondonXAU && s == SESS_LONDON)
     {
      if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
         return false;
     }
   switch(s)
     {
      case SESS_ASIA:
         return InpEnableAsia;
      case SESS_LONDON:
         return InpEnableLondon;
      default:
         return InpEnableNY;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int GetSessCutoff(int s)
  {
   switch(s)
     {
      case SESS_ASIA:
         return InpAsiaCutH * 60 + InpAsiaCutM;
      case SESS_LONDON:
         return InpLondonCutH * 60 + InpLondonCutM;
      default:
         return InpNYCutH * 60 + InpNYCutM;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime GetSessStart(int s)
  {
   switch(s)
     {
      case SESS_ASIA:
         return asiaStart;
      case SESS_LONDON:
         return londonStart;
      default:
         return nyStart;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool GetBkUp(int s)
  {
   switch(s)
     {
      case SESS_ASIA:
         return asiaBreakoutUp;
      case SESS_LONDON:
         return londonBreakoutUp;
      default:
         return nyBreakoutUp;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool GetBkDn(int s)
  {
   switch(s)
     {
      case SESS_ASIA:
         return asiaBreakoutDown;
      case SESS_LONDON:
         return londonBreakoutDown;
      default:
         return nyBreakoutDown;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool GetFBH(int s)
  {
   switch(s)
     {
      case SESS_ASIA:
         return asiaFBH;
      case SESS_LONDON:
         return londonFBH;
      default:
         return nyFBH;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool GetFBL(int s)
  {
   switch(s)
     {
      case SESS_ASIA:
         return asiaFBL;
      case SESS_LONDON:
         return londonFBL;
      default:
         return nyFBL;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool GetRjH(int s)
  {
   switch(s)
     {
      case SESS_ASIA:
         return asiaRejectHigh;
      case SESS_LONDON:
         return londonRejectHigh;
      default:
         return nyRejectHigh;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool GetRjL(int s)
  {
   switch(s)
     {
      case SESS_ASIA:
         return asiaRejectLow;
      case SESS_LONDON:
         return londonRejectLow;
      default:
         return nyRejectLow;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void LogMsg(string msg)
  {
   if(InpLogging)
      PrintFormat("[ORB SMC] %s", msg);
  }

//+------------------------------------------------------------------+
// WEB DASHBOARD EXPORT (Refactor v2)
// Atomic JSON Writer
//+------------------------------------------------------------------+
// Helper makro
#define WB_BOOL(v) ((v) ? "true" : "false")
#define WB_STR(v)  ("\"" + JsonEscape(v) + "\"")

// Escape karakter yang bisa merusak JSON (quote, backslash, control chars)
string JsonEscape(string s)
  {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\n", "\\n");
   StringReplace(s, "\r", "\\r");
   StringReplace(s, "\t", "\\t");
   return s;
  }

// Helper fungsi global
string Num(double v) { return DoubleToString(v, _Digits); }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string Num2(double v) { return DoubleToString(v, 2); }
string BiasStr(ENUM_BIAS b) { return b == BIAS_BULLISH ? "BULL" : b == BIAS_BEARISH ? "BEAR" : "NEUT"; }

// Gabung array string dengan separator, tanpa koma terakhir
string JoinStrings(string &arr[], string sep)
  {
   string result = "";
   int n = ArraySize(arr);
   for(int i = 0; i < n; i++)
     {
      if(i > 0)
         result += sep;
      result += arr[i];
     }
   return result;
  }

// Build JSON untuk satu sesi (contoh minimal)
string BuildSessionJson(int s)
  {
   string gateText;
   color gateColor;
   GetGateStatus(s, gateText, gateColor);
   double orHA[SESS_COUNT] = {asiaORHigh, londonORHigh, nyORHigh};
   double orLA[SESS_COUNT] = {asiaORLow, londonORLow, nyORLow};
   bool enA[SESS_COUNT] = {InpEnableAsia, InpEnableLondon, InpEnableNY};
   bool actA[SESS_COUNT] = {asiaSession, londonSession, nySession};
// SMC state label — mirrors GetSMCLabel() used by the on-chart panel
   string smcLabel;
   color smcColor;
   GetSMCLabel(s, smcLabel, smcColor);
// Scan banner text — mirrors GetScanLabel() used by the on-chart panel
   string scanText;
   color scanColor, scanBg;
   GetScanLabel(s, scanText, scanColor, scanBg);
// Entry preview direction/gating — mirrors DrawStatusPanel()'s pvBul/pvHasDir logic exactly,
// so the exported entry/SL/TP match what the panel actually displays.
   bool pvBul;
   if(UsesSMC(s))
      pvBul = setupBull[s];
   else
     {
      bool pvbU = GetBkUp(s), pvbD = GetBkDn(s);
      pvBul = (pvbU && pvbD) ? (dailyBias != BIAS_BEARISH) : pvbU;
     }
   bool pvHasDir = UsesSMC(s) ? (smcState[s] >= SMC_ZONE) : (GetBkUp(s) || GetBkDn(s));
   if(!pvHasDir && orbFallbackActive[s])
      pvHasDir = GetBkUp(s) || GetBkDn(s);
   double pvEntry = 0, pvSL = 0, pvTP = 0, pvSLP = 0, pvTPP = 0, pvRR = 0, pvRisk = 0, pvRiskPct = 0;
   if(pvHasDir && GetSessORH(s) > 0)
      PreviewEntryRisk(s, pvBul, pvEntry, pvSL, pvTP, pvSLP, pvTPP, pvRR, pvRisk, pvRiskPct);
   double opPnL = 0, opEntry = 0, opSL = 0, opTP = 0;
   bool hasPos = GetOpenPosBySession(s, opPnL, opEntry, opSL, opTP);
   string grade = InpUseProbScore ? GetProbGrade(probScore[s]) : "OFF";
   string parts[];
   int idx = 0;
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"name\":" + WB_STR(SESS_NAME[s]);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"en\":"   + WB_BOOL(enA[s]);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"act\":"  + WB_BOOL(actA[s]);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"smc\":"  + WB_STR(EnumToString(smcState[s]));
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"smc_label\":" + WB_STR(smcLabel);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"scan\":" + WB_STR(scanText);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"bull\":" + WB_BOOL(setupBull[s]);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"orh\":"  + Num(orHA[s]);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"orl\":"  + Num(orLA[s]);
// Auto mode classifier (ORB vs SMC) — mirrors the AUTO block in DrawStatusPanel()
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"auto_smc\":" + WB_BOOL(gAutoSMC[s]);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"mc_score\":" + IntegerToString(gMarketCharScore[s]);
// OB
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"ob_v\":" + WB_BOOL(ob[s].valid);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"ob_b\":" + WB_BOOL(ob[s].bullish);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"ob_h\":" + Num(ob[s].high);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"ob_l\":" + Num(ob[s].low);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"ob_touch\":" + IntegerToString(ob[s].touchCount);
// FVG
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"fv_v\":" + WB_BOOL(fvg[s].valid);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"fv_b\":" + WB_BOOL(fvg[s].bullish);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"fv_h\":" + Num(fvg[s].high);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"fv_l\":" + Num(fvg[s].low);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"fv_touch\":" + IntegerToString(fvg[s].touchCount);
// Gate & Risk
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"gate\":" + WB_STR(gateText);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"score\":" + DoubleToString(probScore[s], 0);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"grade\":" + WB_STR(grade);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"entry\":" + Num(pvEntry);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"sl\":"    + Num(pvSL);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"tp\":"    + Num(pvTP);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"rr\":"    + DoubleToString(pvRR, 2);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"rk_p\":"  + Num2(pvRiskPct);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"rk_u\":"  + Num2(pvRisk);
// Daily trade bookkeeping — mirrors TRADES/BUY/SELL rows in DrawStatusPanel()
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"trades\":" + IntegerToString(sessTradeCount[s]);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"max_trades\":" + IntegerToString(InpMaxTrades);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"buy_done\":" + WB_BOOL(tradeBuyDone[s]);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"sell_done\":" + WB_BOOL(tradeSellDone[s]);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"partial\":" + WB_BOOL(partialTaken[s]);
// Position
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"has_p\":" + WB_BOOL(hasPos);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"pnl\":"   + Num2(opPnL);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"p_entry\":" + Num(opEntry);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"p_sl\":"    + Num(opSL);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"p_tp\":"    + Num(opTP);
// LTF Suggestion Engine
   string ltfEntry = "0", ltfSl = "0", ltfTp = "0";
   if(ltfSuggState[s] >= SMC_ZONE)
     {
      double lPrice = ltfSuggBull[s] ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double lAtr = GetATRLTF(1);
      double lSlDist = 0, lTpDist = 0;
      ENUM_ORDER_TYPE lType = ltfSuggBull[s] ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      CalcLTFSuggestSLTP(s, lType, lPrice, lAtr, lSlDist, lTpDist);
      ltfEntry = Num(lPrice);
      ltfSl = Num(ltfSuggBull[s] ? lPrice - lSlDist : lPrice + lSlDist);
      ltfTp = Num(ltfSuggBull[s] ? lPrice + lTpDist : lPrice - lTpDist);
     }
   string ltfObj = "\"ltf\":{"
                   + "\"state\":" + WB_STR(EnumToString(ltfSuggState[s])) + ","
                   + "\"bull\":" + WB_BOOL(ltfSuggBull[s]) + ","
                   + "\"score\":" + DoubleToString(ltfSuggScore[s], 0) + ","
                   + "\"grade\":" + WB_STR(GetProbGrade(ltfSuggScore[s])) + ","
                   + "\"entry\":" + ltfEntry + ","
                   + "\"sl\":" + ltfSl + ","
                   + "\"tp\":" + ltfTp + ","
                   + "\"executed\":" + WB_BOOL(ltfSuggActed[s])
                   + "}";
   ArrayResize(parts, idx + 1);
   parts[idx++] = ltfObj;
   return "{" + JoinStrings(parts, ",") + "}";
  }
//+------------------------------------------------------------------+
//| Write JSON file                                                  |
//+------------------------------------------------------------------+
void WriteWebData()
  {
   string fileName = "orbsmc_live_" + _Symbol + ".json";
   string tmpFile  = fileName + ".tmp";
   string parts[];
   int idx = 0;
// Header
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"version\":\"" + EA_VERSION + "\"";
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"status\":\"LIVE\"";
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"ts\":" + IntegerToString((long)TimeCurrent());
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"symbol\":\"" + _Symbol + "\"";
// Account
   string acc = "\"acc\":{"
                + "\"bal\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ","
                + "\"eq\":"  + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + ","
                + "\"free\":" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2)
                + "}";
   ArrayResize(parts, idx + 1);
   parts[idx++] = acc;
// Bias — HTF & Daily (PDM), mirrors the HTF BIAS / DAY BIAS rows in DrawStatusPanel()
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"htf_bias\":" + WB_STR(BiasStr(htfBias));
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"use_daily_bias\":" + WB_BOOL(InpUseDailyBias);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"daily_bias\":" + WB_STR((InpUseDailyBias && pdHigh > pdLow) ? BiasStr(dailyBias) : "OFF");
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"pd_high\":" + Num(pdHigh);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"pd_low\":" + Num(pdLow);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"pd_mid\":" + Num(pdMid);
// Footer strip — mirrors ATR/SL/TP/Lot/Spread/Vol/PP/VP/DR shown in the panel footer
   double footAtr = GetATR(1);
   double footLot = InpAutoLot ? CalcRiskLot(footAtr * gATR_SL) : InpLotSize;
   string volStr = volRegime == VOL_CALM ? "CALM" : volRegime == VOL_EXPLOSIVE ? "HOT"
                   : volRegime == VOL_HIGH ? "HIGH" : "NORM";
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"atr\":" + Num(footAtr);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"sl_mode\":" + WB_STR(EnumToString(InpSLMode));
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"tp_mode\":" + WB_STR(EnumToString(InpTPMode));
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"lot\":" + Num2(footLot);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"auto_lot\":" + WB_BOOL(InpAutoLot);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"spread\":" + DoubleToString((double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), 0);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"vol_regime\":" + WB_STR(volStr);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"pivot_pp\":" + (ppPP > 0 ? Num(ppPP) : "0");
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"vp_ready\":" + WB_BOOL(vpReady);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"vp_poc\":" + (vpReady ? Num(vpPOC) : "0");
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"dr_high\":" + Num(dealingRange.high);
   ArrayResize(parts, idx + 1);
   parts[idx++] = "\"dr_low\":" + Num(dealingRange.low);
// Sessions
   string sessParts[];
   int sidx = 0;
   for(int s = 0; s < SESS_COUNT; s++)
     {
      ArrayResize(sessParts, sidx + 1);
      sessParts[sidx++] = BuildSessionJson(s); // harus return {...}
     }
   string sessJson = "\"sess\":[" + JoinStrings(sessParts, ",") + "]";
   ArrayResize(parts, idx + 1);
   parts[idx++] = sessJson;
// Root JSON
   string j = "{" + JoinStrings(parts, ",") + "}";
// Debug log
// Write file UTF-8 tanpa BOM
   int fh = FileOpen(tmpFile, FILE_WRITE | FILE_BIN | FILE_COMMON);
   if(fh != INVALID_HANDLE)
     {
      uchar buf[];
      int len = StringToCharArray(j, buf, 0, WHOLE_ARRAY, CP_UTF8);
      // len = jumlah byte UTF-8 valid
      FileWriteArray(fh, buf, 0, len-1); // tulis hanya len byte
      FileClose(fh);
     }
// Replace file
   if(FileIsExist(fileName, FILE_COMMON))
      FileDelete(fileName, FILE_COMMON);
   if(FileIsExist(tmpFile, FILE_COMMON))
      FileMove(tmpFile, FILE_COMMON, fileName, FILE_COMMON);
  }



//+------------------------------------------------------------------+
//| TradingView-style quick trade handlers                           |
//+------------------------------------------------------------------+
// Close all open positions for this symbol & magic
void CloseAllPositionsForSymbolMagic()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PosInfo.SelectByIndex(i))
         continue;
      if(PosInfo.Symbol() != _Symbol)
         continue;
      if(PosInfo.Magic() != InpMagic)
         continue;
      ulong t = PosInfo.Ticket();
      Trade.PositionClose(t);
     }
// Also cancel pending orders for this symbol/magic
   for(int j = OrdersTotal() - 1; j >= 0; j--)
     {
      ulong ot = OrderGetTicket(j);
      if(ot == 0)
         continue;
      if(!OrderSelect(ot))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      Trade.OrderDelete(OrderGetTicket(j));
     }
  }

// Close positions and pending orders associated with a specific session
void ClosePositionsForSession(int sess)
  {
   if(sess < 0 || sess >= SESS_COUNT)
      return;
// Close positions where session derived from open time or comment matches
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PosInfo.SelectByIndex(i))
         continue;
      if(PosInfo.Symbol() != _Symbol)
         continue;
      if(PosInfo.Magic() != InpMagic)
         continue;
      int ps = GetSessFromCmt(PosInfo.Time());
      if(ps < 0)
        {
         string cm = PosInfo.Comment();
         for(int k = 0; k < SESS_COUNT; k++)
            if(StringFind(cm, SESS_NAME[k]) >= 0)
              {
               ps = k;
               break;
              }
        }
      if(ps == sess)
         Trade.PositionClose(PosInfo.Ticket());
     }
// Delete pending orders whose comment contains session name
   for(int j = OrdersTotal() - 1; j >= 0; j--)
     {
      ulong ot = OrderGetTicket(j);
      if(ot == 0)
         continue;
      if(!OrderSelect(ot))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      string oc = OrderGetString(ORDER_COMMENT);
      if(StringFind(oc, SESS_NAME[sess]) >= 0)
         Trade.OrderDelete(ot);
     }
  }

// Handle chart object clicks for quick trade buttons, and drags for the
// position tool's SL/TP lines
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_DRAG)
     {
      string dobj = sparam;
      const string pSL = "TV_POS_SL_";
      const string pTP = "TV_POS_TP_";
      if(StringFind(dobj, pSL) == 0)
        {
         int dsess = (int)StringToInteger(StringSubstr(dobj, StringLen(pSL)));
         if(dsess < 0 || dsess >= SESS_COUNT || !gPosToolActive[dsess])
            return;
         double newSL = ObjectGetDouble(0, dobj, OBJPROP_PRICE, 0);
         double minDist = MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point, 10 * _Point);
         bool bul = (gPosToolType[dsess] == ORDER_TYPE_BUY);
         double entry = gPosToolEntry[dsess];
         int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         if(bul && entry - newSL < minDist)
            newSL = NormalizeDouble(entry - minDist, digs);
         else
            if(!bul && newSL - entry < minDist)
               newSL = NormalizeDouble(entry + minDist, digs);
         ObjectSetDouble(0, dobj, OBJPROP_PRICE, newSL);
         gPosToolSL[dsess] = newSL;
         gPosToolLot[dsess] = CalcRiskLot(MathAbs(entry - newSL));
         UpdatePositionToolVisuals(dsess);
         return;
        }
      if(StringFind(dobj, pTP) == 0)
        {
         int dsess = (int)StringToInteger(StringSubstr(dobj, StringLen(pTP)));
         if(dsess < 0 || dsess >= SESS_COUNT || !gPosToolActive[dsess])
            return;
         double newTP = ObjectGetDouble(0, dobj, OBJPROP_PRICE, 0);
         double minDist2 = MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point, 10 * _Point);
         bool bul2 = (gPosToolType[dsess] == ORDER_TYPE_BUY);
         double entry2 = gPosToolEntry[dsess];
         int digs2 = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         if(bul2 && newTP - entry2 < minDist2)
            newTP = NormalizeDouble(entry2 + minDist2, digs2);
         else
            if(!bul2 && entry2 - newTP < minDist2)
               newTP = NormalizeDouble(entry2 - minDist2, digs2);
         ObjectSetDouble(0, dobj, OBJPROP_PRICE, newTP);
         gPosToolTP[dsess] = newTP;
         UpdatePositionToolVisuals(dsess);
         return;
        }
      return;
     }
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;
   string obj = sparam;
// Expect names like TV_BTN_BUY_<sess>, TV_BTN_SELL_<sess>, TV_BTN_CLOSE_<sess>
   const string pBuy = "TV_BTN_BUY_";
   const string pSell = "TV_BTN_SELL_";
   const string pClose = "TV_BTN_CLOSE_";
   int sess = -1;
   if(StringFind(obj, pBuy) == 0)
     {
      sess = (int)StringToInteger(StringSubstr(obj, StringLen(pBuy)));
      if(sess < 0 || sess >= SESS_COUNT)
         sess = GetSessFromCmt(TimeCurrent());
      if(sess < 0)
         sess = 0;
      double lot = (InpQuickLot > 0) ? InpQuickLot : (InpAutoLot ? CalcRiskLot(GetATR(1) * gATR_SL) : InpLotSize);
      ShowPositionTool(sess, ORDER_TYPE_BUY, lot, InpQuickSL_Pips, InpQuickTP_Pips);
      return;
     }
   if(StringFind(obj, pSell) == 0)
     {
      sess = (int)StringToInteger(StringSubstr(obj, StringLen(pSell)));
      if(sess < 0 || sess >= SESS_COUNT)
         sess = GetSessFromCmt(TimeCurrent());
      if(sess < 0)
         sess = 0;
      double lot2 = (InpQuickLot > 0) ? InpQuickLot : (InpAutoLot ? CalcRiskLot(GetATR(1) * gATR_SL) : InpLotSize);
      ShowPositionTool(sess, ORDER_TYPE_SELL, lot2, InpQuickSL_Pips, InpQuickTP_Pips);
      return;
     }
   if(StringFind(obj, pClose) == 0)
     {
      sess = (int)StringToInteger(StringSubstr(obj, StringLen(pClose)));
      if(sess < 0 || sess >= SESS_COUNT)
         sess = -1;
      if(sess >= 0)
         ClosePositionsForSession(sess);
      else
         CloseAllPositionsForSymbolMagic();
      ReconcileSessTradeCount();
      return;
     }
// Position tool confirm/cancel buttons
   const string pPosOK = "TV_POS_OK_";
   const string pPosCancel = "TV_POS_CANCEL_";
   if(StringFind(obj, pPosOK) == 0)
     {
      int psess = (int)StringToInteger(StringSubstr(obj, StringLen(pPosOK)));
      if(psess >= 0 && psess < SESS_COUNT)
         ExecutePositionTool(psess);
      return;
     }
   if(StringFind(obj, pPosCancel) == 0)
     {
      int psess = (int)StringToInteger(StringSubstr(obj, StringLen(pPosCancel)));
      if(psess >= 0 && psess < SESS_COUNT)
         HidePositionTool(psess);
      return;
     }
// Quick param click: allow clicking the q labels to cycle values
   if(StringFind(obj, "TV_QLOT_") == 0)
     {
      int si = (int)StringToInteger(StringSubstr(obj, StringLen("TV_QLOT_")));
      if(si >= 0 && si < SESS_COUNT)
        {
         // cycle between InpQuickLot, InpLotSize, and AutoLot calc
         if(gQuickLotSess[si] == InpLotSize)
            gQuickLotSess[si] = (InpQuickLot > 0) ? InpQuickLot : InpLotSize;
         else
            if(gQuickLotSess[si] == (InpQuickLot > 0 ? InpQuickLot : InpLotSize))
               gQuickLotSess[si] = (InpAutoLot ? CalcRiskLot(GetATR(1) * gATR_SL) : InpLotSize);
            else
               gQuickLotSess[si] = InpLotSize;
        }
      return;
     }
   if(StringFind(obj, "TV_QSL_") == 0)
     {
      int si = (int)StringToInteger(StringSubstr(obj, StringLen("TV_QSL_")));
      if(si >= 0 && si < SESS_COUNT)
         gQuickSL_pipsSess[si] = (gQuickSL_pipsSess[si] + 5) % 101; // cycle 0-100 by 5
      return;
     }
   if(StringFind(obj, "TV_QTP_") == 0)
     {
      int si = (int)StringToInteger(StringSubstr(obj, StringLen("TV_QTP_")));
      if(si >= 0 && si < SESS_COUNT)
         gQuickTP_pipsSess[si] = (gQuickTP_pipsSess[si] + 10) % 501; // cycle 0-500 by 10
      return;
     }
  }

// Per-session draggable position-tool state (replaces the single-instance
// gPendingSess/etc. below once Task 5 of this plan removes them) — allows
// more than one session to have an unconfirmed tool open simultaneously.
bool            gPosToolActive[SESS_COUNT] = {false, false, false};
ENUM_ORDER_TYPE gPosToolType[SESS_COUNT];
double          gPosToolEntry[SESS_COUNT] = {0, 0, 0};
double          gPosToolSL[SESS_COUNT] = {0, 0, 0};
double          gPosToolTP[SESS_COUNT] = {0, 0, 0};
double          gPosToolLot[SESS_COUNT] = {0, 0, 0};

// Quick-override globals consumed by ExecuteTrade
bool gUseQuickParams = false;
double gQuickLot = 0.0;
double gQuickSL = 0.0; // absolute price
double gQuickTP = 0.0; // absolute price

// Per-session quick parameters (editable via panel)
double gQuickLotSess[SESS_COUNT];
int gQuickSL_pipsSess[SESS_COUNT];
int gQuickTP_pipsSess[SESS_COUNT];

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
//| Position Tool — deletes all 8 objects for one session's tool and  |
//| clears its active flag. Safe to call even if the session has no   |
//| active tool (ObjectDelete on a non-existent name is a harmless     |
//| no-op in MQL5).                                                    |
//+------------------------------------------------------------------+
void HidePositionTool(int sess)
  {
   string s = string(sess);
   ObjectDelete(0, "TV_POS_ENTRY_" + s);
   ObjectDelete(0, "TV_POS_SL_" + s);
   ObjectDelete(0, "TV_POS_TP_" + s);
   ObjectDelete(0, "TV_POS_SLBOX_" + s);
   ObjectDelete(0, "TV_POS_TPBOX_" + s);
   ObjectDelete(0, "TV_POS_INFO_" + s);
   ObjectDelete(0, "TV_POS_OK_" + s);
   ObjectDelete(0, "TV_POS_CANCEL_" + s);
   gPosToolActive[sess] = false;
  }

//+------------------------------------------------------------------+
//| Position Tool — redraws the colored SL/TP zone boxes and the info |
//| label from the CURRENT gPosToolSL[sess]/gPosToolTP[sess] (i.e.     |
//| wherever the user has dragged the lines to). Called once when the |
//| tool is first shown and again after every drag event for this     |
//| session. Never touches the SL/TP lines themselves — those are the |
//| interactive objects the user drags; this function only redraws   |
//| the non-interactive visuals that follow them.                     |
//+------------------------------------------------------------------+
void UpdatePositionToolVisuals(int sess)
  {
   if(!gPosToolActive[sess])
      return;
   string s = string(sess);
   datetime t1 = TimeCurrent();
   datetime t2 = t1 + PeriodSeconds(_Period) * 30;
   bool bul = (gPosToolType[sess] == ORDER_TYPE_BUY);
   double entry = gPosToolEntry[sess], sl = gPosToolSL[sess], tp = gPosToolTP[sess];
   DrawRect("TV_POS_SLBOX_" + s, t1, t2, MathMax(entry, sl), MathMin(entry, sl), C'160,50,50', true, false);
   DrawRect("TV_POS_TPBOX_" + s, t1, t2, MathMax(entry, tp), MathMin(entry, tp), C'40,120,70', true, false);
   double slDist = MathAbs(entry - sl);
   double tpDist = MathAbs(tp - entry);
   double rr = (slDist > 0) ? tpDist / slDist : 0;
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pip = (digs == 5 || digs == 3) ? _Point * 10.0 : _Point;
   double slPips = (pip > 0) ? slDist / pip : 0;
   double tpPips = (pip > 0) ? tpDist / pip : 0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double riskAmt = (tickSz > 0) ? gPosToolLot[sess] * (slDist / tickSz) * tickVal : 0;
   string txt = StringFormat("%s %s  Lot %.2f  SL %.0fp  TP %.0fp  RR 1:%.1f  Risk %.2f",
                             SESS_NAME[sess], bul ? "BUY" : "SELL", gPosToolLot[sess], slPips, tpPips, rr, riskAmt);
   DrawTextObj("TV_POS_INFO_" + s, t1, MathMax(entry, tp), txt, clrWhite, 8);
  }

//+------------------------------------------------------------------+
//| Position Tool — creates all 8 objects for one session's tool at   |
//| the current market price, with initial SL/TP from sl_pips/tp_pips |
//| (0 = a sensible default distance, matching how the old confirm    |
//| overlay's 0-pips case let the EA "compute" a value — here we just  |
//| pick 200/400 points as a starting point the user is expected to    |
//| drag anyway). Replaces this session's existing tool first, if any, |
//| so re-clicking BUY/SELL for the same session never leaves orphaned |
//| duplicate objects.                                                 |
//+------------------------------------------------------------------+
void ShowPositionTool(int sess, ENUM_ORDER_TYPE type, double lot, int sl_pips, int tp_pips)
  {
   if(gPosToolActive[sess])
      HidePositionTool(sess);
   string s = string(sess);
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pt = _Point;
   double slPrice, tpPrice;
   if(type == ORDER_TYPE_BUY)
     {
      slPrice = NormalizeDouble(price - (sl_pips > 0 ? sl_pips : 200) * pt, digs);
      tpPrice = NormalizeDouble(price + (tp_pips > 0 ? tp_pips : 400) * pt, digs);
     }
   else
     {
      slPrice = NormalizeDouble(price + (sl_pips > 0 ? sl_pips : 200) * pt, digs);
      tpPrice = NormalizeDouble(price - (tp_pips > 0 ? tp_pips : 400) * pt, digs);
     }

   gPosToolActive[sess] = true;
   gPosToolType[sess] = type;
   gPosToolEntry[sess] = price;
   gPosToolSL[sess] = slPrice;
   gPosToolTP[sess] = tpPrice;
   gPosToolLot[sess] = (lot > 0) ? lot : CalcRiskLot(MathAbs(price - slPrice));

// Entry reference line — not draggable, purely visual
   string eName = "TV_POS_ENTRY_" + s;
   ObjectCreate(0, eName, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0, eName, OBJPROP_PRICE, price);
   ObjectSetInteger(0, eName, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, eName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, eName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, eName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, eName, OBJPROP_HIDDEN, true);

// SL line — draggable
   string slName = "TV_POS_SL_" + s;
   ObjectCreate(0, slName, OBJ_HLINE, 0, 0, slPrice);
   ObjectSetDouble(0, slName, OBJPROP_PRICE, slPrice);
   ObjectSetInteger(0, slName, OBJPROP_COLOR, C'210,80,80');
   ObjectSetInteger(0, slName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, slName, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, slName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, slName, OBJPROP_HIDDEN, false);

// TP line — draggable
   string tpName = "TV_POS_TP_" + s;
   ObjectCreate(0, tpName, OBJ_HLINE, 0, 0, tpPrice);
   ObjectSetDouble(0, tpName, OBJPROP_PRICE, tpPrice);
   ObjectSetInteger(0, tpName, OBJPROP_COLOR, C'80,210,130');
   ObjectSetInteger(0, tpName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, tpName, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, tpName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, tpName, OBJPROP_HIDDEN, false);

// CONFIRM / CANCEL buttons — offset vertically per session so simultaneous
// tools for different sessions don't stack their buttons on top of each other
   int bx = InpPanelX + 420, by = InpPanelY + 10 + sess * 60;
   string okName = "TV_POS_OK_" + s, cancelName = "TV_POS_CANCEL_" + s;
   ObjectCreate(0, okName, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, okName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, okName, OBJPROP_XDISTANCE, bx);
   ObjectSetInteger(0, okName, OBJPROP_YDISTANCE, by);
   ObjectSetInteger(0, okName, OBJPROP_XSIZE, 90);
   ObjectSetInteger(0, okName, OBJPROP_YSIZE, 22);
   ObjectSetString(0, okName, OBJPROP_TEXT, SESS_NAME[sess] + " CONFIRM");
   ObjectSetInteger(0, okName, OBJPROP_BGCOLOR, C'40,160,90');
   ObjectCreate(0, cancelName, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, cancelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, cancelName, OBJPROP_XDISTANCE, bx + 100);
   ObjectSetInteger(0, cancelName, OBJPROP_YDISTANCE, by);
   ObjectSetInteger(0, cancelName, OBJPROP_XSIZE, 90);
   ObjectSetInteger(0, cancelName, OBJPROP_YSIZE, 22);
   ObjectSetString(0, cancelName, OBJPROP_TEXT, "CANCEL");
   ObjectSetInteger(0, cancelName, OBJPROP_BGCOLOR, C'160,60,60');

   UpdatePositionToolVisuals(sess);
  }

//+------------------------------------------------------------------+
//| Position Tool — sends the real order using the tool's current      |
//| (possibly dragged) SL/TP and recalculated lot, via the existing    |
//| quick-param override mechanism ExecuteTrade already reads — the    |
//| exact same path the old text confirm overlay used. Always hides    |
//| the tool afterward, matching the old overlay's "always dismiss on  |
//| confirm attempt" behavior, whether the trade succeeded or not.     |
//+------------------------------------------------------------------+
void ExecutePositionTool(int sess)
  {
   if(!gPosToolActive[sess])
      return;
   if(HasOpenOrPendingTrade())
     {
      LogMsg("MANUAL TRADE BLOCKED — position/order already open for " + _Symbol);
      DrawTextObj("TV_POS_INFO_" + string(sess), TimeCurrent(), MathMax(gPosToolEntry[sess], gPosToolTP[sess]),
                  "BLOCKED: another position/order already open", clrOrange, 8);
      return;
     }
   double curPrice = (gPosToolType[sess] == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point, 10 * _Point);
   bool bul = (gPosToolType[sess] == ORDER_TYPE_BUY);
   bool slValid = bul ? (curPrice - gPosToolSL[sess] >= minDist) : (gPosToolSL[sess] - curPrice >= minDist);
   bool tpValid = bul ? (gPosToolTP[sess] - curPrice >= minDist) : (curPrice - gPosToolTP[sess] >= minDist);
   if(!slValid || !tpValid)
     {
      LogMsg("MANUAL TRADE REJECTED — SL/TP no longer valid vs current market for " + SESS_NAME[sess]);
      DrawTextObj("TV_POS_INFO_" + string(sess), TimeCurrent(), MathMax(gPosToolEntry[sess], gPosToolTP[sess]),
                  "REJECTED: price moved, SL/TP no longer valid — re-drag and confirm again", clrOrange, 8);
      return;
     }
   gUseQuickParams = true;
   gQuickLot = gPosToolLot[sess];
   gQuickSL = gPosToolSL[sess];
   gQuickTP = gPosToolTP[sess];
   bool sent = ExecuteTrade(gPosToolType[sess], sess);
   gUseQuickParams = false;
   if(sent)
     {
      ReconcileSessTradeCount();
      HidePositionTool(sess);
     }
   else
     {
      LogMsg("MANUAL TRADE NOT SENT — a trade gate blocked the order for " + SESS_NAME[sess] + "; tool remains open");
      DrawTextObj("TV_POS_INFO_" + string(sess), TimeCurrent(), MathMax(gPosToolEntry[sess], gPosToolTP[sess]),
                  "NOT SENT: a trade gate blocked this order — check journal", clrOrange, 8);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
