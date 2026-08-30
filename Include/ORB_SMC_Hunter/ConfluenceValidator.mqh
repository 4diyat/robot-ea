//+------------------------------------------------------------------+
//|                                          ConfluenceValidator.mqh |
//| Gate tunggal antara "breakout terdeteksi" dan "boleh entry".     |
//| Menggabungkan hasil ORBDetector + snapshot SSMCContext + status   |
//| news + status risk jadi satu SConfluenceReport (pass + skor +     |
//| alasan). Validator TIDAK memanggil modul lain (loose coupling —  |
//| EA utama merakit ctx lalu memanggil Review()).                    |
//|                                                                  |
//| Gate keras (hard, semua wajib lolos):                             |
//|   G1 breakout valid (body close, min range, bukan false breakout) |
//|   G2 arah searah bias HTF                                          |
//|   G3 liquidity searah sudah di-sweep (bila InpRequireLiquiditySweep)|
//|   G4 zona OB/FVG tersedia utk retest (requireRetest — tidak ada   |
//|      direct breakout entry, selalu)                                |
//|   G5 tidak dalam window blokir news                                |
//|   G6 spread <= maxSpreadPips                                       |
//|   G7 risk manager mengizinkan (max trades / daily loss)           |
//| Skor konfluensi (lunak, >= minScore utk lolos):                    |
//|   +25 sweep presisi (|wick-| kecil) +20 BOS/CHoCH setelah sweep   |
//|   +15 zona fresh (<=3 bar)         +15 range sehat (>2×ATR sesi)  |
//|   +10 extension masih kecil        +10 tidak di RSI ekstrem arah   |
//|   + 5 sesi London/NY (likuiditas)                                   |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_CONFLUENCEVALIDATOR_MQH
#define ORB_SMC_HUNTER_CONFLUENCEVALIDATOR_MQH

#include "HunterSettings.mqh"

class CConfluenceValidator
  {
private:
   SHunterSettings     m_cfg;

   /** Hitung skor 0..100 + isi reasons penolakan/catatan. */
   int                 ComputeScore(const SBreakout &bo,const SSMCContext &smc,
                                    SConfluenceReport &rep) const;
   /** Tambah alasan (guard kapasitas array). */
   void                AddReason(SConfluenceReport &rep,const string why) const;

public:
   bool              Init(const SHunterSettings &cfg);

   /** Evaluasi kandidat breakout → laporan gate+skor.
       @param blockedByNews   flag dari NewsFilter.IsEntryBlocked()
       @param spreadPips      spread real-time
       @param riskOk          flag dari RiskManager.CanOpenNew()
       @param riskNote        alasan bila riskOk=false */
   SConfluenceReport Review(const SBreakout &bo,
                            const SSMCContext &smc,
                            const bool blockedByNews,
                            const double spreadPips,
                            const bool riskOk,
                            const string riskNote) const;

   /** Evaluasi ulang ringan utk fase WAITING_RETEST (cegah entry bila
       kondisi memburuk: zona hilang/invalid, extension kelewat).
       @return true masih layak. */
   bool              StillValid(const SSignalPlan &plan,const SSMCContext &smcNow) const;
  };

#endif // ORB_SMC_HUNTER_CONFLUENCEVALIDATOR_MQH
//+------------------------------------------------------------------+
