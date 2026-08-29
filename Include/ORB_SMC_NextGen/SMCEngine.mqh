//+------------------------------------------------------------------+
//| ORB_SMC_NextGen — SMCEngine.mqh                                 |
//| Market structure (BOS/CHoCH), deteksi swing high/low, liquidity  |
//| pools (equal highs/lows), identifikasi order block, deteksi FVG. |
//| SEMUA deteksi berbasis CLOSED BAR (shift >= 1) — tanpa repaint,  |
//| tanpa lookahead bias.                                            |
//|                                                                  |
//| Definisi teknis (keputusan desain):                              |
//|  - Swing   : fractal InpSwingLookback kiri/kanan pada closed bar |
//|  - Pool    : grup swing sejenis dalam toleransi InpLiqTolerancePips |
//|  - Sweep   : wick menembus MELAMPAUI level pool (bukan sekadar   |
//|              menyentuh) — sweep adalah penembusan likuiditas     |
//|  - OB      : candle terakhir berlawanan arah sebelum displacement |
//|              impulsif (close menembus high/low candle sebelumnya |
//|              minimal 10% range candle tsb — filter kualitas)     |
//|  - FVG     : gap 3-candle (hi[1]<lo[3] bullish / lo[1]>hi[3] bear)|
//|  - BOS     : break ekstrem searah bias struktur (HH/LL baru)     |
//|  - CHoCH   : break ekstrem pertama melawan bias (reversal)       |
//|  - Mitigasi OB  : close menembus sisi jauh zona                  |
//|  - Fill FVG     : close menembus tepi jauh gap (fully filled)    |
//| Scan dibatasi SMC_SCAN_BARS terakhir (performa backtest).        |
//| Fase 3: TERIMPLEMENTASI.                                         |
//+------------------------------------------------------------------+
#ifndef ORBSMC_SMC_ENGINE_MQH
#define ORBSMC_SMC_ENGINE_MQH

#include <ORB_SMC_NextGen\Defines.mqh>

#define SMC_SCAN_BARS       3000   // batas scan struktur (closed bars terakhir)
#define HTF_PERIOD          PERIOD_H4   // timeframe bias HTF

//+------------------------------------------------------------------+
//| Swing point (fractal berurutan yang terkonfirmasi di closed bar) |
//+------------------------------------------------------------------+
struct SSwing
  {
   bool            valid;
   ENUM_SWING_TYPE type;        // SWING_HIGH / SWING_LOW
   double          price;       // harga ekstrem swing
   datetime        time;
   int             index;       // shift bar (konteks timeframe eksekusi)
   int             leftBars, rightBars; // konfirmasi kiri/kanan
   bool            swept;       // likuiditasnya sudah di-sweep
  };

//+------------------------------------------------------------------+
//| Liquidity pool — equal highs/lows (resting liquidity)            |
//+------------------------------------------------------------------+
struct SLiqPool
  {
   bool            valid;
   bool            isHigh;      // equal highs (buy-side) / equal lows (sell-side)
   double          level;
   datetime        firstTime;
   int             members;     // jumlah swing yang membentuk pool
   bool            swept;       // sudah tersapu
   datetime        sweptTime;
   double          sweptWick;   // harga ekstrem wick penyapu
  };

//+------------------------------------------------------------------+
//| Order block / FVG (direpresentasikan sebagai zona retest)        |
//+------------------------------------------------------------------+
struct SZone
  {
   bool            valid;
   ENUM_ZONE_TYPE  type;        // ZONE_ORDER_BLOCK / ZONE_FVG
   ENUM_BIAS       direction;   // arah zona (bullish zone = area demand)
   double          top;
   double          bottom;
   datetime        originTime;
   int             originIndex;
   bool            active;      // belum dimitigasi / belum fully filled
   bool            mitigated;   // harga sudah menembus zona
   datetime        mitigateTime;
  };

//+------------------------------------------------------------------+
//| Event struktur (BOS / CHoCH) untuk rendering label chart         |
//+------------------------------------------------------------------+
struct SStructEvent
  {
   ENUM_STRUCT_EVENT type;
   ENUM_BIAS         direction;  // arah break struktur
   double            price;
   datetime          time;
   int               index;
  };

