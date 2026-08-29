//+------------------------------------------------------------------+
//| ORB_SMC_NextGen — SessionManager.mqh                            |
//| Deteksi jam sesi (broker time + InpGMTOffset → UTC), penentuan   |
//| Opening Range per sesi, dan penyimpanan high/low range untuk     |
//| KETIGA sesi (Asia/London/NY) secara terpisah dalam array/struct  |
//| per sesi — BUKAN overwrite satu variabel — sehingga data sesi    |
//| yang sudah lewat tetap tampil di dashboard. Reset seluruh data   |
//| di awal hari trading baru (00:00 UTC = start sesi Asia).         |
//| Fase 3: TERIMPLEMENTASI.                                         |
//+------------------------------------------------------------------+
#ifndef ORBSMC_SESSION_MANAGER_MQH
#define ORBSMC_SESSION_MANAGER_MQH

#include <ORB_SMC_NextGen\Defines.mqh>

//+------------------------------------------------------------------+
//| Waktu sesi per hari (input UTC → datetime hari berjalan)         |
//+------------------------------------------------------------------+
struct SSessionTimes
  {
   bool     enabled;   // sesi diaktifkan via input InpEnable*
   bool     valid;     // konfigurasi masuk akal (start < end)
   int      startHour, startMin;  // UTC
   int      endHour, endMin;      // UTC
   datetime startUtc;    // datetime sesi hari ini (UTC)
   datetime endUtc;      // datetime akhir sesi hari ini (UTC)
   datetime rangeEndUtc; // startUtc + InpRangeMinutes*60 — akhir jendela OR
  };

//+------------------------------------------------------------------+
//| Data Opening Range per sesi — disimpan sepanjang hari trading    |
//+------------------------------------------------------------------+
struct SSessionRange
  {
   bool            formed;
   datetime        rangeStart;  // == startUtc
   datetime        rangeEnd;    // == rangeEndUtc
   double          high;        // harga tertinggi jendela OR
   double          low;         // harga terendah jendela OR
   datetime        highTime;
   datetime        lowTime;
   double          sizePips;    // ukuran range dalam pip
   ENUM_RANGE_STATUS status;    // Ranging / BreakoutUp / BreakoutDown
   datetime        breakTime;   // waktu konfirmasi breakout (diisi ORBDetector)
   ENUM_BREAK_DIR  breakDir;
  };

//+------------------------------------------------------------------+
//| CSessionManager                                                  |
//+------------------------------------------------------------------+
class CSessionManager
  {
public:
   //--- lifecycle (dipanggil main EA) ---
   bool              Init();       // salin konfigurasi input → internal
   void              OnTick();     // deteksi hari baru + refresh datetime sesi (murah, tiap tick)
   void              OnNewBar();   // finalisasi OR saat jendela selesai (basis closed bar)

   //--- query sesi ---
   int               GetCurrentSession();                     // SESS_* aktif sekarang / SESS_NONE
   int               GetSessionAt(datetime utcTime);          // sesi pemilik waktu tsb
   const SSessionTimes& GetTimes(int session);
   const SSessionRange& GetRange(int session);
   bool              InRangeWindow(int session, datetime utcTime);
   bool              RangeFormed(int session);
   int               GetSecondsToSessionEnd(int session);     // sisa detik ke endUtc
   int               GetSecondsToForceClose(int session);     // sisa detik ke (endUtc - InpForceCloseMinutesBeforeEnd)
   bool              IsForceCloseWindow(int session);         // sudah masuk jendela force-close?
   bool              IsNewTradingDay();                       // tanggal UTC berubah

   //--- konversi waktu (broker ↔ UTC via InpGMTOffset) ---
   datetime          ToUtc(datetime brokerTime);              // UTC = broker - offset*3600
   datetime          ToBroker(datetime utcTime);              // broker = UTC + offset*3600
   datetime          UtcDayStart(datetime utcTime);           // 00:00 UTC tanggal tsb
   int               FindBar(datetime brokerTime);            // shift bar pada TF eksekusi (exact → fallback)

   //--- label dashboard / komentar order ---
   string            SessionName(int session);                // "Asia"/"London"/"New York"/"None"
   string            SessionShortName(int session);           // "ASIA"/"LDN"/"NY" — komentar order
   color             SessionColor(int session);

   //--- dipanggil ORBDetector saat breakout terkonfirmasi ---
   void              UpdateRangeStatus(int session, ENUM_RANGE_STATUS st, ENUM_BREAK_DIR dir, datetime time);

private:
   SSessionTimes     m_times[SESS_COUNT];
   SSessionRange     m_ranges[SESS_COUNT];
   datetime          m_lastUtcDay;   // tanggal UTC terakhir diproses (deteksi hari baru)
   bool              m_isNewDay;     // flag hari baru (dikonsumsi main EA sekali)
   bool              m_initOk;

   void              SetSessionCfg(int session, bool enabled, int startH, int endH);
   void              ResetDay();                     // reset range+times saat hari trading baru
   void              RebuildTimes();                 // hitung datetime hari ini dari konfigurasi input
   void              ComputeRange(int session);      // scan bar jendela OR (closed) → high/low/sizePips
  };

