//+------------------------------------------------------------------+
//| ORB_SMC_NextGen — VisualRenderer.mqh                             |
//| Menggambar seluruh elemen chart: Opening Range, OB, FVG,         |
//| BOS/CHoCH + swing label, liquidity sweep, panah entry/retest,    |
//| pivot harian, volume profile (VAH/VAL/POC), marker & shading     |
//| news. Semua objek memakai prefix unik per kategori (PREFIX_*),   |
//| dihapus tepat sasaran — TIDAK pakai ObjectsDeleteAll agar tidak   |
//| menyentuh objek milik user.                                      |
//|                                                                    |
//| Model render:                                                    |
//|  - Static layers (range, OB, FVG, struktur, pivot, volume        |
//|    profile, news): digambar ulang hanya saat bar baru / event    |
//|    relevan (hapus prefix → gambar ulang dari koleksi internal).  |
//|  - Dynamic layer (entry arrow): hanya saat entry baru muncul.    |
//|  - Tidak ada akses buffer indikator per tick.                    |
//| Fase 3: TERIMPLEMENTASI.                                         |
//+------------------------------------------------------------------+
#ifndef ORBSMC_VISUAL_RENDERER_MQH
#define ORBSMC_VISUAL_RENDERER_MQH

#include <ORB_SMC_NextGen\Defines.mqh>
#include <ORB_SMC_NextGen\SessionManager.mqh>
#include <ORB_SMC_NextGen\ORBDetector.mqh>
#include <ORB_SMC_NextGen\SMCEngine.mqh>
#include <ORB_SMC_NextGen\ConfluenceValidator.mqh>
#include <ORB_SMC_NextGen\TradeExecutor.mqh>
#include <ORB_SMC_NextGen\NewsFilter.mqh>

//--- instance global (didefinisikan di file utama)
extern CSessionManager      g_sessions;
extern CORBDetector         g_orb;
extern CSMCEngine           g_smc;
extern CConfluenceValidator g_confluence;
extern CTradeExecutor       g_executor;
extern CNewsFilter          g_news;

#define VP_MAX_BUCKETS       300
#define MAX_STRUCT_LABELS    80     // batas label swing di chart (anti clutter)
#define MAX_SWEEP_MARKERS    40

//+------------------------------------------------------------------+
//| Info VP hasil kalkulasi (dipakai renderer)                       |
//+------------------------------------------------------------------+
struct SVolumeProfileInfo
  {
   bool     valid;
   long     poc;         // volume bucket POC
   double   pocPrice;
   double   vahPrice;
   double   valPrice;
   datetime fromTime;
   datetime toTime;
   long     buckets[VP_MAX_BUCKETS];
   int      bucketCount;
   double   bucketSize;
   double   priceMin;
  };

//+------------------------------------------------------------------+
//| CVisualRenderer                                                  |
//+------------------------------------------------------------------+
class CVisualRenderer
  {
public:
   //--- lifecycle ---
   bool              Init();
   void              OnTick();            // entry arrows baru (ringan)
   void              OnNewBar();          // gambar ulang static layers

   //--- status layer ---
   void              MarkStaticDirty();   // dipanggil pemilik data saat koleksinya berubah
   void              MarkEntryDirty();    // dipanggil setelah entry baru (market/pending)
   void              OnNewsRefresh();     // dipanggil setelah NewsFilter refresh
   void              CleanupAll();        // hapus SEMUA objek EA (OnDeinit)

   //--- helper warna (dashboard ikut memakai palet ini) ---
   color             ColorForBias(ENUM_BIAS bias);
   color             ColorForBreakDir(ENUM_BREAK_DIR dir);

private:
   bool              m_initOk;
   bool              m_staticDirty;
   bool              m_entryDirty;

   //--- helper objek ---
   bool              CreateHLine(string name, double price, color clr, ENUM_LINE_STYLE style, int width);
   bool              CreateRect(string name, datetime t1, double p1, datetime t2, double p2,
                                color borderClr, ENUM_LINE_STYLE borderStyle, color fillClr, string desc, bool back);
   bool              CreateTrendLine(string name, datetime t1, double p1, datetime t2, double p2,
                                     color clr, ENUM_LINE_STYLE style, int width);
   bool              CreateArrow(string name, datetime time, double price, ENUM_OBJECT objType,
                                 uchar code, color clr, string label);
   bool              CreateText(string name, datetime time, double price, string text, color clr, int fontSize,
                                ENUM_ANCHOR_POINT anchor = ANCHOR_LEFT_LOWER);

   //--- layer statis ---
   void              DrawRanges();                     // PREFIX_RANGE
   void              DrawPivots();                     // PREFIX_PIVOT
   void              DrawVolumeProfile();              // PREFIX_VP
   void              DrawZones();                      // PREFIX_OB_ + PREFIX_FVG_
   void              DrawStructure();                  // PREFIX_STRUCT_
   void              DrawSweeps();                     // PREFIX_SWEEP_
   void              DrawNewsMarkers();                // PREFIX_NEWS_

   //--- layer dinamis ---
   void              DrawEntryArrows();                // PREFIX_ENTRY_

   //--- kalkulasi (offline, saat redraw) ---
   bool              ComputeDailyPivots(double &pp, double &r1, double &r2, double &r3,
                                        double &s1, double &s2, double &s3);
   bool              ComputeVolumeProfile(datetime from, datetime to, SVolumeProfileInfo &out);
   bool              GetRangeForDisplay(int session, double &hi, double &lo);
   void              RemovePrefix(const string prefix);  // hapus SEMUA objek ber-prefix tsb
   void              GetRightEdgeTimes(datetime &t1, datetime &t2);   // koordinat kanan chart → waktu
  };

