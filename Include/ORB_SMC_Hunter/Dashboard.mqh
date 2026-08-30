//+------------------------------------------------------------------+
//|                                                     Dashboard.mqh|
//| Panel HUD "night-ops": header band + LED status, progress bar    |
//| candle & force-close, 6 section band, baris dua-kolom (label     |
//| kiri / value kanan rata) dgn font mono Consolas.                 |
//|                                                                  |
//| Objek dibuat SEKALI per BuildLayout (dekor: HUNT_DASH_SHDW/HB/   |
//| ACC/CHIP/VER/LED/TRK*/FL*/SB* + per baris HUNT_DASH_R##[V]);     |
//| update harian = diff text/color saja, tanpa re-create. API luar  |
//| (SetRow/UpdateOnTimer/SetNewsTime/formatter) identik v0.9x.      |
//|                                                                  |
//| Cadence (kontrak): SetRow per baris per-bar & per-tick (diff-    |
//| only); UpdateOnTimer (EventSetTimer 1s) utk countdown + bars —   |
//| BUKAN tiap tick.                                                 |
//|                                                                  |
//| CATATAN TRANSPARANSI: MT5 tak mendukung alpha pada window object; |
//| efek "kaca" diemu-lasikan bg gelap solid + aksen cyan.          |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_DASHBOARD_MQH
#define ORB_SMC_HUNTER_DASHBOARD_MQH

#include "HunterSettings.mqh"

#define HUNT_DASH_W      360
#define HUNT_DASH_H0     10
#define HUNT_DASH_LNH    15
#define HUNT_DASH_PAD    18
#define HUNT_DASH_BANDH  16      // tinggi pita judul seksi
#define HUNT_DASH_HDRH   26      // tinggi header band
#define HUNT_DASH_NSEC   6       // jumlah seksi

class CHunterDashboard
  {
private:
   SHunterSettings     m_cfg;
   bool                m_built;
   int                 m_bgX,m_bgY,m_panelH;                  // anchor panel
   string              m_rowNames[HUNT_DASH_ROWS_TOTAL];      // label (kiri)
   string              m_rowVal[HUNT_DASH_ROWS_TOTAL];        // value (kanan)
   string              m_rowText[HUNT_DASH_ROWS_TOTAL];       // cache mentah
   color               m_rowColor[HUNT_DASH_ROWS_TOTAL];
   bool                m_rowSplit[HUNT_DASH_ROWS_TOTAL];      // 2 kolom aktif?
   int                 m_rowY[HUNT_DASH_ROWS_TOTAL];
   color               m_led;

   /** Perkiraan lebar teks px (Consolas ~0.60em/char). */
   static int          TextPx(const string t,const int fs)
     {
      return((int)(StringLen(t)*fs*0.60));
     }
   /** Rectangle-label dekoratif (koordinasi relatif anchor panel). */
   void                Rect(const string nm,const int dx,const int dy,
                            const int w,const int h,const color fill,
                            const color edge)
     {
      ObjectDelete(0,nm);
      ObjectCreate(0,nm,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,nm,OBJPROP_CORNER,m_cfg.dashCorner);
      ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,m_bgX+dx);
      ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,m_bgY+dy);
      ObjectSetInteger(0,nm,OBJPROP_XSIZE,w);
      ObjectSetInteger(0,nm,OBJPROP_YSIZE,h);
      ObjectSetInteger(0,nm,OBJPROP_BGCOLOR,fill);
      if(edge==clrNONE)
         ObjectSetInteger(0,nm,OBJPROP_BORDER_TYPE,NONE_BORDER);
      else
        {
         ObjectSetInteger(0,nm,OBJPROP_BORDER_TYPE,BORDER_FLAT);
         ObjectSetInteger(0,nm,OBJPROP_COLOR,edge);
        }
      ObjectSetInteger(0,nm,OBJPROP_BACK,false);
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
     }
   /** Label teks (anchor = property; koordinat relatif anchor panel). */
   void                Text(const string nm,const int dx,const int dy,
                            const string font,const int fs,const color clr,
                            const string txt,const ENUM_ANCHOR_POINT anc)
     {
      ObjectDelete(0,nm);
      ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,nm,OBJPROP_CORNER,m_cfg.dashCorner);
      ObjectSetInteger(0,nm,OBJPROP_ANCHOR,anc);
      ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,m_bgX+dx);
      ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,m_bgY+dy);
      ObjectSetString(0,nm,OBJPROP_FONT,font);
      ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,fs);
      ObjectSetInteger(0,nm,OBJPROP_COLOR,clr);
      ObjectSetString(0,nm,OBJPROP_TEXT,txt);
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
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
   /** Render ulang satu baris dari cache (split 2 kolom / utuh). */
   void                RenderRow(const int i)
     {
      ObjectSetString(0,m_rowNames[i],OBJPROP_TEXT,
                      m_rowSplit[i] ? StringSubstr(m_rowText[i],0,StringFind(m_rowText[i],": "))
                                    : m_rowText[i]);
      ObjectSetInteger(0,m_rowNames[i],OBJPROP_COLOR,
                       m_rowSplit[i] ? HUNT_COL_DASH_LABEL : m_rowColor[i]);
      if(m_rowSplit[i])
        {
         int p=StringFind(m_rowText[i],": ");
         ObjectSetString(0,m_rowVal[i],OBJPROP_TEXT,StringSubstr(m_rowText[i],p+2));
         ObjectSetInteger(0,m_rowVal[i],OBJPROP_COLOR,m_rowColor[i]);
        }
      else
         ObjectSetString(0,m_rowVal[i],OBJPROP_TEXT,"");
     }
   /** Putuskan layak-split (value tak boleh menabrak label). */
   bool                WantSplit(const string text,const int p) const
     {
      if(p<3 || p>22)
         return(false);
      string lab=StringSubstr(text,0,p);
      string val=StringSubstr(text,p+2);
      int fs=m_cfg.dashFontSize;
      return(TextPx(lab,fs)+TextPx(val,fs)+44 <= HUNT_DASH_W-2*HUNT_DASH_PAD);
     }
   void                SetLed(const color c)
     {
      if(c==m_led)
         return;
      m_led=c;
      ObjectSetInteger(0,"HUNT_DASH_LED",OBJPROP_BGCOLOR,c);
     }

