//+------------------------------------------------------------------+
//|                                                 DataService.mqh  |
//| Satu-satunya sumber data pasar. CopyRates/CopyBuffer dipanggil    |
//| SEKALI per bar baru (bukan per modul per tick).                    |
//|                                                                  |
//| Kontrak anti-repaint: index `back` dihitung dari bar CLOSED       |
//| terdekat: back=0 → bar terakhir yang sudah close (= shift 1),     |
//| back=1 → sebelumnya, dst. Bar berjalan TIDAK pernah diekspos       |
//| lewat getter bar — hanya lewat CurrentBarTime()/NewBarArrived().   |
//| Buffer indikator disimpan dengan orientasi identik (back).        |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_DATASERVICE_MQH
#define ORB_SMC_HUNTER_DATASERVICE_MQH

#include <Trade\SymbolInfo.mqh>
#include "HunterSettings.mqh"

class CDataService
  {
private:
   CSymbolInfo         m_sym;             // spread, tick, lot constraints
   SHunterSettings     m_cfg;             // salinan settings (pipSize dll)
   int                 m_hAtr;            // handle ATR (tf eksekusi)
   int                 m_hRsi;            // handle RSI (tf eksekusi)
   MqlRates            m_rate[];          // cache bar CLOSED exec TF
   MqlRates            m_htf[];           // cache bar CLOSED HTF
   double              m_atr[];           // selaras m_rate (back-index)
   double              m_rsi[];           // selaras m_rate (back-index)
   datetime            m_lastExecBar;     // time bar berjalan saat refresh
   datetime            m_htfBar;          // time bar HTF berjalan saat refresh

   /** Isi cache rate exec TF: closed only (start pos 1), series-order. */
   int                 RefreshExecRates(const int bars)
     {
      ArraySetAsSeries(m_rate,true);
      int n=CopyRates(_Symbol,_Period,1,bars,m_rate);
      return(n>0 ? n : ArraySize(m_rate));   // gagal: pertahankan cache lama
     }
   /** Isi cache rate HTF (closed only, series-order). */
   int                 RefreshHtfRates(const int bars)
     {
      ArraySetAsSeries(m_htf,true);
      int n=CopyRates(_Symbol,m_cfg.htf,1,bars,m_htf);
      return(n>0 ? n : ArraySize(m_htf));
     }
   /** Salin buffer 0 indikator (closed only, series-order) ke dst[]. */
   bool                RefreshIndicator(const int handle,const int bars,double &dst[])
     {
      ArraySetAsSeries(dst,true);
      int n=CopyBuffer(handle,0,1,bars,dst);
      return(n>0);
     }

public:
                     CDataService(void) : m_hAtr(INVALID_HANDLE),
                                          m_lastExecBar(0), m_htfBar(0) {}
                    ~CDataService(void) { }

   //+---------------------------------------------------------------+
   //| Init: siap pakai symbol info + buat handle indikator (seumur    |
   //| OnInit). [in] cfg settings tersnapshot.                          |
   //| Return false → EA wajib INIT_FAILED (handle indikator wajib).   |
   //+---------------------------------------------------------------+
   bool              Init(const SHunterSettings &cfg)
     {
      m_cfg=cfg;
      if(!m_sym.Initialize(_Symbol))
        {
         PrintFormat("%s | DataService: simbol %s gagal di-inisialisasi",HUNT_NAME,_Symbol);
         return(false);
        }
      m_hAtr=iATR(_Symbol,PERIOD_CURRENT,m_cfg.atrPeriod);
      m_hRsi=iRSI(_Symbol,PERIOD_CURRENT,m_cfg.obosPeriod,PRICE_CLOSE);
      if(m_hAtr==INVALID_HANDLE || m_hRsi==INVALID_HANDLE)
        {
         PrintFormat("%s | DataService: gagal buat handle indikator (err=%d)",
                     HUNT_NAME,GetLastError());
         return(false);
        }
      if(!m_sym.RefreshRates())
         return(false);
      //--- warm-up awal (di tester bar historis tersedia langsung)
      RefreshExecRates(600);
      RefreshHtfRates(150);
      RefreshIndicator(m_hAtr,ArraySize(m_rate),m_atr);
      RefreshIndicator(m_hRsi,ArraySize(m_rate),m_rsi);
      m_lastExecBar=iTime(_Symbol,_Period,0);
      return(true);
     }
   /** Release handle indikator — panggil di OnDeinit. */
   void              Release(void)
     {
      if(m_hAtr!=INVALID_HANDLE)
        {
         IndicatorRelease(m_hAtr);
         m_hAtr=INVALID_HANDLE;
        }
      if(m_hRsi!=INVALID_HANDLE)
        {
         IndicatorRelease(m_hRsi);
         m_hRsi=INVALID_HANDLE;
        }
     }

   //+---------------------------------------------------------------+
   //| Deteksi bar closed baru; bila ya → refresh cache bar+indikator+  |
   //| HTF (HTF hanya bila bar HTF-nya juga baru). Gate utk SELURUH     |
   //| pipeline sinyal. Return true bila bar baru terjadi.              |
   //+---------------------------------------------------------------+
   bool              UpdateOnBar(const int lookbackExec,const int lookbackHtf)
     {
      datetime t0=iTime(_Symbol,_Period,0);
      if(t0==0 || t0==m_lastExecBar)
         return(false);
      m_lastExecBar=t0;
      RefreshExecRates(lookbackExec);
      RefreshIndicator(m_hAtr,ArraySize(m_rate),m_atr);
      RefreshIndicator(m_hRsi,ArraySize(m_rate),m_rsi);
      datetime th=iTime(_Symbol,m_cfg.htf,0);
      if(th!=0 && th!=m_htfBar)
        {
         m_htfBar=th;
         RefreshHtfRates(lookbackHtf);
        }
      return(true);
     }
   /** Refresh Bid/Ask/spread saja — murah, aman tiap tick. */
   bool              RefreshQuotes(void)
     {
      return(m_sym.RefreshRates());
     }

   //--- akses bar (closed only) ------------------------------------------
   bool              GetClosedBar(const int back,MqlRates &dst) const
     {
      int n=ArraySize(m_rate);
      if(back<0 || back>=n)
         return(false);
      dst=m_rate[back];
      return(true);
     }
   bool              GetClose(const int back,double &dst) const
     {
      int n=ArraySize(m_rate);
      if(back<0 || back>=n)
         return(false);
      dst=m_rate[back].close;
      return(true);
     }
   bool              GetOpen(const int back,double &dst) const
     {
      int n=ArraySize(m_rate);
      if(back<0 || back>=n)
         return(false);
      dst=m_rate[back].open;
      return(true);
     }
   bool              GetHigh(const int back,double &dst) const
     {
      int n=ArraySize(m_rate);
      if(back<0 || back>=n)
         return(false);
      dst=m_rate[back].high;
      return(true);
     }
   bool              GetLow(const int back,double &dst) const
     {
      int n=ArraySize(m_rate);
      if(back<0 || back>=n)
         return(false);
      dst=m_rate[back].low;
      return(true);
     }
   int               ClosedBars(void) const   { return(ArraySize(m_rate)); }
   bool              HasBars(const int need) const { return(ArraySize(m_rate)>=need); }

   //--- akses HTF -----------------------------------------------------------
   bool              GetHtfBar(const int back,MqlRates &dst) const
     {
      int n=ArraySize(m_htf);
      if(back<0 || back>=n)
         return(false);
      dst=m_htf[back];
      return(true);
     }
   int               HtfClosedBars(void) const { return(ArraySize(m_htf)); }

   //--- indikator (handle+CopyBuffer; closed bar) -------------------------
   double            Atr(const int back) const
     {
      if(back<0 || back>=ArraySize(m_atr))
         return(0.0);
      return(m_atr[back]);
     }
   double            Rsi(const int back) const
     {
      if(back<0 || back>=ArraySize(m_rsi))
         return(DBL_MAX);
      return(m_rsi[back]);
     }

   //--- quotes & simbol -------------------------------------------------------
   //--- getter memakai fungsi global Symbol*Info — const-safe utk semua
   double            Bid(void) const        { return(SymbolInfoDouble(_Symbol,SYMBOL_BID)); }
   double            Ask(void) const        { return(SymbolInfoDouble(_Symbol,SYMBOL_ASK)); }
   double            SpreadPips(void) const
     {
      if(m_cfg.pipSize<=0.0)
         return(0.0);
      double pts=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
      return(pts*m_cfg.point/m_cfg.pipSize);
     }
   double            PipSize(void) const    { return(m_cfg.pipSize); }
   double            Point(void) const      { return(m_cfg.point); }
   int               Digits(void) const     { return(m_cfg.digits); }
   ENUM_TIMEFRAMES   Htf(void) const        { return(m_cfg.htf); }
   double            TickValue(void) const  { return(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE)); }
   double            TickSize(void) const   { return(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE)); }
   double            VolumeMin(void) const  { return(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)); }
   double            VolumeMax(void) const  { return(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX)); }
   double            VolumeStep(void) const { return(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)); }

   /** Normalisasi volume ke step + clamp min/max. 0 → tak layak. */
   double            NormalizeVolume(double vol) const
     {
      double step=VolumeStep();
      if(step<=0.0)
         return(0.0);
      vol=MathFloor(vol/step+0.5)*step;
      if(vol<VolumeMin())
         vol=VolumeMin();
      if(vol>VolumeMax())
         vol=VolumeMax();
      if(vol<VolumeMin())
         return(0.0);
      return(vol);
     }
   /** Normalisasi harga ke digits simbol. */
   double            NormalizePrice(double price) const
     {
      return(NormalizeDouble(price,m_cfg.digits));
     }

   //--- waktu ------------------------------------------------------------------
   bool              NewBarArrived(void) const
     {
      datetime t0=iTime(_Symbol,_Period,0);
      return(t0!=0 && t0!=m_lastExecBar);
     }
   datetime          CurrentBarTime(void) const { return(m_lastExecBar); }

   /** Bar closed D1 terakhir (untuk pivot) — dipanggil awal hari saja. */
   bool              GetPrevDailyBar(MqlRates &dst) const
     {
      MqlRates d1[];
      ArraySetAsSeries(d1,true);
      if(CopyRates(_Symbol,PERIOD_D1,1,1,d1)<=0)
         return(false);
      dst=d1[0];
      return(true);
     }
  };

#endif // ORB_SMC_HUNTER_DATASERVICE_MQH
//+------------------------------------------------------------------+