//+------------------------------------------------------------------+
bool CVisualRenderer::Init()
  {
   m_staticDirty = true;
   m_entryDirty  = true;
   m_initOk      = true;
   return m_initOk;
  }
//+------------------------------------------------------------------+
//| Tiap tick: hanya layer dinamis entry (ringan)                    |
//+------------------------------------------------------------------+
void CVisualRenderer::OnTick()
  {
   if(!m_initOk)
      return;
   if(m_entryDirty)
     {
      DrawEntryArrows();
      m_entryDirty = false;
     }
  }
//+------------------------------------------------------------------+
//| Tiap bar baru: redraw static layers bila ada perubahan data       |
//+------------------------------------------------------------------+
void CVisualRenderer::OnNewBar()
  {
   if(!m_initOk)
      return;
   if(!m_staticDirty)
      return;
   m_staticDirty = false;

   if(InpShowOB || InpShowFVG)          DrawZones();
   else { RemovePrefix(PREFIX_OB); RemovePrefix(PREFIX_FVG); }

   if(InpShowPivot)                     DrawPivots();
   else                                  RemovePrefix(PREFIX_PIVOT);

   if(InpShowVolumeProfile)             DrawVolumeProfile();
   else                                  RemovePrefix(PREFIX_VP);

   if(InpShowStructure)                 DrawStructure();
   else                                  RemovePrefix(PREFIX_STRUCT);

   if(InpShowSweep)                     DrawSweeps();
   else                                  RemovePrefix(PREFIX_SWEEP);

   if(InpShowNewsMarkers)               DrawNewsMarkers();
   else                                  RemovePrefix(PREFIX_NEWS);

   DrawRanges();   // range selalu digambar (dasar sistem ORB)
  }
//+------------------------------------------------------------------+
void CVisualRenderer::MarkStaticDirty()
  {
   m_staticDirty = true;
  }
//+------------------------------------------------------------------+
void CVisualRenderer::MarkEntryDirty()
  {
   m_entryDirty = true;
  }
//+------------------------------------------------------------------+
void CVisualRenderer::OnNewsRefresh()
  {
   if(InpShowNewsMarkers)
      DrawNewsMarkers();
  }
//+------------------------------------------------------------------+
//| Bersihkan seluruh objek EA — dipanggil OnDeinit main EA          |
//+------------------------------------------------------------------+
void CVisualRenderer::CleanupAll()
  {
   RemovePrefix(PREFIX_ALL);
  }
//+------------------------------------------------------------------+
color CVisualRenderer::ColorForBias(ENUM_BIAS bias)
  {
   switch(bias)
     {
      case BIAS_BULLISH: return CLR_BULL;
      case BIAS_BEARISH: return CLR_BEAR;
     }
   return CLR_NEUTRAL;
  }
//+------------------------------------------------------------------+
color CVisualRenderer::ColorForBreakDir(ENUM_BREAK_DIR dir)
  {
   switch(dir)
     {
      case BREAK_UP:   return CLR_BULL;
      case BREAK_DOWN: return CLR_BEAR;
     }
   return CLR_NEUTRAL;
  }
//+------------------------------------------------------------------+
//| === HELPER OBJEK ===                                             |
//+------------------------------------------------------------------+
bool CVisualRenderer::CreateHLine(string name, double price, color clr, ENUM_LINE_STYLE style, int width)
  {
   if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, price))
      return false;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
  }
