//+------------------------------------------------------------------+
//|                                               HunterDefines.mqh  |
//| ORB_SMC_Hunter — tipe & konstanta bersama                          |
//|                                                                  |
//| Aturan arsitektur:                                               |
//|  - Modul TIDAK boleh mereferensikan input `Inp*` langsung.       |
//|    Semua config mengalir lewat SHunterSettings (snapshot).      |
//|  - Semua struct di sini adalah POD + Reset(); tanpa logika       |
//|    trading.                                                      |
//|  - Ruang waktu internal EA = broker (TimeCurrent); input jam     |
//|    bentrok dengan EA milik user lain di chart yang sama.         |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_DEFINES_MQH
#define ORB_SMC_HUNTER_DEFINES_MQH


//+------------------------------------------------------------------+
//| Helper utilitas string — MQL5: StringToLower/Upper/TrimLeft/Right  |
//| mengubah argumen in-place (return int), bukan fungsi ekspresi.       |
//| Pass-by-value = salinan lokal → aman utk ekspresi `x==ToUpper(y)`. |
//+------------------------------------------------------------------+
string HUNT_ToLower(string s)  { StringToLower(s);  return(s); }
string HUNT_ToUpper(string s)  { StringToUpper(s);  return(s); }
string HUNT_Trim(string s)     { StringTrimLeft(s); StringTrimRight(s); return(s); }

//=== EA identity =====================================================
#define HUNT_NAME             "ORB_SMC_Hunter"
#define HUNT_VERSION          "1.15"

//=== Prefix objek chart (1 per kategori render) ======================
#define HUNT_PREFIX_OR        "HUNT_OR_"     // garis opening range per sesi
#define HUNT_PREFIX_OB        "HUNT_OB_"     // kotak order block
#define HUNT_PREFIX_FVG       "HUNT_FVG_"    // kotak fair value gap
#define HUNT_PREFIX_STR       "HUNT_STR_"    // label HH/HL/LH/LL + BOS/CHoCH
#define HUNT_PREFIX_SWP       "HUNT_SWP_"    // marker liquidity sweep
#define HUNT_PREFIX_ENT       "HUNT_ENT_"    // panah + label entry/retest
#define HUNT_PREFIX_PIV       "HUNT_PIV_"    // garis pivot harian
#define HUNT_PREFIX_VP        "HUNT_VP_"     // histogram volume profile
#define HUNT_PREFIX_NEWS      "HUNT_NEWS_"   // vline + shading window news
#define HUNT_PREFIX_SESS      "HUNT_SESS_"   // band latar sesi (rectangle fill)
#define HUNT_PREFIX_DASH      "HUNT_DASH_"   // panel dashboard
#define HUNT_OBJ_FILTER       "HUNT_"        // filter prefix utk sweep cleanup
#define HUNT_PREFIX_BG        "HUNT_DASH_BG"   // background panel (1 objek)