//+------------------------------------------------------------------+
//| CSMCEngine                                                       |
//+------------------------------------------------------------------+
class CSMCEngine
  {
public:
   //--- lifecycle ---
   bool            Init();
   void            OnNewBar();          // rebuild struktur (closed bars)

   //--- market structure ---
   ENUM_BIAS       GetBias();                        // bias struktur TF eksekusi (konteks lokal)
   ENUM_BIAS       GetHTFBias();                     // bias H4 (filter arah breakout)
   bool            DetectStructure(int session, ENUM_BREAK_DIR orbDir); // struktur searah breakout?

   //--- swing & liquidity ---
   int             GetSwingCount();
   const SSwing&   GetSwing(int i);                  // guard index → dummy
   int             GetLiqCount();
   const SLiqPool& GetLiqPool(int i);
   int             GetPoolOpposingBreak(int session, ENUM_BREAK_DIR dir, SLiqPool &out);
                                                      // liquidity pool di arah breakout yang BELUM swept (penolak sinyal)
   bool            SweepOfPoolInDir(ENUM_BREAK_DIR dir, datetime sinceTime, SLiqPool &sweptPool);
                                                      // sudah ada sweep liquidity di arah breakout sejak OR terbentuk?

   //--- order block & FVG ---
   int             GetOBCount();
   const SZone&    GetOB(int i);
   int             GetFVGCount();
   const SZone&    GetFVG(int i);
   bool            GetRetestZone(ENUM_BREAK_DIR dir, SRetestZone &out);
                                                      // zona OB/FVG aktif terbaik di arah breakout (prioritas OB)
   bool            ZoneTouched(const SRetestZone &zone, datetime sinceTime);
                                                      // harga (closed bar) sudah menyentuh zona
   bool            IsReactedAtZone(const SRetestZone &zone, ENUM_BREAK_DIR dir, datetime sinceTime, SRetestZone &confirmed);
                                                      // mode EXECUTION: reaksi = wick rejection / close searah breakout
   double          GetStructStopLevel(ENUM_BREAK_DIR dir, double entryPrice);
                                                      // struktur terdekat untuk penempatan SL (OB bawah / swing / liq level)

   //--- event struktur untuk rendering ---
   int             GetStructEventCount();
   const SStructEvent& GetStructEvent(int i);
   bool            HasRecentSweep(datetime sinceTime, ENUM_BREAK_DIR dir, SLiqPool &pool);
                                                      // sweep terbaru sejak waktu tertentu (dipakai validator + renderer)

private:
   //--- koleksi internal ---
   SSwing          m_swings[MAX_SWINGS];
   int             m_swingCount;
   SLiqPool        m_pools[MAX_LIQ_POOLS];
   int             m_poolCount;
   SZone           m_obs[MAX_ORDER_BLOCKS];
   int             m_obCount;
   SZone           m_fvgs[MAX_FVGS];
   int             m_fvgCount;
   SStructEvent    m_events[MAX_STRUCT_EVENTS];
   int             m_eventCount;
   ENUM_BIAS       m_localBias;      // bias struktur lokal (hasil deteksi terakhir)
   ENUM_BIAS       m_htfBias;        // cache bias H4
   int             m_htfBarCount;    // jumlah bar H4 saat cache dibuat
   bool            m_initOk;

   //--- pipeline internal (closed-bar only) ---
   void            DetectSwings();
   void            BuildLiquidityPools();
   void            DetectOrderBlocks();
   void            DetectFVGs();
   void            DetectStructureEvents();
   void            UpdateMitigations();   // tandai OB/FVG yang termitigasi/terfill
   void            UpdateSweeps();        // tandai pool yang tersapu
   void            AddEvent(ENUM_STRUCT_EVENT type, ENUM_BIAS dir, const SSwing &sw);
   ENUM_BIAS       ComputeHTFBias();      // bias H4 (cached, recompute saat bar H4 baru)
  };

//+------------------------------------------------------------------+
//| Inisialisasi — kosongkan koleksi, bangun cache HTF               |
//+------------------------------------------------------------------+
bool CSMCEngine::Init()
  {
   m_swingCount = 0;
   m_poolCount  = 0;
   m_obCount    = 0;
   m_fvgCount   = 0;
   m_eventCount = 0;
   ZeroMemory(m_swings);
   ZeroMemory(m_pools);
   ZeroMemory(m_obs);
   ZeroMemory(m_fvgs);
   ZeroMemory(m_events);
   m_localBias   = BIAS_NEUTRAL;
   m_htfBias     = BIAS_NEUTRAL;
   m_htfBarCount = Bars(_Symbol, HTF_PERIOD);
   m_initOk      = true;

   // Analisis awal langsung (late-attach EA harus punya konteks segera)
   OnNewBar();
   return m_initOk;
  }
//+------------------------------------------------------------------+
//| Rebuild seluruh analisis struktur saat bar baru (closed bars)    |
//+------------------------------------------------------------------+
void CSMCEngine::OnNewBar()
  {
   if(!m_initOk)
      return;

   DetectSwings();
   BuildLiquidityPools();
   DetectOrderBlocks();
   DetectFVGs();
   DetectStructureEvents();
   UpdateSweeps();
   UpdateMitigations();

   // Bias HTF: recompute hanya saat bar H4 baru (hemat)
   int h4 = Bars(_Symbol, HTF_PERIOD);
   if(h4 != m_htfBarCount)
     {
      m_htfBarCount = h4;
      m_htfBias = ComputeHTFBias();
     }
  }
