//+------------------------------------------------------------------+
//|                                                     Dashboard.mqh|
//| Panel: OBJ_RECTANGLE_LABEL (bg, satu) + OBJ_LABEL per baris       |
//| (HUNT_DASH_R##). Layout dibuat SEKALI; update = diff text/color   |
//| saja (ObjectSetString/SetInteger pada objek existing — tidak       |
//| pernah re-create). Baris mengikuti ENUM_HUNT_DASH_ROWS_TOTAL.      |
//|                                                                  |
//| Cadence (kontrak): UpdateOnBar utk data berat-per-bar;            |
//| UpdateOnTick utk posisi/P/L/RSI/news; UpdateOnTimer (EventSetTimer |
//| 1s) utk countdown candle & force-close — BUKAN dihitung tiap tick. |
//|                                                                  |
//| CATATAN TRANSPARANSI: MT5 tidak mendukung alpha pada window object; |
//| "semi-transparan" diemu- lasikan via bg gelap solid + panel di       |
//| margin pojok. Warna state = palet renderer (Ready entry = hijau).   |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_DASHBOARD_MQH
#define ORB_SMC_HUNTER_DASHBOARD_MQH

#include "HunterSettings.mqh"

#define HUNT_DASH_W      360
#define HUNT_DASH_H0     10
#define HUNT_DASH_LNH    15
#define HUNT_DASH_PAD    18

class CHunterDashboard
  {
private:
   SHunterSettings     m_cfg;
   bool                m_built;
   string              m_rowNames[HUNT_DASH_ROWS_TOTAL];
   string              m_rowText[HUNT_DASH_ROWS_TOTAL];
   color               m_rowColor[HUNT_DASH_ROWS_TOTAL];

   /** Diff-only setter: skip bila teks+warna identik (hemat repaint). */
   void                SetRow(const int row,const string text,const color clr)
     {
      if(row<0 || row>=HUNT_DASH_ROWS_TOTAL)
         return;
      if(m_rowText[row]==text && m_rowColor[row]==clr)
         return;
      m_rowText[row]=text;
      m_rowColor[row]=clr;
      ObjectSetString(0,m_rowNames[row],OBJPROP_TEXT,text);
      ObjectSetInteger(0,m_rowNames[row],OBJPROP_COLOR,clr);
     }
   /** Letak ulang label utk corner terpilih. */
   void                PlaceObj(const string nm,const int idx)
     {
      int corner=m_cfg.dashCorner;
      ObjectSetInteger(0,nm,OBJPROP_CORNER,corner);
      int x=(corner==CORNER_LEFT_LOWER || corner==CORNER_LEFT_UPPER ? 10
             : -(HUNT_DASH_W+6));
      ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x);
      int y=(corner==CORNER_LEFT_UPPER || corner==CORNER_RIGHT_UPPER ? HUNT_DASH_H0
             : -(HUNT_DASH_H0+HUNT_DASH_ROWS_TOTAL*HUNT_DASH_LNH+10));
      ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y+HUNT_DASH_PAD+idx*HUNT_DASH_LNH);
     }
   color               StateColor(const int state) const
     {
      switch(state)
        {
         case HUNT_STATE_READY_ENTRY:        return(HUNT_COL_READY);
         case HUNT_STATE_WAIT_RETEST:
         case HUNT_STATE_WAIT_BREAKOUT:      return(HUNT_COL_WAIT);
         case HUNT_STATE_BREAKOUT_CONFIRMED: return(clrDeepSkyBlue);
         case HUNT_STATE_MANAGING:           return(clrPaleGreen);
         case HUNT_STATE_RANGE_FORMING:      return(clrSilver);
         case HUNT_STATE_FORCE_CLOSED:       return(clrOrangeRed);
        }
      return(clrGray);
     }
   static string       StatusText(const SOpenRange &r)
     {
      switch(r.status)
        {
         case ORB_STATUS_RANGING:         return("Ranging");
         case ORB_STATUS_BREAKOUT_UP:     return("Breakout Up");
         case ORB_STATUS_BREAKOUT_DOWN:   return("Breakout Down");
         case ORB_STATUS_INVALIDATED:     return("Invalidated");
         case ORB_STATUS_FORMING:         return("Forming");
        }
      return("--");
     }