//+------------------------------------------------------------------+
//| Inisialisasi — baca input sesi, bangun jadwal hari berjalan      |
//+------------------------------------------------------------------+
bool CSessionManager::Init()
  {
   SetSessionCfg(SESS_ASIA,   InpEnableAsia,   InpAsiaStart,   InpAsiaEnd);
   SetSessionCfg(SESS_LONDON, InpEnableLondon, InpLondonStart, InpLondonEnd);
   SetSessionCfg(SESS_NY,     InpEnableNY,     InpNYStart,     InpNYEnd);

   RebuildTimes();
   m_lastUtcDay = UtcDayStart(ToUtc(TimeCurrent()));
   m_isNewDay   = false;
   m_initOk     = true;

   // Log ringkas konfigurasi (sekali di init)
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(m_times[s].enabled && !m_times[s].valid)
         Print(EA_TITLE, " : sesi ", SessionName(s), " TIDAK valid (start >= end) — dinonaktifkan.");
     }
   return m_initOk;
  }
//+------------------------------------------------------------------+
//| Salin konfigurasi input ke struct internal per sesi              |
//+------------------------------------------------------------------+
void CSessionManager::SetSessionCfg(int session, bool enabled, int startH, int endH)
  {
   m_times[session].enabled   = enabled;
   m_times[session].valid     = enabled && (endH > startH);
   m_times[session].startHour = startH;
   m_times[session].startMin  = 0;
   m_times[session].endHour   = endH;
   m_times[session].endMin    = 0;
  }
//+------------------------------------------------------------------+
//| Deteksi hari trading baru & refresh jadwal (tiap tick, murah)    |
//+------------------------------------------------------------------+
void CSessionManager::OnTick()
  {
   datetime dayStart = UtcDayStart(ToUtc(TimeCurrent()));
   if(dayStart != m_lastUtcDay)
     {
      m_isNewDay   = true;
      m_lastUtcDay = dayStart;
      ResetDay();
     }
   else
      m_isNewDay = false;
  }
//+------------------------------------------------------------------+
//| Finalisasi Opening Range saat jendela selesai (closed bar)       |
//| Juga menangani late-attach: sesi yang OR-nya sudah lewat langsung |
//| dihitung begitu EA jalan.                                        |
//+------------------------------------------------------------------+
void CSessionManager::OnNewBar()
  {
   datetime nowUtc = ToUtc(TimeCurrent());
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(!m_times[s].enabled || !m_times[s].valid)
         continue;
      if(!m_ranges[s].formed && nowUtc >= m_times[s].rangeEndUtc)
         ComputeRange(s);
     }
  }
//+------------------------------------------------------------------+
//| Sesi aktif saat ini                                              |
//+------------------------------------------------------------------+
int CSessionManager::GetCurrentSession()
  {
   datetime nowUtc = ToUtc(TimeCurrent());
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(m_times[s].enabled && m_times[s].valid &&
         nowUtc >= m_times[s].startUtc && nowUtc < m_times[s].endUtc)
         return s;
     }
   return SESS_NONE;
  }
//+------------------------------------------------------------------+
//| Sesi pemilik waktu UTC tertentu                                  |
//+------------------------------------------------------------------+
int CSessionManager::GetSessionAt(datetime utcTime)
  {
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(m_times[s].enabled && m_times[s].valid &&
         utcTime >= m_times[s].startUtc && utcTime < m_times[s].endUtc)
         return s;
     }
   return SESS_NONE;
  }
//+------------------------------------------------------------------+
const SSessionTimes& CSessionManager::GetTimes(int session)
  {
   static SSessionTimes dummy;   // fallback aman bila index out of range
   if(session < 0 || session >= SESS_COUNT)
      return dummy;
   return m_times[session];
  }
