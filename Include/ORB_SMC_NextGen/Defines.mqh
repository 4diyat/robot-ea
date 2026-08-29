//+------------------------------------------------------------------+
//| ORB_SMC_NextGen — Defines.mqh                                   |
//| Modul inti: enum, konstanta, prefix objek chart, palet warna    |
//| terpusat, struct bersama, dan helper pip/point multi-pair safe. |
//| ATURAN:                                                          |
//|  - modul ini TIDAK boleh meng-include modul lain                 |
//|  - TIDAK boleh mereferensikan variabel input (input dideklarasi  |
//|    SETELAH include ini di file utama) — fungsi yang butuh input  |
//|    (EAMagic, GetATR) ada di Helpers.mqh                          |
//+------------------------------------------------------------------+
#ifndef ORBSMC_DEFINES_MQH
#define ORBSMC_DEFINES_MQH

//--- Identitas EA
#define EA_TITLE            "ORB_SMC_NextGen"
#define EA_VERSION          "1.00"
#define EA_COMMENT_BASE     "ORBSMC"    // komentar order (jaga pendek; sesi disisipkan saat eksekusi)

//--- Indeks sesi
#define SESS_ASIA           0
#define SESS_LONDON         1
#define SESS_NY             2
#define SESS_COUNT          3
#define SESS_NONE           (-1)

//--- Kapasitas koleksi (anti overflow / array out of range)
#define MAX_SWINGS          200
#define MAX_LIQ_POOLS       32
#define MAX_ORDER_BLOCKS    64
#define MAX_FVGS            64
#define MAX_STRUCT_EVENTS   128
#define MAX_NEWS_EVENTS     256
#define MAX_TRACKED         64
#define MAX_DASH_ROWS       64

//--- State machine EA (state tersimpan PER SESI, bukan satu global)
enum ENUM_EA_STATE
  {
   STATE_IDLE = 0,              // tidak ada sesi aktif / setup batal / sudah force-close
   STATE_RANGE_FORMING,         // OR sedang dibentuk (menit pertama sesi)
   STATE_WAITING_BREAKOUT,      // OR final — menunggu breakout valid
   STATE_BREAKOUT_CONFIRMED,    // breakout lolos ORBDetector — menunggu validasi confluence
   STATE_WAITING_RETEST,        // confluence lolos — menunggu retest OB/FVG (atau limit terpasang)
   STATE_READY_ENTRY,           // retest tervalidasi — kirim market order (mode EXECUTION)
   STATE_TRADED                 // sudah entry di sesi ini — kelola posisi
  };

//--- Enum bersama
enum ENUM_BREAK_DIR    { BREAK_NONE = 0, BREAK_UP, BREAK_DOWN };
enum ENUM_BIAS         { BIAS_NEUTRAL = 0, BIAS_BULLISH, BIAS_BEARISH };
enum ENUM_ENTRY_MODE   { ENTRY_EXECUTION = 0, ENTRY_PENDING_ORDER };
enum ENUM_RANGE_STATUS { RANGE_NONE = 0, RANGE_RANGING, RANGE_BREAKOUT_UP, RANGE_BREAKOUT_DOWN };
enum ENUM_ZONE_TYPE    { ZONE_NONE = 0, ZONE_ORDER_BLOCK, ZONE_FVG };
enum ENUM_SWING_TYPE   { SWING_HIGH = 0, SWING_LOW };
enum ENUM_STRUCT_EVENT { STRUCT_NONE = 0, STRUCT_BOS, STRUCT_CHOCH };
enum ENUM_NEWS_IMPACT  { IMPACT_NONE = 0, IMPACT_LOW = 1, IMPACT_MEDIUM = 2, IMPACT_HIGH = 3 };
enum ENUM_RISK_BASE    { RISK_BASE_BALANCE = 0, RISK_BASE_EQUITY };   // basis % risiko per trade

//--- Prefix objek chart (unik per kategori — JANGAN diubah setelah live,
//--- supaya objek versi lama tetap bisa dibersihkan oleh EA yang sama)
#define PREFIX_ALL      "ORBSMC_"
#define PREFIX_RANGE    "ORBSMC_RANGE_"
#define PREFIX_OB       "ORBSMC_OB_"
#define PREFIX_FVG      "ORBSMC_FVG_"
#define PREFIX_STRUCT   "ORBSMC_STRUCT_"
#define PREFIX_SWEEP    "ORBSMC_SWEEP_"
#define PREFIX_ENTRY    "ORBSMC_ENTRY_"
#define PREFIX_PIVOT    "ORBSMC_PIVOT_"
#define PREFIX_VP       "ORBSMC_VP_"
#define PREFIX_NEWS     "ORBSMC_NEWS_"
#define PREFIX_DASH     "ORBSMC_DASH_"