//=== Palet warna (konsisten state↔objek↔dashboard) ====================
#define HUNT_COL_ASIA         clrDodgerBlue
#define HUNT_COL_LONDON       clrOrange
#define HUNT_COL_NY           clrMediumOrchid
//--- band latar sesi: solid gelap (tanpa alpha, back=true) + varian live
#define HUNT_COL_BAND_ASIA      C'10,26,40'
#define HUNT_COL_BAND_LONDON    C'40,28,8'
#define HUNT_COL_BAND_NY        C'30,14,40'
#define HUNT_COL_BAND_ASIA_ON   C'14,42,64'
#define HUNT_COL_BAND_LONDON_ON C'64,44,10'
#define HUNT_COL_BAND_NY_ON     C'50,22,66'
#define HUNT_COL_BULL         clrSeaGreen
#define HUNT_COL_BEAR         clrIndianRed
#define HUNT_COL_READY        clrLime
#define HUNT_COL_WAIT         clrGold
#define HUNT_COL_NEWS_HIGH    clrRed
#define HUNT_COL_NEWS_MED     clrOrangeRed
#define HUNT_COL_TEXT         clrGainsboro
#define HUNT_COL_AMD_ACC      C'0,150,136'   // teal   — Accumulation
#define HUNT_COL_AMD_MAN      C'255,111,97'  // coral  — Manipulation
#define HUNT_COL_AMD_DIS      C'155,89,182'  // purple — Distribution
#define HUNT_COL_AMD_DONE     C'117,117,117' // gray   — Selesai
#define HUNT_COL_DASH_BG      C'8,12,20'    // HUD night-ops (v0.99+)
#define HUNT_COL_DASH_BORDER  C'46,64,92'
#define HUNT_COL_DASH_HDR     C'10,20,34'
#define HUNT_COL_DASH_ACCENT  C'0,203,255'  // cyan garis & aksen
#define HUNT_COL_DASH_LABEL   C'124,142,168'// kolom label (muted)
#define HUNT_COL_DASH_SECT    C'96,208,232' // judul seksi
#define HUNT_COL_DASH_TRACK   C'26,38,56'   // track progress bar
#define HUNT_COL_DASH_SHDW    C'3,5,9'      // drop shadow panel

#define HUNT_CODE_ASIA        "ASI"
#define HUNT_CODE_LONDON      "LON"
#define HUNT_CODE_NY          "NY"

//=== Batas kapasitas (hindari array tak terbatas) ====================
#define HUNT_SESSION_COUNT    3              // Asia, London, NY
#define HUNT_MAX_ZONES        64             // zona OB/FVG simultan dipertahankan
#define HUNT_MAX_SWINGS       128
#define HUNT_MAX_POOLS        32
#define HUNT_MAX_STRUCT       48
#define HUNT_MAX_NEWS         64             // event dalam jendela display
#define HUNT_VOLPROFILE_BINS  48
#define HUNT_REASONS_MAX      8

//=== Enum sesi =======================================================
enum ENUM_HUNT_SESSION
  {
   HUNT_SESSION_NONE    = -1,
   HUNT_SESSION_ASIA    = 0,
   HUNT_SESSION_LONDON  = 1,
   HUNT_SESSION_NY      = 2
  };

//=== Arah ============================================================
enum ENUM_HUNT_DIR
  {
   HUNT_DIR_NONE = 0,
   HUNT_DIR_BUY  = 1,
   HUNT_DIR_SELL = -1
  };

//=== Bias struktur HTF ===============================================
enum ENUM_HUNT_BIAS
  {
   HUNT_BIAS_NONE    = 0,
   HUNT_BIAS_BULLISH = 1,
   HUNT_BIAS_BEARISH = -1
  };

//=== Status Opening Range per sesi ===================================
enum ENUM_ORB_STATUS
  {
   ORB_STATUS_NONE           = 0,  // belum mulai hari / sesi nonaktif
   ORB_STATUS_FORMING,             // range masih terbentuk (InpRangeMinutes)
   ORB_STATUS_RANGING,             // range formed, harga di dalam batas
   ORB_STATUS_BREAKOUT_UP,         // body-close di atas high
   ORB_STATUS_BREAKOUT_DOWN,       // body-close di bawah low
   ORB_STATUS_INVALIDATED          // false-breakout / min-range gagal
  };

//=== State machine per sesi (inti orkestrasi EA) =====================
enum ENUM_HUNT_STATE
  {
   HUNT_STATE_IDLE = 0,          // menganggur sampai sesi berikutnya
   HUNT_STATE_RANGE_FORMING,     // OR sedang terbentuk
   HUNT_STATE_WAIT_BREAKOUT,     // OR valid, menunggu breakout terkonfirmasi
   HUNT_STATE_BREAKOUT_CONFIRMED,// breakout lolos ORBDetector, evaluasi confluence
   HUNT_STATE_WAIT_RETEST,       // menunggu retest zona / pending order terpasang
   HUNT_STATE_READY_ENTRY,       // reaksi retest terkonfirmasi (mode EXECUTION)
   HUNT_STATE_MANAGING,          // posisi aktif dari sesi ini (TP1/trailing)
   HUNT_STATE_FORCE_CLOSED       // force-close sudah dieksekusi; lock s/d sesi habis
  };

