//+------------------------------------------------------------------+
//|                                              VisualRenderer.mqh  |
//| Render 9 kategori elemen chart. Prinsip:                            |
//|  - Nama objek: PREFIX + id stabil (mis. "HUNT_OB_17") — ledger    |
//|    internal menyimpan nama yang dibuat; penghapusan SELALU        |
//|    per-objek via ObjectDelete berdasarkan ledger, TIDAK pernah     |
//|    ObjectsDeleteAll (risiko menyentuh objek user lain).            |
//|  - Layer statis (range, OB, FVG, struktur, pivot, volume profile): |
//|    rebuild hanya saat bar baru / event, bukan per tick.             |
//|  - News marker: rebuild hanya saat NewsFilter.refresh;             |
//|    event yang sudah lewat + melampaui jendela display dihapus.      |
//|  - Pivot & Volume Profile dihitung ulang awal hari/sesi saja.      |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_VISUALRENDERER_MQH
#define ORB_SMC_HUNTER_VISUALRENDERER_MQH

#include "HunterSettings.mqh"
#include "SessionManager.mqh"
#include "SMCEngine.mqh"

class CVisualRenderer
  {
private:
   SHunterSettings     m_cfg;
   int                 m_chart;
   //--- ledger flat (category,name) — MQL5 tak mendukung array-of-array
   SLedgerEntry        m_ledger[];

   /** Daftar nama baru ke ledger kategori (idempoten via ObjectFind). */
   void                LedgerAdd(const int category,const string name,
                                 const datetime expireTime=0);
   /** Hapus semua objek terdaftar satu kategori (+kembali ke ledger). */
   void                LedgerClear(const int category);
   /** helper create/anchor garis, kotak, teks, panah (OBJPROP_* standar) */
   void                DrawTimeLine(const string name,const datetime t1,const double p1,
                                    const datetime t2,const double p2,const color clr,
                                    const int width,const ENUM_LINE_STYLE style,const bool back);
   void                DrawZoneBox(const string name,const datetime t1,const double p1,
                                   const datetime t2,const double p2,const color fill,
                                   const color border,const bool dashed);
   void                DrawTextLabel(const string name,const datetime t,const double p,
                                      const string text,const color clr,const int fsize,
                                      const ENUM_ANCHOR_TYPE anchor);
   void                DrawArrow(const string name,const datetime t,const double p,
                                  const int code,const color clr,const string subText);

   /** Volume profile: histogram bin harga dari tick-volume bar closed
       dlm jendela sesi berjalan (approximasi per-bar, BUKAN per-tick —
       trade-off: murah & deterministik vs presisi tick-level). */
   void                ComputeVolumeProfile(const CSessionManager &sessions,
                                            const CDataService &data,
                                            const int session,SVolumeProfile &vp) const;
   /** Pivot standar dari HLC hari sebelumnya (closed). */
   void                ComputeDailyPivot(const CDataService &data,
                                         const datetime dayUtc,SPivotSet &pv) const;

public:
                     CVisualRenderer(void) : m_chart(0) { ArrayFree(m_ledger); }

   bool              Init(const SHunterSettings &cfg);

   //--- update berkala (dipanggil pipeline per bar baru) -------------------
   /** Garis OR per sesi (high/low dibatasi rentang waktu sesi, warna per
       sesi, hapus otomatis saat sesi berikutnya mulai). */
   void              RenderOpeningRanges(const CSessionManager &sessions,const datetime nowUtc);
   /** Kotak OB + FVG dari engine; hapus saat mitigated/invalid/filled. */
   void              RenderZones(const CSMCEngine &smc);
   /** Label HH/HL/LH/LL + penanda BOS vs CHoCH (warna beda). */
   void              RenderStructure(const CSMCEngine &smc);
   /** Panah di wick yang menyapu pool equal high/low. */
   void              RenderSweeps(const CSMCEngine &smc);
   /** Panah + label entry/SL/TP/RR pada plan & fill. */
   void              RenderEntryMarker(const SSignalPlan &plan,const datetime fillTime,
                                       const double fillPrice);
   /** Pivot PP/R1-3/S1-3 + label ujung kanan (recompute awal hari). */
   void              RenderPivots(const CDataService &data,const datetime dayUtc);
   /** Histogram VP + garis VAH/VAL/POC (recompute awal sesi). */
   void              RenderVolumeProfile(const CSessionManager &sessions,
                                         const CDataService &data,const datetime nowUtc);
   /** Vline event + label + shading window blokir (dipanggil HANYA saat
       news refresh — jangan per tick). */
   void              RenderNews(const SNewsEvent &events[],const int count,
                                const datetime nowUtc);

   /** Bersihkan objek expired (zona invalid, news lewat, range sesi lalu). */
   void              CleanupExpired(const CSMCEngine &smc,const CSessionManager &sessions,
                                     const datetime nowUtc);

   /** OnDeinit + reload safety: hapus SEMUA objek berprefix HUNT_* milik
       EA (iterasi ledger, fallback scan prefix via ObjectsTotal, bukan
       ObjectsDeleteAll global). */
   void              ClearAllOwned(const bool fullLedgerRebuild=true);
   /** Total objek milik EA (diagnostics dashboard). */
   int               OwnedObjectCount(void) const;
  };

#endif // ORB_SMC_HUNTER_VISUALRENDERER_MQH
//+------------------------------------------------------------------+
