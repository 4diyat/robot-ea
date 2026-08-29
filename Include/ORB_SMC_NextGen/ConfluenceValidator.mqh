//+------------------------------------------------------------------+
//| ORB_SMC_NextGen — ConfluenceValidator.mqh                        |
//| Menggabungkan sinyal ORB + SMC menjadi satu skor confluence      |
//| sebelum entry diizinkan. Penjaga gerbang tunggal (single gate)   |
//| agar tidak ada jalur entry yang mem-bypass filter.               |
//|                                                                  |
//| Urutan gate (semua wajib lolos):                                 |
//|  1. Ukuran range minimum                                         |
//|  2. Breakout tidak void (false-breakout)                         |
//|  3. Arah breakout searah bias HTF (H4) — NEUTRAL = lolos + catat |
//|  4. Liquidity sweep (opsional via InpRequireLiquiditySweep):     |
//|     pool di arah breakout harus SUDAH tersapu sejak OR terbentuk |
//|  5. Zona retest OB/FVG wajib ada (InpRequireFVGRetest)           |
//|  6. Window blokir news                                           |
//|  7. Spread maksimum                                              |
//|                                                                    |
//| Invalidation retest (berlaku utk kedua mode entry):              |
//|  - bar habis  : InpRetestMaxBars bar sejak konfirmasi breakout   |
//|  - over-extend: harga bergerak > InpMaxExtensionBeforeRetest%    |
//|                 dari ukuran range melampaui level breakout       |
//|                                                                    |
//| Fase 3: TERIMPLEMENTASI.                                         |
//+------------------------------------------------------------------+
#ifndef ORBSMC_CONFLUENCE_VALIDATOR_MQH
#define ORBSMC_CONFLUENCE_VALIDATOR_MQH

#include <ORB_SMC_NextGen\Defines.mqh>
#include <ORB_SMC_NextGen\SessionManager.mqh>
#include <ORB_SMC_NextGen\ORBDetector.mqh>
#include <ORB_SMC_NextGen\SMCEngine.mqh>
#include <ORB_SMC_NextGen\RiskManager.mqh>
#include <ORB_SMC_NextGen\NewsFilter.mqh>

//--- instance global (didefinisikan di file utama)
extern CSessionManager      g_sessions;
extern CORBDetector         g_orb;
extern CSMCEngine           g_smc;
extern CRiskManager         g_risk;
extern CNewsFilter          g_news;

//+------------------------------------------------------------------+
//| Hasil validasi confluence per sesi                               |
//+------------------------------------------------------------------+
struct SValidationResult
  {
   bool            approved;          // semua gate lolos
   int             score;             // 0..100 (indikasi, bukan satu-satunya penentu)
   ENUM_BREAK_DIR  dir;
   datetime        decisionTime;
   SRetestZone     zone;              // zona retest terpilih (entry/sl)
   string          rejectReason;      // alasan penolakan (untuk log + dashboard)
  };

//+------------------------------------------------------------------+
//| CConfluenceValidator                                             |
//+------------------------------------------------------------------+
class CConfluenceValidator
  {
public:
   bool                Init();
   void                OnNewBar();                     // evaluasi sinyal baru per sesi + countdown invalidasi
   void                Reset(int session);             // hari baru / setup batal

   //--- gate evaluasi ---
   bool                Evaluate(int session, SValidationResult &out); // gate lengkap untuk breakout terbaru
   int                 Score(int session, ENUM_BREAK_DIR dir);        // skor 0..100 (dipakai dashboard)

   //--- cek masa retest (berlaku utk kedua mode entry) ---
   int                 GetRetestBarsLeft(int session);                // sisa bar sebelum invalid (>=0)
   bool                IsRetestInvalid(int session);                  // bar habis / over-extension
   double              GetMaxExtensionPrice(int session);             // batas harga ekstensi (dari OR)

   //--- konteks setup (dipakai state machine & dashboard) ---
   bool                HasActiveSetup(int session);
   const SValidationResult& LastResult(int session);

   //--- pembatalan setup ---
   void                InvalidateSession(int session);                // reset konteks sesi (setelah force-close / traded)

private:
   struct SSessionContext
     {
      bool           activeSetup;       // ada setup breakout yang lolos validasi
      datetime       breakTime;         // broker time bar konfirmasi breakout
      ENUM_BREAK_DIR dir;
      double         breakLevel;
      double         rangeSizePrice;    // ukuran OR (harga) — basis % over-extension
      SRetestZone    zone;
      SValidationResult last;
      bool           invalidated;       // setup sudah dibatalkan
      string         invalidReason;
     };
   SSessionContext     m_ctx[SESS_COUNT];
   bool                m_initOk;

   bool                GateHTFBias(int session, ENUM_BREAK_DIR dir, string &reason);
   bool                GateLiquiditySweep(int session, ENUM_BREAK_DIR dir, string &reason);
   bool                GateZone(int session, ENUM_BREAK_DIR dir, SRetestZone &zone, string &reason);
   bool                GateNews(string &reason);
   bool                GateSpread(string &reason);
   int                 ComputeScore(int session, ENUM_BREAK_DIR dir);
  };