//=== Mode eksekusi entry =============================================
enum ENUM_ENTRY_MODE
  {
   ENTRY_EXECUTION    = 0,       // market order setelah reaksi retest di closed bar
   ENTRY_PENDING_ORDER = 1       // limit di tepi zona, expiry berbasis bar
  };

//=== Mode ukuran lot (v1.03) =========================================
enum ENUM_HUNT_LOT_MODE
  {
   HUNT_LOT_ADAPTIVE = 0,       // sizing risiko % (InpRiskPercent) per trade
   HUNT_LOT_FIXED    = 1        // lot tetap (InpFixedLots)
  };

//=== Mode trading (v1.02) ==============================================
enum ENUM_HUNT_MODE
  {
   HUNT_MODE_INTRADAY = 0,       // sesi-anchored, force-close, tanpa overnight
   HUNT_MODE_SWING    = 1        // hold overnight, jendela/stop lebih lebar
  };

//=== Basis waktu input sesi ==========================================
enum ENUM_HUNT_TIME_BASE
  {
   HUNT_TIME_BASE_BROKER = 0,    // jam input = waktu chart/broker
   HUNT_TIME_BASE_UTC    = 1,    // jam input = UTC (konversi via GMT offset)
   HUNT_TIME_BASE_AUTODST= 2     // London/NY = jam LOKAL bursa + aturan DST
  };

//=== Basis perhitungan risiko =========================================
enum ENUM_HUNT_RISK_BASE
  {
   HUNT_RISK_BASE_BALANCE = 0,
   HUNT_RISK_BASE_EQUITY  = 1
  };

//=== Tipe zona SMC (OB + FVG disatukan dalam satu pipeline SZone) ====
enum ENUM_HUNT_ZONE_TYPE
  {
   HUNT_ZONE_NONE     = 0,
   HUNT_ZONE_OB_BULL  = 1,
   HUNT_ZONE_OB_BEAR  = 2,
   HUNT_ZONE_FVG_BULL = 3,
   HUNT_ZONE_FVG_BEAR = 4,
   HUNT_ZONE_BREAKER_BULL = 5, // v1.07: OB bear dipatahkan naik → support
   HUNT_ZONE_BREAKER_BEAR = 6  // v1.07: OB bull dipatahkan turun → resistance
  };

enum ENUM_HUNT_ZONE_STATE
  {
   HUNT_ZONE_ACTIVE   = 0,
   HUNT_ZONE_MITIGATED = 1,      // harga sudah menyentuh >50% zona
   HUNT_ZONE_INVALID  = 2       // ditutup penuh / menembus lawan arah
  };

//=== Event struktur ===================================================
enum ENUM_HUNT_STRUCT_TYPE
  {
   HUNT_STRUCT_NONE = 0,
   HUNT_STRUCT_BOS,
   HUNT_STRUCT_CHOCH
  };

//=== Label swing (HH/HL/LH/LL) ========================================
enum ENUM_HUNT_SWING_LABEL
  {
   HUNT_SWING_UNKNOWN = 0,
   HUNT_SWING_HH,
   HUNT_SWING_HL,
   HUNT_SWING_LH,
   HUNT_SWING_LL
  };

