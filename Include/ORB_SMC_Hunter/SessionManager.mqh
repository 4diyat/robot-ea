//+------------------------------------------------------------------+
//|                                              SessionManager.mqh  |
//| Jadwal sesi + Opening Range PER SESI TERPISAH (Asia/London/NY).    |
//| Data sesi yang sudah lewat TETAP tersimpan sampai reset hari,       |
//| supaya dashboard bisa menampilkan ketiganya.                         |
//|                                                                    |
//| Ruang waktu: BROKER (TimeCurrent / bar chart). Jam input sudah       |
//| dikonversi dari UTC→broker saat snapshot bila InpTimeBase=UTC.        |
//| Sesi boleh overlap (London/NY) — tidak ada "active" tunggal utk      |
//| logika; ActiveSession() hanya label dashboard.                        |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_SESSIONMANAGER_MQH
#define ORB_SMC_HUNTER_SESSIONMANAGER_MQH

#include "DataService.mqh"

//+------------------------------------------------------------------+
//| Awal hari broker (00:00 waktu server) utk timestamp sembarang.      |
//+------------------------------------------------------------------+
datetime HUNT_BrokerDayStart(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t,dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   return(StructToTime(dt));
  }

class CSessionManager
  {
private:
   SHunterSettings     m_cfg;
   SOpenRange          m_or[HUNT_SESSION_COUNT];  // persisten sepanjang hari
   int                 m_active;                  // utk label dashboard
   datetime            m_day;                     // awal hari broker berjalan
   datetime            m_ingested[HUNT_SESSION_COUNT]; // waktu bar terakhir
                                                   // yang sudah diserap ke OR

   /** Serap bar closed dalam [sessionStart, rangeEnd) ke high/low/bars.
       Idempoten via m_ingested — aman dipanggil berulang per update. */
   void                IngestBars(const int session,const CDataService &data)
     {
      SOpenRange &r=m_or[session];
      int nb=data.ClosedBars();
      for(int b=nb-1;b>=0;b--)              // urut dari yang tertua
        {
         MqlRates br;
         if(!data.GetClosedBar(b,br))
            continue;
         if(br.time<=m_ingested[session])
            continue;
         if(br.time>=r.rangeEnd)             // di luar jendela: lewati & maju memo
           {
            m_ingested[session]=br.time;
            continue;
           }
         if(br.time<r.sessionStart)
            continue;
         if(r.high<=0.0 || br.high>r.high)
            r.high=br.high;
         if(r.low<=0.0  || br.low<r.low)
            r.low=br.low;
         r.bars++;
         m_ingested[session]=br.time;
        }
     }
   /** Bangun jendela sesi (start/end/rangeEnd, ruang broker) satu sesi. */
   void                BuildSessionWindows(const int session,const datetime day)
     {
      if(session<0 || session>=HUNT_SESSION_COUNT)
         return;
      int sh=m_cfg.startHourBrk[session];
      int eh=m_cfg.endHourBrk[session];
      m_or[session].session=(ENUM_HUNT_SESSION)session;
      m_or[session].sessionStart=day+sh*3600;
      m_or[session].sessionEnd  =day+eh*3600;
      if(m_or[session].sessionEnd<=m_or[session].sessionStart)
         m_or[session].sessionEnd+=86400;               // lintas tengah malam
      m_or[session].rangeEnd=m_or[session].sessionStart+m_cfg.rangeMinutes*60;
     }

public:
                     CSessionManager(void) : m_active(HUNT_SESSION_NONE),
                                             m_day(0)
     {
      for(int i=0;i<HUNT_SESSION_COUNT;i++)
        {
         m_or[i].Reset();
         m_ingested[i]=0;
        }
     }

   //--- identitas & warna sesi (statis — dipakai juga by main/renderer) ------
   static string     SessionName(const int session)
     {
      switch(session)
        {
         case HUNT_SESSION_ASIA  : return("Asia");
         case HUNT_SESSION_LONDON: return("London");
         case HUNT_SESSION_NY    : return("New York");
        }
      return("None");
     }
   static string     SessionCode(const int session)
     {
      switch(session)
        {
         case HUNT_SESSION_ASIA  : return(HUNT_CODE_ASIA);
         case HUNT_SESSION_LONDON: return(HUNT_CODE_LONDON);
         case HUNT_SESSION_NY    : return(HUNT_CODE_NY);
        }
      return("---");
     }
   static color      SessionColor(const int session)
     {
      switch(session)
        {
         case HUNT_SESSION_ASIA  : return(HUNT_COL_ASIA);
         case HUNT_SESSION_LONDON: return(HUNT_COL_LONDON);
         case HUNT_SESSION_NY    : return(HUNT_COL_NY);
        }
      return(clrGray);
     }

   //--- query ---------------------------------------------------------------
   /** Sesi terakhir-yang-cocok utk label dashboard (prefer sesi malam). */
   int               ActiveSession(const datetime nowBroker) const
     {
      for(int s=HUNT_SESSION_COUNT-1;s>=0;s--)
         if(IsSessionLive(s,nowBroker))
            return(s);
      return(HUNT_SESSION_NONE);
     }
   /** Sesi sedang berjalan? */
   bool              IsSessionLive(const int session,const datetime nowBroker) const
     {
      if(session<0 || session>=HUNT_SESSION_COUNT || !m_cfg.enableSession[session])
         return(false);
      const SOpenRange &r=m_or[session];
      return(nowBroker>=r.sessionStart && nowBroker<r.sessionEnd);
     }
   /** true sekarang di dalam jendela pembentukan OR sesi. */
   bool              IsRangeForming(const int session,const datetime nowBroker) const
     {
      if(!IsSessionLive(session,nowBroker))
         return(false);
      return(nowBroker<m_or[session].rangeEnd);
     }
   /** Salin range tersimpan satu sesi (tetap tersedia walau sesi lewat). */
   bool              GetRange(const int session,SOpenRange &dst) const
     {
      if(session<0 || session>=HUNT_SESSION_COUNT)
         return(false);
      dst=m_or[session];
      return(true);
     }
   int               SecondsToSessionEnd(const int session,const datetime nowBroker) const
     {
      if(session<0 || session>=HUNT_SESSION_COUNT)
         return(0);
      return((int)(m_or[session].sessionEnd-nowBroker));
     }
   int               SecondsToRangeEnd(const int session,const datetime nowBroker) const
     {
      if(session<0 || session>=HUNT_SESSION_COUNT)
         return(0);
      return((int)(m_or[session].rangeEnd-nowBroker));
     }
   /** Sisa detik menuju batas force-close (end − forceCloseMinBefore). */
   int               SecondsToForceClose(const int session,const datetime nowBroker) const
     {
      if(session<0 || session>=HUNT_SESSION_COUNT)
         return(0);
      if(m_cfg.forceCloseMinBefore<=0)
         return(-1);                              // fitur off
      return((int)((m_or[session].sessionEnd-m_cfg.forceCloseMinBefore*60)-nowBroker));
     }
   /** true sekarang >= cutoff force-close && masih di dalam sesi. */
   bool              InForceCloseWindow(const int session,const datetime nowBroker) const
     {
      if(m_cfg.forceCloseMinBefore<=0)
         return(false);
      if(!IsSessionLive(session,nowBroker))
         return(false);
      return(SecondsToForceClose(session,nowBroker)<=0);
     }
   /** Re-arm status OR satu sesi (RANGING = breakout baru bisa di-emit). */
   bool              SetOrStatus(const int session,const ENUM_ORB_STATUS st)
     {
      if(session<0 || session>=HUNT_SESSION_COUNT)
         return(false);
      m_or[session].status=st;
      if(st==ORB_STATUS_RANGING)
        {
         m_or[session].breakoutTime=0;
         m_or[session].breakoutDir=HUNT_DIR_NONE;
         m_or[session].barsSinceBreakout=0;
        }
      return(true);
     }
   /** Awal hari trading berjalan (broker). */
   datetime          CurrentDayUtc(void) const  { return(m_day); }
   datetime          GetDayStartUtc(void) const { return(m_day); }
   /** true bila nowBroker pindah hari → catat hari baru, minta rollover. */
   bool              CheckDailyRolloverRequired(const datetime nowBroker)
     {
      datetime d=HUNT_BrokerDayStart(nowBroker);
      if(d==m_day || m_day==0)
         return(false);
      m_day=d;
      return(true);
     }

   //--- lifecycle --------------------------------------------------------------
   //+---------------------------------------------------------------+
   //| Init: simpan config + bangun jendela sesi utk hari broker now.   |
   //+---------------------------------------------------------------+
   bool              Init(const SHunterSettings &cfg,const datetime nowBroker)
     {
      m_cfg=cfg;
      m_day=HUNT_BrokerDayStart(nowBroker);
      for(int s=0;s<HUNT_SESSION_COUNT;s++)
        {
         m_or[s].Reset();
         m_ingested[s]=0;
         if(m_cfg.enableSession[s])
            BuildSessionWindows(s,m_day);
        }
      m_active=ActiveSession(nowBroker);
      return(true);
     }
   //+---------------------------------------------------------------+
   //| Update tiap bar closed: serap OR, formasi, validasi ukuran,      |
   //| hitung bar sejak breakout. Closed-bar only.                      |
   //+---------------------------------------------------------------+
   void              Update(const CDataService &data,const datetime nowBroker)
     {
      for(int s=0;s<HUNT_SESSION_COUNT;s++)
        {
         if(!m_cfg.enableSession[s])
            continue;
         SOpenRange &r=m_or[s];
         if(r.sessionStart==0)
            continue;
         IngestBars(s,data);
         if(nowBroker>=r.rangeEnd && !r.formed)
           {
            r.formed=true;
            double sz=(data.PipSize()>0.0 ? (r.high-r.low)/data.PipSize() : 0.0);
            r.sizeOk=(m_cfg.minRangePips<=0.0 || sz>=m_cfg.minRangePips);
            if(!r.sizeOk)
              {
               r.status=ORB_STATUS_INVALIDATED;
               PrintFormat("%s | sesi%d: OR %.1f pips < min %.1f → skip hari ini",
                           HUNT_NAME,s,sz,m_cfg.minRangePips);
              }
            else
               r.status=ORB_STATUS_RANGING;
           }
         if(r.breakoutTime>0)
            r.barsSinceBreakout++;
        }
      m_active=ActiveSession(nowBroker);
     }
   /** Reset total (awal hari trading baru). */
   void              ResetDaily(const datetime nowBroker)
     {
      m_day=HUNT_BrokerDayStart(nowBroker);
      for(int i=0;i<HUNT_SESSION_COUNT;i++)
        {
         m_or[i].Reset();
         m_ingested[i]=0;
         if(m_cfg.enableSession[i])
            BuildSessionWindows(i,m_day);
        }
      m_active=ActiveSession(nowBroker);
     }
  };

#endif // ORB_SMC_HUNTER_SESSIONMANAGER_MQH
//+------------------------------------------------------------------+
