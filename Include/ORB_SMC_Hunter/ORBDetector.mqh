//+------------------------------------------------------------------+
//|                                                 ORBDetector.mqh  |
//| Validasi breakout Opening Range (semua pada CLOSED bar):          |
//|  1. body-close menembus level OR + buffer pip (wick-only ditolak  |
//|     bila InpRequireBodyClose);                                     |
//|  2. filter ukuran minimum range sudah dieksekusi SessionManager    |
//|     (sizeOk) — breakout tidak diemit bila false;                   |
//|  3. false-breakout filter: setelah breakout, close kembali ke      |
//|     dalam range selama HUNT_FALSEBO_INSIDE bar beruntun →          |
//|     status INVALIDATED; close menembus level LAWAN → juga void.    |
//| Emit sekali per breakout per sesi (memo m_emitted) — caller wajib   |
//| Reset(session) bila ingin mengizinkan event breakout berikutnya.   |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_ORBDETECTOR_MQH
#define ORB_SMC_HUNTER_ORBDETECTOR_MQH

#include "HunterSettings.mqh"
#include "DataService.mqh"

#define HUNT_FALSEBO_INSIDE  2      // DEFAULT ambang; live: m_cfg.falseBreakBars

class CORBDetector
  {
private:
   SHunterSettings     m_cfg;
   bool                m_emitted[HUNT_SESSION_COUNT];
   int                 m_insideCount[HUNT_SESSION_COUNT];

public:
                     CORBDetector(void)
     {
      for(int i=0;i<HUNT_SESSION_COUNT;i++)
        {
         m_emitted[i]=false;
         m_insideCount[i]=0;
        }
     }

   bool              Init(const SHunterSettings &cfg)
     {
      m_cfg=cfg;
      ResetAll();
      return(true);
     }

   /** true bila body-close bar ke-`back` menembus level searah + buffer.
       [in] orIn range sesi; data; back; dir arah uji. [ret] bool. */
   bool              IsBodyBreakout(const SOpenRange &orIn,const CDataService &data,
                                    const int back,const ENUM_HUNT_DIR dir) const
     {
      MqlRates br;
      if(!data.GetClosedBar(back,br))
         return(false);
      double buf=m_cfg.breakoutBufferPips*data.PipSize();
      if(dir==HUNT_DIR_BUY)
         return(br.close>orIn.high+buf);
      if(dir==HUNT_DIR_SELL)
         return(br.close<orIn.low-buf);
      return(false);
     }

   /** true bila hanya wick menembus (close masih di dalam) — ditolak. */
   bool              IsWickOnlyBreach(const SOpenRange &orIn,const CDataService &data,
                                       const int back,const ENUM_HUNT_DIR dir) const
     {
      MqlRates br;
      if(!data.GetClosedBar(back,br))
         return(false);
      if(dir==HUNT_DIR_BUY)
         return(br.high>orIn.high && br.close<=orIn.high);
      if(dir==HUNT_DIR_SELL)
         return(br.low<orIn.low && br.close>=orIn.low);
      return(false);
     }

   /** Update status RANGING↔breakout + false-breakout INVALIDATED utk 1
       sesi dari bar closed terbaru. Tidak meng-emits event. */
   void              RefreshStatus(const int session,SOpenRange &orIn,
                                   const CDataService &data)
     {
      if(!orIn.formed || orIn.status==ORB_STATUS_NONE || orIn.status==ORB_STATUS_INVALIDATED)
         return;
      MqlRates br;
      if(!data.GetClosedBar(0,br))
         return;
      //--- breakout yang sedang hidup: cek invalidasi
      if(orIn.status==ORB_STATUS_BREAKOUT_UP || orIn.status==ORB_STATUS_BREAKOUT_DOWN)
        {
         bool backInside=(orIn.status==ORB_STATUS_BREAKOUT_UP && br.close<orIn.high
                          && br.close>orIn.low)
                         ||(orIn.status==ORB_STATUS_BREAKOUT_DOWN && br.close>orIn.low
                            && br.close<orIn.high);
         bool reverseBreak=(orIn.status==ORB_STATUS_BREAKOUT_UP && br.close<orIn.low)
                           ||(orIn.status==ORB_STATUS_BREAKOUT_DOWN && br.close>orIn.high);
         if(reverseBreak)
            orIn.status=ORB_STATUS_INVALIDATED;
         else if(backInside)
           {
            m_insideCount[session]++;
            if(m_cfg.falseBreakBars>0 &&
               m_insideCount[session]>=m_cfg.falseBreakBars)
               orIn.status=ORB_STATUS_INVALIDATED;
           }
         else
            m_insideCount[session]=0;
         return;
        }
      //--- masih ranging: update barSinceBreakout bukan tugas kita; skip
     }

   //+---------------------------------------------------------------+
   //| Evaluasi bar closed terbaru utk satu sesi; isi `dst` HANYA bila |
   //| breakout BARU yang valid terjadi (sekali emit per sesi).         |
   //| [in]  session, data, nowBroker                                  |
   //| [dst] orInOut (status/level breakout), dst (SBreakout)          |
   //| Return true = event breakout valid ter-emit.                    |
   //+---------------------------------------------------------------+
   bool              Assess(const int session,SOpenRange &orIn,
                            const CDataService &data,const datetime nowBroker,
                            SBreakout &res)
     {
      if(session<0 || session>=HUNT_SESSION_COUNT)
         return(false);
      if(!orIn.formed || !orIn.sizeOk || m_emitted[session])
         return(false);
      if(nowBroker<orIn.rangeEnd || nowBroker>=orIn.sessionEnd)
         return(false);                      // hanya dlm sesi, setelah OR
      if(orIn.status!=ORB_STATUS_RANGING)
         return(false);
      MqlRates br;
      if(!data.GetClosedBar(0,br) || br.time<orIn.rangeEnd)
         return(false);

      res.session=(ENUM_HUNT_SESSION)session;
      res.time=br.time;
      res.rangeSizePips=(data.PipSize()>0.0 ? (orIn.high-orIn.low)/data.PipSize() : 0.0);
      res.valid=false;
      res.rejectReason="";
      res.bodyClose=true;

      if(IsBodyBreakout(orIn,data,0,HUNT_DIR_BUY))
        {
         orIn.status=ORB_STATUS_BREAKOUT_UP;
         orIn.breakoutTime=br.time;
         orIn.breakoutPrice=br.close;
         orIn.breakoutDir=HUNT_DIR_BUY;
         orIn.barsSinceBreakout=0;
         m_insideCount[session]=0;
         res.dir=HUNT_DIR_BUY;
         res.closePrice=br.close;
         res.levelBroken=orIn.high;
         res.valid=true;
         m_emitted[session]=true;
         return(true);
        }
      if(IsBodyBreakout(orIn,data,0,HUNT_DIR_SELL))
        {
         orIn.status=ORB_STATUS_BREAKOUT_DOWN;
         orIn.breakoutTime=br.time;
         orIn.breakoutPrice=br.close;
         orIn.breakoutDir=HUNT_DIR_SELL;
         orIn.barsSinceBreakout=0;
         m_insideCount[session]=0;
         res.dir=HUNT_DIR_SELL;
         res.closePrice=br.close;
         res.levelBroken=orIn.low;
         res.valid=true;
         m_emitted[session]=true;
         return(true);
        }
      //--- wick-only: catat penolakan (info utk log), status tetap RANGING
      if(m_cfg.requireBodyClose &&
         (IsWickOnlyBreach(orIn,data,0,HUNT_DIR_BUY)||IsWickOnlyBreach(orIn,data,0,HUNT_DIR_SELL)))
        {
         res.rejectReason="wick-only breach (requireBodyClose)";
         res.dir=(br.high>orIn.high ? HUNT_DIR_BUY : HUNT_DIR_SELL);
        }
      return(false);
     }

   /** Reset memo emitted + counter satu sesi (izinkan event baru lagi). */
   void              Reset(const int session)
     {
      if(session<0 || session>=HUNT_SESSION_COUNT)
         return;
      m_emitted[session]=false;
      m_insideCount[session]=0;
     }
   /** Reset semua (awal hari). */
   void              ResetAll(void)
     {
      for(int i=0;i<HUNT_SESSION_COUNT;i++)
        {
         m_emitted[i]=false;
         m_insideCount[i]=0;
        }
     }
  };

#endif // ORB_SMC_HUNTER_ORBDETECTOR_MQH
//+------------------------------------------------------------------+