//=== Event hasil TradeExecutor.Manage() (bit flags utk EA utama) ====
enum ENUM_HUNT_EXEC_EVENT
  {
   HUNT_EVT_NONE           = 0,
   HUNT_EVT_PENDING_FILLED = 1,   // pending terisi → state MANAGING
   HUNT_EVT_PENDING_EXPIRED= 2,   // expiry bar habis → order dihapus
   HUNT_EVT_POS_CLOSED     = 4,   // posisi tertutup (TP/SL/manual)
   HUNT_EVT_PARTIAL        = 8    // partial TP1 done → SL ke breakeven
  };

//=== Impact news (mengikuti skala investing.com 1..3) ================
enum ENUM_HUNT_NEWS_IMPACT
  {
   HUNT_NEWS_IMPACT_ANY  = 0,
   HUNT_NEWS_IMPACT_LOW  = 1,
   HUNT_NEWS_IMPACT_MED  = 2,
   HUNT_NEWS_IMPACT_HIGH = 3
  };

//=== Baris dashboard (indeks tetap — panel dibuat sekali, isi di-diff)|
enum ENUM_HUNT_DASH_ROW
  {
   HUNT_DASH_HDR = 0,                // header + versi
   //--- Section Sesi & Range
   HUNT_DASH_SESSION_ACTIVE,         // sesi aktif + sisa waktu
   HUNT_DASH_RANGE_ASIA,             // H/L/pips + status Asia
   HUNT_DASH_RANGE_LONDON,           // H/L/pips + status London
   HUNT_DASH_RANGE_NY,               // H/L/pips + status NY
   HUNT_DASH_CANDLE_TIMER,           // countdown close bar mm:ss
   //--- Section Struktur & Sinyal
   HUNT_DASH_AMD,                    // fase siklus AMD (badge warna)
   HUNT_DASH_CHOCH,                  // alert CHoCH HTF terbaru (N menit)
   HUNT_DASH_HTF_BIAS,               // bias HTF
   HUNT_DASH_STATE,                  // state machine (label teknis)
   HUNT_DASH_SIGNAL,                 // sinyal SMC terakhir
   HUNT_DASH_RETEST_CD,              // sisa bar retest / extension %
   HUNT_DASH_OBOS,                   // RSI + Overbought/Oversold/Neutral
   //--- Section Confluence Checklist (read-only)
   HUNT_DASH_CHK_BIAS,               // HTF bias searah
   HUNT_DASH_CHK_SWEEP,              // liquidity sweep terkonfirmasi
   HUNT_DASH_CHK_BODY,               // body close valid di luar range
   HUNT_DASH_CHK_RETEST,             // reaksi retest / status pending
   HUNT_DASH_CHK_NEWS,               // news window aman
   HUNT_DASH_CHK_SUM,                // N/5 syarat terpenuhi
   //--- Section Posisi & Risiko
   HUNT_DASH_POSITION,               // arah/lot/entry/SL/TP/PL
   HUNT_DASH_PENDING,                // level limit + sisa bar expiry
   HUNT_DASH_FORCECLOSE,             // countdown force-close sesi
   HUNT_DASH_TODAY,                   // trade n/max + daily P/L
   //--- Section News
   HUNT_DASH_NEWS_STATE,             // status + event + countdown
   HUNT_DASH_NEWS_DESC,              // deskripsi event berikunya/terblokir
   HUNT_DASH_NEWS_UPDATED,           // waktu fetch terakhir
   //--- Section Performa (riwayat transaksi EA)
   HUNT_DASH_PERF_SUMMARY,           // win rate | avgR | total (lookback)
   HUNT_DASH_PERF_T1,                // trade terakhir -3
   HUNT_DASH_PERF_T2,                // trade terakhir -2
   HUNT_DASH_PERF_T3,                // trade terakhir -1
   HUNT_DASH_ROWS_TOTAL              // = jumlah baris; WAJIB terakhir
  };