//+------------------------------------------------------------------+
bool CVisualRenderer::CreateRect(string name, datetime t1, double p1, datetime t2, double p2,
                                 color borderClr, ENUM_LINE_STYLE borderStyle, color fillClr, string desc, bool back)
  {
   if(t1 >= t2 || p1 <= 0.0 || p2 <= 0.0)
      return false;
   if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2))
      return false;
   ObjectSetInteger(0, name, OBJPROP_COLOR, borderClr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, borderStyle);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, fillClr);
   ObjectSetInteger(0, name, OBJPROP_BACK, back);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TEXT, desc);
   return true;
  }
//+------------------------------------------------------------------+
bool CVisualRenderer::CreateTrendLine(string name, datetime t1, double p1, datetime t2, double p2,
                                      color clr, ENUM_LINE_STYLE style, int width)
  {
   if(t1 >= t2)
      return false;
   if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2))
      return false;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
  }
//+------------------------------------------------------------------+
bool CVisualRenderer::CreateArrow(string name, datetime time, double price, ENUM_OBJECT objType,
                                  uchar code, color clr, string label)
  {
   if(!ObjectCreate(0, name, objType, 0, time, price))
      return false;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   if(label != "")
      ObjectSetString(0, name, OBJPROP_TEXT, label);
   return true;
  }
//+------------------------------------------------------------------+
bool CVisualRenderer::CreateText(string name, datetime time, double price, string text, color clr, int fontSize,
                                 ENUM_ANCHOR_POINT anchor)
  {
   if(!ObjectCreate(0, name, OBJ_TEXT, 0, time, price))
      return false;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   return true;
  }
//+------------------------------------------------------------------+
//| === LAYER: OPENING RANGE ===                                     |
//| Garis high/low dibatasi rentang [rangeStart, rangeEnd] sesi,     |
//| warna per sesi. Sesi yang sudah lewat tidak digambar (dihapus    |
//| otomatis — dashboard tetap menampilkan datanya).                 |
//+------------------------------------------------------------------+
void CVisualRenderer::DrawRanges()
  {
   RemovePrefix(PREFIX_RANGE);

   for(int s = 0; s < SESS_COUNT; s++)
     {
      const SSessionTimes &t = g_sessions.GetTimes(s);
      if(!t.enabled || !t.valid)
         continue;

      datetime nowUtc = g_sessions.ToUtc(TimeCurrent());
      if(nowUtc < t.startUtc)
         continue;

      // garis hanya tampil selama sesi berjalan
      if(nowUtc >= t.endUtc)
         continue;

      double hi, lo;
      if(!GetRangeForDisplay(s, hi, lo))
         continue;

      datetime t1 = g_sessions.ToBroker(t.startUtc);
      datetime t2 = g_sessions.ToBroker(t.rangeEndUtc);
      color   clr = g_sessions.SessionColor(s);
      string  sn  = g_sessions.SessionShortName(s);

      CreateTrendLine(PREFIX_RANGE + sn + "_H", t1, hi, t2, hi, clr, STYLE_SOLID, 1);
      CreateTrendLine(PREFIX_RANGE + sn + "_L", t1, lo, t2, lo, clr, STYLE_SOLID, 1);

      double pips = PriceToPips(hi - lo);
      // label tipe+ukuran di ujung KIRI; label HARGA di ujung KANAN tiap garis
      CreateText(PREFIX_RANGE + sn + "_TXT", t1, hi + PipSize() * 4.0,
                 StringFormat("%s OR %.1fp", sn, pips), clr, 7);
      if(InpShowPriceLabels)
        {
         CreateText(PREFIX_RANGE + sn + "_HPR", t2, hi + PipSize() * 2.0, FmtPrice(hi), clr, 7);
         CreateText(PREFIX_RANGE + sn + "_LPR", t2, lo - PipSize() * 2.0, FmtPrice(lo), clr, 7, ANCHOR_LEFT_UPPER);
        }
     }
  }