//--- Palet warna terpusat (dipakai chart + dashboard agar konsisten)
#define CLR_ASIA        C'48,148,210'   // biru — sesi Asia
#define CLR_LONDON      C'225,130,40'   // oranye — sesi London
#define CLR_NY          C'150,95,205'   // ungu — sesi New York
#define CLR_BULL        C'0,160,120'    // hijau bullish
#define CLR_BEAR        C'225,65,85'    // merah bearish
#define CLR_BULL_DIM    C'95,170,150'
#define CLR_BEAR_DIM    C'205,120,130'
#define CLR_NEUTRAL     C'150,152,158'
#define CLR_TEXT        C'232,234,238'
#define CLR_TEXT_DIM    C'165,168,174'
#define CLR_PANEL_BG    C'16,20,28'
#define CLR_NEWS_HIGH   C'235,70,70'
#define CLR_NEWS_MED    C'235,165,60'
#define CLR_SWEEP       C'255,0,190'    // magenta — penanda liquidity sweep
#define CLR_READY       C'70,215,90'    // state Ready entry — SAMA dengan warna panah entry
#define CLR_BOS         C'0,185,225'    // cyan — BOS
#define CLR_CHOCH       C'255,160,0'    // oranye terang — CHoCH
#define CLR_OB_BULL     C'45,190,160'
#define CLR_OB_BEAR     C'235,95,105'
#define CLR_FVG_BULL    C'120,200,90'
#define CLR_FVG_BEAR    C'235,120,60'
#define CLR_PIVOT       C'140,145,155'
#define CLR_POC         C'255,215,90'   // emas — POC paling menonjol
#define CLR_VAH_VAL     C'200,150,240'  // VAH/VAL

//+------------------------------------------------------------------+
//| Referensi zona retest (OB atau FVG) — alur: SMC → Confluence →   |
//| Risk (penempatan SL/entry). Satu struct bersama agar tidak ada   |
//| duplikasi definisi antar modul.                                  |
//+------------------------------------------------------------------+
struct SRetestZone
  {
   ENUM_ZONE_TYPE  type;         // ZONE_ORDER_BLOCK / ZONE_FVG
   datetime        originTime;   // waktu candle asal zona
   int             originIndex;  // index candle asal (referensi internal SMCEngine)
   double          top;          // batas atas zona
   double          bottom;       // batas bawah zona
   bool            active;       // masih valid (belum dimitigasi / belum ter-fill penuh)
   bool            touched;      // retest sudah menyentuh zona
   datetime        touchTime;    // waktu sentuhan pertama
   double          entryPrice;   // level entry yang disarankan (sesuai mode entry)
  };

//+------------------------------------------------------------------+
//| PipSize() — ukuran 1 pip untuk simbol aktif (multi-pair safe).   |
//| Konvensi: FX 3/5-digit & XAU 2-digit → 1 pip = 10 point;         |
//| indeks 0/1-digit (US30, GER40) → 1 pip = 1 point.                |
//+------------------------------------------------------------------+
double PipSize()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return (digits == 2 || digits == 3 || digits == 5) ? 10.0 * _Point : _Point;
  }
//+------------------------------------------------------------------+
//| pips → selisih harga                                             |
//+------------------------------------------------------------------+
double PipsToPrice(double pips)
  {
   return pips * PipSize();
  }
//+------------------------------------------------------------------+
//| selisih harga → pips                                             |
//+------------------------------------------------------------------+
double PriceToPips(double priceDiff)
  {
   double ps = PipSize();
   return (ps > 0.0) ? priceDiff / ps : 0.0;
  }
//+------------------------------------------------------------------+
//| Format harga sesuai digit simbol (label chart/dashboard)         |
//+------------------------------------------------------------------+
string FmtPrice(double v)
  {
   return DoubleToString(v, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
  }
//+------------------------------------------------------------------+
//| Format jam:menit dari datetime (label news, dashboard)           |
//+------------------------------------------------------------------+
string TimeHHMM(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return StringFormat("%02d:%02d", dt.hour, dt.min);
  }
//+------------------------------------------------------------------+
//| Detik → "HH:MM:SS" (atau "MM:SS" bila < 1 jam)                   |
//+------------------------------------------------------------------+
string FormatClock(int seconds)
  {
   if(seconds < 0)
      seconds = 0;
   int h = seconds / 3600;
   int m = (seconds % 3600) / 60;
   int s = seconds % 60;
   if(h > 0)
      return StringFormat("%02d:%02d:%02d", h, m, s);
   return StringFormat("%02d:%02d", m, s);
  }

#endif // ORBSMC_DEFINES_MQH
