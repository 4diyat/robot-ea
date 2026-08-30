//+------------------------------------------------------------------+
//|                                              HunterSettings.mqh |
//| Snapshot config: EA utama menyalin seluruh input ke struct ini   |
//| satu kali di OnInit (SnapshotSettings). Modul hanya membaca      |
//| salinan → modul tidak bergantung pada nama input, lebih mudah     |
//| di-unit-test lewat EA harness, dan validasi terpusat di satu      |
//| tempat (mengembalikan INIT_PARAMETERS_INCORRECT).                 |
//|                                                                  |
//| TRADE-OFF: input yang diubah saat EA berjalan tetap butuh        |
//| reinit (MT5 memang me-reload EA saat input diganti — no cost).   |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_SETTINGS_MQH
#define ORB_SMC_HUNTER_SETTINGS_MQH

#include "HunterDefines.mqh"

struct SHunterSettings
  {
   //--- identitas
   long            magic;
   //--- sesi (jam sudah ternormalisasi ke UTC oleh EA saat snapshot)
   bool            enableSession[HUNT_SESSION_COUNT];
   int             startHourUtc[HUNT_SESSION_COUNT];
   int             endHourUtc[HUNT_SESSION_COUNT];
   int             gmtOffset;            // broker - UTC (jam)
   //--- ORB
   int             rangeMinutes;
   double          minRangePips;
   double          breakoutBufferPips;   // jarak body-close di luar level OR
   bool            requireBodyClose;     // wick-only tidak dihitung
   //--- SMC
   int             swingLookback;        // kiri=kanan, closed-bar only
   bool            requireLiquiditySweep;
   bool            requireRetest;        // wajib retest zona (no direct entry)
   int             retestMaxBars;
   double          maxExtensionPct;      // % dari OR sebelum retest = invalid
   double          liqTolPips;           // klaster equal highs/lows
   bool            useFvgAsZone;         // FVG boleh jadi zona retest
   double          obDisplacementAtr;    // displacement OB minimal (× ATR)
   int             atrPeriod;
   ENUM_TIMEFRAMES htf;                  // timeframe bias struktur
   double          pipSize;              // dihitung dari digits (multi-pair)
   double          point;
   int             digits;
   //--- Confluence
   int             minScore;             // ambang skor utk lolos validator
   //--- Risk
   double          riskPercent;
   ENUM_HUNT_RISK_BASE riskBase;
   double          minRR;                // ke TP akhir
   double          tp1RR;                // 0 = partial off
   double          partialClosePct;
   bool            trailAfterTp1;
   int             maxTradesPerDay;      // 0 = unlimited
   double          maxDailyLossPct;      // 0 = off
   int             forceCloseMinBefore;  // menit sebelum akhir sesi
   double          maxSpreadPips;        // 0 = off
   int             maxSlippagePoints;
   int             orderRetries;
   int             orderRetryDelayMs;
   //--- RSI OB/OS (info dashboard)
   int             obosPeriod;
   double          obosUpper;
   double          obosLower;
   //--- News
   bool            newsEnabled;
   int             newsRefreshHours;
   bool            newsIncludeMedium;
   string          newsCurrencyOverride; // "" = auto base/quote
   int             newsBeforeMin;
   int             newsAfterMin;
   int             newsFetchTimeoutMs;
   int             newsCacheMaxAgeHours; // di atas ini dianggap stale
   //--- Visual
   bool            showOB;
   bool            showFvg;
   bool            showStructure;
   bool            showSweep;
   bool            showEntryArrows;
   bool            showPivot;
   bool            showVolumeProfile;
   bool            showNewsMarkers;
   //--- Dashboard
   bool            showDashboard;
   int             dashCorner;           // nilai ENUM_BASE_CORNER 0..3
   int             dashFontSize;
  };

//--- Nilai default (diganti oleh SnapshotSettings di EA utama) ---------
void SettingsDefaults(SHunterSettings &s)
  {
   s.magic                 = 20260830;
   s.gmtOffset             = 0;
   s.rangeMinutes          = 30;
   s.minRangePips          = 0.0;
   s.breakoutBufferPips    = 0.0;
   s.requireBodyClose      = true;
   s.swingLookback         = 3;
   s.requireLiquiditySweep = true;
   s.requireRetest         = true;
   s.retestMaxBars         = 10;
   s.maxExtensionPct       = 50.0;
   s.liqTolPips            = 2.0;
   s.useFvgAsZone          = true;
   s.obDisplacementAtr     = 1.0;
   s.atrPeriod             = 14;
   s.htf                   = PERIOD_H4;
   s.pipSize               = 0.0001;
   s.point                 = 0.00001;
   s.digits                = 5;
   s.minScore              = 60;
   s.riskPercent           = 0.5;
   s.riskBase              = HUNT_RISK_BASE_BALANCE;
   s.minRR                 = 2.0;
   s.tp1RR                 = 1.0;
   s.partialClosePct       = 50.0;
   s.trailAfterTp1         = true;
   s.maxTradesPerDay       = 3;
   s.maxDailyLossPct       = 3.0;
   s.forceCloseMinBefore   = 30;
   s.maxSpreadPips         = 0.0;
   s.maxSlippagePoints     = 30;
   s.orderRetries          = 3;
   s.orderRetryDelayMs     = 500;
   s.obosPeriod            = 14;
   s.obosUpper             = 70.0;
   s.obosLower             = 30.0;
   s.newsEnabled           = true;
   s.newsRefreshHours      = 6;
   s.newsIncludeMedium     = true;
   s.newsCurrencyOverride  = "";
   s.newsBeforeMin         = 30;
   s.newsAfterMin          = 30;
   s.newsFetchTimeoutMs    = 8000;
   s.newsCacheMaxAgeHours  = 48;
   s.showOB                = true;
   s.showFvg               = true;
   s.showStructure         = true;
   s.showSweep             = true;
   s.showEntryArrows       = true;
   s.showPivot             = true;
   s.showVolumeProfile     = true;
   s.showNewsMarkers       = true;
   s.showDashboard         = true;
   s.dashCorner            = 0;   // CORNER_LEFT_UPPER
   s.dashFontSize          = 9;
   for(int i=0;i<HUNT_SESSION_COUNT;i++)
     {
      s.enableSession[i]   = true;
      s.startHourUtc[i]    = 0;
      s.endHourUtc[i]      = 0;
     }
  }

#endif // ORB_SMC_HUNTER_SETTINGS_MQH
//+------------------------------------------------------------------+