//+------------------------------------------------------------------+
//| === LAYER: PIVOT HARIAN ===                                      |
//+------------------------------------------------------------------+
void CVisualRenderer::DrawPivots()
  {
   RemovePrefix(PREFIX_PIVOT);

   double pp, r1, r2, r3, s1, s2, s3;
   if(!ComputeDailyPivots(pp, r1, r2, r3, s1, s2, s3))
      return;

   datetime labelTime = TimeCurrent() + 3 * PeriodSeconds(PERIOD_CURRENT);

   CreateHLine(PREFIX_PIVOT + "PP", pp, CLR_PIVOT, STYLE_DOT, 1);
   CreateHLine(PREFIX_PIVOT + "R1", r1, CLR_PIVOT, STYLE_DOT, 1);
   CreateHLine(PREFIX_PIVOT + "R2", r2, CLR_PIVOT, STYLE_DOT, 1);
   CreateHLine(PREFIX_PIVOT + "R3", r3, CLR_PIVOT, STYLE_DOT, 1);
   CreateHLine(PREFIX_PIVOT + "S1", s1, CLR_PIVOT, STYLE_DOT, 1);
   CreateHLine(PREFIX_PIVOT + "S2", s2, CLR_PIVOT, STYLE_DOT, 1);
   CreateHLine(PREFIX_PIVOT + "S3", s3, CLR_PIVOT, STYLE_DOT, 1);

   if(InpShowPriceLabels)
     {
      CreateText(PREFIX_PIVOT + "L_PP", labelTime, pp, "PP " + FmtPrice(pp), CLR_PIVOT, 7);
      CreateText(PREFIX_PIVOT + "L_R1", labelTime, r1, "R1 " + FmtPrice(r1), CLR_PIVOT, 7);
      CreateText(PREFIX_PIVOT + "L_R2", labelTime, r2, "R2 " + FmtPrice(r2), CLR_PIVOT, 7);
      CreateText(PREFIX_PIVOT + "L_R3", labelTime, r3, "R3 " + FmtPrice(r3), CLR_PIVOT, 7);
      CreateText(PREFIX_PIVOT + "L_S1", labelTime, s1, "S1 " + FmtPrice(s1), CLR_PIVOT, 7);
      CreateText(PREFIX_PIVOT + "L_S2", labelTime, s2, "S2 " + FmtPrice(s2), CLR_PIVOT, 7);
      CreateText(PREFIX_PIVOT + "L_S3", labelTime, s3, "S3 " + FmtPrice(s3), CLR_PIVOT, 7);
     }
  }
//+------------------------------------------------------------------+
//| === LAYER: VOLUME PROFILE ===                                    |
//+------------------------------------------------------------------+
void CVisualRenderer::DrawVolumeProfile()
  {
   RemovePrefix(PREFIX_VP);

   int sess = g_sessions.GetCurrentSession();
   if(sess == SESS_NONE)
      return;
   const SSessionTimes &t = g_sessions.GetTimes(sess);

   datetime from = g_sessions.ToBroker(t.startUtc);
   datetime to   = TimeCurrent();
   if(to - from < PeriodSeconds(PERIOD_CURRENT))
      return;

   SVolumeProfileInfo vp;
   if(!ComputeVolumeProfile(from, to, vp))
      return;

   // koordinat kanan chart → waktu (profil menempel di sisi kanan)
   datetime t1, t2;
   GetRightEdgeTimes(t1, t2);
   if(t2 <= t1)
      return;

   // histogram per bucket
   for(int b = 0; b < vp.bucketCount; b++)
     {
      if(vp.buckets[b] <= 0)
         continue;
      double pLow  = vp.priceMin + b * vp.bucketSize;
      double pHigh = pLow + vp.bucketSize;
      color  c     = (b == (int)((vp.pocPrice - vp.priceMin) / vp.bucketSize)) ? CLR_POC : CLR_NEUTRAL;
      CreateRect(PREFIX_VP + "B" + IntegerToString(b), t1, pLow, t2, pHigh,
                 clrNONE, STYLE_SOLID, c, "", true);
     }

   // VAH / VAL / POC
   CreateTrendLine(PREFIX_VP + "POC", t1, vp.pocPrice, t2, vp.pocPrice, CLR_POC, STYLE_SOLID, 2);
   CreateTrendLine(PREFIX_VP + "VAH", t1, vp.vahPrice, t2, vp.vahPrice, CLR_VAH_VAL, STYLE_DASH, 1);
   CreateTrendLine(PREFIX_VP + "VAL", t1, vp.valPrice, t2, vp.valPrice, CLR_VAH_VAL, STYLE_DASH, 1);
   if(InpShowPriceLabels)
     {
      CreateText(PREFIX_VP + "T_POC", t2, vp.pocPrice, "POC " + FmtPrice(vp.pocPrice), CLR_POC, 7);
      CreateText(PREFIX_VP + "T_VAH", t2, vp.vahPrice, "VAH " + FmtPrice(vp.vahPrice), CLR_VAH_VAL, 7);
      CreateText(PREFIX_VP + "T_VAL", t2, vp.valPrice, "VAL " + FmtPrice(vp.valPrice), CLR_VAH_VAL, 7);
     }
  }
