//+------------------------------------------------------------------+
//|                                                    SMCEngine.mqh |
//| Smart Money Concepts — SEMUA kalkulasi berbasis closed bar:     |
//|  - Swing high/low detection (fractal lookback; konfirmasi butuh   |
//|    `swingLookback` bar SETELAH swing → tanpa lookahead bias);     |
//|  - Liquidity pool: klaster equal highs / equal lows (toleransi    |
//|    pips), status swept saat wick menembus & close kembali;        |
//|  - Market structure: HH/HL/LH/LL + BOS vs CHoCH;                  |
//|  - Bias HTF dari struktur timeframe InpHTF (H4 default);         |
//|  - Order block: candle berlawanan terakhir sebelum displacement   |
//|    ≥ obDisplacementAtr × ATR;                                      |
//|  - FVG: gap 3 candle (low[0]>high[2] bull / high[0]<low[2] bear). |
//| OB & FVG disimpan TERSEDIA di satu array SZone agar pipeline      |
//| retest/mitigasi/expiry cukup satu jalur kode.                     |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_SMCENGINE_MQH
#define ORB_SMC_HUNTER_SMCENGINE_MQH

#include "DataService.mqh"

class CSMCEngine
  {
private:
   SHunterSettings     m_cfg;
   datetime            m_fromTime;        // batas kiri jendela kalkulasi
   //--- koleksi (dikelola dengan kapasitas maks Defines)
   SSwingPoint         m_swings[HUNT_MAX_SWINGS];
   int                 m_swingCount;
   ulong               m_swingSeq;
   SLiquidityPool      m_pools[HUNT_MAX_POOLS];
   int                 m_poolCount;
   SStructureEvent     m_struct[HUNT_MAX_STRUCT];
   int                 m_structCount;
   SZone               m_zones[HUNT_MAX_ZONES];
   int                 m_zoneCount;
   ulong               m_zoneSeq;        // id generator zona
   ENUM_HUNT_BIAS      m_biasHtf;
   datetime            m_biasHtfTime;     // waktu event struktur terakhir
   int                 m_lastHtfBarProcessed;

   /** Scan ulang swing closed di jendela data → append ke m_swings[]. */
   void                DetectSwings(const CDataService &data);
   /** Klasterisasi swing jadi pool + deteksi sweep oleh bar closed. */
   void                UpdatePools(const CDataService &data);
   /** Bangun ulang label HH/HL/LH/LL + event BOS/CHoCH dari m_swings[]. */
   void                UpdateStructure(const CDataService &data);
   /** Update bias HTF hanya saat bar HTF baru closed. */
   void                UpdateHtfBias(const CDataService &data);
   /** Deteksi OB displacement pada bar closed terakhir (bullish utk dir BUY). */
   bool                DetectOrderBlock(const CDataService &data,const int back,
                                         const ENUM_HUNT_DIR dir,SZone &out);
   /** Deteksi FVG 3-candle pada posisi back (back=back candle terbaru). */
   bool                DetectFvg(const CDataService &data,const int back,
                                  const ENUM_HUNT_DIR dir,SZone &out);
   /** Mitigasi/fill: update state semua zona terhadap bar closed baru. */
   void                UpdateZonesVsBar(const CDataService &data,const int back);
   /** Buang zona yang melewati m_fromTime / sudah invalid. */
   void                PruneCollections(const CDataService &data);
   /** Tambah zona bila belum duplikat (top/bottom/created mirip). */
   void                AddZoneUnique(SZone &z);
   /** Zona index di array utk id tsb; -1 bila tidak ada. */
   int                 ZoneIndexOf(const ulong id) const;

public:
                     CSMCEngine(void) : m_fromTime(0), m_swingCount(0), m_swingSeq(1),
                                        m_poolCount(0), m_structCount(0), m_zoneCount(0),
                                        m_zoneSeq(1), m_biasHtf(HUNT_BIAS_NONE),
                                        m_biasHtfTime(0), m_lastHtfBarProcessed(0) {}

   /** cfg + jendela warmup (bar yang dianggap utk formasi). */
   bool              Init(const SHunterSettings &cfg,const datetime windowFrom);

   /** Pipeline utama, dipanggil SATU kali per bar closed:
       swings → pools → structure → zones → mitigation update. */
   void              Update(const CDataService &data);

   //--- query utk validator/renderer --------------------------------------
   ENUM_HUNT_BIAS    HtfBias(void) const            { return(m_biasHtf); }
   string            HtfBiasText(void) const;        // "Bullish"/"Bearish"/"None"

   /** true bila pool SEARAH breakout (equal-high utk BUY) sudah di-sweep. */
   bool              IsLiquiditySwept(const ENUM_HUNT_DIR dir,const datetime since) const;
   /** Waktu sweep terbaru utk arah tsb (0 = belum ada). */
   datetime          LastSweepTime(const ENUM_HUNT_DIR dir) const;
   /** true bila event BOS/CHoCH searah terjadi setelah `since`. */
   bool              HasStructureShift(const ENUM_HUNT_DIR dir,const datetime since) const;

   /** Pilih zona aktif paling dekat dengan `price` utk arah breakout,
       terbentuk >= `from`. @return true + out terisi. */
   bool              NearestActiveZone(const ENUM_HUNT_DIR dir,const double price,
                                       const datetime from,SZone &out) const;
   /** Salin snapshot semua zona (utk renderer & review). */
   void              CopyZones(SZone &dst[]) const;
   void              CopySwings(SSwingPoint &dst[]) const;
   void              CopyPools(SLiquidityPool &dst[]) const;
   void              CopyStructure(SStructureEvent &dst[]) const;
   /** true bila zona id masih state ACTIVE. */
   bool              IsZoneActive(const ulong id) const;
   /** Tandai zona dipakai entry (hindari re-use utk setup berikutnya). */
   void              MarkZoneUsed(const ulong id);

   /** Reset semua koleksi (awal hari trading). */
   void              ResetDaily(const datetime windowFrom);
  };

#endif // ORB_SMC_HUNTER_SMCENGINE_MQH
//+------------------------------------------------------------------+
