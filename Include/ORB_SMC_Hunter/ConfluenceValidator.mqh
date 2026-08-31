//+------------------------------------------------------------------+
//|                                          ConfluenceValidator.mqh |
//| Gate tunggal antara "breakout terdeteksi" dan "boleh entry".      |
//| Menerima PRIMITIF/snapshot (SBreakout, SSMCContext, flag) — tidak  |
//| memanggil modul lain (loose coupling; EA utama yang merakit).      |
//|                                                                  |
//| Hard-gates (semua wajib): G1 breakout valid · G2 searah bias HTF   |
//|  (bias None = TIDAK lolos) · G3 pool searah di-sweep (bila         |
//|  requireLiquiditySweep) · G4 zona OB/FVG tersedia (requireRetest;  |
//|  false = opt-in sadar entry-langsung, lihat docs) · G5 bebas window |
//|  news (veto mutlak) · G6 spread · G7 risk-ok. v1.07 opt-in: +G3b    |
//|  inducement · +G4b discount/premium — BOBOT SKOR TETAP 7 komponen.  |
//| Skor lunak ≥ minScore: +25 sweep · +20 BOS pasca-sweep · +15 zona   |
//|  fresh · +15 range>2×ATR · +10 extension<½maks · +10 RSI bukan      |
//|  ekstrem searah · +5 sesi London/NY.                               |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_CONFLUENCEVALIDATOR_MQH
#define ORB_SMC_HUNTER_CONFLUENCEVALIDATOR_MQH

#include "HunterSettings.mqh"

class CConfluenceValidator
  {
private:
   SHunterSettings     m_cfg;

   void                AddReason(SConfluenceReport &rep,const string why) const
     {
      if(rep.reasonCount<HUNT_REASONS_MAX)
         rep.reasons[rep.reasonCount++]=why;
     }
   /** true bila semua reasons hanya CATATAN (tidak ada marker "Gn:"). */
   bool                OnlyNotes(const SConfluenceReport &rep) const
     {
      for(int i=0;i<rep.reasonCount;i++)
        {
         string r=rep.reasons[i];
         if(StringLen(r)<3)
            continue;
         if(StringGetCharacter(r,0)=='G' && StringFind(r,":")>0)
            return(false);
        }
      return(true);
     }

   int                 ComputeScore(const SBreakout &bo,const SSMCContext &smc,
                                    const int session,SConfluenceReport &rep) const
     {
      int sc=0;
      if(smc.sweptInDirection)
        {
         sc+=25;
         AddReason(rep,"sweep ok");
        }
      if(smc.bosSinceSweep)
        {
         sc+=20;
         AddReason(rep,"BOS/CHoCH post-sweep");
        }
      if(smc.zoneFound && smc.zoneFresh)
        {
         sc+=15;
         AddReason(rep,"zona fresh");
        }
      if(smc.rangeBigAtr)
        {
         sc+=15;
         AddReason(rep,"OR > 2xATR");
        }
      if(smc.extensionPct<m_cfg.maxExtensionPct*0.5)
        {
         sc+=10;
         AddReason(rep,"extension terkendali");
        }
      if(!smc.rsiExtreme)
        {
         sc+=10;
         AddReason(rep,"RSI netral");
        }
      if(session==HUNT_SESSION_LONDON || session==HUNT_SESSION_NY)
        {
         sc+=5;
         AddReason(rep,"sesi likuid");
        }
      return(sc);
     }

public:
   bool              Init(const SHunterSettings &cfg)
     {
      m_cfg=cfg;
      return(true);
     }

   //+---------------------------------------------------------------+
   //| Evaluasi kandidat breakout. [in] bo, smc, blockedByNews,         |
   //| spreadPips, riskOk, riskNote. Return laporan pass+skor+alasan.   |
   //+---------------------------------------------------------------+
   SConfluenceReport Review(const SBreakout &bo,const SSMCContext &smc,
                            const bool blockedByNews,const double spreadPips,
                            const bool riskOk,const string riskNote) const
     {
      SConfluenceReport rep;
      rep.passed=false;
      rep.score=0;
      rep.reasonCount=0;
      for(int i=0;i<HUNT_REASONS_MAX;i++)
         rep.reasons[i]="";

      //--- G1 — breakout itu sendiri; fatal → tanpa skor
      if(!bo.valid || bo.dir==HUNT_DIR_NONE || !bo.bodyClose)
        {
         AddReason(rep,"G1: breakout tidak valid");
         return(rep);
        }
      //--- G5 — news = veto mutlak
      if(blockedByNews)
        {
         AddReason(rep,"G5: window news aktif");
         return(rep);
        }
      //--- G2 — bias HTF
      if(smc.htfBias==HUNT_BIAS_NONE)
         AddReason(rep,"G2: bias HTF belum terbentuk");
      else if(!(bo.dir==HUNT_DIR_BUY && smc.htfBias==HUNT_BIAS_BULLISH) &&
              !(bo.dir==HUNT_DIR_SELL && smc.htfBias==HUNT_BIAS_BEARISH))
         AddReason(rep,"G2: arah vs bias HTF bentrok");
      //--- G3 — sweep
      if(m_cfg.requireLiquiditySweep && !smc.sweptInDirection)
         AddReason(rep,"G3: pool searah belum di-sweep");
      //--- G4 — zona retest (false = opt-in entry langsung; lihat docs)
      if(m_cfg.requireRetest && !smc.zoneFound)
         AddReason(rep,"G4: tidak ada OB/FVG utk retest");
      //--- G3b (v1.07, opt-in) — inducement: minor liq tersapu pra-break
      if(m_cfg.requireInducement && !smc.inducementSwept)
         AddReason(rep,"G3b: minor liquidity belum tersapu");
      //--- G4b (v1.07, opt-in) — zona di discount/premium range hari
      if(m_cfg.requireDiscount && smc.zoneFound && !smc.pricePosOk)
         AddReason(rep,"G4b: zona di luar discount/premium");
      //--- G6 — spread
      if(m_cfg.maxSpreadPips>0.0 && spreadPips>m_cfg.maxSpreadPips)
         AddReason(rep,"G6: spread di atas batas");
      //--- G7 — risk
      if(!riskOk)
         AddReason(rep,"G7: risk: "+riskNote);

      rep.score=ComputeScore(bo,smc,(int)bo.session,rep);
      rep.passed=OnlyNotes(rep) && rep.score>=m_cfg.minScore;
      if(!rep.passed && OnlyNotes(rep))
         AddReason(rep,StringFormat("skor %d < min %d",rep.score,m_cfg.minScore));
      return(rep);
     }

   /** [DEPRIKASI utk fase zona — v1.06] Pemeriksaan lama 'zona masih hidup'
       lewat ctx.zoneFound proved WRONG: bar sentuh pertama menandai zona
       MITIGATED → zoneFound false → retest mode EXECUTION ikut terbunuh.
       Sejak v1.06 main memakai CSMCEngine::ZoneStillActive (geometri level
       plan, alive=ACTIVE|MITIGATED) — zone.id sendiri tak stabil antar-
       rebuild. Method dipertahankan utk kompatibilitas API. */
   bool              StillValid(const SSignalPlan &plan,const SSMCContext &smcNow) const
     {
      if(plan.zoneId!=0 && !smcNow.zoneFound)
         return(false);
      if(smcNow.extensionPct>m_cfg.maxExtensionPct)
         return(false);
      return(true);
     }
  };

#endif // ORB_SMC_HUNTER_CONFLUENCEVALIDATOR_MQH
//+------------------------------------------------------------------+