//+------------------------------------------------------------------+
//| === LAYER: ORDER BLOCK & FVG ===                                 |
//+------------------------------------------------------------------+
void CVisualRenderer::DrawZones()
  {
   RemovePrefix(PREFIX_OB);
   RemovePrefix(PREFIX_FVG);

   datetime tEnd = TimeCurrent();

   if(InpShowOB)
     {
      for(int i = 0; i < g_smc.GetOBCount(); i++)
        {
         const SZone &z = g_smc.GetOB(i);
         if(!z.valid || !z.active)
            continue;
         if(z.originTime >= tEnd)
            continue;
         color  c   = (z.direction == BIAS_BULLISH) ? CLR_OB_BULL : CLR_OB_BEAR;
         string nm  = PREFIX_OB + IntegerToString(z.originIndex);
         string lbl = (z.direction == BIAS_BULLISH ? "OB+" : "OB-");
         CreateRect(nm, z.originTime, z.top, tEnd, z.bottom, c, STYLE_SOLID, c, lbl, true);
         // label harga tepi zona (atas & bawah) di sisi kiri kotak
         if(InpShowPriceLabels)
           {
            CreateText(nm + "_TP", z.originTime, z.top + PipSize() * 2.0, FmtPrice(z.top), c, 7);
            CreateText(nm + "_BP", z.originTime, z.bottom - PipSize() * 2.0, FmtPrice(z.bottom), c, 7, ANCHOR_LEFT_UPPER);
           }
        }
     }

   if(InpShowFVG)
     {
      for(int i = 0; i < g_smc.GetFVGCount(); i++)
        {
         const SZone &z = g_smc.GetFVG(i);
         if(!z.valid || !z.active)
            continue;
         if(z.originTime >= tEnd)
            continue;
         color  c   = (z.direction == BIAS_BULLISH) ? CLR_FVG_BULL : CLR_FVG_BEAR;
         string nm  = PREFIX_FVG + IntegerToString(z.originIndex);
         string lbl = (z.direction == BIAS_BULLISH ? "FVG+" : "FVG-");
         CreateRect(nm, z.originTime, z.top, tEnd, z.bottom, c, STYLE_DASH, clrNONE, lbl, true);
         // label harga tepi zona (atas & bawah) di sisi kiri kotak
         if(InpShowPriceLabels)
           {
            CreateText(nm + "_TP", z.originTime, z.top + PipSize() * 2.0, FmtPrice(z.top), c, 7);
            CreateText(nm + "_BP", z.originTime, z.bottom - PipSize() * 2.0, FmtPrice(z.bottom), c, 7, ANCHOR_LEFT_UPPER);
           }
        }
     }
  }
//+------------------------------------------------------------------+
//| === LAYER: STRUKTUR (BOS/CHoCH + label swing) ===                |
//+------------------------------------------------------------------+
void CVisualRenderer::DrawStructure()
  {
   RemovePrefix(PREFIX_STRUCT);

   datetime tEnd = TimeCurrent();

   // label swing HH/HL/LH/LL — iterasi tertua → terbaru
   double   lastHigh = -DBL_MAX;
   double   lastLow  = DBL_MAX;
   int      drawn    = 0;
   for(int i = 0; i < g_smc.GetSwingCount() && drawn < MAX_STRUCT_LABELS; i++)
     {
      const SSwing &sw = g_smc.GetSwing(i);
      if(!sw.valid || sw.time > tEnd)
         continue;
      string lbl;
      if(sw.type == SWING_HIGH)
        {
         lbl = (sw.price > lastHigh) ? "HH" : "LH";
         lastHigh = sw.price;
        }
      else
        {
         lbl = (sw.price < lastLow) ? "LL" : "HL";
         lastLow = sw.price;
        }
      double off = (sw.type == SWING_HIGH) ? PipSize() * 3.0 : -PipSize() * 3.0;
      CreateText(PREFIX_STRUCT + "SW" + IntegerToString(i), sw.time, sw.price + off,
                 lbl + (InpShowPriceLabels ? (" " + FmtPrice(sw.price)) : ""), CLR_TEXT_DIM, 7);
      drawn++;
     }

   // event BOS/CHoCH — panah + label
   for(int i = 0; i < g_smc.GetStructEventCount(); i++)
     {
      const SStructEvent &e = g_smc.GetStructEvent(i);
      if(e.time > tEnd)
         continue;
      color  c    = (e.type == STRUCT_BOS) ? CLR_BOS : CLR_CHOCH;
      string lbl  = ((e.type == STRUCT_BOS) ? "BOS " : "CHoCH ")
                    + (InpShowPriceLabels ? FmtPrice(e.price) : "");
      double  off = (e.direction == BIAS_BULLISH) ? -PipSize() * 4.0 : PipSize() * 4.0;
      uchar  code = (e.direction == BIAS_BULLISH) ? 233 : 234;
      CreateArrow(PREFIX_STRUCT + "EV" + IntegerToString(i), e.time, e.price + off,
                  OBJ_ARROW_UP, code, c, lbl);
     }
  }
