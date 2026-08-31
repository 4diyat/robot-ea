//+------------------------------------------------------------------+
//|                                              VisualRenderer.mqh  |
//| Render 9 kategori elemen chart. Prinsip:                            |
//|  - Nama objek = PREFIX kategori + id stabil (mis. "HUNT_OB_23");     |
//|    LEDGER internal (category,name,expire) → penghapusan SELALU        |
//|    per-objek by name. TIDAK pernah ObjectsDeleteAll — objek user      |
//|    lain tidak tersentuh.                                              |
//|  - Kategori statis (range, zona, struktur, sweep, news): rebuild      |
//|    per bar baru (clear-kategori → gambar ulang dari snapshot).        |
//|  - Pivot & Volume Profile: recompute hanya awal hari / ganti sesi.     |
//|  - News: re-render hanya saat NewsFilter.refresh (main yang decide).   |
//|  - ChartRedraw sekali per siklus (Finish()), bukan per objek.          |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_VISUALRENDERER_MQH
#define ORB_SMC_HUNTER_VISUALRENDERER_MQH

#include "HunterSettings.mqh"
#include "SessionManager.mqh"
#include "SMCEngine.mqh"
#include "NewsFilter.mqh"

class CVisualRenderer
  {
private:
   SHunterSettings     m_cfg;
   SLedgerEntry        m_ledger[];
   bool                m_dirty;
   //--- anchor recompute utk layer berat
   datetime            m_pivotDay;
   datetime            m_vpAnchor;
   SVolumeProfile      m_vp;
   SPivotSet           m_piv;

   //=== ledger ---------------------------------------------------------
   void                LedgerAdd(const int category,const string name,const datetime expireTime)
     {
      int i=ArraySize(m_ledger);
      ArrayResize(m_ledger,i+1);
      m_ledger[i].category=category;
      m_ledger[i].name=name;
      m_ledger[i].expireTime=expireTime;
     }
   void                LedgerRemove(const string name)
     {
      ObjectDelete(0,name);
      for(int i=ArraySize(m_ledger)-1;i>=0;i--)
         if(m_ledger[i].name==name)
           {
            for(int k=i;k<ArraySize(m_ledger)-1;k++)
               m_ledger[k]=m_ledger[k+1];
            ArrayResize(m_ledger,ArraySize(m_ledger)-1);
            return;
           }
     }
   void                LedgerClear(const int category)
     {
      for(int i=ArraySize(m_ledger)-1;i>=0;i--)
        {
         if(m_ledger[i].category!=category)
            continue;
         ObjectDelete(0,m_ledger[i].name);
         for(int k=i;k<ArraySize(m_ledger)-1;k++)
            m_ledger[k]=m_ledger[k+1];
         ArrayResize(m_ledger,ArraySize(m_ledger)-1);
        }
     }
   void                Touch(const string name) { m_dirty=true; }

   //=== primitive ------------------------------------------------------
   void                BaseObj(const string name,const ENUM_OBJECT type)
     {
      ObjectDelete(0,name);
      ObjectCreate(0,name,type,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_ZORDER,0);
     }
   void                DrawTimeLine(const string name,const datetime t1,const double p1,
                                    const datetime t2,const double p2,const color clr,
                                    const int width,const ENUM_LINE_STYLE style,const bool back,
                                    const int category,const datetime expireTime)
     {
      BaseObj(name,OBJ_TREND);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,width);
      ObjectSetInteger(0,name,OBJPROP_STYLE,style);
      ObjectSetInteger(0,name,OBJPROP_BACK,back);
      ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,false);
      ObjectSetInteger(0,name,OBJPROP_RAY_LEFT,false);
      ObjectSetDouble(0,name,OBJPROP_PRICE,0,p1);
      ObjectSetDouble(0,name,OBJPROP_PRICE,1,p2);
      ObjectSetInteger(0,name,OBJPROP_TIME,0,(long)t1);
      ObjectSetInteger(0,name,OBJPROP_TIME,1,(long)t2);
      LedgerAdd(category,name,expireTime);
      Touch(name);
     }
   void                DrawZoneBox(const string name,const datetime t1,const double p1,
                                   const datetime t2,const double p2,const color fillClr,
                                   const bool dashedFill,const int category,const datetime expireTime)
     {
      BaseObj(name,OBJ_RECTANGLE);
      ObjectSetInteger(0,name,OBJPROP_COLOR,fillClr);
      ObjectSetInteger(0,name,OBJPROP_BGCOLOR,fillClr);
      ObjectSetInteger(0,name,OBJPROP_FILL,!dashedFill);
      ObjectSetInteger(0,name,OBJPROP_STYLE,(dashedFill ? STYLE_DOT : STYLE_SOLID));
      ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
      ObjectSetDouble(0,name,OBJPROP_PRICE,0,p1);
      ObjectSetDouble(0,name,OBJPROP_PRICE,1,p2);
      ObjectSetInteger(0,name,OBJPROP_TIME,0,(long)t1);
      ObjectSetInteger(0,name,OBJPROP_TIME,1,(long)t2);
      LedgerAdd(category,name,expireTime);
      Touch(name);
     }
   void                DrawTextLabel(const string name,const datetime t,const double p,
                                     const string text,const color clr,const int fsize,
                                     const ENUM_ANCHOR_POINT anchor,const int category,
                                     const datetime expireTime)
     {
      BaseObj(name,OBJ_TEXT);
      ObjectSetString(0,name,OBJPROP_TEXT,text);
      ObjectSetString(0,name,OBJPROP_FONT,"Arial");
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fsize);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,anchor);
      ObjectSetDouble(0,name,OBJPROP_PRICE,p);
      ObjectSetInteger(0,name,OBJPROP_TIME,(long)t);
      LedgerAdd(category,name,expireTime);
      Touch(name);
     }
   void                DrawArrow(const string name,const datetime t,const double p,
                                 const int code,const color clr,const int anchor,
                                 const int category,const datetime expireTime)
     {
      BaseObj(name,OBJ_ARROW);
      ObjectSetInteger(0,name,OBJPROP_ARROWCODE,code);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,anchor);
      ObjectSetDouble(0,name,OBJPROP_PRICE,0,p);
      ObjectSetDouble(0,name,OBJPROP_PRICE,1,p);
      ObjectSetInteger(0,name,OBJPROP_TIME,0,(long)t);
      ObjectSetInteger(0,name,OBJPROP_TIME,1,(long)t);
      LedgerAdd(category,name,expireTime);
      Touch(name);
     }
   string              PipsStr(const CDataService &data,const double diff) const
     {
      return(StringFormat("%.0fp",HUNT_PriceToPips(diff,data.PipSize())));
     }

   //=== layer berat (recompute terjadwal) --------------------------------
   void                ComputeDailyPivot(const CDataService &data,const datetime dayBroker)
     {
      m_piv.valid=false;
      MqlRates prev;
      if(!data.GetPrevDailyBar(prev))
         return;
      double pp=(prev.high+prev.low+prev.close)/3.0;
      m_piv.valid=true;
      m_piv.dayUtc=dayBroker;
      m_piv.pp=pp;
      m_piv.r1=2.0*pp-prev.low;
      m_piv.s1=2.0*pp-prev.high;
      m_piv.r2=pp+(prev.high-prev.low);
      m_piv.s2=pp-(prev.high-prev.low);
      m_piv.r3=prev.high+2.0*(pp-prev.low);
      m_piv.s3=prev.low-2.0*(prev.high-pp);
     }
   /** Volume profile jendela sesi (approximasi per-bar; lihat docs). */
   void                ComputeVolumeProfile(const CDataService &data,const SOpenRange &r)
     {
      m_vp.valid=false;
      m_vp.binCount=0;
      int nb=data.ClosedBars();
      if(nb<=0)
         return;
      double hi=-DBL_MAX,lo=DBL_MAX;
      long volSum=0;
      for(int i=0;i<nb;i++)
        {
         MqlRates br;
         if(!data.GetClosedBar(i,br))
            break;
         if(br.time<r.sessionStart)
            continue;
         if(br.time>r.sessionEnd)
            continue;
         if(br.high>hi)
            hi=br.high;
         if(lo==DBL_MAX || br.low<lo)
            lo=br.low;
         volSum+=br.tick_volume;
        }
      if(hi<=0.0 || lo>=hi || volSum<=0)
         return;
      double binH=(hi-lo)/HUNT_VOLPROFILE_BINS;
      if(binH<=0.0)
         return;
      long vols[HUNT_VOLPROFILE_BINS];
      for(int b=0;b<HUNT_VOLPROFILE_BINS;b++)
         vols[b]=0;
      for(int i=0;i<nb;i++)
        {
         MqlRates br;
         if(!data.GetClosedBar(i,br))
            break;
         if(br.time<r.sessionStart || br.time>r.sessionEnd)
            continue;
         double tp=(br.high+br.low+br.close)/3.0;
         int bin=(int)MathFloor((tp-lo)/binH);
         if(bin<0)
            bin=0;
         if(bin>=HUNT_VOLPROFILE_BINS)
            bin=HUNT_VOLPROFILE_BINS-1;
         vols[bin]+=br.tick_volume;
        }
      int poc=0;
      long maxv=0,sum=0;
      for(int b=0;b<HUNT_VOLPROFILE_BINS;b++)
        {
         m_vp.bins[b].priceLow=lo+b*binH;
         m_vp.bins[b].priceHigh=lo+(b+1)*binH;
         m_vp.bins[b].volume=vols[b];
         if(vols[b]>maxv)
           {
            maxv=vols[b];
            poc=b;
           }
         sum+=vols[b];
        }
      //--- value area 70%: expand dari POC
      long need=(long)(sum*0.7);
      long acc=vols[poc];
      int up=poc,dn=poc;
      while(acc<need && (up+1<HUNT_VOLPROFILE_BINS || dn-1>=0))
        {
         long vu=(up+1<HUNT_VOLPROFILE_BINS ? vols[up+1] : -1);
         long vd=(dn-1>=0 ? vols[dn-1] : -1);
         if(vu>=vd)
           {
            up++;
            acc+=MathMax(0,vu);
           }
         else
           {
            dn--;
            acc+=MathMax(0,vd);
           }
        }
      m_vp.poc=lo+(poc+0.5)*binH;
      m_vp.vah=lo+(up+1)*binH;
      m_vp.val=lo+dn*binH;
      m_vp.maxVol=(double)maxv;
      m_vp.binCount=HUNT_VOLPROFILE_BINS;
      m_vp.valid=true;
      m_vp.windowFrom=r.sessionStart;
      m_vp.windowTo=r.sessionEnd;
     }