//+------------------------------------------------------------------+
const SSessionRange& CSessionManager::GetRange(int session)
  {
   static SSessionRange dummy;
   if(session < 0 || session >= SESS_COUNT)
      return dummy;
   return m_ranges[session];
  }
//+------------------------------------------------------------------+
bool CSessionManager::InRangeWindow(int session, datetime utcTime)
  {
   const SSessionTimes &t = GetTimes(session);
   return (t.enabled && t.valid && utcTime >= t.startUtc && utcTime < t.rangeEndUtc);
  }
//+------------------------------------------------------------------+
bool CSessionManager::RangeFormed(int session)
  {
   return GetRange(session).formed;
  }
//+------------------------------------------------------------------+
//| Sisa detik menuju akhir sesi                                     |
//+------------------------------------------------------------------+
int CSessionManager::GetSecondsToSessionEnd(int session)
  {
   const SSessionTimes &t = GetTimes(session);
   if(!t.enabled || !t.valid)
      return 0;
   return (int)(t.endUtc - ToUtc(TimeCurrent()));
  }
//+------------------------------------------------------------------+
//| Sisa detik menuju batas force-close (end - InpForceCloseMinutesBeforeEnd) |
//| Nilai negatif = jendela sudah lewat.                             |
//+------------------------------------------------------------------+
int CSessionManager::GetSecondsToForceClose(int session)
  {
   const SSessionTimes &t = GetTimes(session);
   if(!t.enabled || !t.valid)
      return 0;
   return (int)((t.endUtc - InpForceCloseMinutesBeforeEnd * 60) - ToUtc(TimeCurrent()));
  }
//+------------------------------------------------------------------+
//| Sudah masuk jendela force-close sesi?                            |
//+------------------------------------------------------------------+
bool CSessionManager::IsForceCloseWindow(int session)
  {
   const SSessionTimes &t = GetTimes(session);
   if(!t.enabled || !t.valid)
      return false;
   if(InpForceCloseMinutesBeforeEnd <= 0)
      return false;   // safety net akhir sesi ditangani di state machine
   datetime nowUtc = ToUtc(TimeCurrent());
   return (nowUtc >= t.endUtc - InpForceCloseMinutesBeforeEnd * 60 && nowUtc < t.endUtc);
  }
//+------------------------------------------------------------------+
//| Tanggal UTC berubah = hari trading baru (flag sekali konsumsi)   |
//+------------------------------------------------------------------+
bool CSessionManager::IsNewTradingDay()
  {
   return m_isNewDay;
  }
//+------------------------------------------------------------------+
//| Broker time → UTC                                                |
//+------------------------------------------------------------------+
datetime CSessionManager::ToUtc(datetime brokerTime)
  {
   return brokerTime - InpGMTOffset * 3600;
  }
//+------------------------------------------------------------------+
//| UTC → broker time                                                |
//+------------------------------------------------------------------+
datetime CSessionManager::ToBroker(datetime utcTime)
  {
   return utcTime + InpGMTOffset * 3600;
  }