//+------------------------------------------------------------------+
//| Bias struktur lokal (arah break ekstrem terakhir)                |
//+------------------------------------------------------------------+
ENUM_BIAS CSMCEngine::GetBias()
  {
   return m_localBias;
  }
//+------------------------------------------------------------------+
//| Bias HTF (H4) — cache di-refresh saat bar H4 baru                |
//+------------------------------------------------------------------+
ENUM_BIAS CSMCEngine::GetHTFBias()
  {
   return m_htfBias;
  }
//+------------------------------------------------------------------+
//| Apakah struktur HTF searah arah breakout?                        |
//+------------------------------------------------------------------+
bool CSMCEngine::DetectStructure(int session, ENUM_BREAK_DIR orbDir)
  {
   ENUM_BIAS htf = GetHTFBias();
   if(htf == BIAS_NEUTRAL)
      return true;   // tanpa bias jelas → tidak menghalangi (catat oleh validator)
   if(orbDir == BREAK_UP)
      return (htf == BIAS_BULLISH);
   if(orbDir == BREAK_DOWN)
      return (htf == BIAS_BEARISH);
   return false;
  }
//+------------------------------------------------------------------+
int CSMCEngine::GetSwingCount()
  {
   return m_swingCount;
  }
//+------------------------------------------------------------------+
const SSwing& CSMCEngine::GetSwing(int i)
  {
   static SSwing dummy;
   if(i < 0 || i >= m_swingCount)
      return dummy;
   return m_swings[i];
  }
//+------------------------------------------------------------------+
int CSMCEngine::GetLiqCount()
  {
   return m_poolCount;
  }
//+------------------------------------------------------------------+
const SLiqPool& CSMCEngine::GetLiqPool(int i)
  {
   static SLiqPool dummy;
   if(i < 0 || i >= m_poolCount)
      return dummy;
   return m_pools[i];
  }
//+------------------------------------------------------------------+
//| Pool TERDEKAT di arah breakout yang belum tersapu (opposing      |
//| liquidity = resting orders yang belum diambil) — penolak sinyal. |
//+------------------------------------------------------------------+
int CSMCEngine::GetPoolOpposingBreak(int session, ENUM_BREAK_DIR dir, SLiqPool &out)
  {
   double refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    best     = -1;
   double bestDist = DBL_MAX;
   for(int p = 0; p < m_poolCount; p++)
     {
      const SLiqPool &pool = m_pools[p];
      if(!pool.valid || pool.swept)
         continue;
      bool opposing = (dir == BREAK_UP && pool.isHigh) || (dir == BREAK_DOWN && !pool.isHigh);
      if(!opposing)
         continue;
      double dist = MathAbs(pool.level - refPrice);
      if(dist < bestDist)
        {
         bestDist = dist;
         best     = p;
        }
     }
   if(best >= 0)
      out = m_pools[best];
   return best;
  }
