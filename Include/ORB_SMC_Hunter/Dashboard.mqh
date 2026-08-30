//+------------------------------------------------------------------+
//|                                                     Dashboard.mqh|
//| Panel: OBJ_RECTANGLE_LABEL (bg, satu) + OBJ_LABEL per baris       |
//| (HUNT_DASH_R##). Layout dibuat SEKALI; update = diff text/color   |
//| saja (ObjectSetString/SetInteger pada objek existing — tidak       |
//| pernah re-create). Baris mengikuti ENUM_HUNT_DASH_ROWS_TOTAL.      |
//|                                                                  |
//| Cadence (kontrak): main memanggil SetRow utk baris per-bar &         |
//| per-tick (diff-only, tanpa wrapper); UpdateOnTimer (EventSetTimer     |
//| 1s) utk countdown candle & force-close — BUKAN dihitung tiap tick.   |
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
   //+---------------------------------------------------------------+
   //| API utama: SetRow per id baris — diff-only (skip bila identik)    |
   //| sehingga tidak pernah ada re-create/repaint objek tanpa perlu.     |
   //+---------------------------------------------------------------+
   /** Update SATU baris (objek sudah dibuat BuildLayout). */
   void                SetRow(const int row,const string text,const color clr=HUNT_COL_TEXT)
     {
      if(!IsActive())
         return;
      if(row<0 || row>=HUNT_DASH_ROWS_TOTAL)
         return;
      if(m_rowText[row]==text && m_rowColor[row]==clr)
         return;
      m_rowText[row]=text;
      m_rowColor[row]=clr;
      ObjectSetString(0,m_rowNames[row],OBJPROP_TEXT,text);
      ObjectSetInteger(0,m_rowNames[row],OBJPROP_COLOR,clr);
     }
   /** Warna konsisten utk label state machine (sinkron palet renderer). */
   static color        StateColor(const int state)
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
   /** Teks status OR (dipakai formatter baris range). */
   static color        BiasColor(const ENUM_HUNT_BIAS b)
     {
      if(b==HUNT_BIAS_BULLISH)
         return(HUNT_COL_BULL);
      if(b==HUNT_BIAS_BEARISH)
         return(HUNT_COL_BEAR);
      return(clrGray);
     }
   /** Warna baris checklist: ok=lime, gagal=indianred, tanpa setup=gray. */
   static color        ChkColor(const bool hasDir,const bool ok)
     {
      if(!hasDir)
         return(clrGray);
      return(ok ? clrLimeGreen : clrIndianRed);
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
