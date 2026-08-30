//+------------------------------------------------------------------+
//|                                                     Dashboard.mqh|
//| Panel OBJ_RECTANGLE_LABEL (bg) + OBJ_LABEL per baris. Layout      |
//| dibuat SEKALI (BuildLayout) — update hanya ObjectSetString/Set-   |
//| Integer pada objek existing (diff text), tidak re-create.         |
//|                                                                  |
//| Update cadence (sesuai spec):                                     |
//|  - per bar  : range per sesi, bias HTF, state, signal            |
//|  - per tick : floating P/L, countdown news, status OB/OS          |
//|  - per detik (OnTimer(1)) : candle timer, countdown force-close  |
//|                                                                  |
//| CATATAN TRANSPARANSI: OBJ_RECTANGLE_LABEL (window object) tidak  |
//| mendukung alpha di MT5 — "semi-transparan" diemu- lasikan lewat   |
//| warna bg gelap solid + border tipis; candle TIDAK tertutup area   |
//| karena panel menempati margin pojok (ANCHOR + offset X/Y).        |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_DASHBOARD_MQH
#define ORB_SMC_HUNTER_DASHBOARD_MQH

#include "HunterSettings.mqh"

class CHunterDashboard
  {
private:
   SHunterSettings     m_cfg;
   int                 m_chart;
   bool                m_built;
   string              m_rowNames[HUNT_DASH_ROWS_TOTAL];  // HUNT_DASH_R##
   string              m_rowText[HUNT_DASH_ROWS_TOTAL];   // cache diff
   color               m_rowColor[HUNT_DASH_ROWS_TOTAL]; // cache diff
   color               m_bgColor;
   color               m_borderColor;
   int                 m_bgHeight;                        // resize per jumlah baris

   /** ObjectSetString+cache hanya bila berubah (hemat repaint). */
   void                SetRow(const int row,const string text,const color clr);
   /** Warna state machine (konsisten dgn warna panah entry renderer). */
   color               StateColor(const int state) const;
   /** Bangun ulang tinggi panel & posisi tiap baris saat font/corner berubah. */
   void                LayoutRows(void);

public:
                     CHunterDashboard(void) : m_chart(0), m_built(false),
                                              m_bgColor(C'16,22,34'),
                                              m_borderColor(C'70,88,118'),
                                              m_bgHeight(0) {}

   /** Buat panel + baris (sekali; idempoten). corner/fontSize dr settings. */
   bool              BuildLayout(const SHunterSettings &cfg);
   /** Hapus semua objek HUNT_DASH_* (OnDeinit / disable toggle). */
   void              Destroy(void);
   /** true bila panel aktif & built (gate utk pipeline render). */
   bool              IsActive(void) const { return(m_cfg.showDashboard && m_built); }

   //--- update per kelompok (EA yang memutuskan kapan manggil) ----------
   /** Per bar baru: sesi aktif, OR per sesi + status, bias, state,
       sinyal, retest countdown, stats hari ini. */
   void              UpdateOnBar(const int activeSession,const SOpenRange &orAsia,
                                 const SOpenRange &orLondon,const SOpenRange &orNy,
                                 const ENUM_HUNT_BIAS bias,const int state,
                                 const string signalLine,const int retestBarsLeft);
   /** Per tick (ringan, hanya diff): posisi, pending, OB/OS, news state. */
   void              UpdateOnTick(const string posLine,const string pendingLine,
                                  const double rsi,const int obosState,
                                  const SNewsStatus &news);
   /** Per detik (OnTimer): candle countdown mm:ss + force-close countdown. */
   void              UpdateOnTimer(const int secToBarClose,const int secToForceClose,
                                   const string sessionName);
   /** Helper format baris sesi utk UpdateOnBar (dipaket di sini supaya
       formatting konsisten; exposed static utk unit test harness). */
   static string     FormatRangeLine(const string name,const SOpenRange &or_);
   /** Format status RSI. */
   static string     FormatObos(const double rsi,const double upper,const double lower);
  };

#endif // ORB_SMC_HUNTER_DASHBOARD_MQH
//+------------------------------------------------------------------+
