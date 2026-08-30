//+------------------------------------------------------------------+
//|                                                 ORBDetector.mqh  |
//| Validasi breakout Opening Range:                                 |
//|  1. body-close menembus level OR (wick-only ditolak bila         |
//|     InpRequireBodyClose) + buffer pip opsional;                  |
//|  2. filter ukuran minimum range (min range pips, konversi pips→  |
//|     price via settings.pipSize — multi-pair aman);              |
//|  3. false-breakout filter: close kembali ke dalam range dalam     |
//|     bar setelah breakout → status INVALIDATED.                    |
//| Semua evaluasi pada CLOSED bar (shift>=1) — tanpa repaint.        |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_ORBDETECTOR_MQH
#define ORB_SMC_HUNTER_ORBDETECTOR_MQH

#include "HunterSettings.mqh"
#include "DataService.mqh"

class CORBDetector
  {
private:
   SHunterSettings     m_cfg;
   //--- memo per sesi: breakout yang sudah di-emits (jangan emit 2x)
   bool                m_emitted[HUNT_SESSION_COUNT];

   /** true bila body-close bar ke-`back` menembus level+buffer searah. */
   bool                IsBodyBreakout(const SOpenRange &or_,
                                      const CDataService &data,const int back,
                                      const ENUM_HUNT_DIR dir) const;
   /** true bila hanya wick yang menembus (body masih di dalam). */
   bool                IsWickOnlyBreach(const SOpenRange &or_,
                                        const CDataService &data,const int back,
                                        const ENUM_HUNT_DIR dir) const;
   /** Filter false-breakout: close kembali menembus balik ke dalam OR. */
   bool                IsFalseBreakout(const SOpenRange &or_,
                                       const CDataService &data,const int back) const;

public:
                     CORBDetector(void) { ArrayInitialize(m_emitted,false); }

   bool              Init(const SHunterSettings &cfg);

   /** Evaluasi 1 sesi utk bar closed terbaru. Dipanggil dari pipeline EA
       saat sesi dalam keadaan WAIT_BREAKOUT / BREAKOUT_CONFIRMED.
       @return true bila `out` terisi breakout BARU yang valid (emit sekali). */
   bool              Assess(const int session,SOpenRange &orInOut,
                            const CDataService &data,SBreakout &out);

   /** Update status ranning/breakout utk dashboard (tidak meng-emits event):
       dipanggil tiap bar closed utk sesi dengan range formed. */
   void              RefreshStatus(SOpenRange &orInOut,const CDataService &data);

   /** Reset memo emitted utk satu sesi (pemanggil baru setelah sesi habis). */
   void              Reset(const int session);
   /** Reset semua (awal hari). */
   void              ResetAll(void);
  };

#endif // ORB_SMC_HUNTER_ORBDETECTOR_MQH
//+------------------------------------------------------------------+
