//+------------------------------------------------------------------+
//|                                                    SMCEngine.mqh |
//| Smart Money Concepts — SEMUA kalkulasi pada CLOSED bar:            |
//|  - Swing high/low: fractal dengan lookback KIRI=KANAN; sebuah swing |
//|    baru dianggap setelah `swingLookback` bar menutup di kanannya →   |
//|    tanpa lookahead bias;                                            |
//|  - Liquidity pool: klaster swing sisi-sama dalam toleransi pips,    |
//|    touches>=2 = equal highs/lows; swept saat wick menembus level      |
//|    (break-close juga dianggap likuiditas terambil);                  |
//|  - Struktur: label HH/HL/LH/LL + event BOS/CHoCH per swing patah;   |
//|  - Bias HTF: derive-once + LOCK; flip hanya via CHoCH (lihat       |
//|    UpdateHtfBias) — bukan recalc tiap bar;                            |
//|  - Zona: OB (candle berlawanan terakhir sebelum displacement ≥       |
//|    obDisplacementAtr×ATR pasca break) + FVG (gap 3-candle) disatukan  |
//|    dalam SZone — satu jalur retest/mitigasi/expiry.                   |
//| Semantik zona: TOUCH → MITIGATED (OB) / MITIGATED; close melewati    |
//| tepi jauh (bull: <bottom, bear: >top) → INVALID; FVG juga INVALID      |
//| saat extreme menyentuh tepi jauh (= "fully filled"). usedForEntry      |
//| persist antar-rebuild via memo createdTime (sekali pakai per setup).   |
//| Model: REBUILD-WHOLESAL tiap bar closed — deterministik, idempoten,   |
//| tanpa state terakumulasi (murah: ≤400 bar × koleksi kecil).            |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_SMCENGINE_MQH
#define ORB_SMC_HUNTER_SMCENGINE_MQH

#include "DataService.mqh"

#define HUNT_SCAN_BARS     400      // kedalaman rebuild utk exec TF
#define HUNT_OB_SCAN_BACK  12       // maks candle mundur utk cari OB
#define HUNT_USED_MEMO     16
#define HUNT_BREAKER_TMP   24      // seed breaker maks per rebuild

