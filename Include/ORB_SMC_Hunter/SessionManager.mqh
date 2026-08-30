//+------------------------------------------------------------------+
//|                                              SessionManager.mqh  |
//| Jadwal sesi + Opening Range PER SESI TERPISAH (Asia/London/NY).  |
//| Data sesi yang sudah lewat TETAP tersimpan sampai reset hari,     |
//| supaya dashboard bisa menampilkan ketiganya.                      |
//|                                                                  |
//| Waktu internal selalu UTC; jam input sudah dikonversi saat        |
//| snapshot settings (lihat EA utama). GMT offset dipakai kembali    |
//| oleh NewsFilter (event UTC broker-time display) & dashboard.      |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_SESSIONMANAGER_MQH
#define ORB_SMC_HUNTER_SESSIONMANAGER_MQH

#include "DataService.mqh"

class CSessionManager
  {
private:
   SHunterSettings     m_cfg;
   SOpenRange          m_or[HUNT_SESSION_COUNT]; // persisten sepanjang hari
   int                 m_active;                 // ENUM_HUNT_SESSION
   datetime            m_dayUtc;                  // hari trading berjalan (UTC date)

   /** Bangun jendela sesi (start/end/rangeEnd UTC) utk satu sesi hari ini. */
   void                BuildSessionWindows(const int session,const datetime dayUtc);
   /** Tambahkan high/low bar closed yang jatuh dalam jendela OR sesi. */
   void                ExtendRange(const int session,const datetime barTime,
                                    const double hi,const double lo);
   /** Deteksi pergantian hari trading UTC → ResetDaily(). */
   bool                CheckNewDay(const datetime nowUtc);

public:
                     CSessionManager(void) : m_active(HUNT_SESSION_NONE),
                                             m_dayUtc(0) {}

   /** Inisialisasi + bangun jendela sesi hari ini. */
   bool              Init(const SHunterSettings &cfg,const datetime nowUtc);

   /** Update tiap bar closed: formasi OR (high/low per sesi), status,
       barsSinceBreakout, transisi ORB_STATUS_*.
       @param data bar cache dari DataService (closed only). */
   void              Update(const CDataService &data,const datetime nowUtc);

   //--- query -----------------------------------------------------------
   /** Sesi yang sedang berjalan (berdasarkan nowUtc). */
   int               ActiveSession(const datetime nowUtc) const;
   /** true bila sekarang di dalam jendela OR sesi tsb. */
   bool              IsRangeForming(const int session,const datetime nowUtc) const;
   /** Salin range tersimpan satu sesi (tetap tersedia walau sesi lewat). */
   bool              GetRange(const int session,SOpenRange &out) const;
   /** Sisa detik sampai akhir SESI (bukan akhir range); <0 bila lewat. */
   int               SecondsToSessionEnd(const int session,const datetime nowUtc) const;
   /** Sisa detik sampai akhir jendela OR. */
   int               SecondsToRangeEnd(const int session,const datetime nowUtc) const;
   /** Sisa detik menuju batas force-close (end - forceCloseMinBefore). */
   int               SecondsToForceClose(const int session,const datetime nowUtc) const;
   /** true bila sekarang >= force-close cutoff sesi tsb. */
   bool              InForceCloseWindow(const int session,const datetime nowUtc) const;
   /** Awal hari trading berjalan (00:00 UTC). */
   datetime          CurrentDayUtc(void) const  { return(m_dayUtc); }
   /** Batas kiri jendela kalkulasi utk SMCEngine (pagi ini). */
   datetime          GetDayStartUtc(void) const { return(m_dayUtc); }
   /** true bila nowUtc berada di hari trading baru → pemanggil wajib
       melakukan rollover (reset risk/smc/orb/state). Auto-mencatat hari. */
   bool              CheckDailyRolloverRequired(const datetime nowUtc);
   /** Session label utk dashboard/objek. */
   static string     SessionName(const int session);
   /** Warna default per sesi (konsisten dg garis range & tag). */
   static color      SessionColor(const int session);
   /** Broker-time display helper: utc + gmtOffset*3600. */
   datetime          ToBrokerTime(const datetime utc) const;

   //--- kontrol -----------------------------------------------------------
   /** Reset seluruh range & status (awal hari trading baru). */
   void              ResetDaily(void);
   /** Panggil saat sesi berakhir / setelah force-close: bersihkan state
       sesi tsb (range tetap disimpan utk dashboard s/d akhir hari). */
   void              LockSession(const int session);
  };

#endif // ORB_SMC_HUNTER_SESSIONMANAGER_MQH
//+------------------------------------------------------------------+