//+------------------------------------------------------------------+
//| Sudah ada pool tersapu (sejak sinceTime) di arah breakout?       |
//| Bullish breakout → buy-side liquidity (equal highs) tersapu.     |
//+------------------------------------------------------------------+
bool CSMCEngine::SweepOfPoolInDir(ENUM_BREAK_DIR dir, datetime sinceTime, SLiqPool &sweptPool)
  {
   for(int p = 0; p < m_poolCount; p++)
     {
      const SLiqPool &pool = m_pools[p];
      if(!pool.valid || !pool.swept || pool.sweptTime < sinceTime)
         continue;
      bool match = (dir == BREAK_UP && pool.isHigh) || (dir == BREAK_DOWN && !pool.isHigh);
      if(match)
        {
         sweptPool = pool;
         return true;
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
int CSMCEngine::GetOBCount()
  {
   return m_obCount;
  }
//+------------------------------------------------------------------+
const SZone& CSMCEngine::GetOB(int i)
  {
   static SZone dummy;
   if(i < 0 || i >= m_obCount)
      return dummy;
   return m_obs[i];
  }
//+------------------------------------------------------------------+
int CSMCEngine::GetFVGCount()
  {
   return m_fvgCount;
  }
//+------------------------------------------------------------------+
const SZone& CSMCEngine::GetFVG(int i)
  {
   static SZone dummy;
   if(i < 0 || i >= m_fvgCount)
      return dummy;
   return m_fvgs[i];
  }
//+------------------------------------------------------------------+
//| Zona retest terbaik di arah breakout:                            |
//|  - OB aktif searah, terdekat, di sisi masuk yang masuk akal      |
//|    SECARA STRUKTUR:                                              |
//|      bullish breakout → OB/FVG berada DI BAWAH harga (retest    |
//|      turun ke zona) → BuyLimit di zone.top (tepi pertama)        |
//|      bearish breakout → OB/FVG berada DI ATAS harga (retest     |
//|      naik ke zona) → SellLimit di zone.bottom (tepi pertama)     |
//|  - fallback FVG bila InpUseFVGAsRetest                          |
//+------------------------------------------------------------------+
bool CSMCEngine::GetRetestZone(ENUM_BREAK_DIR dir, SRetestZone &out)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   ENUM_BIAS want = (dir == BREAK_UP) ? BIAS_BULLISH : BIAS_BEARISH;

   // 1) Order block
   int    bestOB   = -1;
   double bestDist = DBL_MAX;
   for(int k = 0; k < m_obCount; k++)
     {
      const SZone &z = m_obs[k];
      if(!z.active || z.direction != want)
         continue;
      double d = -1.0;
      if(dir == BREAK_UP && bid >= z.top)
         d = bid - z.top;                      // OB/FVG di BAWAH harga — retest turun ke zona
      else if(dir == BREAK_DOWN && ask <= z.bottom)
         d = z.bottom - ask;                   // OB/FVG di ATAS harga — retest naik ke zona
      if(d >= 0.0 && d < bestDist)
        {
         bestDist = d;
         bestOB   = k;
        }
     }
   if(bestOB >= 0)
     {
      const SZone &z = m_obs[bestOB];
      out.type        = ZONE_ORDER_BLOCK;
      out.originTime  = z.originTime;
      out.originIndex = z.originIndex;
      out.top         = z.top;
      out.bottom      = z.bottom;
      out.active      = z.active;
      out.touched     = false;
      out.touchTime   = 0;
      out.entryPrice  = (dir == BREAK_UP) ? z.top : z.bottom;
      return true;
     }

   // 2) Fallback FVG
   if(!InpUseFVGAsRetest)
      return false;
   int bestF = -1;
   bestDist = DBL_MAX;
   for(int k = 0; k < m_fvgCount; k++)
     {
      const SZone &z = m_fvgs[k];
      if(!z.active || z.direction != want)
         continue;
      double d = -1.0;
      if(dir == BREAK_UP && bid >= z.top)
         d = bid - z.top;                      // FVG di BAWAH harga — retest turun ke zona
      else if(dir == BREAK_DOWN && ask <= z.bottom)
         d = z.bottom - ask;                   // FVG di ATAS harga — retest naik ke zona
      if(d >= 0.0 && d < bestDist)
        {
         bestDist = d;
         bestF    = k;
        }
     }
   if(bestF >= 0)
     {
      const SZone &z = m_fvgs[bestF];
      out.type        = ZONE_FVG;
      out.originTime  = z.originTime;
      out.originIndex = z.originIndex;
      out.top         = z.top;
      out.bottom      = z.bottom;
      out.active      = z.active;
      out.touched     = false;
      out.touchTime   = 0;
      out.entryPrice  = (dir == BREAK_UP) ? z.top : z.bottom;
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
//| Zona tersentuh oleh closed bar sejak sinceTime?                  |
//+------------------------------------------------------------------+
bool CSMCEngine::ZoneTouched(const SRetestZone &zone, datetime sinceTime)
  {
   int start = iBarShift(_Symbol, PERIOD_CURRENT, sinceTime, false);
   if(start < 0)
      start = Bars(_Symbol, PERIOD_CURRENT) - 1;
   if(start < 1)
      start = 1;
   for(int i = start; i >= 1; i--)
     {
      datetime bt = iTime(_Symbol, PERIOD_CURRENT, i);
      if(bt < sinceTime)
         break;
      double l = iLow(_Symbol, PERIOD_CURRENT, i);
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      if(l <= zone.top && h >= zone.bottom)
         return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
//| Mode EXECUTION: reaksi valid di zona?                            |
//| Buy : candle menyentuh zona (wick turun) lalu CLOSE bullish      |
//|       (close > open = kembali searah breakout) — wick rejection. |
//| Sell: cermin. Basis closed bar — eksekusi di bar berikutnya.     |
//+------------------------------------------------------------------+
bool CSMCEngine::IsReactedAtZone(const SRetestZone &zone, ENUM_BREAK_DIR dir, datetime sinceTime, SRetestZone &confirmed)
  {
   int start = iBarShift(_Symbol, PERIOD_CURRENT, sinceTime, false);
   if(start < 0)
      start = Bars(_Symbol, PERIOD_CURRENT) - 1;
   if(start < 1)
      start = 1;
   for(int i = start; i >= 1; i--)
     {
      datetime bt = iTime(_Symbol, PERIOD_CURRENT, i);
      if(bt < sinceTime)
         break;
      double o = iOpen(_Symbol, PERIOD_CURRENT, i);
      double c = iClose(_Symbol, PERIOD_CURRENT, i);
      double l = iLow(_Symbol, PERIOD_CURRENT, i);
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      if(!(l <= zone.top && h >= zone.bottom))
         continue;   // belum menyentuh zona

      bool reaction = false;
      if(dir == BREAK_UP)
         reaction = (c > o) && (l < zone.top);   // close bullish + wick menembus zona
      else
         reaction = (c < o) && (h > zone.bottom);

      if(reaction)
        {
         confirmed           = zone;
         confirmed.touched   = true;
         confirmed.touchTime = bt;
         confirmed.entryPrice = c;   // market order di close candle reaksi
         return true;
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
//| Level SL struktural: swing/OB/pool terdekat di sisi aman.        |
//| Buy  → struktur terdekat DI BAWAH entry.                         |
//| Sell → struktur terdekat DI ATAS entry.                          |
//+------------------------------------------------------------------+
double CSMCEngine::GetStructStopLevel(ENUM_BREAK_DIR dir, double entryPrice)
  {
   double best     = 0.0;
   double bestDist = DBL_MAX;

   if(dir == BREAK_UP)
     {
      for(int i = 0; i < m_swingCount; i++)
        {
         const SSwing &sw = m_swings[i];
         if(!sw.valid || sw.type != SWING_LOW)
            continue;
         double d = entryPrice - sw.price;
         if(d > 0.0 && d < bestDist) { bestDist = d; best = sw.price; }
        }
      for(int k = 0; k < m_obCount; k++)
        {
         const SZone &z = m_obs[k];
         if(z.direction != BIAS_BULLISH)
            continue;
         double d = entryPrice - z.bottom;
         if(d > 0.0 && d < bestDist) { bestDist = d; best = z.bottom; }
        }
      for(int p = 0; p < m_poolCount; p++)
        {
         const SLiqPool &pool = m_pools[p];
         if(pool.isHigh)
            continue;   // equal lows = support di bawah entry
         double d = entryPrice - pool.level;
         if(d > 0.0 && d < bestDist) { bestDist = d; best = pool.level; }
        }
     }
   else
     {
      for(int i = 0; i < m_swingCount; i++)
        {
         const SSwing &sw = m_swings[i];
         if(!sw.valid || sw.type != SWING_HIGH)
            continue;
         double d = sw.price - entryPrice;
         if(d > 0.0 && d < bestDist) { bestDist = d; best = sw.price; }
        }
      for(int k = 0; k < m_obCount; k++)
        {
         const SZone &z = m_obs[k];
         if(z.direction != BIAS_BEARISH)
            continue;
         double d = z.top - entryPrice;
         if(d > 0.0 && d < bestDist) { bestDist = d; best = z.top; }
        }
      for(int p = 0; p < m_poolCount; p++)
        {
         const SLiqPool &pool = m_pools[p];
         if(!pool.isHigh)
            continue;   // equal highs = resistance di atas entry
         double d = pool.level - entryPrice;
         if(d > 0.0 && d < bestDist) { bestDist = d; best = pool.level; }
        }
     }
   return best;
  }
//+------------------------------------------------------------------+
int CSMCEngine::GetStructEventCount()
  {
   return m_eventCount;
  }
//+------------------------------------------------------------------+
const SStructEvent& CSMCEngine::GetStructEvent(int i)
  {
   static SStructEvent dummy;
   if(i < 0 || i >= m_eventCount)
      return dummy;
   return m_events[i];
  }
//+------------------------------------------------------------------+
bool CSMCEngine::HasRecentSweep(datetime sinceTime, ENUM_BREAK_DIR dir, SLiqPool &pool)
  {
   return SweepOfPoolInDir(dir, sinceTime, pool);
  }
//+------------------------------------------------------------------+
//| === PIPELINE INTERNAL (closed-bar only) ===                      |
//+------------------------------------------------------------------+
//| Deteksi swing fractal (high/low dikelilingi lookback bar)        |
//+------------------------------------------------------------------+
void CSMCEngine::DetectSwings()
  {
   m_swingCount = 0;
   ZeroMemory(m_swings);

   int lookback = MathMax(2, InpSwingLookback);
   int bars     = Bars(_Symbol, PERIOD_CURRENT);
   int limit    = MathMin(bars, SMC_SCAN_BARS);

   for(int i = lookback; i < limit - lookback && m_swingCount < MAX_SWINGS; i++)
     {
      // --- swing high (strict: lebih tinggi dari semua tetangga) ---
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      bool isHigh = true;
      for(int k = 1; k <= lookback && isHigh; k++)
        {
         if(iHigh(_Symbol, PERIOD_CURRENT, i - k) >= h ||
            iHigh(_Symbol, PERIOD_CURRENT, i + k) >= h)
            isHigh = false;
        }
      if(isHigh)
        {
         SSwing &sw = m_swings[m_swingCount++];
         sw.valid = true;  sw.type = SWING_HIGH;  sw.price = h;
         sw.time  = iTime(_Symbol, PERIOD_CURRENT, i);
         sw.index = i;  sw.leftBars = lookback;  sw.rightBars = lookback;  sw.swept = false;
        }

      // --- swing low ---
      double l = iLow(_Symbol, PERIOD_CURRENT, i);
      bool isLow = true;
      for(int k = 1; k <= lookback && isLow; k++)
        {
         if(iLow(_Symbol, PERIOD_CURRENT, i - k) <= l ||
            iLow(_Symbol, PERIOD_CURRENT, i + k) <= l)
            isLow = false;
        }
      if(isLow)
        {
         SSwing &sw = m_swings[m_swingCount++];
         sw.valid = true;  sw.type = SWING_LOW;  sw.price = l;
         sw.time  = iTime(_Symbol, PERIOD_CURRENT, i);
         sw.index = i;  sw.leftBars = lookback;  sw.rightBars = lookback;  sw.swept = false;
        }
     }
  }
//+------------------------------------------------------------------+
//| Grup swing sejenis dalam toleransi pip → liquidity pool.         |
//| Catatan: pengelompokan berbasis anchor pertama (bukan clustering |
//| penuh) — trade-off kecepatan vs presisi, cukup untuk deteksi     |
//| equal highs/lows mayor.                                          |
//+------------------------------------------------------------------+
void CSMCEngine::BuildLiquidityPools()
  {
   m_poolCount = 0;
   ZeroMemory(m_pools);

   double tol = PipsToPrice(InpLiqTolerancePips);
   bool   used[MAX_SWINGS];
   ArrayInitialize(used, false);

   for(int i = 0; i < m_swingCount && m_poolCount < MAX_LIQ_POOLS; i++)
     {
      if(used[i])
         continue;
      const SSwing &a = m_swings[i];

      SLiqPool pool;
      pool.valid     = true;
      pool.isHigh    = (a.type == SWING_HIGH);
      pool.level     = a.price;
      pool.firstTime = a.time;
      pool.members   = 1;
      pool.swept     = false;
      pool.sweptTime = 0;
      pool.sweptWick = 0.0;
      used[i] = true;

      for(int j = i + 1; j < m_swingCount; j++)
        {
         if(used[j] || m_swings[j].type != a.type)
            continue;
         if(MathAbs(m_swings[j].price - a.price) <= tol)
           {
            pool.members++;
            used[j] = true;
           }
        }
      m_pools[m_poolCount++] = pool;
     }
  }
//+------------------------------------------------------------------+
//| Order block: candle terakhir berlawanan arah sebelum displacement|
//| impulsif. Kualitas: close impuls harus menembus ekstrem candle   |
//| OB minimal 10% dari range candle OB (mengurangi OB noise).       |
//+------------------------------------------------------------------+
void CSMCEngine::DetectOrderBlocks()
  {
   m_obCount = 0;
   ZeroMemory(m_obs);

   int bars  = Bars(_Symbol, PERIOD_CURRENT);
   int limit = MathMin(bars, SMC_SCAN_BARS);

   for(int i = 3; i < limit && m_obCount < MAX_ORDER_BLOCKS; i++)
     {
      double o = iOpen(_Symbol, PERIOD_CURRENT, i);
      double c = iClose(_Symbol, PERIOD_CURRENT, i);
      double prevO = iOpen(_Symbol, PERIOD_CURRENT, i + 1);
      double prevC = iClose(_Symbol, PERIOD_CURRENT, i + 1);
      double prevH = iHigh(_Symbol, PERIOD_CURRENT, i + 1);
      double prevL = iLow(_Symbol, PERIOD_CURRENT, i + 1);
      double prevRange = MathMax(prevH - prevL, _Point);

      if(c > o && prevC < prevO)                    // impuls bullish setelah candle bearish
        {
         if(c > prevH + 0.10 * prevRange)           // displacement nyata
           {
            SZone &ob = m_obs[m_obCount++];
            ob.valid = true;  ob.type = ZONE_ORDER_BLOCK;  ob.direction = BIAS_BULLISH;
            ob.top = prevH;   ob.bottom = prevL;
            ob.originTime  = iTime(_Symbol, PERIOD_CURRENT, i + 1);
            ob.originIndex = i + 1;
            ob.active = true;  ob.mitigated = false;  ob.mitigateTime = 0;
           }
        }
      else if(c < o && prevC > prevO)               // impuls bearish setelah candle bullish
        {
         if(c < prevL - 0.10 * prevRange)
           {
            SZone &ob = m_obs[m_obCount++];
            ob.valid = true;  ob.type = ZONE_ORDER_BLOCK;  ob.direction = BIAS_BEARISH;
            ob.top = prevH;   ob.bottom = prevL;
            ob.originTime  = iTime(_Symbol, PERIOD_CURRENT, i + 1);
            ob.originIndex = i + 1;
            ob.active = true;  ob.mitigated = false;  ob.mitigateTime = 0;
           }
        }
     }
  }
//+------------------------------------------------------------------+
//| FVG: gap 3-candle — hi[shift+2] < lo[shift] (bull) / mirror (bear)|
//+------------------------------------------------------------------+
void CSMCEngine::DetectFVGs()
  {
   m_fvgCount = 0;
   ZeroMemory(m_fvgs);

   int bars  = Bars(_Symbol, PERIOD_CURRENT);
   int limit = MathMin(bars, SMC_SCAN_BARS);

   for(int i = 3; i < limit && m_fvgCount < MAX_FVGS; i++)
     {
      double hi0 = iHigh(_Symbol, PERIOD_CURRENT, i);          // candle terkiri
      double lo0 = iLow(_Symbol, PERIOD_CURRENT, i);
      double hi2 = iHigh(_Symbol, PERIOD_CURRENT, i - 2);      // candle terkanan
      double lo2 = iLow(_Symbol, PERIOD_CURRENT, i - 2);

      if(lo2 > hi0)   // bullish FVG
        {
         SZone &f = m_fvgs[m_fvgCount++];
         f.valid = true;  f.type = ZONE_FVG;  f.direction = BIAS_BULLISH;
         f.top = lo2;  f.bottom = hi0;
         f.originTime  = iTime(_Symbol, PERIOD_CURRENT, i - 1);
         f.originIndex = i - 1;
         f.active = true;  f.mitigated = false;  f.mitigateTime = 0;
        }
      else if(hi2 < lo0)   // bearish FVG
        {
         SZone &f = m_fvgs[m_fvgCount++];
         f.valid = true;  f.type = ZONE_FVG;  f.direction = BIAS_BEARISH;
         f.top = lo0;  f.bottom = hi2;
         f.originTime  = iTime(_Symbol, PERIOD_CURRENT, i - 1);
         f.originIndex = i - 1;
         f.active = true;  f.mitigated = false;  f.mitigateTime = 0;
        }
     }
  }
//+------------------------------------------------------------------+
//| BOS/CHoCH — iterasi swing tertua→terbaru:                        |
//|  - swing high baru yang LEBIH TINGGI dari swing high terakhir:   |
//|      bias bullish → BOS (HH); bias bearish → CHoCH (reversal)    |
//|  - swing low baru yang LEBIH RENDAH dari swing low terakhir:     |
//|      bias bearish → BOS (LL); bias bullish → CHoCH               |
//|  - swing yang tidak menembus ekstrem → hanya struktur internal,  |
//|    bias tidak berubah.                                           |
//+------------------------------------------------------------------+
void CSMCEngine::DetectStructureEvents()
  {
   m_eventCount = 0;
   ZeroMemory(m_events);
   m_localBias = BIAS_NEUTRAL;
   if(m_swingCount < 2)
      return;

   ENUM_BIAS bias     = BIAS_NEUTRAL;
   double    lastHigh = -DBL_MAX;
   double    lastLow  = DBL_MAX;
   bool      haveHigh = false;
   bool      haveLow  = false;

   // tertua (index kecil) → terbaru (index besar)
   for(int i = 0; i < m_swingCount; i++)
     {
      const SSwing &sw = m_swings[i];
      if(sw.type == SWING_HIGH)
        {
         if(haveHigh && sw.price > lastHigh)
           {
            if(bias == BIAS_BULLISH)
               AddEvent(STRUCT_BOS, BIAS_BULLISH, sw);
            else
               AddEvent(STRUCT_CHOCH, BIAS_BULLISH, sw);
            bias = BIAS_BULLISH;
           }
         else if(!haveHigh)
            bias = BIAS_BULLISH;   // leg pertama
         lastHigh = sw.price;
         haveHigh = true;
        }
      else
        {
         if(haveLow && sw.price < lastLow)
           {
            if(bias == BIAS_BEARISH)
               AddEvent(STRUCT_BOS, BIAS_BEARISH, sw);
            else
               AddEvent(STRUCT_CHOCH, BIAS_BEARISH, sw);
            bias = BIAS_BEARISH;
           }
         else if(!haveLow)
            bias = BIAS_BEARISH;
         lastLow = sw.price;
         haveLow = true;
        }
     }
   m_localBias = bias;
  }
//+------------------------------------------------------------------+
void CSMCEngine::AddEvent(ENUM_STRUCT_EVENT type, ENUM_BIAS dir, const SSwing &sw)
  {
   if(m_eventCount >= MAX_STRUCT_EVENTS)
      return;
   SStructEvent &e = m_events[m_eventCount++];
   e.type      = type;
   e.direction = dir;
   e.price     = sw.price;
   e.time      = sw.time;
   e.index     = sw.index;
  }
//+------------------------------------------------------------------+
//| Tandai OB/FVG yang termitigasi / fully filled                    |
//+------------------------------------------------------------------+
void CSMCEngine::UpdateMitigations()
  {
   int bars = Bars(_Symbol, PERIOD_CURRENT);

   for(int k = 0; k < m_obCount; k++)
     {
      SZone &z = m_obs[k];
      if(!z.active)
         continue;
      int start = z.originIndex - 1;
      if(start > bars - 1) start = bars - 1;
      if(start < 1) start = 1;
      for(int i = start; i >= 1; i--)
        {
         double c = iClose(_Symbol, PERIOD_CURRENT, i);
         if(z.direction == BIAS_BULLISH && c < z.bottom)
           {
            z.mitigated = true;  z.active = false;
            z.mitigateTime = iTime(_Symbol, PERIOD_CURRENT, i);
            break;
           }
         if(z.direction == BIAS_BEARISH && c > z.top)
           {
            z.mitigated = true;  z.active = false;
            z.mitigateTime = iTime(_Symbol, PERIOD_CURRENT, i);
            break;
           }
        }
     }

   for(int k = 0; k < m_fvgCount; k++)
     {
      SZone &z = m_fvgs[k];
      if(!z.active)
         continue;
      int start = z.originIndex - 1;
      if(start > bars - 1) start = bars - 1;
      if(start < 1) start = 1;
      for(int i = start; i >= 1; i--)
        {
         double c = iClose(_Symbol, PERIOD_CURRENT, i);
         // fully filled: close menembus tepi terjauh gap
         if(z.direction == BIAS_BULLISH && c <= z.bottom)
           {
            z.mitigated = true;  z.active = false;
            z.mitigateTime = iTime(_Symbol, PERIOD_CURRENT, i);
            break;
           }
         if(z.direction == BIAS_BEARISH && c >= z.top)
           {
            z.mitigated = true;  z.active = false;
            z.mitigateTime = iTime(_Symbol, PERIOD_CURRENT, i);
            break;
           }
        }
     }
  }
//+------------------------------------------------------------------+
//| Tandai pool yang tersapu (wick menembus MELAMPAUI level)         |
//+------------------------------------------------------------------+
void CSMCEngine::UpdateSweeps()
  {
   int bars = Bars(_Symbol, PERIOD_CURRENT);
   for(int p = 0; p < m_poolCount; p++)
     {
      SLiqPool &pool = m_pools[p];
      if(pool.swept)
         continue;
      int start = iBarShift(_Symbol, PERIOD_CURRENT, pool.firstTime, true);
      if(start < 0 || start > bars - 1)
         start = bars - 1;
      if(start < 1)
         start = 1;
      for(int i = start - 1; i >= 1; i--)
        {
         double l = iLow(_Symbol, PERIOD_CURRENT, i);
         double h = iHigh(_Symbol, PERIOD_CURRENT, i);
         if(pool.isHigh && l < pool.level)
           {
            pool.swept     = true;
            pool.sweptTime = iTime(_Symbol, PERIOD_CURRENT, i);
            pool.sweptWick = l;
            break;
           }
         if(!pool.isHigh && h > pool.level)
           {
            pool.swept     = true;
            pool.sweptTime = iTime(_Symbol, PERIOD_CURRENT, i);
            pool.sweptWick = h;
            break;
           }
        }
     }
  }
//+------------------------------------------------------------------+
//| Bias HTF: struktur swing pada H4 (lookback 2) — arah break       |
//| ekstrem terakhir dalam jendela scan.                             |
//+------------------------------------------------------------------+
ENUM_BIAS CSMCEngine::ComputeHTFBias()
  {
   int h4bars = Bars(_Symbol, HTF_PERIOD);
   if(h4bars < 40)
      return BIAS_NEUTRAL;

   int    lb      = 2;
   int    limit   = MathMin(h4bars, 400);
   ENUM_BIAS bias = BIAS_NEUTRAL;
   double  lastHigh = -DBL_MAX;
   double  lastLow  = DBL_MAX;
   bool    haveHigh = false;
   bool    haveLow  = false;

   for(int i = limit - lb - 1; i >= lb; i--)
     {
      double h = iHigh(_Symbol, HTF_PERIOD, i);
      bool isH = true;
      for(int k = 1; k <= lb && isH; k++)
        {
         if(iHigh(_Symbol, HTF_PERIOD, i - k) >= h || iHigh(_Symbol, HTF_PERIOD, i + k) >= h)
            isH = false;
        }
      if(isH)
        {
         if(!haveHigh || h > lastHigh)
            bias = BIAS_BULLISH;   // break ekstrem baru ke atas
         lastHigh = h;
         haveHigh = true;
        }

      double l = iLow(_Symbol, HTF_PERIOD, i);
      bool isL = true;
      for(int k = 1; k <= lb && isL; k++)
        {
         if(iLow(_Symbol, HTF_PERIOD, i - k) <= l || iLow(_Symbol, HTF_PERIOD, i + k) <= l)
            isL = false;
        }
      if(isL)
        {
         if(!haveLow || l < lastLow)
            bias = BIAS_BEARISH;
         lastLow = l;
         haveLow = true;
        }
     }
   return bias;
  }

#endif // ORBSMC_SMC_ENGINE_MQH
