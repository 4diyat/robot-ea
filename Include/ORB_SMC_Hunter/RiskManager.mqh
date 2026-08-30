//+------------------------------------------------------------------+
//|                                                   RiskManager.mqh|
//| Position sizing % risiko, SL struktural + buffer ATR, TP multi-  |
//| level (RR dinamis), gate max daily loss & max trades/day,        |
//| keputusan partial-close di TP1 & trailing berbasis struktur.     |
//|                                                                  |
//| Tidak menyentuh CTrade — hanya MENGHITUNG & MEMUTUSKAN;          |
//| TradeExecutor yang mengeksekusi. Daily stats dipegang di sini    |
//| (balance awal hari dicatat saat rollover).                        |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_RISKMANAGER_MQH
#define ORB_SMC_HUNTER_RISKMANAGER_MQH

#include "DataService.mqh"

class CRiskManager
  {
private:
   SHunterSettings     m_cfg;
   double              m_dayStartBalance;   // utk % daily loss
   datetime            m_dayUtc;
   int                 m_tradesToday;
   double              m_pnlToday;          // P/L realisasi hari ini (currency)
   bool                m_dayHalted;         // kena limit daily loss → blokir

   /** Hitung tick-value → lot, lalu normalisasi step/min/max simbol. */
   double              CalcLots(const double moneyRisk,const double slDistance) const;

public:
                     CRiskManager(void) : m_dayStartBalance(0.0), m_dayUtc(0),
                                          m_tradesToday(0), m_pnlToday(0.0),
                                          m_dayHalted(false) {}

   bool              Init(const SHunterSettings &cfg);
   /** Reset rollover: catat balance awal hari, zerokan counter. */
   void              OnNewDay(const datetime dayUtc,const double balance);

   /** Lengkapi plan: SL dari struktur (bottom/top zona ± ATR buffer),
       TP2 dari max(minRR, swing target), TP1 dari tp1RR; validasi tick
       size & stop-level broker. @return false + note bila plan tak layak. */
   bool              BuildPlan(SSignalPlan &plan,const CDataService &data,
                               const ENUM_HUNT_DIR dir,const double structLevel,
                               const ulong zoneId) const;

   /** Gate pra-entry agregat (trades/day, daily loss, day halted). */
   bool              CanOpenNewTrade(string &note) const;
   /** Dipanggil EA setelah trade ditutup (realized). */
   void              RegisterClosedTrade(const double pnlCurrency);
   /** Dipanggil EA saat order entry baru terisi. */
   void              RegisterOpenedTrade(void);

   /** Jumlah lot utk partial close TP1 (sudah ternormalisasi step). */
   double              PartialCloseVolume(const double openVolume) const;
   /** Trailing berbasis struktur: @return newSL (0 = tidak diubah).
       Hanya maju searah posisi, tidak pernah mundur. */
   double              ProposeTrailingSl(const ENUM_HUNT_DIR dir,const double curSl,
                                         const double refStruct,const double curPrice) const;

   //--- getter utk dashboard -------------------------------------------
   int               TradesToday(void) const   { return(m_tradesToday); }
   int               MaxTrades(void) const     { return(m_cfg.maxTradesPerDay); }
   double            DailyPnl(void) const      { return(m_pnlToday); }
   double            DailyPnlPct(void) const;  // % thd balance awal hari
   double            MaxDailyLossPct(void) const { return(m_cfg.maxDailyLossPct); }
   bool              IsHalted(void) const      { return(m_dayHalted); }
  };

#endif // ORB_SMC_HUNTER_RISKMANAGER_MQH
//+------------------------------------------------------------------+
