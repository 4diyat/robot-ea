//+------------------------------------------------------------------+
//| ORB_SMC_NextGen — ORBDetector.mqh                               |
//| Validasi breakout Opening Range: body close vs wick, filter      |
//| ukuran minimum range, dan filter false-breakout. Semua deteksi   |
//| berbasis CLOSED BAR (shift >= 1) — tanpa repaint/lookahead.      |
//|                                                                  |
//| Aturan deteksi:                                                  |
//|  1. Bar closed MENUTUP di luar level OR + buffer → kandidat.     |
//|  2. InpRequireBodyClose → close harus melewati level dengan     |
//|     badan candle (close = titik akhir body; badan minimal        |
//|     InpBreakoutConfirmBars bar di luar level).                   |
//|  3. Setelah konfirmasi: bar berikutnya menutup KEMBALI di dalam  |
//|     range → breakout void (bukan sinyal baru) — false-breakout.  |
//|  4. Sinyal baru hanya dihasilkan bila setup di-reset (setup      |
//|     invalid / force-close / hari baru).                          |
//| Fase 3: TERIMPLEMENTASI.                                         |
//+------------------------------------------------------------------+
#ifndef ORBSMC_ORB_DETECTOR_MQH
#define ORBSMC_ORB_DETECTOR_MQH

#include <ORB_SMC_NextGen\Defines.mqh>
#include <ORB_SMC_NextGen\SessionManager.mqh>

//+------------------------------------------------------------------+
//| Hasil deteksi breakout per sesi                                  |
//+------------------------------------------------------------------+
struct SBreakoutSignal
  {
   bool            confirmed;
   ENUM_BREAK_DIR  dir;
   datetime        barTime;         // waktu bar close yang mengonfirmasi
   double          levelPrice;      // level OR yang ditembus
   double          closePrice;      // harga close bar breakout
   bool            bodyClose;       // body (bukan wick) menembus level
   int             barsSinceBreak;  // jumlah bar closed sejak konfirmasi
   bool            voided;          // breakout dibatalkan (close kembali masuk range)
  };

//+------------------------------------------------------------------+
//| CORBDetector                                                     |
//+------------------------------------------------------------------+
class CORBDetector
  {
public:
   //--- lifecycle ---
   bool               Init();
   void               OnNewBar();     // update counter & deteksi breakout (closed bars)
   void               Reset(int session); // reset detektor per sesi (hari baru / setup baru)

   //--- query ---
   bool               DetectBreakout(int session, SBreakoutSignal &out); // true jika sinyal berubah
   bool               IsValidRangeSize(const SSessionRange &range);      // >= InpMinRangePips
   const SBreakoutSignal& LastSignal(int session);
   bool               SignalVoided(int session);   // breakout sudah dibatalkan (close balik masuk range)

private:
   SBreakoutSignal    m_signal[SESS_COUNT];
   bool               m_signalNotified[SESS_COUNT]; // sinyal sudah dikirim ke pemakai (anti duplikat)
   bool               m_initOk;

   bool               FindBreakout(int session, SBreakoutSignal &out);   // scan closed bar pasca OR
   bool               BarBreaks(int session, int shift, ENUM_BREAK_DIR dir, double level, double buffer,
                                SBreakoutSignal &out);                    // bar tsb menembus level?
   void               CheckVoid(int session);                             // bar berikutnya balik masuk range → void
  };

//+------------------------------------------------------------------+
bool CORBDetector::Init()
  {
   for(int s = 0; s < SESS_COUNT; s++)
     {
      ZeroMemory(m_signal[s]);
      m_signal[s].dir = BREAK_NONE;
      m_signalNotified[s] = false;
     }
   m_initOk = true;
   return m_initOk;
  }
//+------------------------------------------------------------------+
//| Dipanggil tiap bar baru — deteksi berbasis closed bar            |
//+------------------------------------------------------------------+
void CORBDetector::OnNewBar()
  {
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(!m_signal[s].confirmed)
         continue;
      m_signal[s].barsSinceBreak++;
      CheckVoid(s);
     }
  }