//=== Kategori ledger objek renderer ==================================
enum ENUM_HUNT_LEDGER
  {
   HUNT_LED_OR = 0,   // HUNT_OR_*
   HUNT_LED_OB,       // HUNT_OB_*
   HUNT_LED_FVG,      // HUNT_FVG_*
   HUNT_LED_STR,      // HUNT_STR_*
   HUNT_LED_SWP,      // HUNT_SWP_*
   HUNT_LED_ENT,      // HUNT_ENT_*
   HUNT_LED_PIV,      // HUNT_PIV_*
   HUNT_LED_VP,       // HUNT_VP_*
   HUNT_LED_NEWS,     // HUNT_NEWS_*
   HUNT_LED_SESS,     // HUNT_SESS_* (v1.13 band latar)
   HUNT_LED_COUNT
  };

//--- entri ledger: satu nama objek per baris, berkategori (hapus presisi,
//--- tanpa ObjectsDeleteAll; array of array tidak didukung MQL5 → flat)
struct SLedgerEntry
  {
   int               category;   // ENUM_HUNT_LEDGER
   string            name;
   datetime          expireTime; // 0 = tidak auto-expire
  };

//=== Struktur data bersama =============================================

//--- Opening Range satu sesi (waktu dlm RUANG WAKTU BROKER/TimeCurrent) --
struct SOpenRange
  {
   //--- identitas & waktu
   ENUM_HUNT_SESSION session;
   datetime          sessionStart;    // awal sesi (broker)
   datetime          sessionEnd;      // akhir sesi (batas force-close)
   datetime          rangeEnd;        // sessionStart + InpRangeMinutes
   //--- nilai range
   double            high;
   double            low;
   int               bars;            // bar closed selama jendela OR
   //--- status
   bool              formed;          // jendela OR selesai
   bool              sizeOk;          // lolos filter InpMinRangePips
   ENUM_ORB_STATUS   status;
   datetime          breakoutTime;
   double            breakoutPrice;
   ENUM_HUNT_DIR     breakoutDir;
   int               barsSinceBreakout; // utk expiry/invalidasi berbasis bar
   //--- Reset
   void              Reset(void)
     {
      session=(ENUM_HUNT_SESSION)HUNT_SESSION_NONE;
      sessionStart=0; sessionEnd=0; rangeEnd=0;
      high=0.0; low=0.0; bars=0;
      formed=false; sizeOk=false;
      status=ORB_STATUS_NONE;
      breakoutTime=0; breakoutPrice=0.0;
      breakoutDir=HUNT_DIR_NONE; barsSinceBreakout=0;
     }
  };

//--- Swing point (confirmed hanya setelah lookback kanan closed) ------
struct SSwingPoint
  {
   datetime          time;
   double            price;
   ENUM_HUNT_DIR     type;            // BUY=swing high, SELL=swing low (sisi yg dipatahkan)
   ENUM_HUNT_SWING_LABEL label;
   bool              confirmed;       // right-side lookback terpenuhi
  };

//--- Liquidity pool (cluster equal highs / equal lows) -----------------
struct SLiquidityPool
  {
   double            level;           // harga klaster
   int               touches;         // jumlah wick yang menyamai level
   datetime          firstTime;
   datetime          lastTouchTime;
   bool              abovePrice;      // true=equal highs (diatas), false=equal lows
   bool              swept;
   datetime          sweptTime;
   double            sweptExtreme;    // wick ekstrem saat sweep
  };

//--- Break of structure / change of character --------------------------
struct SStructureEvent
  {
   ENUM_HUNT_STRUCT_TYPE kind;
   ENUM_HUNT_DIR         dir;         // arah pematahan
   datetime              time;
   double                price;       // level swing yang dipatahkan
   int                   chartIndex;  // utk anchor objek (bar time dipakai utk render)
  };