//+------------------------------------------------------------------+
//| === LAYER: LIQUIDITY SWEEP ===                                   |
//+------------------------------------------------------------------+
void CVisualRenderer::DrawSweeps()
  {
   RemovePrefix(PREFIX_SWEEP);

   datetime tEnd  = TimeCurrent();
   int      drawn = 0;
   for(int i = g_smc.GetLiqCount() - 1; i >= 0 && drawn < MAX_SWEEP_MARKERS; i--)
     {
      const SLiqPool &pool = g_smc.GetLiqPool(i);
      if(!pool.valid || !pool.swept || pool.sweptTime > tEnd)
         continue;
      // arah wick penyapu: EQH tersapu → wick turun (marker di bawah level)
      uchar  code = pool.isHigh ? 242 : 241;      // down / up
      string nm   = PREFIX_SWEEP + IntegerToString(i);
      CreateArrow(nm, pool.sweptTime, pool.sweptWick, OBJ_ARROW_UP, code, CLR_SWEEP,
                  (InpShowPriceLabels ? ("SWEEP " + FmtPrice(pool.level)) : "SWEEP"));
      drawn++;
     }
  }
//+------------------------------------------------------------------+
//| === LAYER: NEWS MARKER & SHADING ===                             |
//+------------------------------------------------------------------+
void CVisualRenderer::DrawNewsMarkers()
  {
   RemovePrefix(PREFIX_NEWS);

   datetime now   = TimeCurrent();
   double   chartMin = ChartGetDouble(0, CHART_PRICE_MIN, 0);
   double   chartMax = ChartGetDouble(0, CHART_PRICE_MAX, 0);
   if(chartMin <= 0.0 || chartMax <= chartMin)
      return;

   int cnt = 0;
   for(int i = 0; i < g_news.GetEventCount() && cnt < 40; i++)
     {
      const SNewsEvent &e = g_news.GetEvent(i);
      if(!e.relevant)
         continue;

      datetime t0 = e.time - InpNewsBufferBeforeMin * 60;
      datetime t1 = e.time + InpNewsBufferAfterMin * 60;
      if(t1 < now)
         continue;   // event + buffer sudah lewat — jangan menumpuk history

      color  c    = (e.impact == IMPACT_HIGH) ? CLR_NEWS_HIGH : CLR_NEWS_MED;
      string base = PREFIX_NEWS + IntegerToString(cnt);

      // shading jendela blokir (rectangle transparan)
      CreateRect(base + "_W", t0, chartMax, t1, chartMin, clrNONE, STYLE_SOLID, c, "news window", true);

      // garis vertikal di waktu event
      ObjectCreate(0, base + "_V", OBJ_VLINE, 0, e.time, 0);
      ObjectSetInteger(0, base + "_V", OBJPROP_COLOR, c);
      ObjectSetInteger(0, base + "_V", OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, base + "_V", OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, base + "_V", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, base + "_V", OBJPROP_HIDDEN, true);

      // label: currency + judul singkat + waktu
      string lbl = e.currency + " " + e.title + " " + TimeHHMM(e.time);
      CreateText(base + "_T", e.time, chartMax, lbl, c, 7);
      cnt++;
     }
  }