//+------------------------------------------------------------------+
//| 00:00 UTC dari tanggal waktu tsb                                 |
//+------------------------------------------------------------------+
datetime CSessionManager::UtcDayStart(datetime utcTime)
  {
   MqlDateTime dt;
   TimeToStruct(utcTime, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
  }
//+------------------------------------------------------------------+
//| Shift bar pada TF eksekusi untuk waktu broker tertentu.          |
//| exact=true dulu; bila tidak tepat di boundary, pakai containing. |
//+------------------------------------------------------------------+
int CSessionManager::FindBar(datetime brokerTime)
  {
   int sh = iBarShift(_Symbol, PERIOD_CURRENT, brokerTime, true);
   if(sh < 0)
      sh = iBarShift(_Symbol, PERIOD_CURRENT, brokerTime, false);
   return sh;
  }
//+------------------------------------------------------------------+
string CSessionManager::SessionName(int session)
  {
   switch(session)
     {
      case SESS_ASIA:   return "Asia";
      case SESS_LONDON: return "London";
      case SESS_NY:     return "New York";
     }
   return "None";
  }
//+------------------------------------------------------------------+
string CSessionManager::SessionShortName(int session)
  {
   switch(session)
     {
      case SESS_ASIA:   return "ASIA";
      case SESS_LONDON: return "LDN";
      case SESS_NY:     return "NY";
     }
   return "???";
  }
//+------------------------------------------------------------------+
color CSessionManager::SessionColor(int session)
  {
   switch(session)
     {
      case SESS_ASIA:   return CLR_ASIA;
      case SESS_LONDON: return CLR_LONDON;
      case SESS_NY:     return CLR_NY;
     }
   return CLR_NEUTRAL;
  }
//+------------------------------------------------------------------+
void CSessionManager::UpdateRangeStatus(int session, ENUM_RANGE_STATUS st, ENUM_BREAK_DIR dir, datetime time)
  {
   if(session < 0 || session >= SESS_COUNT)
      return;
   m_ranges[session].status    = st;
   m_ranges[session].breakDir  = dir;
   m_ranges[session].breakTime = time;
  }
//+------------------------------------------------------------------+
//| Reset seluruh data range & jadwal untuk hari trading baru        |
//+------------------------------------------------------------------+
void CSessionManager::ResetDay()
  {
   ZeroMemory(m_ranges);
   for(int s = 0; s < SESS_COUNT; s++)
     {
      m_ranges[s].status   = RANGE_NONE;
      m_ranges[s].breakDir = BREAK_NONE;
     }
   RebuildTimes();
  }
//+------------------------------------------------------------------+
//| Hitung datetime sesi hari ini dari konfigurasi input (UTC)       |
//+------------------------------------------------------------------+
void CSessionManager::RebuildTimes()
  {
   datetime dayStart = UtcDayStart(ToUtc(TimeCurrent()));
   for(int s = 0; s < SESS_COUNT; s++)
     {
      if(!m_times[s].enabled)
         continue;
      m_times[s].startUtc = dayStart + m_times[s].startHour * 3600 + m_times[s].startMin * 60;
      m_times[s].endUtc   = dayStart + m_times[s].endHour   * 3600 + m_times[s].endMin   * 60;
      // OR window: clamp agar tidak melewati akhir sesi
      datetime orEnd = m_times[s].startUtc + InpRangeMinutes * 60;
      m_times[s].rangeEndUtc = MathMin(orEnd, m_times[s].endUtc);
     }
  }
//+------------------------------------------------------------------+
//| Scan bar jendela OR (closed bars) → high/low/sizePips.           |
//| Bar dihitung bila open time ∈ [rangeStart, rangeEnd) — bar yang  |
//| open tepat di rangeEnd termasuk periode breakout, bukan range.   |
//+------------------------------------------------------------------+
void CSessionManager::ComputeRange(int session)
  {
   const SSessionTimes &t = GetTimes(session);
   if(!t.enabled || !t.valid)
      return;

   datetime startB = ToBroker(t.startUtc);
   datetime endB   = ToBroker(t.rangeEndUtc);

   int startShift = FindBar(startB);
   if(startShift < 0)
      startShift = Bars(_Symbol, PERIOD_CURRENT) - 1;

   double   hi  = -DBL_MAX;
   double   lo  = DBL_MAX;
   datetime hiT = 0, loT = 0;
   int      barsSeen = 0;

   // Hanya closed bars (shift >= 1) — tanpa lookahead/repaint
   for(int i = startShift; i >= 1; i--)
     {
      datetime barTime = iTime(_Symbol, PERIOD_CURRENT, i);
      if(barTime < startB)
         break;                       // sudah di luar jendela
      if(barTime >= endB)
         continue;                    // bar tepat di/batas akhir → milik breakout
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      double l = iLow(_Symbol, PERIOD_CURRENT, i);
      if(h > hi) { hi = h; hiT = barTime; }
      if(l < lo) { lo = l; loT = barTime; }
      barsSeen++;
     }

   if(barsSeen <= 0 || hi == -DBL_MAX || lo == DBL_MAX)
      return;                          // data belum cukup — coba bar berikutnya

   SSessionRange &r = m_ranges[session];
   r.formed     = true;
   r.rangeStart = t.startUtc;
   r.rangeEnd   = t.rangeEndUtc;
   r.high       = hi;
   r.low        = lo;
   r.highTime   = hiT;
   r.lowTime    = loT;
   r.sizePips   = PriceToPips(hi - lo);
   r.status     = RANGE_RANGING;
   r.breakDir   = BREAK_NONE;
  }

#endif // ORBSMC_SESSION_MANAGER_MQH