//--- Zona unifikasi OB + FVG (satu pipeline retest/mitigasi) ----------
struct SZone
  {
   ulong             id;              // auto-increment, utk link objek/ledger
   ENUM_HUNT_ZONE_TYPE type;
   double            top;
   double            bottom;
   datetime          createdTime;     // bar origin (OB candle / gap candle tengah)
   datetime          extendTime;      // ujung kanan render (diperpanjang s/d aktif)
   ENUM_HUNT_ZONE_STATE state;
   int               retestCount;
   datetime          lastTouchTime;
   bool              usedForEntry;    // sudah dipakai entry → tidak dipakai ulang
  };

//--- Hasil deteksi breakout (ORBDetector → ConfluenceValidator) -------
struct SBreakout
  {
   ENUM_HUNT_SESSION session;
   ENUM_HUNT_DIR     dir;
   datetime          time;
   double            closePrice;      // body-close yang menembus level
   double            levelBroken;     // high/low OR yang ditembus
   double            rangeSizePips;
   bool              bodyClose;       // false = wick-only → TIDAK valid
   bool              valid;
   string            rejectReason;
  };

//--- Snapshot konteks SMC utk validator (decoupling antar modul) -------
struct SSMCContext
  {
   ENUM_HUNT_BIAS    htfBias;
   bool              sweptInDirection; // pool searah breakout sudah di-sweep
   datetime          sweepTime;
   bool              bosSinceSweep;    // struktur patah searah setelah sweep
   bool              zoneFound;
   ENUM_HUNT_ZONE_TYPE zoneType;
   double            zoneTop;
   double            zoneBottom;
   ulong             zoneId;
   bool              zoneFresh;        // zona dibuat ≤ N bar lalu
   bool              rangeBigAtr;      // OR > 2×ATR (kualitas volatilitas)
   double            extensionPct;     // % range yang sudah ditempuh saat ini
   double            rsi;              // info dashboard; bukan gate kecuali diminta
   bool              rsiExtreme;       // overbought/oversold searah breakout
   bool              inducementSwept;  // v1.07: minor liq tersapu pra-break
   bool              pricePosOk;       // v1.07: zona di discount/premium range hari
  };

//+------------------------------------------------------------------+
//| Event CHoCH HTF (bias reversal) — dikonsumsi main utk cancel setup.  |
//+------------------------------------------------------------------+
struct SChochEvent
  {
   datetime        time;          // waktu bar HTF close yg mematahkan ref
   double          price;         // level referensi yg dipatahkan
   ENUM_HUNT_DIR   fromDir;       // arah bias lama
   ENUM_HUNT_DIR   toDir;         // arah bias baru
   void            Reset(void)
     {
      time=0; price=0.0; fromDir=HUNT_DIR_NONE; toDir=HUNT_DIR_NONE;
     }
  };

//--- Rencana trade lengkap (dibuat validator, dieksekusi TradeExecutor) |
struct SSignalPlan
  {
   ulong             planId;
   ENUM_HUNT_SESSION session;
   ENUM_HUNT_DIR     dir;
   ENUM_ENTRY_MODE   mode;
   // --- level
   double            entry;           // market: harga saat kirim; pending: level limit
   double            sl;
   double            tp1;
   double            tp2;
   double            slDistPips;
   double            rrFinal;         // ke TP2
   double            lots;
   // --- asal-usul & tracking
   datetime          breakoutTime;
   ulong             zoneId;
   double            zoneTopSnap;       // snapshot tepi zona utk retest/SL
   double            zoneBottomSnap;
   int               score;           // confluence 0..100
   datetime          validUntilBarTime; // expiry berbasis bar (retest/pendng)
   ulong             pendingTicket;   // 0 bila belum/market mode
   bool              submitted;
   bool              partialDone;     // TP1 partial sudah dieksekusi
   string            note;
   void              Reset(void)
     {
      planId=0; session=(ENUM_HUNT_SESSION)HUNT_SESSION_NONE;
      dir=HUNT_DIR_NONE; mode=ENTRY_EXECUTION;
      entry=0.0; sl=0.0; tp1=0.0; tp2=0.0;
      slDistPips=0.0; rrFinal=0.0; lots=0.0;
      breakoutTime=0; zoneId=0; score=0;
      zoneTopSnap=0.0; zoneBottomSnap=0.0;
      validUntilBarTime=0; pendingTicket=0; submitted=false;
      partialDone=false; note="";
     }
  };