public:
                     CHunterDashboard(void) : m_built(false), m_bgX(0), m_bgY(0),
                                              m_panelH(0), m_led(clrNONE) {}

   //+---------------------------------------------------------------+
   //| Bangun panel penuh (dekor + baris). Idempoten: destroy-rebuild. |
   //| Return false bila dashboard di-nonaktifkan via input.           |
   //+---------------------------------------------------------------+
   bool              BuildLayout(const SHunterSettings &cfg)
     {
      m_cfg=cfg;
      Destroy();
      if(!m_cfg.showDashboard)
         return(false);
      int corner=m_cfg.dashCorner;
      int rows=HUNT_DASH_ROWS_TOTAL;
      m_panelH=HUNT_DASH_HDRH+8+rows*HUNT_DASH_LNH+HUNT_DASH_NSEC*HUNT_DASH_BANDH+6;
      m_bgX =(corner==CORNER_LEFT_UPPER||corner==CORNER_LEFT_LOWER ? 6 : -(HUNT_DASH_W+6));
      m_bgY =(corner==CORNER_LEFT_UPPER||corner==CORNER_RIGHT_UPPER
              ? HUNT_DASH_H0 : -(HUNT_DASH_H0+m_panelH));
      //--- peta awal seksi (enum = indeks baris pertama tiap grup)
      int sectStart[HUNT_DASH_NSEC];
      sectStart[0]=HUNT_DASH_SESSION_ACTIVE;
      sectStart[1]=HUNT_DASH_AMD;
      sectStart[2]=HUNT_DASH_CHK_BIAS;
      sectStart[3]=HUNT_DASH_POSITION;
      sectStart[4]=HUNT_DASH_NEWS_STATE;
      sectStart[5]=HUNT_DASH_PERF_SUMMARY;
      string sectTitle[HUNT_DASH_NSEC];
      sectTitle[0]="SESSIONS & RANGE";
      sectTitle[1]="STRUCTURE & SIGNAL";
      sectTitle[2]="CONFLUENCE CHECK";
      sectTitle[3]="POSITION & RISK";
      sectTitle[4]="NEWS FILTER";
      sectTitle[5]="PERFORMANCE";
      int bandY[HUNT_DASH_NSEC];
      for(g=0;g<HUNT_DASH_NSEC;g++)
         bandY[g]=-1;
      //--- layout vertikal: band di ATAS baris pertamanya
      int y=HUNT_DASH_HDRH+8;
      int g,i;
      for(i=0;i<rows;i++)
        {
         for(g=0;g<HUNT_DASH_NSEC;g++)
            if(sectStart[g]==i)
              {
               bandY[g]=y;
               y+=HUNT_DASH_BANDH;
              }
         m_rowY[i]=y;
         y+=HUNT_DASH_LNH;
        }
      //--- dekorasi (urutan = z-order: shadow → bg → header → dst)
      int sx=(corner==CORNER_LEFT_UPPER||corner==CORNER_LEFT_LOWER ? 4 : -4);
      Rect("HUNT_DASH_SHDW",sx,4,HUNT_DASH_W,m_panelH,HUNT_COL_DASH_SHDW,clrNONE);
      Rect("HUNT_DASH_BG",0,0,HUNT_DASH_W,m_panelH,HUNT_COL_DASH_BG,HUNT_COL_DASH_BORDER);
      Rect("HUNT_DASH_HB",1,1,HUNT_DASH_W-2,HUNT_DASH_HDRH-2,HUNT_COL_DASH_HDR,clrNONE);
      Rect("HUNT_DASH_ACC",1,HUNT_DASH_HDRH-1,HUNT_DASH_W-2,1,HUNT_COL_DASH_ACCENT,clrNONE);
      Rect("HUNT_DASH_LED",12,10,6,6,clrDimGray,HUNT_COL_DASH_HDR);
      //--- progress bars (track + fill), zona y = HDRH..HDRH+8
      int trkW=HUNT_DASH_W-2*10;
      Rect("HUNT_DASH_TRKA",10,HUNT_DASH_HDRH+2,trkW,2,HUNT_COL_DASH_TRACK,clrNONE);
      Rect("HUNT_DASH_FLA",10,HUNT_DASH_HDRH+2,0,2,HUNT_COL_DASH_ACCENT,clrNONE);
      Rect("HUNT_DASH_TRKB",10,HUNT_DASH_HDRH+5,trkW,2,HUNT_COL_DASH_TRACK,clrNONE);
      Rect("HUNT_DASH_FLB",10,HUNT_DASH_HDRH+5,0,2,clrOrange,clrNONE);
      //--- section bands
      for(g=0;g<HUNT_DASH_NSEC;g++)
         if(bandY[g]>=0)
           {
            Rect("HUNT_DASH_SB"+IntegerToString(g),1,bandY[g],HUNT_DASH_W-2,HUNT_DASH_BANDH-1,
                 C'11,17,28',clrNONE);
            Rect("HUNT_DASH_SBT"+IntegerToString(g),3,bandY[g]+3,3,HUNT_DASH_BANDH-7,
                 HUNT_COL_DASH_ACCENT,clrNONE);
            Text("HUNT_DASH_SBL"+IntegerToString(g),14,bandY[g]+3,"Segoe UI",7,
                 HUNT_COL_DASH_SECT,sectTitle[g],ANCHOR_LEFT_UPPER);
           }
      //--- strip bawah (penutup frame)
      Rect("HUNT_DASH_ACCB",1,m_panelH-2,HUNT_DASH_W-2,1,C'24,54,72',clrNONE);
      //--- header: judul + chip simbol/TF + versi (= row HDR)
      Text("HUNT_DASH_TITLE",26,6,"Segoe UI",10,C'236,242,249',
           HUNT_NAME,ANCHOR_LEFT_UPPER);
      string tf=EnumToString((ENUM_TIMEFRAMES)_Period);
      StringReplace(tf,"PERIOD_","");
      Text("HUNT_DASH_CHIP",HUNT_DASH_W-12,5,"Consolas",7,
           C'150,166,192',StringFormat("%s  %s",_Symbol,tf),ANCHOR_RIGHT_UPPER);
      Text("HUNT_DASH_VER",HUNT_DASH_W-12,15,"Consolas",6,
           HUNT_COL_DASH_SECT,HUNT_VERSION,ANCHOR_RIGHT_UPPER);
      //--- baris dua kolom
      for(i=0;i<rows;i++)
        {
         m_rowNames[i]=HUNT_PREFIX_DASH+"R"+IntegerToString((long)i);
         m_rowVal[i]  =HUNT_PREFIX_DASH+"R"+IntegerToString((long)i)+"V";
         m_rowText[i]="";
         m_rowColor[i]=HUNT_COL_TEXT;
         m_rowSplit[i]=false;
         Text(m_rowNames[i],HUNT_DASH_PAD+4,m_rowY[i]+1,"Consolas",m_cfg.dashFontSize,
              HUNT_COL_DASH_LABEL,"",ANCHOR_LEFT_UPPER);
         Text(m_rowVal[i],HUNT_DASH_W-HUNT_DASH_PAD,m_rowY[i]+1,"Consolas",m_cfg.dashFontSize,
              HUNT_COL_TEXT,"",ANCHOR_RIGHT_UPPER);
        }
      m_built=true;
      SetRow(HUNT_DASH_HDR,"EA v"+HUNT_VERSION,HUNT_COL_DASH_LABEL);
      ChartRedraw(0);
      return(true);
     }
   /** Hapus SEMUA objek dashboard (prefix-scoped; OnDeinit / rebuild). */
   void              Destroy(void)
     {
      for(int i=ObjectsTotal(0,-1,-1)-1;i>=0;i--)
        {
         string nm=ObjectName(0,i);
         if(StringFind(nm,HUNT_PREFIX_DASH)==0)
            ObjectDelete(0,nm);
        }
      m_built=false;
      m_led=clrNONE;
     }
   bool              IsActive(void) const { return(m_cfg.showDashboard && m_built); }

   /** Per detik (OnTimer): countdown candle + force-close + progress. */
   void              UpdateOnTimer(const int secToBarClose,const int totalBarSec,
                                   const int secToForceClose,const string fcLabel)
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
      //--- progress bar A: elapsed bar (0..1)
      int trkW=HUNT_DASH_W-20;
      int wa=0;
      if(totalBarSec>0)
         wa=(int)((long)(totalBarSec-MathMax(0,secToBarClose))*trkW/totalBarSec);
      ObjectSetInteger(0,"HUNT_DASH_FLA",OBJPROP_XSIZE,MathMax(0,MathMin(trkW,wa)));
      ObjectSetInteger(0,"HUNT_DASH_FLA",OBJPROP_COLOR,
                       (secToBarClose<=30 ? C'255,92,92' : HUNT_COL_DASH_ACCENT));
      //--- progress bar B: pendekatan force-close (jendela 30 mnt terakhir)
      int wb=0;
      color cb=clrSlateGray;
      if(fcLabel!="")
        {
         if(secToForceClose<=0)
           {
            wb=trkW;
            cb=clrOrangeRed;
           }
         else
           {
            wb=(int)((long)(1800-MathMax(0,secToForceClose))*trkW/1800);
            cb=(secToForceClose<=300 ? clrOrange : C'70,110,150');
            if(wb<0)
               wb=0;
           }
        }
      ObjectSetInteger(0,"HUNT_DASH_FLB",OBJPROP_XSIZE,MathMin(trkW,wb));
      ObjectSetInteger(0,"HUNT_DASH_FLB",OBJPROP_COLOR,cb);
     }
   //+---------------------------------------------------------------+
   //| API utama: SetRow per id baris — diff-only (skip bila identik).   |
   //| Teks "Label: value" otomatis dua kolom (value rata kanan, warna    |
   //| data; label grey) bila muat; selain itu satu kolom utuh warna.      |
   //+---------------------------------------------------------------+
   void              SetRow(const int row,const string text,const color clr=HUNT_COL_TEXT)
     {
      if(!IsActive())
         return;
      if(row<0 || row>=HUNT_DASH_ROWS_TOTAL)
         return;
      if(m_rowText[row]==text && m_rowColor[row]==clr)
         return;
      if(row==HUNT_DASH_HDR)
        {
         m_rowText[row]=text;
         m_rowColor[row]=clr;
         ObjectSetString(0,"HUNT_DASH_VER",OBJPROP_TEXT,text);
         return;
        }
      m_rowText[row]=text;
      m_rowColor[row]=clr;
      int p=StringFind(text,": ");
      m_rowSplit[row]=(p>0 && WantSplit(text,p));
      RenderRow(row);
      if(row==HUNT_DASH_STATE)
         SetLed(clr);
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
   /** Baris kecil waktu fetch news (tetap satu kolom grey). */
   void                SetNewsTime(const string line)
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