//+------------------------------------------------------------------+
bool CConfluenceValidator::Init()
  {
   for(int s = 0; s < SESS_COUNT; s++)
     {
      ZeroMemory(m_ctx[s]);
      m_ctx[s].dir = BREAK_NONE;
     }
   m_initOk = true;
   return m_initOk;
  }
//+------------------------------------------------------------------+
//| Tiap bar baru: cek invalidasi retest untuk setup yang aktif.     |
//| Deteksi breakout baru dilakukan state machine via Evaluate().    |
//+------------------------------------------------------------------+
void CConfluenceValidator::OnNewBar()
  {
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(!m_ctx[s].activeSetup || m_ctx[s].invalidated)
         continue;
      if(IsRetestInvalid(s))
        {
         m_ctx[s].invalidated   = true;
         m_ctx[s].invalidReason = "retest invalid";
         Print(EA_TITLE, " : setup ", g_sessions.SessionName(s), " dibatalkan — ",
               (GetRetestBarsLeft(s) <= 0 ? "batas bar retest habis" : "harga over-extended"));
        }
     }
  }
//+------------------------------------------------------------------+
void CConfluenceValidator::Reset(int session)
  {
   if(session < 0 || session >= SESS_COUNT)
      return;
   ZeroMemory(m_ctx[session]);
   m_ctx[session].dir = BREAK_NONE;
  }
//+------------------------------------------------------------------+
//| Gate lengkap untuk breakout terbaru sesi tsb.                    |
//| Dipanggil state machine saat sinyal breakout baru muncul.        |
//+------------------------------------------------------------------+
bool CConfluenceValidator::Evaluate(int session, SValidationResult &out)
  {
   ZeroMemory(out);
   out.approved = false;
   out.dir      = BREAK_NONE;

   if(session < 0 || session >= SESS_COUNT)
     {
      out.rejectReason = "sesi tidak valid";
      return false;
     }

   const SBreakoutSignal &brk = g_orb.LastSignal(session);
   if(!brk.confirmed || brk.voided)
     {
      out.rejectReason = "breakout tidak valid (void/false-breakout)";
      return false;
     }

   const SSessionRange &range = g_sessions.GetRange(session);
   if(!g_orb.IsValidRangeSize(range))
     {
      out.rejectReason = StringFormat("OR terlalu kecil (%.1f pip < %.1f)", range.sizePips, InpMinRangePips);
      return false;
     }

   string reason = "";
   if(!GateHTFBias(session, brk.dir, reason))
     {
      out.rejectReason = reason;
      return false;
     }
   if(!GateLiquiditySweep(session, brk.dir, reason))
     {
      out.rejectReason = reason;
      return false;
     }
   if(!GateZone(session, brk.dir, out.zone, reason))
     {
      out.rejectReason = reason;
      return false;
     }
   if(!GateNews(reason))
     {
      out.rejectReason = reason;
      return false;
     }
   if(!GateSpread(reason))
     {
      out.rejectReason = reason;
      return false;
     }

   // --- semua gate lolos: rekam konteks setup ---
   SSessionContext &ctx = m_ctx[session];
   ctx.activeSetup   = true;
   ctx.invalidated   = false;
   ctx.invalidReason = "";
   ctx.breakTime     = brk.barTime;
   ctx.dir           = brk.dir;
   ctx.breakLevel    = brk.levelPrice;
   ctx.rangeSizePrice = range.sizePips * PipSize();
   ctx.zone          = out.zone;
   ctx.last          = out;

   out.approved     = true;
   out.dir          = brk.dir;
   out.decisionTime = TimeCurrent();
   out.score        = ComputeScore(session, brk.dir);
   ctx.last         = out;

   Print(EA_TITLE, " : ", g_sessions.SessionName(session), " breakout ", (brk.dir == BREAK_UP ? "UP" : "DOWN"),
         " lolos confluence — skor ", out.score, "/100 | zona ",
         (out.zone.type == ZONE_ORDER_BLOCK ? "OB" : "FVG"),
         " [", FmtPrice(out.zone.bottom), " - ", FmtPrice(out.zone.top), "]");
   return true;
  }