//+------------------------------------------------------------------+
//| === LAYER: ENTRY ARROW ===                                       |
//+------------------------------------------------------------------+
void CVisualRenderer::DrawEntryArrows()
  {
   RemovePrefix(PREFIX_ENTRY);

   if(!InpShowEntryArrows)
      return;

   for(int i = 0; i < g_executor.GetTrackedCount(); i++)
     {
      const STrackedPosition &t = g_executor.GetTrackedAt(i);
      if(t.ticket == 0)
         continue;

      double   rr   = (MathAbs(t.entryPrice - t.sl) > 0.0)
                      ? MathAbs(t.tp - t.entryPrice) / MathAbs(t.entryPrice - t.sl) : 0.0;
      string   base = PREFIX_ENTRY + IntegerToString(i);
      if(t.isOrder)
        {
         color c = (t.dir == BREAK_UP) ? CLR_BULL_DIM : CLR_BEAR_DIM;
         CreateArrow(base + "_A", t.openTime, t.entryPrice, OBJ_ARROW_UP,
                     (t.dir == BREAK_UP) ? 233 : 234, c, "LIMIT");
         CreateText(base + "_T", t.openTime, t.entryPrice + (t.dir == BREAK_UP ? PipSize()*4 : -PipSize()*4),
                    StringFormat("%s LIMIT %.2f\nSL %s | TP %s | RR %.1f",
                                 (t.dir == BREAK_UP ? "BUY" : "SELL"), t.lots,
                                 FmtPrice(t.sl), FmtPrice(t.tp), rr), c, 7);
        }
      else
        {
         color c = (t.dir == BREAK_UP) ? CLR_BULL : CLR_BEAR;
         uchar code = (t.dir == BREAK_UP) ? 233 : 234;
         CreateArrow(base + "_A", t.openTime, t.entryPrice, OBJ_ARROW_UP, code, c, "ENTRY");
         CreateText(base + "_T", t.openTime, t.entryPrice + (t.dir == BREAK_UP ? PipSize()*4 : -PipSize()*4),
                    StringFormat("%s ENTRY %.2f @%s\nSL %s | TP %s | RR %.1f",
                                 (t.dir == BREAK_UP ? "BUY" : "SELL"), t.lots,
                                 FmtPrice(t.entryPrice), FmtPrice(t.sl), FmtPrice(t.tp), rr), c, 7);
        }
     }
  }
//+------------------------------------------------------------------+
//| Pivot standar harian: H/L/C hari sebelumnya (D1 closed)          |
//+------------------------------------------------------------------+
bool CVisualRenderer::ComputeDailyPivots(double &pp, double &r1, double &r2, double &r3,
                                         double &s1, double &s2, double &s3)
  {
   if(Bars(_Symbol, PERIOD_D1) < 3)
      return false;
   double h = iHigh(_Symbol, PERIOD_D1, 1);
   double l = iLow(_Symbol, PERIOD_D1, 1);
   double c = iClose(_Symbol, PERIOD_D1, 1);
   if(h <= 0.0 || l <= 0.0 || c <= 0.0)
      return false;

   pp = (h + l + c) / 3.0;
   r1 = 2.0 * pp - l;
   s1 = 2.0 * pp - h;
   r2 = pp + (h - l);
   s2 = pp - (h - l);
   r3 = h + 2.0 * (pp - l);
   s3 = l - 2.0 * (h - pp);
   return true;
  }