public:
                     CVisualRenderer(void) : m_dirty(false), m_pivotDay(0),
                                             m_vpAnchor(0)
     {
      ArrayFree(m_ledger);
      m_vp.valid=false;
      m_piv.valid=false;
     }

   bool              Init(const SHunterSettings &cfg)
     {
      m_cfg=cfg;
      return(true);
     }
   /** Panggil di akhir siklus render — 1x redraw, hemat CPU. */
   void              Finish(void)
     {
      if(m_dirty)
        {
         ChartRedraw(0);
         m_dirty=false;
        }
     }

   //+---------------------------------------------------------------+
   //| 0. Band LATAR sesi — rectangle terisi full-tinggi chart per      |
   //| jendela sesi, hari ini + 3 hari ke belakang (pengulangan harian,   |
   //| jam broker). Warna solid gelap (constraint TANPA alpha);          |
   //| OBJPROP_BACK=true → candle tetap di depan; sesi LIVE memakai      |
   //| varian lebih terang. Rebuild per bar via ledger HUNT_LED_SESS.     |
   //+---------------------------------------------------------------+
   void              RenderSessionBands(const CSessionManager &sessions,const datetime nowBrk)
     {
      LedgerClear(HUNT_LED_SESS);
      if(!m_cfg.showSessionBands)
         return;
      datetime day0=sessions.GetDayStartUtc();
      if(day0<=0)
         return;
      for(int d=3;d>=0;d--)                      // hari ini + 3 lampau
        {
         datetime day=day0-d*86400;
         for(int s=0;s<HUNT_SESSION_COUNT;s++)
           {
            if(!m_cfg.enableSession[s])
               continue;
            datetime t1=day+m_cfg.startHourBrk[s]*3600;
            datetime t2=day+m_cfg.endHourBrk[s]*3600;
            if(t2<=t1)
               t2+=86400;                         // wrap tengah malam
            if(t1>nowBrk+7200)
               continue;                          // tak menggambar masa depan
            bool liveNow=(nowBrk>=t1 && nowBrk<t2);
            color c;
            if(s==HUNT_SESSION_ASIA)
               c=(liveNow ? HUNT_COL_BAND_ASIA_ON : HUNT_COL_BAND_ASIA);
            else if(s==HUNT_SESSION_LONDON)
               c=(liveNow ? HUNT_COL_BAND_LONDON_ON : HUNT_COL_BAND_LONDON);
            else
               c=(liveNow ? HUNT_COL_BAND_NY_ON : HUNT_COL_BAND_NY);
            string nm=StringFormat("%s%d_%I64d",HUNT_PREFIX_SESS,s,(long)t1);
            BaseObj(nm,OBJ_RECTANGLE);
            ObjectSetInteger(0,nm,OBJPROP_COLOR,c);
            ObjectSetInteger(0,nm,OBJPROP_BGCOLOR,c);
            ObjectSetInteger(0,nm,OBJPROP_FILL,true);
            ObjectSetInteger(0,nm,OBJPROP_BACK,true);
            ObjectSetInteger(0,nm,OBJPROP_ZORDER,-1);
            ObjectSetDouble(0,nm,OBJPROP_PRICE,0,1.0e8);
            ObjectSetDouble(0,nm,OBJPROP_PRICE,1,-1.0e8);
            ObjectSetInteger(0,nm,OBJPROP_TIME,0,(long)t1);
            ObjectSetInteger(0,nm,OBJPROP_TIME,1,(long)t2);
            LedgerAdd(HUNT_LED_SESS,nm,0);
            Touch(nm);
           }
        }
     }

   //+---------------------------------------------------------------+
   //| 1. Garis OR per sesi — hanya sesi dgn range formed; hapus saat     |
   //| sesi lain mulai (rebuild kategori tiap bar). Warn per sesi.        |
   //+---------------------------------------------------------------+
   void              RenderOpeningRanges(const CSessionManager &sessions,const CDataService &data,
                                         const datetime nowBrk)
     {
      LedgerClear(HUNT_LED_OR);
      for(int s=0;s<HUNT_SESSION_COUNT;s++)
        {
         SOpenRange r;
         if(!sessions.GetRange(s,r) || !r.formed || r.high<=0.0 || r.low<=0.0)
            continue;
         //--- sesi live ATAU yang baru lewat (<=6 jam) tetap tampil;
         //--- sesi lama otomatis hilang saat sesi baru mulai / ganti hari
         if(!sessions.IsSessionLive(s,nowBrk) && (nowBrk-r.sessionEnd)>6*3600)
            continue;
         color clr=CSessionManager::SessionColor(s);
         string tag=IntegerToString((long)s);
         DrawTimeLine(HUNT_PREFIX_OR+"hi"+tag,r.sessionStart,r.high,r.sessionEnd,r.high,
                      clr,2,STYLE_SOLID,false,HUNT_LED_OR,0);
         DrawTimeLine(HUNT_PREFIX_OR+"lo"+tag,r.sessionStart,r.low,r.sessionEnd,r.low,
                      clr,2,STYLE_SOLID,false,HUNT_LED_OR,0);
         string st="Ranging";
         if(r.status==ORB_STATUS_BREAKOUT_UP)
            st="Breakout Up";
         else if(r.status==ORB_STATUS_BREAKOUT_DOWN)
            st="Breakout Down";
         else if(r.status==ORB_STATUS_INVALIDATED)
            st="Invalidated";
         DrawTextLabel(HUNT_PREFIX_OR+"lbl"+tag,r.rangeEnd,r.high,
                       StringFormat("%s OR %s %s",CSessionManager::SessionName(s),st,
                                    PipsStr(data,r.high-r.low)),clr,8,ANCHOR_LEFT_LOWER,
                       HUNT_LED_OR,0);
        }
     }

   //+---------------------------------------------------------------+
   //| 2. Zona OB (fill) & FVG (dot border) — hilang saat mitigated/      |
   //| invalid (engine state).                                            |
   //+---------------------------------------------------------------+
   void              RenderZones(const CSMCEngine &smc,const datetime nowBrk)
     {
      LedgerClear(HUNT_LED_OB);
      LedgerClear(HUNT_LED_FVG);
      SZone zs[];
      smc.CopyZones(zs);
      for(int i=0;i<ArraySize(zs);i++)
        {
         SZone z=zs[i];
         if(z.state==HUNT_ZONE_INVALID)
            continue;                              // dihapus (bukan cuma hide)
         bool bull=(z.type==HUNT_ZONE_OB_BULL||z.type==HUNT_ZONE_FVG_BULL||
                    z.type==HUNT_ZONE_BREAKER_BULL);
         bool fvg=(z.type==HUNT_ZONE_FVG_BULL||z.type==HUNT_ZONE_FVG_BEAR);
         if(fvg && !m_cfg.showFvg)
            continue;
         if(!fvg && !m_cfg.showOB)
            continue;
         color c=(bull ? HUNT_COL_BULL : HUNT_COL_BEAR);
         string nm=(fvg ? HUNT_PREFIX_FVG : HUNT_PREFIX_OB)+IntegerToString((long)z.id);
         bool   mit=(z.state==HUNT_ZONE_MITIGATED);
         datetime t2e=(z.extendTime>z.createdTime ? z.extendTime : nowBrk);
         //--- mitigated: kotak PUDAR, berhenti di titik fill (tidak menjuntai
         //--- ke kanan), auto-hapus 12 bar — chart tidak lagi menumpuk zona mati
         datetime zexp=(mit ? nowBrk+12*PeriodSeconds(_Period) : 0);
         DrawZoneBox(nm,z.createdTime,z.top,t2e,z.bottom,
                     (mit ? clrDimGray : c),fvg,HUNT_LED_OB,zexp);
         if(mit)
            DrawTextLabel(nm+"~mit",t2e,z.top,
                          (fvg ? "FVG filled" : (z.type>=HUNT_ZONE_BREAKER_BULL ?
                                                   "BRK mit." : "OB mit.")),clrDimGray,7,ANCHOR_LEFT_LOWER,
                          (fvg ? HUNT_LED_FVG : HUNT_LED_OB),zexp);
        }
     }

   /** 3. Label HH/HL/LH/LL + BOS vs CHoCH (panah pendek warna beda). */
   void              RenderStructure(const CSMCEngine &smc)
     {
      LedgerClear(HUNT_LED_STR);
      if(!m_cfg.showStructure)
         return;
      SSwingPoint sw[];
      smc.CopySwings(sw);
      for(int i=0;i<ArraySize(sw);i++)
        {
         string lab="";
         switch(sw[i].label)
           {
            case HUNT_SWING_HH : lab="HH"; break;
            case HUNT_SWING_HL : lab="HL"; break;
            case HUNT_SWING_LH : lab="LH"; break;
            case HUNT_SWING_LL : lab="LL"; break;
           }
         if(lab=="")
            continue;
         color c=(sw[i].type==HUNT_DIR_BUY ? clrTomato : clrDodgerBlue);
         DrawTextLabel(HUNT_PREFIX_STR+"sw"+IntegerToString((long)sw[i].time),sw[i].time,sw[i].price,
                       lab,c,7,(sw[i].type==HUNT_DIR_BUY ? ANCHOR_LOWER : ANCHOR_UPPER),
                       HUNT_LED_STR,0);
        }
      SStructureEvent evs[];
      smc.CopyStructure(evs);
      for(int i=0;i<ArraySize(evs);i++)
        {
         bool choch=(evs[i].kind==HUNT_STRUCT_CHOCH);
         color c=(choch ? clrMagenta : (evs[i].dir==HUNT_DIR_BUY ? clrLimeGreen : clrOrangeRed));
         DrawArrow(HUNT_PREFIX_STR+"bo"+IntegerToString((long)evs[i].time),evs[i].time,evs[i].price,
                   (evs[i].dir==HUNT_DIR_BUY ? 241 : 242),c,
                   (evs[i].dir==HUNT_DIR_BUY ? ANCHOR_TOP : ANCHOR_BOTTOM),HUNT_LED_STR,0);
         DrawTextLabel(HUNT_PREFIX_STR+"bt"+IntegerToString((long)evs[i].time),evs[i].time,evs[i].price,
                       (choch ? "CHoCH" : "BOS"),c,7,ANCHOR_LEFT_LOWER,HUNT_LED_STR,0);
        }
     }

   /** 4. Panah sweep di wick ekstrem pool equal-high/low. */
   void              RenderSweeps(const CSMCEngine &smc)
     {
      LedgerClear(HUNT_LED_SWP);
      if(!m_cfg.showSweep)
         return;
      SLiquidityPool ps[];
      smc.CopyPools(ps);
      for(int i=0;i<ArraySize(ps);i++)
        {
         if(!ps[i].swept)
            continue;
         DrawArrow(HUNT_PREFIX_SWP+IntegerToString((long)ps[i].sweptTime),ps[i].sweptTime,
                   ps[i].sweptExtreme,(ps[i].abovePrice ? 242 : 241),clrDeepPink,
                   (ps[i].abovePrice ? ANCHOR_BOTTOM : ANCHOR_TOP),HUNT_LED_SWP,0);
        }
     }

   /** 5. Panah + label retest/entry (harga, SL, TP, RR aktual). */
   void              RenderEntryMarker(const SSignalPlan &plan,const datetime fillTime,
                                        const double fillPrice,const CDataService &data)
     {
      if(!m_cfg.showEntryArrows)
         return;
      string nm=HUNT_PREFIX_ENT+IntegerToString((long)plan.planId);
      bool buy=(plan.dir==HUNT_DIR_BUY);
      DrawArrow(nm,fillTime,fillPrice,(buy ? 233 : 234),(buy ? HUNT_COL_READY : HUNT_COL_BEAR),
                (buy ? ANCHOR_TOP : ANCHOR_BOTTOM),HUNT_LED_ENT,fillTime+86400);
      int dg=data.Digits();
      DrawTextLabel(nm+"lbl",fillTime,fillPrice,
                    StringFormat("%s @ %s | SL %s | TP %s | RR %.1f",
                                 (buy ? "BUY" : "SELL"),DoubleToString(plan.entry,dg),
                                 DoubleToString(plan.sl,dg),DoubleToString(plan.tp2,dg),
                                 plan.rrFinal),
                    HUNT_COL_TEXT,8,(buy ? ANCHOR_UPPER : ANCHOR_LOWER),HUNT_LED_ENT,
                    fillTime+86400);
     }

   /** 5b. Penanda CHoCH HTF (bias reversal) — dipanggil main saat event. */
   void                RenderHtfChoch(const datetime t,const double price,
                                      const ENUM_HUNT_DIR newDir)
     {
      if(!m_cfg.showStructure)
         return;
      string nm=HUNT_PREFIX_STR+"htfc"+IntegerToString((long)t);
      DrawArrow(nm,t,price,(newDir==HUNT_DIR_BUY ? 233 : 234),clrOrange,
                (newDir==HUNT_DIR_BUY ? ANCHOR_BOTTOM : ANCHOR_TOP),HUNT_LED_STR,0);
      DrawTextLabel(nm+"l",t,price,
                    StringFormat("CHoCH HTF → %s",(newDir==HUNT_DIR_BUY ? "Bullish" : "Bearish")),
                    clrOrange,8,ANCHOR_LOWER,HUNT_LED_STR,0);
     }

   /** 6. Pivot harian (awal hari) — garis tipis + label ujung kanan. */
   void              RenderPivots(const CDataService &data,const datetime dayBroker)
     {
      if(!m_cfg.showPivot)
         return;
      if(m_pivotDay==dayBroker && m_piv.valid)
         return;                                   // recompute hanya awal hari
      m_pivotDay=dayBroker;
      ComputeDailyPivot(data,dayBroker);
      LedgerClear(HUNT_LED_PIV);
      if(!m_piv.valid)
         return;
      datetime t2=dayBroker+86400;
      double lv[7]=
        {
         m_piv.r3,m_piv.r2,m_piv.r1,m_piv.pp,m_piv.s1,m_piv.s2,m_piv.s3
        };
      string nm[7]={"R3","R2","R1","PP","S1","S2","S3"};
      color cl[7]=
        {
         clrRosyBrown,clrIndianRed,clrLightCoral,clrSilver,
         clrCadetBlue,clrSteelBlue,clrCornflowerBlue
        };
      for(int i=0;i<7;i++)
        {
         string s=StringFormat("%s%d",nm[i],i);
         DrawTimeLine(HUNT_PREFIX_PIV+s,dayBroker,lv[i],t2,lv[i],cl[i],1,STYLE_DOT,false,
                      HUNT_LED_PIV,t2);
         DrawTextLabel(HUNT_PREFIX_PIV+nm[i]+"_t",t2,lv[i],
                       StringFormat("%s %s",nm[i],DoubleToString(lv[i],data.Digits())),
                       cl[i],7,ANCHOR_RIGHT_LOWER,HUNT_LED_PIV,t2);
        }
     }

   /** 7. Volume profile sesi berjalan (recompute ganti sesi/hari). */
   void              RenderVolumeProfile(const CSessionManager &sessions,const CDataService &data,
                                          const datetime nowBrk)
     {
      if(!m_cfg.showVolumeProfile)
         return;
      int s=sessions.ActiveSession(nowBrk);
      if(s<0)
         return;                                   // tanpa sesi aktif: pertahankan
      SOpenRange r;
      if(!sessions.GetRange(s,r))
         return;
      if(m_vpAnchor==r.sessionStart && m_vp.valid)
         return;                                   // hemat: skip bila sesi sama
      m_vpAnchor=r.sessionStart;
      ComputeVolumeProfile(data,r);
      LedgerClear(HUNT_LED_VP);
      if(!m_vp.valid)
         return;
      datetime t1=data.CurrentBarTime();
      datetime t2=t1+PeriodSeconds(_Period)*30;
      //--- lebar bin waktu proporsional volume (max = 1/6 lebar panel)
      for(int i=0;i<m_vp.binCount;i++)
        {
         if(m_vp.bins[i].volume<=0)
            continue;
         double frac=(m_vp.maxVol>0.0 ? (double)m_vp.bins[i].volume/m_vp.maxVol : 0.0);
         datetime bEnd=t1+(datetime)((t2-t1)*frac/6.0);
         string nm=HUNT_PREFIX_VP+"b"+IntegerToString(i);
         DrawZoneBox(nm,t1,m_vp.bins[i].priceHigh,bEnd,m_vp.bins[i].priceLow,
                     C'70,90,120',false,HUNT_LED_VP,0);
        }
      DrawTimeLine(HUNT_PREFIX_VP+"poc",t1,m_vp.poc,t2,m_vp.poc,clrAqua,2,STYLE_SOLID,false,
                   HUNT_LED_VP,0);
      DrawTimeLine(HUNT_PREFIX_VP+"vah",t1,m_vp.vah,t2,m_vp.vah,clrGold,1,STYLE_DASH,false,
                   HUNT_LED_VP,0);
      DrawTimeLine(HUNT_PREFIX_VP+"val",t1,m_vp.val,t2,m_vp.val,clrGold,1,STYLE_DASH,false,
                   HUNT_LED_VP,0);
      DrawTextLabel(HUNT_PREFIX_VP+"lbl",t1,m_vp.poc,StringFormat("POC %s",DoubleToString(m_vp.poc,data.Digits())),
                    clrAqua,8,ANCHOR_RIGHT_LOWER,HUNT_LED_VP,0);
     }

   /** 8. News: vline + label + shading window — HANYA saat refresh. */
   void              RenderNews(const CNewsFilter &news,const datetime nowBrk)
     {
      LedgerClear(HUNT_LED_NEWS);
      if(!m_cfg.showNewsMarkers || !m_cfg.newsEnabled)
         return;
      SNewsEvent evs[];
      ArrayResize(evs,HUNT_MAX_NEWS);
      int n=news.GetVisibleEvents(evs,HUNT_MAX_NEWS,nowBrk);
      for(int i=0;i<n;i++)
        {
         color c=(evs[i].impact>=3 ? HUNT_COL_NEWS_HIGH : HUNT_COL_NEWS_MED);
         string id=StringFormat("ev%d",(int)evs[i].timeBroker);
         BaseObj(HUNT_PREFIX_NEWS+id,OBJ_VLINE);
         ObjectSetInteger(0,HUNT_PREFIX_NEWS+id,OBJPROP_COLOR,c);
         ObjectSetInteger(0,HUNT_PREFIX_NEWS+id,OBJPROP_STYLE,STYLE_DOT);
         ObjectSetInteger(0,HUNT_PREFIX_NEWS+id,OBJPROP_WIDTH,1);
         ObjectSetInteger(0,HUNT_PREFIX_NEWS+id,OBJPROP_TIME,(long)evs[i].timeBroker);
         LedgerAdd(HUNT_LED_NEWS,HUNT_PREFIX_NEWS+id,evs[i].blockTo+3600);
         DrawTimeLine(HUNT_PREFIX_NEWS+id+"f",evs[i].blockFrom,ChartGetDouble(0,CHART_PRICE_MAX),
                      evs[i].blockFrom,ChartGetDouble(0,CHART_PRICE_MIN),c,1,STYLE_DOT,true,
                      HUNT_LED_NEWS,evs[i].blockTo+3600);
         DrawTimeLine(HUNT_PREFIX_NEWS+id+"t",evs[i].blockTo,ChartGetDouble(0,CHART_PRICE_MAX),
                      evs[i].blockTo,ChartGetDouble(0,CHART_PRICE_MIN),c,1,STYLE_DOT,true,
                      HUNT_LED_NEWS,evs[i].blockTo+3600);
         string shortT=evs[i].title;
         if(StringLen(shortT)>28)
            shortT=StringSubstr(shortT,0,28)+"...";
         DrawTextLabel(HUNT_PREFIX_NEWS+id+"lbl",evs[i].timeBroker,
                       ChartGetDouble(0,CHART_PRICE_MAX),
                       StringFormat("%s %s",evs[i].currency,shortT),c,7,ANCHOR_UPPER,
                       HUNT_LED_NEWS,evs[i].blockTo+3600);
        }
     }

   /** Hapus objek expired (expireTime lewat) — panggil tiap siklus. */
   void              CleanupExpired(const datetime nowBrk)
     {
      for(int i=ArraySize(m_ledger)-1;i>=0;i--)
         if(m_ledger[i].expireTime>0 && m_ledger[i].expireTime<nowBrk)
           {
            ObjectDelete(0,m_ledger[i].name);
            for(int k=i;k<ArraySize(m_ledger)-1;k++)
               m_ledger[k]=m_ledger[k+1];
            ArrayResize(m_ledger,ArraySize(m_ledger)-1);
            m_dirty=true;
           }
     }

   /** OnDeinit/reload: hapus SEMUA objek milik EA (scan prefix HUNT_,
       targeted — bukan ObjectsDeleteAll global). */
   void              ClearAllOwned(void)
     {
      for(int i=ObjectsTotal(0)-1;i>=0;i--)
        {
         string nm=ObjectName(0,i);
         if(StringFind(nm,HUNT_OBJ_FILTER)==0)
            ObjectDelete(0,nm);
        }
      ArrayFree(m_ledger);
      ChartRedraw(0);
     }
   /** Reset memo recompute saat ganti hari (pivot/VP dipaksa ulang). */
   void              OnNewDay(void)
     {
      m_pivotDay=0;
      m_vpAnchor=0;
      m_vp.valid=false;
      m_piv.valid=false;
     }
   int               OwnedObjectCount(void) const { return(ArraySize(m_ledger)); }
  };

#endif // ORB_SMC_HUNTER_VISUALRENDERER_MQH
//+------------------------------------------------------------------+