//+------------------------------------------------------------------+
int CConfluenceValidator::Score(int session, ENUM_BREAK_DIR dir)
  {
   return ComputeScore(session, dir);
  }
//+------------------------------------------------------------------+
//| Sisa bar sebelum retest invalid.                                 |
//| InpRetestMaxBars <= 0 → tanpa batas bar (kembalikan 999999).     |
//+------------------------------------------------------------------+
int CConfluenceValidator::GetRetestBarsLeft(int session)
  {
   if(session < 0 || session >= SESS_COUNT)
      return 0;
   if(InpRetestMaxBars <= 0)
      return 999999;
   const SBreakoutSignal &brk = g_orb.LastSignal(session);
   int left = InpRetestMaxBars - brk.barsSinceBreak;
   return MathMax(0, left);
  }
//+------------------------------------------------------------------+
//| Setup invalid? bar habis ATAU harga over-extended.               |
//+------------------------------------------------------------------+
bool CConfluenceValidator::IsRetestInvalid(int session)
  {
   if(session < 0 || session >= SESS_COUNT)
      return true;
   if(!m_ctx[session].activeSetup)
      return false;

   // 1) bar habis (bila limit diaktifkan)
   if(GetRetestBarsLeft(session) <= 0 && InpRetestMaxBars > 0)
      return true;

   // 2) over-extension: harga sudah lari > X% range melampaui level breakout
   if(InpMaxExtensionBeforeRetest > 0.0)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ext = m_ctx[session].rangeSizePrice * InpMaxExtensionBeforeRetest / 100.0;
      if(m_ctx[session].dir == BREAK_UP && bid > m_ctx[session].breakLevel + ext)
         return true;
      if(m_ctx[session].dir == BREAK_DOWN && bid < m_ctx[session].breakLevel - ext)
         return true;
     }

   // 3) sesi sudah berakhir → setup tidak relevan lagi
   if(g_sessions.GetSecondsToSessionEnd(session) <= 0)
      return true;

   return false;
  }
//+------------------------------------------------------------------+
//| Batas harga ekstensi maksimum sebelum retest (dari level OR)     |
//+------------------------------------------------------------------+
double CConfluenceValidator::GetMaxExtensionPrice(int session)
  {
   if(session < 0 || session >= SESS_COUNT)
      return 0.0;
   if(!m_ctx[session].activeSetup || InpMaxExtensionBeforeRetest <= 0.0)
      return 0.0;
   double ext = m_ctx[session].rangeSizePrice * InpMaxExtensionBeforeRetest / 100.0;
   if(m_ctx[session].dir == BREAK_UP)
      return m_ctx[session].breakLevel + ext;
   return m_ctx[session].breakLevel - ext;
  }
//+------------------------------------------------------------------+
bool CConfluenceValidator::HasActiveSetup(int session)
  {
   if(session < 0 || session >= SESS_COUNT)
      return false;
   return (m_ctx[session].activeSetup && !m_ctx[session].invalidated);
  }
//+------------------------------------------------------------------+
const SValidationResult& CConfluenceValidator::LastResult(int session)
  {
   static SValidationResult dummy;
   if(session < 0 || session >= SESS_COUNT)
      return dummy;
   return m_ctx[session].last;
  }
//+------------------------------------------------------------------+
void CConfluenceValidator::InvalidateSession(int session)
  {
   if(session < 0 || session >= SESS_COUNT)
      return;
   m_ctx[session].activeSetup = false;
   m_ctx[session].invalidated = true;
   m_ctx[session].invalidReason = "dibatalkan (force-close/traded/invalidasi)";
  }