class CSMCEngine
  {
private:
   SHunterSettings     m_cfg;
   datetime            m_fromTime;      // batas kiri jendela (hari ini)
   SSwingPoint         m_swings[HUNT_MAX_SWINGS];
   int                 m_swingCount;
   SLiquidityPool      m_pools[HUNT_MAX_POOLS];
   int                 m_poolCount;
   SStructureEvent     m_struct[HUNT_MAX_STRUCT];
   int                 m_structCount;
   SZone               m_zones[HUNT_MAX_ZONES];
   int                 m_zoneCount;
   ulong               m_zoneSeq;
   ENUM_HUNT_BIAS      m_biasHtf;
   datetime            m_biasHtfTime;
   //--- CHoCH-driven bias lock (spesifikasi HTF BIAS REVERSAL)
   bool                m_biasPrimed;    // bias awal sudah diturunkan
   double              m_chRefPrice;    // ref HL (bias bull) / LH (bias bear)
   datetime            m_chRefTime;
   int                 m_htfBarsSeen;   // jumlah bar HTF closed terakhir
   SChochEvent         m_chEv;
   bool                m_chEvReady;
   datetime            m_usedTimes[HUNT_USED_MEMO];   // persist antar-rebuild
   int                 m_usedCount;
   datetime            m_minorSweptT[2];        // v1.07 inducement: [0]=low [1]=high

   //=== helper --------------------------------------------------------
   void                ClearCollections(void)
     {
      m_swingCount=0;
      m_poolCount=0;
      m_structCount=0;
      m_zoneCount=0;
     }
   bool                IsSwingHigh(const CDataService &data,const int back) const
     {
      int L=m_cfg.swingLookback;
      double h;
      if(back<L || !data.GetHigh(back,h))
         return(false);
      for(int k=1;k<=L;k++)
        {
         double o;
         if(!data.GetHigh(back+k,o) || !data.GetHigh(back-k,o))
            return(false);
         if(o>=h)
            return(false);
        }
      return(true);
     }
   bool                IsSwingLow(const CDataService &data,const int back) const
     {
      int L=m_cfg.swingLookback;
      double lo;
      if(back<L || !data.GetLow(back,lo))
         return(false);
      for(int k=1;k<=L;k++)
        {
         double o;
         if(!data.GetLow(back+k,o) || !data.GetLow(back-k,o))
            return(false);
         if(o<=lo)
            return(false);
        }
      return(true);
     }
   bool                IsZoneUsedMemo(const datetime t) const
     {
      for(int i=0;i<m_usedCount;i++)
         if(m_usedTimes[i]==t)
            return(true);
      return(false);
     }
   void                AddZoneUnique(const ENUM_HUNT_ZONE_TYPE type,const double p1,
                                     const double p2,const datetime created)
     {
      for(int i=0;i<m_zoneCount;i++)
         if(m_zones[i].type==type && m_zones[i].createdTime==created)
            return;
      if(m_zoneCount>=HUNT_MAX_ZONES)
         return;
      SZone z;
      z.id=m_zoneSeq++;
      z.type=type;
      z.top=MathMax(p1,p2);
      z.bottom=MathMin(p1,p2);
      z.createdTime=created;
      z.extendTime=created;
      z.state=(IsZoneUsedMemo(created) ? HUNT_ZONE_INVALID : HUNT_ZONE_ACTIVE);
      z.retestCount=0;
      z.lastTouchTime=0;
      z.usedForEntry=IsZoneUsedMemo(created);
      m_zones[m_zoneCount++]=z;
     }
   bool                ZoneDirMatches(const SZone &z,const ENUM_HUNT_DIR dir) const
     {
      if(dir==HUNT_DIR_BUY)
         return(z.type==HUNT_ZONE_OB_BULL || z.type==HUNT_ZONE_FVG_BULL ||
                z.type==HUNT_ZONE_BREAKER_BULL);
      return(z.type==HUNT_ZONE_OB_BEAR || z.type==HUNT_ZONE_FVG_BEAR ||
             z.type==HUNT_ZONE_BREAKER_BEAR);
     }
   bool                ZoneIsBull(const SZone &z) const
     {
      return(z.type==HUNT_ZONE_OB_BULL || z.type==HUNT_ZONE_FVG_BULL ||
              z.type==HUNT_ZONE_BREAKER_BULL);
     }
   bool                ZoneIsFvg(const SZone &z) const
     {
      return(z.type==HUNT_ZONE_FVG_BULL || z.type==HUNT_ZONE_FVG_BEAR);
     }

   //=== builder per-lapisan --------------------------------------------
   void                BuildSwings(const CDataService &data)
     {
      int n=MathMin(data.ClosedBars(),HUNT_SCAN_BARS);
      int L=m_cfg.swingLookback;
      for(int b=n-1;b>=L;b--)                    // kronologis: tua→baru
        {
         MqlRates br;
         if(!data.GetClosedBar(b,br))
            continue;
         if(br.time<m_fromTime)
            continue;
         bool isH=IsSwingHigh(data,b);
         bool isL=(!isH && IsSwingLow(data,b));
         if(!isH && !isL)
            continue;
         if(m_swingCount>=HUNT_MAX_SWINGS)
            break;
         SSwingPoint s;
         s.time=br.time;
         s.price=(isH ? br.high : br.low);
         s.type=(isH ? HUNT_DIR_BUY : HUNT_DIR_SELL);   // sisi yg dipatahkan
         s.label=HUNT_SWING_UNKNOWN;
         s.confirmed=true;                              // by construction
         m_swings[m_swingCount++]=s;
        }
     }
   void                BuildStructure(const CDataService &data)
     {
      double lastHigh=0.0,lastLow=0.0;
      bool haveH=false,haveL=false;
      for(int i=0;i<m_swingCount;i++)
        {
         if(m_swings[i].type==HUNT_DIR_BUY)
           {
            m_swings[i].label=(!haveH ? HUNT_SWING_HH :
                               (m_swings[i].price>lastHigh ? HUNT_SWING_HH : HUNT_SWING_LH));
            lastHigh=m_swings[i].price;
            haveH=true;
           }
         else
           {
            m_swings[i].label=(!haveL ? HUNT_SWING_HL :
                               (m_swings[i].price>lastLow ? HUNT_SWING_HL : HUNT_SWING_LL));
            lastLow=m_swings[i].price;
            haveL=true;
           }
        }
      //--- BOS/CHoCH: close pertama (kronologis) yg melewati swing, sebelum
      //--- swing berikutnya terkonfirmasi
      ENUM_HUNT_DIR lastDir=HUNT_DIR_NONE;
      for(int i=0;i<m_swingCount;i++)
        {
         SSwingPoint sp=m_swings[i];
         datetime nextT=(i+1<m_swingCount ? m_swings[i+1].time : 0);
         int n=data.ClosedBars();
         for(int b=n-1;b>=0;b--)                // tua→baru
           {
            MqlRates br;
            if(!data.GetClosedBar(b,br))
               break;
            if(br.time<=sp.time || br.time<m_fromTime)
               continue;
            if(nextT>0 && br.time>=nextT)
               break;
            bool brokeUp=(sp.type==HUNT_DIR_BUY && br.close>sp.price);
            bool brokeDn=(sp.type==HUNT_DIR_SELL && br.close<sp.price);
            if(!brokeUp && !brokeDn)
               continue;
            if(m_structCount>=HUNT_MAX_STRUCT)
               break;
            SStructureEvent ev;
            ev.dir=(brokeUp ? HUNT_DIR_BUY : HUNT_DIR_SELL);
            ev.price=sp.price;
            ev.time=br.time;
            ev.kind=(lastDir!=HUNT_DIR_NONE && ev.dir!=lastDir ?
                     HUNT_STRUCT_CHOCH : HUNT_STRUCT_BOS);
            ev.chartIndex=0;
            m_struct[m_structCount++]=ev;
            lastDir=ev.dir;
            break;                              // sekali per swing
           }
        }
     }
   void                BuildPools(const CDataService &data)
     {
      double tol=m_cfg.liqTolPips*data.PipSize();
      double atr0=data.Atr(0);
      if(atr0>0.0 && tol<0.10*atr0)
         tol=0.10*atr0;                          // floor non-FX (BTC/ETH/IDX)
      for(int i=0;i<m_swingCount;i++)
        {
         double lv0=m_swings[i].price;            // anchor klaster (kanonik)
         double lv=lv0,sum=lv0;
         int cnt=1;
         datetime t0=m_swings[i].time,t1=m_swings[i].time;
         int j=i+1;
         for(;j<m_swingCount;j++)
           {
            if(m_swings[j].type!=m_swings[i].type)
               break;
            if(MathAbs(m_swings[j].price-lv0)>tol)  // semua dlm tol ke ANCHOR
               break;
            sum+=m_swings[j].price;
            cnt++;
            lv=sum/cnt;                             // level pool = mean
            t1=m_swings[j].time;
           }
         if(cnt>=2)
           {
            if(m_poolCount<HUNT_MAX_POOLS)
              {
               SLiquidityPool p;
               p.level=lv;
               p.touches=cnt;
               p.firstTime=t0;
               p.lastTouchTime=t1;
               p.abovePrice=(m_swings[i].type==HUNT_DIR_BUY);
               p.swept=false;
               p.sweptTime=0;
               p.sweptExtreme=0.0;
               int n=data.ClosedBars();
               for(int b=n-1;b>=0;b--)          // tua→baru; sweep pertama menang
                 {
                  MqlRates br;
                  if(!data.GetClosedBar(b,br))
                     break;
                  if(br.time<=t1)
                     continue;
                  if(p.abovePrice && br.high>p.level)
                    {
                     p.swept=true;
                     p.sweptTime=br.time;
                     p.sweptExtreme=br.high;
                     break;
                    }
                  if(!p.abovePrice && br.low<p.level)
                    {
                     p.swept=true;
                     p.sweptTime=br.time;
                     p.sweptExtreme=br.low;
                     break;
                    }
                 }
               m_pools[m_poolCount++]=p;
              }
           }
         i=j-1;                                  // lanjut dr luar klaster
        }
     }
   /** v1.07 (inducement): sweep TERAKHIR tiap minor swing (satu-sentuhan) sisi
       low/high dalam jendela rebuild — SATU pass, deterministik, closed-bar. */
   void                BuildInducement(const CDataService &data)
     {
      m_minorSweptT[0]=0;
      m_minorSweptT[1]=0;
      if(!m_cfg.requireInducement)
         return;
      int n=MathMin(data.ClosedBars(),HUNT_SCAN_BARS);
      int swN=m_swingCount;
      for(int b=n-1;b>=0;b--)                     // tua→baru
        {
         MqlRates br;
         if(!data.GetClosedBar(b,br))
            break;
         if(br.time<m_fromTime)
            continue;
         for(int i=0;i<swN;i++)
           {
            if(br.time<=m_swings[i].time)
               continue;
            if(m_swings[i].type==HUNT_DIR_SELL)
              {
               if(br.low<m_swings[i].price)
                  m_minorSweptT[0]=br.time;        // minor low tersapu
              }
            else if(br.high>m_swings[i].price)
               m_minorSweptT[1]=br.time;           // minor high tersapu
          }
        }
     }
   void                BuildOrderBlocks(const CDataService &data)
     {
      if(m_structCount==0)
         return;
      for(int e=0;e<m_structCount;e++)
        {
         SStructureEvent ev=m_struct[e];
         if(ev.time<m_fromTime)
            continue;
         int shift=iBarShift(_Symbol,_Period,ev.time,true);
         if(shift<1)
            continue;
         int b0=shift-1;                         // index closed-bar cache
         double atr=data.Atr(b0>0 ? b0-1 : 0);
         if(atr<=0.0)
            atr=10.0*data.Point();
         for(int k=0;k<=HUNT_OB_SCAN_BACK;k++)
           {
            int b=b0+k;
            MqlRates br,brk;
            if(!data.GetClosedBar(b,br) || !data.GetClosedBar(b0,brk))
               break;
            if(br.time<m_fromTime)
               break;
            if(ev.dir==HUNT_DIR_BUY && br.close<br.open)
              {
               double disp=brk.close-MathMax(br.open,br.close);
               if(disp>=m_cfg.obDisplacementAtr*atr)
                  AddZoneUnique(HUNT_ZONE_OB_BULL,br.high,br.low,br.time);
               break;
              }
            if(ev.dir==HUNT_DIR_SELL && br.close>br.open)
              {
               double disp=MathMin(br.open,br.close)-brk.close;
               if(disp>=m_cfg.obDisplacementAtr*atr)
                  AddZoneUnique(HUNT_ZONE_OB_BEAR,br.high,br.low,br.time);
               break;
              }
           }
        }
     }
   void                BuildFvgs(const CDataService &data)
     {
      if(!m_cfg.useFvgAsZone)
         return;
      int n=MathMin(data.ClosedBars()-2,HUNT_SCAN_BARS-2);
      for(int b=n-1;b>=1;b--)                    // kronologis
        {
         MqlRates r0,r1,r2;                       // r0 terbaru dr tripel ini
         if(!data.GetClosedBar(b-1,r0) || !data.GetClosedBar(b,r1) || !data.GetClosedBar(b+1,r2))
            continue;
         if(r1.time<m_fromTime)
            continue;
         if(r0.low>r2.high)                       // bullish gap
            AddZoneUnique(HUNT_ZONE_FVG_BULL,r0.low,r2.high,r1.time);
         else if(r0.high<r2.low)                  // bearish gap
            AddZoneUnique(HUNT_ZONE_FVG_BEAR,r2.low,r0.high,r1.time);
        }
     }
   void                UpdateZonesVsBars(const CDataService &data)
     {
      int n=MathMin(data.ClosedBars(),HUNT_SCAN_BARS);
      ENUM_HUNT_ZONE_TYPE brkT[HUNT_BREAKER_TMP];    // v1.07 seed breaker
      double            brkTop[HUNT_BREAKER_TMP],brkBot[HUNT_BREAKER_TMP];
      datetime          brkTime[HUNT_BREAKER_TMP];
      for(int z=0;z<m_zoneCount;z++)
        {
         SZone zn=m_zones[z];
         zn.state=HUNT_ZONE_ACTIVE;
         zn.retestCount=0;
         zn.lastTouchTime=0;
         zn.extendTime=zn.createdTime;
         bool bull=ZoneIsBull(zn);
         bool fvg=ZoneIsFvg(zn);
         bool isBrk=(zn.type==HUNT_ZONE_BREAKER_BULL||zn.type==HUNT_ZONE_BREAKER_BEAR);
         int  brkCnt=0;
         for(int b=n-1;b>=0;b--)                  // kronologis → state akhir
           {
            MqlRates br;
            if(!data.GetClosedBar(b,br))
               break;
            if(br.time<=zn.createdTime)
               continue;
            if(br.high<zn.bottom || br.low>zn.top)
               continue;                          // no touch
            zn.retestCount++;
            zn.lastTouchTime=br.time;
            zn.extendTime=br.time;
            bool farCross=(bull ? br.close<zn.bottom : br.close>zn.top);
            bool fvgFilled=(fvg && (bull ? br.low<=zn.bottom : br.high>=zn.top));
            if(farCross || fvgFilled)
               zn.state=HUNT_ZONE_INVALID;
            else
               zn.state=HUNT_ZONE_MITIGATED;
            if(farCross && m_cfg.useBreakers && !fvg && !isBrk &&
               brkCnt<HUNT_BREAKER_TMP)           // v1.07: OB patah → breaker
              {
               brkT[brkCnt]=(bull ? HUNT_ZONE_BREAKER_BEAR : HUNT_ZONE_BREAKER_BULL);
               brkTop[brkCnt]=zn.top;
               brkBot[brkCnt]=zn.bottom;
               brkTime[brkCnt]=br.time;            // createdTime = bar pematah
               brkCnt++;
              }
            if(zn.state==HUNT_ZONE_INVALID)
               break;                             // tak bisa hidup lagi
           }
         for(int q=0;q<brkCnt;q++)
            AddZoneUnique(brkT[q],brkTop[q],brkBot[q],brkTime[q]);
         if(zn.extendTime==zn.createdTime)
            zn.extendTime=data.CurrentBarTime();
         if(zn.usedForEntry)
            zn.state=HUNT_ZONE_INVALID;
         m_zones[z]=zn;
        }
     }
   //--- HTF bias: turunkan sekali, lalu kunci; flip HANYA via CHoCH HTF ------
   /** Derivasi awal (retry per bar HTF s/d berhasil): arah break struktur
       TERAKHIR pada cache HTF. Setelah primed, bias tidak dihitung ulang —
       hanya berubah saat CheckHtfChoch mengonfirmasi pembalikan. */
   void                DeriveInitialBias(const CDataService &data)
     {
      int nh=data.HtfClosedBars();
      int L=2;
      ENUM_HUNT_DIR lastDir=HUNT_DIR_NONE;
      datetime lastT=0;
      for(int b=nh-1;b>=L;b--)                    // kronologis (tua→baru)
        {
         MqlRates c;
         if(!data.GetHtfBar(b,c))
            break;
         bool hi=true,lo=true;
         for(int k=1;k<=L && (hi || lo);k++)
           {
            MqlRates a,z;
            if(!data.GetHtfBar(b+k,a) || !data.GetHtfBar(b-k,z))
              { hi=false; lo=false; break; }
            if(a.high>=c.high || z.high>=c.high) hi=false;
            if(a.low<=c.low   || z.low<=c.low)   lo=false;
           }
         if(!hi && !lo)
            continue;
         for(int s2=b-1;s2>=0;s2--)               // break pertama setelahnya
           {
            MqlRates x;
            if(!data.GetHtfBar(s2,x))
               break;
            if(x.time<=c.time)
               continue;
            if(hi && x.close>c.high)
              { lastDir=HUNT_DIR_BUY;  lastT=x.time; break; }
            if(lo && x.close<c.low)
              { lastDir=HUNT_DIR_SELL; lastT=x.time; break; }
           }
        }
      if(lastDir==HUNT_DIR_NONE)
         return;                                  // belum ada struktur → coba lg
      m_biasHtf=(lastDir==HUNT_DIR_BUY ? HUNT_BIAS_BULLISH : HUNT_BIAS_BEARISH);
      m_biasHtfTime=lastT;
      m_biasPrimed=true;
      RefreshChochRef(data);
     }
   int                 ChochLookback(void) const
     {
      int L=(m_cfg.chochLookback>0 ? m_cfg.chochLookback : m_cfg.swingLookback);
      return(MathMax(1,L));
     }
   /** Fractal confirmed pada index b (order siri: 0 = terbaru). */
   bool                IsHtfSwing(const CDataService &data,const int b,const int L,
                                  const bool high) const
     {
      MqlRates c;
      if(!data.GetHtfBar(b,c))
         return(false);
      for(int k=1;k<=L;k++)
        {
         MqlRates a,z;
         if(!data.GetHtfBar(b+k,a) || !data.GetHtfBar(b-k,z))
            return(false);
         if(high ? (a.high>=c.high || z.high>=c.high)
                 : (a.low<=c.low   || z.low<=c.low))
            return(false);
        }
      return(true);
     }
   /** Swing low TEAKHIR yang lebih tinggi dari swing low sebelumnya (HL). */
   bool                FindLastReversalLow(const CDataService &data,const int L,
                                            double &price,datetime &time) const
     {
      int nh=data.HtfClosedBars();
      bool havePrev=false;
      double prev=0.0;
      price=0.0; time=0;
      for(int b=nh-1-L;b>=L;b--)                  // tua→baru; hasil = HL terbaru
        {
         if(!IsHtfSwing(data,b,L,false))
            continue;
         MqlRates c;
         if(!data.GetHtfBar(b,c))
            break;
         if(havePrev && c.low>prev)
           { price=c.low; time=c.time; }
         prev=c.low; havePrev=true;
        }
      return(price>0.0);
     }
   /** Swing high TERAKHIR yang lebih rendah dari swing high sebelumnya (LH). */
   bool                FindLastReversalHigh(const CDataService &data,const int L,
                                             double &price,datetime &time) const
     {
      int nh=data.HtfClosedBars();
      bool havePrev=false;
      double prev=0.0;
      price=0.0; time=0;
      for(int b=nh-1-L;b>=L;b--)
        {
         if(!IsHtfSwing(data,b,L,true))
            continue;
         MqlRates c;
         if(!data.GetHtfBar(b,c))
            break;
         if(havePrev && c.high<prev)
           { price=c.high; time=c.time; }
         prev=c.high; havePrev=true;
        }
      return(price>0.0);
     }
   /** Sinkronkan level referensi CHoCH berikutnya dg struktur terkini. */
   void                RefreshChochRef(const CDataService &data)
     {
      int L=ChochLookback();
      double p=0.0;
      datetime t=0;
      bool ok=(m_biasHtf==HUNT_BIAS_BULLISH ? FindLastReversalLow(data,L,p,t)
               :(m_biasHtf==HUNT_BIAS_BEARISH ? FindLastReversalHigh(data,L,p,t)
                 : false));
      if(ok)
        { m_chRefPrice=p; m_chRefTime=t; }
      else
        { m_chRefPrice=0.0; m_chRefTime=0; }
     }
   /** SATU kali per HTF bar baru: update/ref/CHoCH. Closed bar saja. */
   void                UpdateHtfBias(const CDataService &data)
     {
      int nh=data.HtfClosedBars();
      if(nh<6)
         return;
      if(!m_biasPrimed)
        {
         DeriveInitialBias(data);
         m_htfBarsSeen=nh;
         return;
        }
      if(nh==m_htfBarsSeen)
         return;                                   // tanpa bar HTF baru: dicek
      m_htfBarsSeen=nh;
      MqlRates c0;
      if(!data.GetHtfBar(0,c0))
         return;
      int L=ChochLookback();
      if(m_biasHtf==HUNT_BIAS_BULLISH)
        {
         double hl=0.0;
         datetime ht=0;
         if(FindLastReversalLow(data,L,hl,ht))
           {
            if(m_chRefPrice>0.0 && c0.close<m_chRefPrice)
               FireHtfChoch(data,c0.time,m_chRefPrice,HUNT_DIR_BUY,HUNT_DIR_SELL);
            else if(hl>m_chRefPrice || m_chRefPrice<=0.0)
              { m_chRefPrice=hl; m_chRefTime=ht; }   // HL baru → ref naik
           }
        }
      else if(m_biasHtf==HUNT_BIAS_BEARISH)
        {
         double lh=0.0;
         datetime ht=0;
         if(FindLastReversalHigh(data,L,lh,ht))
           {
            if(m_chRefPrice>0.0 && c0.close>m_chRefPrice)
               FireHtfChoch(data,c0.time,m_chRefPrice,HUNT_DIR_SELL,HUNT_DIR_BUY);
            else if(lh<m_chRefPrice || m_chRefPrice<=0.0)
              { m_chRefPrice=lh; m_chRefTime=ht; }   // LH baru → ref turun
           }
        }
     }
   void                FireHtfChoch(const CDataService &data,const datetime t,
                                    const double lvl,const ENUM_HUNT_DIR from,
                                    const ENUM_HUNT_DIR to)
     {
      m_biasHtf=(to==HUNT_DIR_BUY ? HUNT_BIAS_BULLISH : HUNT_BIAS_BEARISH);
      m_biasHtfTime=t;
      m_chEv.time=t; m_chEv.price=lvl;
      m_chEv.fromDir=from; m_chEv.toDir=to;
      m_chEvReady=true;
      RefreshChochRef(data);
     }

public:
                     CSMCEngine(void) : m_fromTime(0), m_swingCount(0), m_poolCount(0),
                                        m_structCount(0), m_zoneCount(0), m_zoneSeq(1),
                                        m_biasHtf(HUNT_BIAS_NONE), m_biasHtfTime(0),
                                        m_biasPrimed(false), m_chRefPrice(0.0), m_chRefTime(0),
                                        m_htfBarsSeen(0), m_chEvReady(false),
                                        m_usedCount(0) {}

   bool              Init(const SHunterSettings &cfg,const datetime windowFrom)
     {
      m_cfg=cfg;
      m_fromTime=windowFrom;
      ClearCollections();
      m_minorSweptT[0]=0;
      m_minorSweptT[1]=0;
      return(true);
     }

   /** Pipeline utama — SATU kali per bar closed (rebuild deterministik). */
   void              Update(const CDataService &data)
     {
      ClearCollections();
      BuildSwings(data);
      BuildStructure(data);
      BuildPools(data);
      BuildInducement(data);
      BuildOrderBlocks(data);
      BuildFvgs(data);
      UpdateZonesVsBars(data);
      UpdateHtfBias(data);
     }

   //--- query utk validator/renderer --------------------------------------
   ENUM_HUNT_BIAS    HtfBias(void) const      { return(m_biasHtf); }
   /** Ambil event CHoCH HTF tertunda (main: cancel setup + alert + marker). */
   bool              TakeHtfChoch(SChochEvent &ev)
     {
      if(!m_chEvReady)
         return(false);
      m_chEvReady=false;
      ev=m_chEv;
      m_chEv.Reset();
      return(true);
     }
   /** Level referensi CHoCH aktif (HL utk bull / LH utk bear; 0 = belum ada). */
   double            ChochRefPrice(void) const  { return(m_chRefPrice); }
   datetime          HtfBiasTime(void) const  { return(m_biasHtfTime); }
   string            HtfBiasText(void) const
     {
      switch(m_biasHtf)
        {
         case HUNT_BIAS_BULLISH: return("Bullish");
         case HUNT_BIAS_BEARISH: return("Bearish");
        }
      return("None");
     }
   /** Pool SEARAH breakout sudah di-sweep sejak `since`? */
   bool              IsLiquiditySwept(const ENUM_HUNT_DIR dir,const datetime since) const
     {
      for(int i=0;i<m_poolCount;i++)
         if(m_pools[i].swept && m_pools[i].sweptTime>=since &&
            (m_pools[i].abovePrice==(dir==HUNT_DIR_BUY)))
            return(true);
      return(false);
     }
   datetime          LastSweepTime(const ENUM_HUNT_DIR dir) const
     {
      datetime t=0;
      for(int i=0;i<m_poolCount;i++)
         if(m_pools[i].swept && (m_pools[i].abovePrice==(dir==HUNT_DIR_BUY)) &&
            m_pools[i].sweptTime>t)
            t=m_pools[i].sweptTime;
      return(t);
     }
   /** v1.07: waktu sweep minor-liquidity terakhir (low utk BUY / high utk SELL). */
   datetime          LastMinorSweep(const ENUM_HUNT_DIR dir) const
     {  return(m_minorSweptT[dir==HUNT_DIR_BUY ? 0 : 1]); }
   /** v1.07: level pool BELUM tersapu terdekat searah beyond price; 0 = none. */
   double            NextLiqTarget(const ENUM_HUNT_DIR dir,const double price) const
     {
      double best=0.0;
      bool found=false;
      for(int i=0;i<m_poolCount;i++)
        {
         if(m_pools[i].swept || m_pools[i].level<=0.0)
            continue;
         double lv=m_pools[i].level;
         if(dir==HUNT_DIR_BUY ? (lv<=price) : (lv>=price))
            continue;
         if(!found || (dir==HUNT_DIR_BUY ? lv<best : lv>best))
           { best=lv; found=true; }
        }
      return(found ? best : 0.0);
     }
   bool              HasStructureShift(const ENUM_HUNT_DIR dir,const datetime since) const
     {
      for(int i=0;i<m_structCount;i++)
         if(m_struct[i].dir==dir && m_struct[i].time>=since)
            return(true);
      return(false);
     }
   /** Zona ACTIVE terdekat searah (BUY: di bawah price; SELL: di atas). */
   bool              NearestActiveZone(const ENUM_HUNT_DIR dir,const double price,
                                       const datetime from,SZone &dst) const
     {
      bool found=false;
      double best=-1.0;
      for(int i=0;i<m_zoneCount;i++)
        {
         const SZone z=m_zones[i];
         if(z.state!=HUNT_ZONE_ACTIVE)
            continue;
         if(!ZoneDirMatches(z,dir))
            continue;
         if(z.createdTime<from)
            continue;
         double d=-1.0;
         if(dir==HUNT_DIR_BUY && z.top<price)
            d=price-z.top;
         if(dir==HUNT_DIR_SELL && z.bottom>price)
            d=z.bottom-price;
         if(d<0.0)
            continue;
         if(!found || d<best)
           {
            best=d;
            found=true;
            dst=z;
           }
        }
      return(found);
     }
   /** Level struktural utk SL: tepi terjauh zona (BUY→bottom, SELL→top). */
   double            StructuralSlRef(const SZone &z,const ENUM_HUNT_DIR dir) const
     {
      return(dir==HUNT_DIR_BUY ? z.bottom : z.top);
     }
   void              CopyZones(SZone &dst[]) const
     {
      ArrayResize(dst,m_zoneCount);
      for(int i=0;i<m_zoneCount;i++)
         dst[i]=m_zones[i];
     }
   void              CopySwings(SSwingPoint &dst[]) const
     {
      ArrayResize(dst,m_swingCount);
      for(int i=0;i<m_swingCount;i++)
         dst[i]=m_swings[i];
     }
   void              CopyPools(SLiquidityPool &dst[]) const
     {
      ArrayResize(dst,m_poolCount);
      for(int i=0;i<m_poolCount;i++)
         dst[i]=m_pools[i];
     }
   void              CopyStructure(SStructureEvent &dst[]) const
     {
      ArrayResize(dst,m_structCount);
      for(int i=0;i<m_structCount;i++)
         dst[i]=m_struct[i];
     }
   /** Swing low terkonfirmasi TERTINGGI yang masih di bawah price (BUY
       trail ref). Return true + t/p terisi. */
   bool              LastSwingBelow(const double price,datetime &t,double &p) const
     {
      bool found=false;
      for(int i=0;i<m_swingCount;i++)
        {
         if(m_swings[i].type!=HUNT_DIR_SELL)
            continue;
         if(m_swings[i].price<price && (!found || m_swings[i].price>p))
           {
            found=true;
            p=m_swings[i].price;
            t=m_swings[i].time;
           }
        }
      return(found);
     }
   /** Swing high terkonfirmasi TERENDAH yang masih di atas price (SELL). */
   bool              LastSwingAbove(const double price,datetime &t,double &p) const
     {
      bool found=false;
      for(int i=0;i<m_swingCount;i++)
        {
         if(m_swings[i].type!=HUNT_DIR_BUY)
            continue;
         if(m_swings[i].price>price && (!found || m_swings[i].price<p))
           {
            found=true;
            p=m_swings[i].price;
            t=m_swings[i].time;
           }
        }
      return(found);
     }
   bool              IsZoneActive(const ulong id) const
     {
      for(int i=0;i<m_zoneCount;i++)
         if(m_zones[i].id==id)
            return(m_zones[i].state==HUNT_ZONE_ACTIVE);
      return(false);
     }
   /** v1.06: zona searah dgn level snapshot plan masih HIDUP? Alive =
       ACTIVE atau MITIGATED (tersentuh = mulai retest; INVALID = farCross/
       terisi penuh/terpakai). Match tipe+geometri — rebuild deterministik
       membuat level identik antar-rebuild, sedangkan zone.id BEROTASI. */
   bool              ZoneStillActive(const ENUM_HUNT_DIR dir,const double bottom,
                                     const double top) const
     {
      for(int i=0;i<m_zoneCount;i++)
        {
         const SZone z=m_zones[i];
         if(z.state==HUNT_ZONE_INVALID || !ZoneDirMatches(z,dir))
            continue;
         double tolz=MathMax(1e-9,(MathAbs(top)+MathAbs(bottom))*1e-8);
         if(MathAbs(z.bottom-bottom)<=tolz && MathAbs(z.top-top)<=tolz)
            return(true);
        }
      return(false);
     }
   /** Tandai zona terpakai entry — persist antar-rebuild (memo time). */
   void              MarkZoneUsed(const ulong id)
     {
      for(int i=0;i<m_zoneCount;i++)
        {
         if(m_zones[i].id==id)
           {
            if(m_usedCount<HUNT_USED_MEMO)
               m_usedTimes[m_usedCount++]=m_zones[i].createdTime;
            return;
           }
        }
     }
   void              ResetDaily(const datetime windowFrom)
     {
      m_fromTime=windowFrom;
      ClearCollections();
      m_usedCount=0;
      m_biasHtf=HUNT_BIAS_NONE;
      m_biasHtfTime=0;
      m_biasPrimed=false;
      m_chRefPrice=0.0;
      m_chRefTime=0;
      m_htfBarsSeen=0;
      m_chEv.Reset();
      m_chEvReady=false;
     }
  };

#endif // ORB_SMC_HUNTER_SMCENGINE_MQH
//+------------------------------------------------------------------+
