//+------------------------------------------------------------------+
//|                                                    NewsFilter.mqh|
//| Kalender ekonomi investing.com via WebRequest():                  |
//|   https://sslecal2.investing.com/                                 |
//| CATATAN SETUP WAJIB: URL tsb harus didaftarkan di MT5 →          |
//| Tools → Options → Expert Advisors → "Allow WebRequest for        |
//| listed URL". Tanpa itu fetch selalu gagal (EA tetap jalan —       |
//| fail-safe).                                                        |
//|                                                                  |
//| Perilaku:                                                          |
//|  - Refresh terjadwal (per InpNewsRefreshHours / awal hari),        |
//|    BUKAN per tick; hasil parsing disimpan cache in-memory.        |
//|  - Parsing TOLERAN: tokenisasi string search (bukan regex kaku);  |
//|    baris gagal parse dilewati, tidak membatalkan seluruh batch.   |
//|  - FAIL-SAFE, bukan fail-block: fetch/parse gagal → warning +     |
//|    pakai cache lama (stale flag); tanpa cache sama sekali →       |
//|    news filter dilaporkan NONAKTIF, EA tetap trading.             |
//|  - Hanya memblokir ENTRY BARU dlm window [t-before, t+after]      |
//|    utk event impact HIGH (+MEDIUM bila diaktifkan) dg currency    |
//|    relevan (auto base/quote dari _Symbol, override manual).        |
//|  - Posisi terbuka TIDAK diutak-atik.                               |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_NEWSFILTER_MQH
#define ORB_SMC_HUNTER_NEWSFILTER_MQH

#include "HunterSettings.mqh"

class CNewsFilter
  {
private:
   SHunterSettings     m_cfg;
   SNewsEvent          m_events[HUNT_MAX_NEWS];   // cache hasil parse
   int                 m_count;
   datetime            m_lastFetchUtc;
   bool                m_hasData;                  // minimal 1 fetch sukses
   string              m_currency;                 // hasil detect/override
   string              m_lastError;                // utk status dashboard

   /** Auto-detect: base+quote symbol (XAUUSD → USD; EURJPY → EUR&JPY). */
   void                ResolveCurrency(void);
   /** GET sslecal2 utk rentang tanggal; @return true + body di `html`. */
   bool                FetchCalendar(const datetime dayFromUtc,const datetime dayToUtc,
                                     string &html);
   /** Parsing longgar: pecah response per event-entry, ekstrak waktu,
       currency, impact (jumlah/fill icon), judul. Baris rusak → skip. */
   int                 ParseEvents(const string html,const datetime dayFromUtc,
                                   SNewsEvent &dst[],const int dstMax);
   /** true bila currency event relevan dgn m_currency. */
   bool                IsRelevantCurrency(const string eventCurrency) const;
   /** Impact lolos filter (high selalu; medium via cfg). */
   bool                IsRelevantImpact(const ENUM_HUNT_NEWS_IMPACT imp) const;

public:
                     CNewsFilter(void) : m_count(0), m_lastFetchUtc(0),
                                         m_hasData(false) {}

   bool              Init(const SHunterSettings &cfg);

   /** Refresh bila jatuh tempo (per-transaction call di luar OnTick berat;
       dipanggil dari OnTimer/awal hari). @return true bila data baru. */
   bool              RefreshIfNeeded(const datetime nowUtc);
   /** Force refresh (mis. awal hari trading). */
   bool              Refresh(const datetime nowUtc);

   //--- query -----------------------------------------------------------
   /** Blokir entry baru sekarang? isi `label` = "CUR · judul · dlm Xm". */
   bool              IsEntryBlocked(const datetime nowUtc,string &label) const;
   /** true bila ada event relevan dalam +/- window display (utk render). */
   bool              GetVisibleEvents(SNewsEvent &dst[],const int dstMax,
                                      const datetime nowUtc) const;
   /** Salin status ringkas utk dashboard. */
   SNewsStatus       Status(const datetime nowUtc) const;
   /** Stale? (cache lebih tua dari newsCacheMaxAgeHours) */
   bool              IsStale(const datetime nowUtc) const;
  };

#endif // ORB_SMC_HUNTER_NEWSFILTER_MQH
//+------------------------------------------------------------------+