//+------------------------------------------------------------------+
//| Gate: arah breakout wajib searah bias HTF (H4)                   |
//+------------------------------------------------------------------+
bool CConfluenceValidator::GateHTFBias(int session, ENUM_BREAK_DIR dir, string &reason)
  {
   if(!g_smc.DetectStructure(session, dir))
     {
      ENUM_BIAS htf = g_smc.GetHTFBias();
      reason = StringFormat("bias HTF berlawanan (HTF=%s, breakout=%s)",
                            (htf == BIAS_BULLISH ? "Bullish" : "Bearish"),
                            (dir == BREAK_UP ? "UP" : "DOWN"));
      return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
//| Gate: liquidity pool di arah breakout harus sudah tersapu        |
//| (sejak OR terbentuk). Pool lawan arah yang belum tersapu =       |
//| resting liquidity yang menolak sinyal.                           |
//+------------------------------------------------------------------+
bool CConfluenceValidator::GateLiquiditySweep(int session, ENUM_BREAK_DIR dir, string &reason)
  {
   if(!InpRequireLiquiditySweep)
      return true;

   const SSessionRange &range = g_sessions.GetRange(session);
   datetime since = g_sessions.ToBroker(range.rangeStart);

   SLiqPool sweptPool;
   if(g_smc.SweepOfPoolInDir(dir, since, sweptPool))
      return true;

   // detil diagnostik: pool terdekat yang belum tersapu
   SLiqPool opposing;
   if(g_smc.GetPoolOpposingBreak(session, dir, opposing) >= 0)
      reason = StringFormat("liquidity di arah breakout belum di-sweep (pool %.5s di %s)",
                            (opposing.isHigh ? "EQH" : "EQL"), FmtPrice(opposing.level));
   else
      reason = "tidak ada bukti liquidity sweep di arah breakout";
   return false;
  }
//+------------------------------------------------------------------+
//| Gate: zona retest (OB/FVG) wajib ada                             |
//+------------------------------------------------------------------+
bool CConfluenceValidator::GateZone(int session, ENUM_BREAK_DIR dir, SRetestZone &zone, string &reason)
  {
   if(!InpRequireFVGRetest)
      return true;
   if(g_smc.GetRetestZone(dir, zone))
      return true;
   reason = "tidak ada OB/FVG aktif untuk retest";
   return false;
  }
//+------------------------------------------------------------------+
//| Gate: window blokir news (entry baru saja)                       |
//+------------------------------------------------------------------+
bool CConfluenceValidator::GateNews(string &reason)
  {
   if(g_news.IsBlockedNow(reason))
      return false;
   return true;
  }
//+------------------------------------------------------------------+
//| Gate: spread maksimum                                            |
//+------------------------------------------------------------------+
bool CConfluenceValidator::GateSpread(string &reason)
  {
   if(!g_risk.IsSpreadOk())
     {
      double spreadPips = PriceToPips(SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID));
      reason = StringFormat("spread %.1f pip > maks %.1f", spreadPips, InpMaxSpreadPips);
      return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
//| Skor confluence 0..100 (indikasi kualitas setup):                |
//|  - bias HTF searah            : 20                                |
//|  - liquidity sweep terjadi    : 25                                |
//|  - zona OB (bukan FVG)        : 15                                |
//|  - zona dekat dgn harga       : 10                                |
//|  - ukuran range proporsional  : 10                                |
//|  - bias lokal searah          : 10                                |
//|  - tidak ada news dekat       : 10                                |
//+------------------------------------------------------------------+
int CConfluenceValidator::ComputeScore(int session, ENUM_BREAK_DIR dir)
  {
   int score = 0;

   // 1) bias HTF (20)
   ENUM_BIAS htf = g_smc.GetHTFBias();
   bool htfAligned = (dir == BREAK_UP && htf == BIAS_BULLISH) || (dir == BREAK_DOWN && htf == BIAS_BEARISH);
   if(htfAligned) score += 20;
   else if(htf == BIAS_NEUTRAL) score += 10;

   // 2) liquidity sweep (25)
   const SSessionRange &range = g_sessions.GetRange(session);
   datetime since = g_sessions.ToBroker(range.rangeStart);
   SLiqPool swept;
   if(g_smc.SweepOfPoolInDir(dir, since, swept))
      score += 25;

   // 3) zona (15 + 10 kedekatan)
   SRetestZone zone;
   if(g_smc.GetRetestZone(dir, zone))
     {
      if(zone.type == ZONE_ORDER_BLOCK)
         score += 15;
      else
         score += 8;
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double distPips = PriceToPips(MathAbs(zone.entryPrice - bid));
      if(distPips <= 50.0) score += 10;
      else if(distPips <= 120.0) score += 5;
     }

   // 4) ukuran range (10)
   if(range.sizePips >= 20.0 && range.sizePips <= 600.0)
      score += 10;

   // 5) bias lokal searah (10)
   ENUM_BIAS local = g_smc.GetBias();
   if((dir == BREAK_UP && local == BIAS_BULLISH) || (dir == BREAK_DOWN && local == BIAS_BEARISH))
      score += 10;

   // 6) berita (10)
   string reason;
   if(!g_news.IsBlockedNow(reason))
      score += 10;

   return MathMin(100, score);
  }

#endif // ORBSMC_CONFLUENCE_VALIDATOR_MQH
