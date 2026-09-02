//+------------------------------------------------------------------+
//|                                                   RiskManager.mqh|
//| Tidak menyentuh CTrade — hanya MENGHITUNG & MEMUTUSKAN; Trade-     |
//| Executor yang mengeksekusi. Daily stats dipegang di sini.          |
//|                                                                  |
//|  - BuildPlan: SL = tepi struktural zona ± atrBuffer×ATR (dicek     |
//|    jarak stops-level broker); TP2 = max(minRR, swing target)×risk; |
//|    TP1 = tp1RR×risk (0 = off); RR final divalidasi ≥ minRR;         |
//|  - Sizing: moneyRisk = basis×riskPercent% ; lots = moneyRisk /      |
//|    (slDist/tickSize×tickValue) → normalisasi step/min/max;          |
//|  - CanOpenNewTrade: max trades/day, daily-loss halt, day rollover;  |
//|  - PartialCloseVolume (skip bila < min lot); ProposeTrailingSl      |
//|    hanya maju searah posisi.                                          |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_RISKMANAGER_MQH
#define ORB_SMC_HUNTER_RISKMANAGER_MQH

#include "DataService.mqh"

class CRiskManager
  {
private:
   SHunterSettings     m_cfg;
   double              m_dayStartBalance;
   datetime            m_day;
   int                 m_tradesToday;
   double              m_pnlToday;
   bool                m_dayHalted;

   double              RiskBase(void) const
     {
      return(m_cfg.riskBase==HUNT_RISK_BASE_EQUITY ? AccountInfoDouble(ACCOUNT_EQUITY)
              : AccountInfoDouble(ACCOUNT_BALANCE));
     }
   /** moneyRisk / risiko-moneter-per-lot → lots mentah. 0 bila tak valid. */
   double              CalcLots(const double moneyRisk,const double slDistance,
                                const CDataService &data) const
     {
      double tsz=data.TickSize();
      double tvl=data.TickValue();
      if(tsz<=0.0 || tvl<=0.0 || slDistance<=0.0)
         return(0.0);
      double lossPerLot=slDistance/tsz*tvl;
      if(lossPerLot<=0.0)
         return(0.0);
      return(moneyRisk/lossPerLot);
     }

public:
                     CRiskManager(void) : m_dayStartBalance(0.0), m_day(0),
                                          m_tradesToday(0), m_pnlToday(0.0),
                                          m_dayHalted(false) {}

   bool              Init(const SHunterSettings &cfg)
     {
      m_cfg=cfg;
      return(true);
     }
   /** Rollover: balance awal hari + reset counter. */
   void              OnNewDay(const datetime day,const double balance)
     {
      m_day=day;
      m_dayStartBalance=balance;
      m_tradesToday=0;
      m_pnlToday=0.0;
      m_dayHalted=false;
     }

   //+---------------------------------------------------------------+
   //| Lengkapi plan dari zona & harga eksekusi. [in,out] plan — entry/   |
   //| mode sudah diisi pemanggil (level limit utk pending; utk market    |
   //| diisi harga saat kirim). structLevel = tepi SL zona. Return false  |
   //| + plan.note bila tak layak (jarak stops, RR < min, lot 0).          |
   //+---------------------------------------------------------------+
   bool              BuildPlan(SSignalPlan &plan,const CDataService &data,
                               const double structLevel) const
     {
      double atr=data.Atr(0);
      if(atr<=0.0)
         atr=10.0*data.Point();
      double buf=m_cfg.slAtrMult*atr;
      double minStop=2.0*data.Point();      // dicek ulang saat kirim order
      if(plan.dir==HUNT_DIR_BUY)
        {
         double sl=data.NormalizePrice(structLevel-buf);
         if(plan.entry-sl<minStop)
           {
            plan.note="SL terlalu dekat (stops level)";
            return(false);
           }
         double risk=plan.entry-sl;
         double swingUp=plan.entry+2.0*risk;    // fallback floor
         plan.sl=sl;
         plan.tp2=data.NormalizePrice(MathMax(swingUp,plan.entry+m_cfg.minRR*risk));
         plan.tp1=(m_cfg.tp1RR>0.0 ? data.NormalizePrice(plan.entry+m_cfg.tp1RR*risk) : 0.0);
         double rr=(plan.tp2-plan.entry)/risk;
         if(rr<m_cfg.minRR-0.001)
           {
            plan.note=StringFormat("RR %.2f < min %.2f",rr,m_cfg.minRR);
            return(false);
           }
         plan.rrFinal=rr;
         plan.slDistPips=(data.PipSize()>0.0 ? risk/data.PipSize() : 0.0);
        }
      else if(plan.dir==HUNT_DIR_SELL)
        {
         double sl=data.NormalizePrice(structLevel+buf);
         if(sl-plan.entry<minStop)
           {
            plan.note="SL terlalu dekat (stops level)";
            return(false);
           }
         double risk=sl-plan.entry;
         double swingDn=plan.entry-2.0*risk;
         plan.sl=sl;
         plan.tp2=data.NormalizePrice(MathMin(swingDn,plan.entry-m_cfg.minRR*risk));
         plan.tp1=(m_cfg.tp1RR>0.0 ? data.NormalizePrice(plan.entry-m_cfg.tp1RR*risk) : 0.0);
         double rr=(plan.entry-plan.tp2)/risk;
         if(rr<m_cfg.minRR-0.001)
           {
            plan.note=StringFormat("RR %.2f < min %.2f",rr,m_cfg.minRR);
            return(false);
           }
         plan.rrFinal=rr;
         plan.slDistPips=(data.PipSize()>0.0 ? risk/data.PipSize() : 0.0);
        }
      else
        {
         plan.note="arah plan tidak valid";
         return(false);
        }
      bool   fixedMode=(m_cfg.lotMode==HUNT_LOT_FIXED);
      double moneyRisk=RiskBase()*m_cfg.riskPercent/100.0;
      double lots;
      if(fixedMode)
         lots=m_cfg.fixedLots;                  // risiko efektif = |entry-SL| x nilai lot
      else
         lots=CalcLots(moneyRisk,MathAbs(plan.entry-plan.sl),data);
      if(lots<data.VolumeMin())
         lots=data.VolumeMin();                 // FIXED < min broker → angkat ke min
      lots=data.NormalizeVolume(lots);
      if(lots<=0.0)
        {
         plan.note="lot tidak valid (cek InpFixedLots)";
         return(false);
        }
      if(!fixedMode)
        {
         //--- Guard kontrak besar (kripto/indeks dgn VolumeMin >> kebutuhan):
         //--- normalisasi TIDAK boleh menggelembungkan risiko >150% budget.
         double tsz=data.TickSize();
         if(tsz>0.0)
           {
            double lossPerLot=MathAbs(plan.entry-plan.sl)/tsz*data.TickValue();
            if(lossPerLot>0.0 && lots*lossPerLot>moneyRisk*1.5)
              {
               plan.note="min lot broker >> budget risiko (naikkan balance atau perlebar SL)";
               return(false);
              }
           }
        }
      plan.lots=lots;
      plan.note="";
      return(true);
     }

   /** Gate pra-entry agregat. [out] note alasan penolakan. */
   bool              CanOpenNewTrade(string &note) const
     {
      note="";
      if(m_dayHalted)
        {
         note="daily-loss halt aktif";
         return(false);
        }
      if(m_cfg.maxTradesPerDay>0 && m_tradesToday>=m_cfg.maxTradesPerDay)
        {
         note=StringFormat("max trade/hari %d",m_cfg.maxTradesPerDay);
         return(false);
        }
      return(true);
     }
   /** Validasi ulang mendadak (spread+halt) — dipakai sebelum kirim order. */
   bool              LastMomentCheck(const double spreadPips,string &note) const
     {
      note="";
      if(m_dayHalted)
        {
         note="daily-loss halt";
         return(false);
        }
      if(m_cfg.maxSpreadPips>0.0 && spreadPips>m_cfg.maxSpreadPips)
        {
         note="spread";
         return(false);
        }
      return(true);
     }
   void              RegisterClosedTrade(const double pnlCurrency)
     {
      m_pnlToday+=pnlCurrency;
      if(m_cfg.maxDailyLossPct>0.0 && m_dayStartBalance>0.0 &&
         (m_pnlToday/m_dayStartBalance*100.0)<=-m_cfg.maxDailyLossPct)
        {
         m_dayHalted=true;
         PrintFormat("%s | RISK HALT: daily P/L %.2f%% ≤ -%.2f%% — entry baru diblokir s/d besok",
                     HUNT_NAME,m_pnlToday/m_dayStartBalance*100.0,m_cfg.maxDailyLossPct);
        }
     }
   /** Dipanggil saat order entry terisi (market fill / pending fill). */
   void              RegisterOpenedTrade(void) { m_tradesToday++; }

   /** Lot partial utk TP1; 0 = skip (terlalu kecil). */
   double            PartialCloseVolume(const double openVolume,const CDataService &data) const
     {
      if(m_cfg.tp1RR<=0.0 || m_cfg.partialClosePct<=0.0)
         return(0.0);
      double v=openVolume*m_cfg.partialClosePct/100.0;
      v=data.NormalizeVolume(v);
      //--- jangan tinggalkan sisa < min lot
      if(v<=0.0 || (openVolume-v)<data.VolumeMin())
         return(0.0);
      return(v);
     }
   /** Trailing struktur: kandidat SL baru = refStruktur ∓ buffer; hanya
       MAJU searah posisi & hanya bila profit ≥ 0.5×risk. Return 0 = skip. */
   double            ProposeTrailingSl(const ENUM_HUNT_DIR dir,const double curSl,
                                       const double refStruct,const double curPrice,
                                       const CDataService &data) const
     {
      if(!m_cfg.trailAfterTp1)
         return(0.0);
      double atr=data.Atr(0);
      if(atr<=0.0)
         atr=10.0*data.Point();
      double buf=0.1*atr;
      if(dir==HUNT_DIR_BUY)
        {
         double cand=data.NormalizePrice(refStruct-buf);
         if(cand>curSl && cand<curPrice)
            return(cand);
        }
      else if(dir==HUNT_DIR_SELL)
        {
         double cand=data.NormalizePrice(refStruct+buf);
         if((curSl==0.0 || cand<curSl) && cand>curPrice)
            return(cand);
        }
      return(0.0);
     }

   //--- getter utk dashboard -----------------------------------------------
   int               TradesToday(void) const   { return(m_tradesToday); }
   int               MaxTrades(void) const     { return(m_cfg.maxTradesPerDay); }
   double            DailyPnl(void) const      { return(m_pnlToday); }
   double            DailyPnlPct(void) const
     {
      if(m_dayStartBalance<=0.0)
         return(0.0);
      return(m_pnlToday/m_dayStartBalance*100.0);
     }
   double            MaxDailyLossPct(void) const { return(m_cfg.maxDailyLossPct); }
   bool              IsHalted(void) const      { return(m_dayHalted); }
  };

#endif // ORB_SMC_HUNTER_RISKMANAGER_MQH
//+------------------------------------------------------------------+