//+------------------------------------------------------------------+
//| Volume profile sesi berjalan: histogram tick volume per level,   |
//| POC = bucket volume tertinggi, VA = 70% value area.              |
//+------------------------------------------------------------------+
bool CVisualRenderer::ComputeVolumeProfile(datetime from, datetime to, SVolumeProfileInfo &out)
  {
   ZeroMemory(out);
   if(to <= from)
      return false;

   double chartMax = ChartGetDouble(0, CHART_PRICE_MAX, 0);
   double chartMin = ChartGetDouble(0, CHART_PRICE_MIN, 0);
   if(chartMax <= chartMin)
      return false;

   double vols[];
   int got = CopyTickVolume(_Symbol, PERIOD_CURRENT, from, to, vols);
   if(got <= 0)
      return false;

   int nBuckets = MathMin(VP_MAX_BUCKETS, MathMax(40, (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0) / 4));
   double bSize = (chartMax - chartMin) / nBuckets;

   for(int i = 0; i < got; i++)
     {
      datetime bt = iTime(_Symbol, PERIOD_CURRENT, i);
      if(bt < from || bt >= to)
         continue;
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      double l = iLow(_Symbol, PERIOD_CURRENT, i);
      int loIdx = (int)((l - chartMin) / bSize);
      int hiIdx = (int)((h - chartMin) / bSize);
      loIdx = MathMax(0, MathMin(nBuckets - 1, loIdx));
      hiIdx = MathMax(0, MathMin(nBuckets - 1, hiIdx));
      int span = hiIdx - loIdx + 1;
      if(span <= 0)
         span = 1;
      double per = vols[i] / span;
      for(int b = loIdx; b <= hiIdx; b++)
         out.buckets[b] += (long)MathRound(per);
     }

   // POC
   long maxVol = 0, total = 0;
   int  pocIdx = 0;
   for(int b = 0; b < nBuckets; b++)
     {
      total += out.buckets[b];
      if(out.buckets[b] > maxVol) { maxVol = out.buckets[b]; pocIdx = b; }
     }
   if(total <= 0)
      return false;

   // Value area 70% — perluas dari POC ke sisi dengan volume terbesar
   long target = (long)(total * 0.70);
   long accum  = maxVol;
   int  lo = pocIdx, hi = pocIdx;
   while(accum < target && (lo > 0 || hi < nBuckets - 1))
     {
      long volLo = (lo > 0) ? out.buckets[lo - 1] : -1;
      long volHi = (hi < nBuckets - 1) ? out.buckets[hi + 1] : -1;
      if(volHi >= volLo && hi < nBuckets - 1)
        { hi++; accum += out.buckets[hi]; }
      else if(lo > 0)
        { lo--; accum += out.buckets[lo]; }
      else
         break;
     }

   out.valid      = true;
   out.poc        = maxVol;
   out.pocPrice   = chartMin + (pocIdx + 0.5) * bSize;
   out.vahPrice   = chartMin + (hi + 1) * bSize;
   out.valPrice   = chartMin + lo * bSize;
   out.fromTime   = from;
   out.toTime     = to;
   out.bucketCount = nBuckets;
   out.bucketSize  = bSize;
   out.priceMin    = chartMin;
   return true;
  }
//+------------------------------------------------------------------+
//| High/low range untuk display: pakai range final bila formed,     |
//| kalau belum → scan closed bar sejauh ini (display-only).         |
//+------------------------------------------------------------------+
bool CVisualRenderer::GetRangeForDisplay(int session, double &hi, double &lo)
  {
   const SSessionRange &r = g_sessions.GetRange(session);
   if(r.formed)
     {
      hi = r.high;
      lo = r.low;
      return true;
     }
   const SSessionTimes &t = g_sessions.GetTimes(session);
   if(!t.enabled || !t.valid)
      return false;

   datetime nowUtc  = g_sessions.ToUtc(TimeCurrent());
   datetime endScan = MathMin(nowUtc, t.rangeEndUtc);
   datetime startB  = g_sessions.ToBroker(t.startUtc);
   datetime endB    = g_sessions.ToBroker(endScan);
   if(endB <= startB)
      return false;

   int startShift = g_sessions.FindBar(startB);
   if(startShift < 0)
      startShift = Bars(_Symbol, PERIOD_CURRENT) - 1;

   double hiV = -DBL_MAX, loV = DBL_MAX;
   int    seen = 0;
   for(int i = startShift; i >= 1; i--)
     {
      datetime bt = iTime(_Symbol, PERIOD_CURRENT, i);
      if(bt < startB)
         break;
      if(bt >= endB)
         continue;
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      double l = iLow(_Symbol, PERIOD_CURRENT, i);
      if(h > hiV) hiV = h;
      if(l < loV) loV = l;
      seen++;
     }
   if(seen <= 0)
      return false;
   hi = hiV;
   lo = loV;
   return true;
  }
//+------------------------------------------------------------------+
//| Hapus SEMUA objek ber-prefix tsb (loop aman — tidak menyentuh    |
//| objek lain milik user).                                          |
//+------------------------------------------------------------------+
void CVisualRenderer::RemovePrefix(const string prefix)
  {
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(name == "")
         continue;
      if(StringFind(name, prefix) == 0)
         ObjectDelete(0, name);
     }
  }
//+------------------------------------------------------------------+
//| Koordinat X kanan chart (margin 40-90 px) → waktu — untuk objek  |
//| yang menempel di sisi kanan (volume profile).                    |
//+------------------------------------------------------------------+
void CVisualRenderer::GetRightEdgeTimes(datetime &t1, datetime &t2)
  {
   t1 = 0;
   t2 = 0;
   int width = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS, 0);
   if(width <= 0)
      width = 900;
   int sub = 0;
   double price = 0.0;
   if(!ChartXYToTimePrice(0, width - 110, 0, sub, t1, price))
      t1 = TimeCurrent();
   if(!ChartXYToTimePrice(0, width - 50, 0, sub, t2, price))
      t2 = t1 + 3600;
  }

#endif // ORBSMC_VISUAL_RENDERER_MQH
