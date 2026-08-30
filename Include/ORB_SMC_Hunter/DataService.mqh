//+------------------------------------------------------------------+
//|                                                 DataService.mqh  |
//| Satu-satunya sumber data pasar. Semua modul mengambil bar/indikator |
//| lewat class ini — CopyRates/CopyBuffer dipanggil SEKALI per bar   |
//| baru (bukan per modul per tick).                                   |
//|                                                                  |
//| Kontrak anti-repaint: index `back` dihitung dari bar CLOSED      |
//| terdekat: back=0 → bar terakhir yang sudah close (shift 1),      |
//| back=1 → sebelumnya, dst. Bar berjalan tidak pernah diekspos     |
//| lewat getter bar, hanya lewat IsNewBarArrived()/curBarTime().    |
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
   //--- handle indikator (dibuat sekali di Init, release di Release)
   int                 m_hAtr;            // ATR pada timeframe eksekusi
   int                 m_hRsi;            // RSI pada timeframe eksekusi
   //--- cache bar closed (execution TF) — index 0 = bar closed terbaru
   MqlRates            m_rate[];
   datetime            m_lastExecBar;     // time bar 0 (berjalan) saat refresh
   //--- cache bar closed HTF (bias struktur)
   MqlRates            m_htf[];
   datetime            m_lastHtfBar;
   //--- buffer indikator selaras m_rate[]
   double              m_atr[];
   double              m_rsi[];

   /** Isi ulang cache rate execution TF (max `bars`, closed only).
       @return jumlah bar valid di cache. */
   int                 RefreshExecRates(const int bars);
   /** Isi ulang cache rate HTF. @return jumlah bar valid. */
   int                 RefreshHtfRates(const int bars);
   /** Salin satu buffer indikator dari handle ke array selaras cache. */
   bool                RefreshIndicator(const int handle,const int bars,double &dst[]);

public:
                     CDataService(void) : m_hAtr(INVALID_HANDLE),
                                          m_lastExecBar(0), m_lastHtfBar(0) {}
                    ~CDataService(void) {}

   //--- lifecycle -----------------------------------------------------
   /** Buat handle indikator + siap pakai symbol info.
       @return true sukses; false → EA OnInit harus INIT_FAILED. */
   bool              Init(const SHunterSettings &cfg);
   /** Release handle. Panggil di OnDeinit. */
   void              Release(void);

   //--- update per event ------------------------------------------------
   /** Deteksi bar baru pada timeframe eksekusi; bila ya, refresh cache
       bar + indikator + HTF bila bar HTF juga baru.
       @return true bila bar baru terjadi (dipakai gate seluruh pipeline). */
   bool              UpdateOnBar(const int lookbackExec,const int lookbackHtf);
   /** Refresh harga real-time saja (Bid/Ask/spread) — aman tiap tick,
       murah, tidak menyentuh CopyRates. */
   bool              RefreshQuotes(void);

   //--- akses bar -------------------------------------------------------
   /** Salin bar closed ke-`back`. @return false bila out of range. */
   bool              GetClosedBar(const int back,MqlRates &out) const;
   /** Akses cepat harga tertutup bar ke-`back`. */
   bool              GetClose (const int back,double &out) const;
   bool              GetOpen  (const int back,double &out) const;
   bool              GetHigh  (const int back,double &out) const;
   bool              GetLow   (const int back,double &out) const;
   /** Jumlah bar closed yang tersedia di cache. */
   int               ClosedBars(void) const;
   /** true bila cache cukup untuk `need` bar closed. */
   bool              HasBars(const int need) const;

   //--- akses HTF ---------------------------------------------------------
   bool              GetHtfBar(const int back,MqlRates &out) const;
   int               HtfClosedBars(void) const;

   //--- indikator (selalu dari handle+CopyBuffer, closed bar) -----------
   double            Atr(const int back) const;        // 0.0 bila tak tersedia
   double            Rsi(const int back) const;         // INVALID_VALUE-style: DBL_MAX

   //--- quotes & simbol ----------------------------------------------------
   double            Bid(void) const;
   double            Ask(void) const;
   double            SpreadPips(void) const;
   double            PipSize(void) const  { return(m_cfg.pipSize); }
   double            Point(void) const    { return(m_cfg.point); }
   int               Digits(void) const   { return(m_cfg.digits); }
   double            TickValue(void) const;              // per 1 lot
   double            VolumeMin(void) const;
   double            VolumeMax(void) const;
   double            VolumeStep(void) const;
   /** Normalisasi volume ke step simbol + clamp min/max. */
   double            NormalizeVolume(double vol) const;
   /** Normalisasi harga ke digits simbol. */
   double            NormalizePrice(double price) const;

   //--- waktu ------------------------------------------------------------
   /** true bila bar berjalan sekarang beda dengan bar saat refresh terakhir. */
   bool              NewBarArrived(void) const;
   datetime          CurrentBarTime(void) const;
  };

#endif // ORB_SMC_HUNTER_DATASERVICE_MQH
//+------------------------------------------------------------------+