//+------------------------------------------------------------------+
//| Sinyal breakout baru tersedia untuk diproses? (konsumsi sekali)  |
//+------------------------------------------------------------------+
bool CORBDetector::DetectBreakout(int session, SBreakoutSignal &out)
  {
   if(session < 0 || session >= SESS_COUNT)
      return false;

   // Cari kandidat breakout bila belum ada sinyal aktif
   if(!m_signal[session].confirmed)
      FindBreakout(session, out);

   out = m_signal[session];
   if(out.confirmed && !m_signalNotified[session])
     {
      m_signalNotified[session] = true;
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
//| Ukuran OR memenuhi filter minimum?                               |
//+------------------------------------------------------------------+
bool CORBDetector::IsValidRangeSize(const SSessionRange &range)
  {
   if(InpMinRangePips <= 0.0)
      return true;   // filter off
   return (range.sizePips >= InpMinRangePips);
  }
//+------------------------------------------------------------------+
const SBreakoutSignal& CORBDetector::LastSignal(int session)
  {
   static SBreakoutSignal dummy;
   if(session < 0 || session >= SESS_COUNT)
      return dummy;
   return m_signal[session];
  }
//+------------------------------------------------------------------+
bool CORBDetector::SignalVoided(int session)
  {
   if(session < 0 || session >= SESS_COUNT)
      return false;
   return m_signal[session].voided;
  }
//+------------------------------------------------------------------+
void CORBDetector::Reset(int session)
  {
   if(session < 0 || session >= SESS_COUNT)
      return;
   ZeroMemory(m_signal[session]);
   m_signal[session].dir = BREAK_NONE;
   m_signalNotified[session] = false;
  }
//+------------------------------------------------------------------+
//| Cari breakout pada closed bars setelah OR terbentuk.             |
//| Scan dari bar TERTUA (tepat setelah OR) ke terbaru — sinyal      |
//| diambil dari bar PERTAMA yang menutup di luar level, agar        |
//| tidak melewatkan breakout awal. barsSinceBreak = jumlah bar      |
//| closed sejak bar konfirmasi.                                     |
//+------------------------------------------------------------------+
bool CORBDetector::FindBreakout(int session, SBreakoutSignal &out)
  {
   const SSessionRange &range = g_sessions.GetRange(session);
   if(!range.formed || range.status != RANGE_RANGING)
      return false;

   // Hanya area waktu sesi ini (sampai akhir sesi)
   datetime nowUtc = g_sessions.ToUtc(TimeCurrent());
   const SSessionTimes &t = g_sessions.GetTimes(session);
   if(nowUtc >= t.endUtc)
      return false;   // sesi berakhir — biarkan state machine menangani

   double buffer = PipsToPrice(InpBreakoutBufferPips);

   // Mulai dari bar pertama SETELAH jendela OR (closed bars saja)
   int startShift = g_sessions.FindBar(g_sessions.ToBroker(range.rangeEnd));
   if(startShift < 0)
      startShift = Bars(_Symbol, PERIOD_CURRENT) - 1;

   for(int i = startShift; i >= 1; i--)
     {
      SBreakoutSignal cand;
      if(BarBreaks(session, i, BREAK_UP, range.high, buffer, cand))
        {
         cand.dir        = BREAK_UP;
         cand.levelPrice = range.high;
         cand.confirmed  = true;
         cand.barsSinceBreak = MathMax(0, i - 1);   // bar closed sejak konfirmasi
         m_signal[session] = cand;
         out = cand;
         return true;
        }
      if(BarBreaks(session, i, BREAK_DOWN, range.low, buffer, cand))
        {
         cand.dir        = BREAK_DOWN;
         cand.levelPrice = range.low;
         cand.confirmed  = true;
         cand.barsSinceBreak = MathMax(0, i - 1);
         m_signal[session] = cand;
         out = cand;
         return true;
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
//| Satu closed bar menembus level OR?                               |
//| - dir BREAK_UP   : close - buffer > level (buffer: close harus  |
//|                    melewati level setidaknya buffer di atasnya)  |
//| - InpRequireBodyClose: minimal badan candle berada di luar level |
//|   (badan = range antara open & close); wick-only TIDAK dihitung. |
//| - InpBreakoutConfirmBars > 1: butuh N bar beruntun di luar level |
//|   sebelum konfirmasi (mode konservatif).                         |
//+------------------------------------------------------------------+
bool CORBDetector::BarBreaks(int session, int shift, ENUM_BREAK_DIR dir, double level, double buffer,
                             SBreakoutSignal &out)
  {
   double o = iOpen(_Symbol, PERIOD_CURRENT, shift);
   double c = iClose(_Symbol, PERIOD_CURRENT, shift);
   double h = iHigh(_Symbol, PERIOD_CURRENT, shift);
   double l = iLow(_Symbol, PERIOD_CURRENT, shift);

   bool crossed = false;
   if(dir == BREAK_UP)
      crossed = (c - buffer > level);
   else
      crossed = (c + buffer < level);

   if(!crossed)
      return false;

   // Body close: seluruh badan harus berada di luar level (bukan cuma wick)
   double bodyHigh = MathMax(o, c);
   double bodyLow  = MathMin(o, c);
   if(InpRequireBodyClose)
     {
      if(dir == BREAK_UP && bodyLow <= level)
         return false;
      if(dir == BREAK_DOWN && bodyHigh >= level)
         return false;
     }

   // Konfirmasi multi-bar (opsional): N bar terakhir semuanya di luar level
   int needBars = MathMax(1, InpBreakoutConfirmBars);
   if(needBars > 1)
     {
      int found = 0;
      for(int k = 0; k < needBars; k++)
        {
         int sh = shift - k;
         if(sh < 1)
            break;
         double ck = iClose(_Symbol, PERIOD_CURRENT, sh);
         bool outSide = (dir == BREAK_UP) ? (ck - buffer > level) : (ck + buffer < level);
         if(outSide)
            found++;
         else
            break;   // harus beruntun
        }
      if(found < needBars)
         return false;
     }

   out.barTime    = iTime(_Symbol, PERIOD_CURRENT, shift);
   out.closePrice = c;
   out.bodyClose  = true;
   return true;
  }
//+------------------------------------------------------------------+
//| False-breakout: bar closed SETELAH konfirmasi menutup kembali    |
//| di dalam range → breakout void (setup sesi ini dianggap batal).  |
//+------------------------------------------------------------------+
void CORBDetector::CheckVoid(int session)
  {
   SBreakoutSignal &sig = m_signal[session];
   if(!sig.confirmed || sig.voided)
      return;

   const SSessionRange &range = g_sessions.GetRange(session);
   if(!range.formed)
      return;

   // Satu bar penuh setelah bar konfirmasi
   int breakShift = g_sessions.FindBar(sig.barTime);
   if(breakShift < 1)
      return;
   int checkShift = breakShift - 1;
   if(checkShift < 1)
      return;

   double c = iClose(_Symbol, PERIOD_CURRENT, checkShift);
   if(sig.dir == BREAK_UP && c < range.high)
     {
      sig.voided = true;
      Print(EA_TITLE, " : false breakout UP ", g_sessions.SessionName(session), " — close kembali di dalam range");
     }
   else if(sig.dir == BREAK_DOWN && c > range.low)
     {
      sig.voided = true;
      Print(EA_TITLE, " : false breakout DOWN ", g_sessions.SessionName(session), " — close kembali di dalam range");
     }
  }

//+------------------------------------------------------------------+
//| Instance global CSessionManager — didefinisikan di file utama    |
//+------------------------------------------------------------------+
extern CSessionManager g_sessions;

#endif // ORBSMC_ORB_DETECTOR_MQH