//--- Tag ticket → sesi asal (force-close per sesi) --------------------
struct STicketTag
  {
   ulong             ticket;          // posisi atau order ticket
   ENUM_HUNT_SESSION session;
   ENUM_HUNT_DIR     dir;
   datetime          openTime;
   ulong             planId;
  };

//--- Event news hasil parsing kalender --------------------------------
//--- timeUtc  : waktu event hasil feed (tz sesuai permintaan API, ± shift input)
//--- timeBroker/blockFrom/blockTo : dikonversi ke ruang waktu broker utk
//---     perbandingan TimeCurrent() & render vline (konsisten dgn sesi).
struct SNewsEvent
  {
   datetime          timeUtc;
   datetime          timeBroker;
   string            currency;
   string            title;
   string            desc;          // v1.14: deskripsi singkat (katalog internal)
   ENUM_HUNT_NEWS_IMPACT impact;
   bool              relevant;        // lolos filter currency+impact
   datetime          blockFrom;       // timeBroker - InpNewsBufferBeforeMin
   datetime          blockTo;         // timeBroker + InpNewsBufferAfterMin
  };

//--- Status news utk dashboard & gate entry ----------------------------
struct SNewsStatus
  {
   bool              enabled;
   bool              hasData;         // ada cache valid
   bool              stale;           // fetch gagal & cache > batas
   bool              blockedNow;
   string            blockedEvent;    // "USD · FOMC · dlm 12m"
   datetime          lastFetchUtc;
   datetime          nextEventUtc;
   string            nextInfo;        // v1.14: "CUR HH:MM title — desc" utk dashboard
   int               eventCount;      // relevan hari ini ( utk render )
  };

//--- Laporan confluence ------------------------------------------------
struct SConfluenceReport
  {
   bool              passed;
   int               score;           // 0..100
   int               reasonCount;
   string            reasons[HUNT_REASONS_MAX]; // alasan penolakan/catatan
  };

//--- Volume profile satu sesi ------------------------------------------
struct SVolBin
  {
   double            priceLow;
   double            priceHigh;
   long              volume;          // tick-volume bar yang jatuh di bin
  };
struct SVolumeProfile
  {
   bool              valid;
   SVolBin           bins[HUNT_VOLPROFILE_BINS];
   int               binCount;
   double            poc;             // price of control
   double            vah;             // value area high (70%)
   double            val;             // value area low
   double            maxVol;
   datetime          windowFrom;
   datetime          windowTo;
  };

//--- Pivot harian standar (S1..R3 dari HLC hari sebelumnya) ------------
struct SPivotSet
  {
   bool              valid;
   datetime          dayUtc;          // hari trading yang memakai pivot ini
   double            pp;
   double            r1, r2, r3;
   double            s1, s2, s3;
  };

//=== Helper konversi (inline, tanpa state) =============================
//--- Selisih harga → pips (pipSize disuplai settings; multi-pair aman) --
double HUNT_PriceToPips(const double diff,const double pipSize)
  {
   if(pipSize<=0.0)
      return(0.0);
   return(diff/pipSize);
  }
//--- Pips → jarak harga --------------------------------------------------
double HUNT_PipsToPrice(const double pips,const double pipSize)
  {
   return(pips*pipSize);
  }
//--- Persentase extension (hindari div-by-zero) --------------------------
double HUNT_PctOfRange(const double movePts,const double rangePts)
  {
   if(rangePts<=0.0)
      return(0.0);
   return(100.0*movePts/rangePts);
  }

#endif // ORB_SMC_HUNTER_DEFINES_MQH
//+------------------------------------------------------------------+