public:
                     CHunterDashboard(void) : m_built(false) {}

   //+---------------------------------------------------------------+
   //| Bangun bg + baris (idempoten). Return true ok/false (false =     |
   //| dinonaktifkan via input — bukan error).                            |
   //+---------------------------------------------------------------+
   bool              BuildLayout(const SHunterSettings &cfg)
     {
      m_cfg=cfg;
      if(!m_cfg.showDashboard)
        {
         Destroy();
         return(false);
        }
      if(!m_built)
        {
         ObjectDelete(0,HUNT_PREFIX_BG);
         ObjectCreate(0,HUNT_PREFIX_BG,OBJ_RECTANGLE_LABEL,0,0,0);
         ObjectSetInteger(0,HUNT_PREFIX_BG,OBJPROP_CORNER,m_cfg.dashCorner);
         ObjectSetInteger(0,HUNT_PREFIX_BG,OBJPROP_XDISTANCE,
                          (m_cfg.dashCorner==CORNER_LEFT_UPPER||m_cfg.dashCorner==CORNER_LEFT_LOWER ? 6 : -(HUNT_DASH_W+6)));
         ObjectSetInteger(0,HUNT_PREFIX_BG,OBJPROP_YDISTANCE,
                          (m_cfg.dashCorner==CORNER_LEFT_UPPER||m_cfg.dashCorner==CORNER_RIGHT_UPPER ? HUNT_DASH_H0 : -(HUNT_DASH_H0+HUNT_DASH_ROWS_TOTAL*HUNT_DASH_LNH+12)));
         ObjectSetInteger(0,HUNT_PREFIX_BG,OBJPROP_XSIZE,HUNT_DASH_W);
         ObjectSetInteger(0,HUNT_PREFIX_BG,OBJPROP_YSIZE,HUNT_DASH_ROWS_TOTAL*HUNT_DASH_LNH+16);
         ObjectSetInteger(0,HUNT_PREFIX_BG,OBJPROP_BGCOLOR,HUNT_COL_DASH_BG);
         ObjectSetInteger(0,HUNT_PREFIX_BG,OBJPROP_BORDER_TYPE,BORDER_FLAT);
         ObjectSetInteger(0,HUNT_PREFIX_BG,OBJPROP_COLOR,HUNT_COL_DASH_BORDER);
         ObjectSetInteger(0,HUNT_PREFIX_BG,OBJPROP_BACK,false);
         ObjectSetInteger(0,HUNT_PREFIX_BG,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,HUNT_PREFIX_BG,OBJPROP_HIDDEN,true);
         for(int i=0;i<HUNT_DASH_ROWS_TOTAL;i++)
           {
            m_rowNames[i]=HUNT_PREFIX_DASH+"R"+IntegerToString((long)i);
            ObjectDelete(0,m_rowNames[i]);
            ObjectCreate(0,m_rowNames[i],OBJ_LABEL,0,0,0);
            ObjectSetString(0,m_rowNames[i],OBJPROP_FONT,"Consolas");
            ObjectSetInteger(0,m_rowNames[i],OBJPROP_FONTSIZE,m_cfg.dashFontSize);
            ObjectSetInteger(0,m_rowNames[i],OBJPROP_SELECTABLE,false);
            ObjectSetInteger(0,m_rowNames[i],OBJPROP_HIDDEN,true);
            PlaceObj(m_rowNames[i],i);
            m_rowText[i]="";
            m_rowColor[i]=HUNT_COL_TEXT;
           }
         m_built=true;
        }
      else
        {
         //--- corner/font diganti tanpa re-init? (reinit EA = default MT5) —
         // cukup relayout posisi
         ObjectSetInteger(0,HUNT_PREFIX_BG,OBJPROP_CORNER,m_cfg.dashCorner);
         for(int i=0;i<HUNT_DASH_ROWS_TOTAL;i++)
            PlaceObj(m_rowNames[i],i);
        }
      SetRow(HUNT_DASH_HDR,HUNT_NAME+" v"+HUNT_VERSION,HUNT_COL_TEXT);
      ChartRedraw(0);
      return(true);
     }
   /** Hapus semua objek dashboard (OnDeinit / toggle off). */
   void              Destroy(void)
     {
      ObjectDelete(0,HUNT_PREFIX_BG);
      for(int i=0;i<HUNT_DASH_ROWS_TOTAL;i++)
        {
         string nm=HUNT_PREFIX_DASH+"R"+IntegerToString((long)i);
         ObjectDelete(0,nm);
        }
      m_built=false;
     }
   bool              IsActive(void) const { return(m_cfg.showDashboard && m_built); }

   //+---------------------------------------------------------------+
   //| Per bar baru: sesi, OR per sesi + status, bias, state, sinyal,     |
   //| countdown retest. Semua argumen sudah diformat pemanggil (EA) —    |
   //| panel tidak kenal modul lain (decoupled).                           |
   //+---------------------------------------------------------------+
   void              UpdateOnBar(const string sessionLine,const string rangeAsiaLine,
                                 const string rangeLonLine,const string rangeNyLine,
                                 const string biasLine,const string stateLine,const int stateVal,
                                 const string signalLine,const string retestCdLine)
     {
      if(!IsActive())
         return;
      SetRow(HUNT_DASH_SESSION_ACTIVE,sessionLine,HUNT_COL_TEXT);
      SetRow(HUNT_DASH_RANGE_ASIA,rangeAsiaLine,HUNT_COL_TEXT);
      SetRow(HUNT_DASH_RANGE_LONDON,rangeLonLine,HUNT_COL_TEXT);
      SetRow(HUNT_DASH_RANGE_NY,rangeNyLine,HUNT_COL_TEXT);
      SetRow(HUNT_DASH_HTF_BIAS,biasLine,
             (StringFind(biasLine,"Bullish")>=0 ? HUNT_COL_BULL :
              (StringFind(biasLine,"Bearish")>=0 ? HUNT_COL_BEAR : clrGray)));
      SetRow(HUNT_DASH_STATE,stateLine,StateColor(stateVal));
      SetRow(HUNT_DASH_SIGNAL,signalLine,HUNT_COL_TEXT);
      SetRow(HUNT_DASH_RETEST_CD,retestCdLine,(retestCdLine=="" ? clrGray : HUNT_COL_WAIT));
     }
   /** Per tick (murah): posisi/pending/OBOS/news. pass "" = tak berubah. */
   void              UpdateOnTick(const string posLine,const string pendingLine,
                                  const string obosLine,const string newsLine,
                                  const string todayLine)
     {
      if(!IsActive())
         return;
      if(posLine!="")
         SetRow(HUNT_DASH_POSITION,posLine,HUNT_COL_WAIT);
      if(pendingLine!="")
         SetRow(HUNT_DASH_PENDING,pendingLine,clrDeepSkyBlue);
      if(obosLine!="")
         SetRow(HUNT_DASH_OBOS,obosLine,HUNT_COL_TEXT);
      if(newsLine!="")
         SetRow(HUNT_DASH_NEWS_STATE,newsLine,
                (StringFind(newsLine,"BLOCK")>=0 ? clrRed :
                 (StringFind(newsLine,"STALE")>=0 || StringFind(newsLine,"NO DATA")>=0 ? clrOrange : clrGray)));
      if(todayLine!="")
         SetRow(HUNT_DASH_TODAY,todayLine,HUNT_COL_TEXT);
     }
   /** Per detik (OnTimer): countdown candle + force-close. */
   void              UpdateOnTimer(const int secToBarClose,const int secToForceClose,
                                   const string fcLabel)
     {
      if(!IsActive())
         return;
      int m=secToBarClose/60,s=secToBarClose%60;
      SetRow(HUNT_DASH_CANDLE_TIMER,StringFormat("Bar close in %02d:%02d",m,s),
             (secToBarClose<=30 ? HUNT_COL_WAIT : clrGray));
      if(fcLabel!="")
        {
         int fm=MathMax(0,secToForceClose)/60,fs=MathMax(0,secToForceClose)%60;
         SetRow(HUNT_DASH_FORCECLOSE,StringFormat("%s %02d:%02d",fcLabel,fm,fs),
                (secToForceClose<=300 ? clrOrangeRed : clrGray));
        }
      else
         SetRow(HUNT_DASH_FORCECLOSE,"Force-close: n/a",clrGray);
     }
   void              SetNewsTime(const string line)
     {
      if(IsActive())
         SetRow(HUNT_DASH_NEWS_UPDATED,line,clrGray);
     }

   //--- formatter statis (dipakai EA utk rakit baris; exposed = testable) --
   static string     FormatRangeLine(const string name,const SOpenRange &r,const double pipSize,
                                     const int digits)
     {
      if(r.sessionStart==0)
         return(name+": -- (off)");
      if(!r.formed)
         return(StringFormat("%s: forming...",name));
      double pips=(pipSize>0.0 ? (r.high-r.low)/pipSize : 0.0);
      return(StringFormat("%s: %s / %s  (%.0fp) %s",name,DoubleToString(r.high,digits),
                          DoubleToString(r.low,digits),pips,StatusText(r)));
     }
   static string     FormatObos(const double rsi,const double upper,const double lower,
                                const int period)
     {
      if(rsi==DBL_MAX)
         return("OB/OS: --");
      string st="Neutral";
      if(rsi>=upper)
         st="Overbought";
      else if(rsi<=lower)
         st="Oversold";
      return(StringFormat("RSI(%d) %.1f — %s",period,rsi,st));
     }
  };

#endif // ORB_SMC_HUNTER_DASHBOARD_MQH
//+------------------------------------------------------------------+
