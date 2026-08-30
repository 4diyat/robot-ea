//+------------------------------------------------------------------+
//|                                                TradeExecutor.mqh |
//| Satu-satunya modul yang menyentuh pasar. Semua order lewat CTrade |
//| (MqlTradeRequest dibangun internal CTrade — tidak manual).       |
//|                                                                  |
//|  - Magic number dari settings; komentar order "HUNT|<SESSION>"    |
//|    + ledger internal ticket→session (untuk force-close per sesi); |
//|  - retry InpOrderRetries× dgn delay utk error server transient    |
//|    (requote/busy/off quotes/conn — IsRetryableRetcode);           |
//|  - retcode dipetakan ke pesan via trade.ResultRetcodeDescription; |
//|  - ENTRY_EXECUTION     : Buy/Sell market setelah reaksi retest;   |
//|  - ENTRY_PENDING_ORDER : Buy/Sell Limit di tepi zona, SL/TP        |
//|    dipasang bersamaan (dihitung dari level limit), expiry          |
//|    BERBASIS BAR (hitung bar closed sejak pasang, bukan jam);       |
//|  - CloseSessionPositions(): hanya posisi/pending milik SESI tsb.   |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_TRADEEXECUTOR_MQH
#define ORB_SMC_HUNTER_TRADEEXECUTOR_MQH

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include "DataService.mqh"

class CTradeExecutor
  {
private:
   CTrade              m_trade;
   CPositionInfo       m_pinfo;
   COrderInfo          m_oinfo;
   SHunterSettings     m_cfg;
   //--- ledger tag posisi/order → sesi asal (ticket → tag)
   STicketTag          m_tags[64];
   int                 m_tagCount;
   //--- tracking expiry pending berbasis bar
   datetime            m_pendingPlacedBarTime;   // bar time saat order dipasang

   /** Retry-able retcode? (TRADE_RETCODE_REQUOTE, *_BUSY? via
       ResultRetcode: requote/off-quotes/conn/limit — see impl notes). */
   bool                IsRetryableRetcode(const uint code) const;
   /** Jeda retry (Sleep) + revalidasi harga sebelum percobaan ulang. */
   void                RetryWait(void) const;
   /** Log satu baris hasil order: op, retcode description, harga. */
   void                LogResult(const string op) const;

   /** Simpan/refresh tag utk satu ticket. */
   void                Tag(const ulong ticket,const int session,
                           const ENUM_HUNT_DIR dir,const ulong planId);
   /** Ambil tag utk ticket; false bila bukan milik EA. */
   bool                TagOf(const ulong ticket,STicketTag &out) const;
   /** Buang tag (posisi tertutup / order dihapus). */
   void                Untag(const ulong ticket);
   /** Comment "HUNT|<SESSIONNAME>" utk order. */
   string              MakeComment(const int session) const;
   /** Jarak minimum SL/TP dari harga (stops level broker) dlm price units. */
   double              MinStopDistance(void) const;

public:
                     CTradeExecutor(void) : m_tagCount(0),
                                            m_pendingPlacedBarTime(0) {}

   /** Set magic, deviation (maxSlippagePoints), type filling, comment mode. */
   bool              Init(const SHunterSettings &cfg);

   //--- eksekusi -----------------------------------------------------------
   /** Mode ENTRY_EXECUTION: market Buy/Sell + SL/TP atomik via
       m_trade.Buy/Sell(volume,symbol,0,sl,tp,comment). Plan.entry diisi
       harga fill aktual (OrderInfo), utk recompute RR display.
       @return true terisi. */
   bool              OpenMarket(SSignalPlan &plan,const CDataService &data);
   /** Mode ENTRY_PENDING_ORDER: BuyLimit/SellLimit di plan.entry +
       SL/TP dihitung dari LEVEL LIMIT. @return true terpasang. */
   bool              PlacePending(SSignalPlan &plan);
   /** Hapus pending order by ticket (expiry / invalidasi / force-close). */
   bool              CancelOrder(const ulong ticket,const string why);
   /** Tutup posisi by ticket; volume=0 → penuh. */
   bool              ClosePosition(const ulong ticket,const double volume,const string why);

   //--- manajemen & sinkronisasi -------------------------------------------
   /** Sinkron ledger vs server + deteksi event lifecycle plan.
       Isi flags ENUM_HUNT_EXEC_EVENT (bitwise). Expiry pending dihitung
       dari jumlah bar closed sejak m_pendingPlacedBarTime > retestMaxBars. */
   int               Manage(const CDataService &data,SSignalPlan &activePlan);
   /** true bila ada posisi open milik magic EA. */
   bool              HasOpenPosition(void) const;
   /** true bila ada pending order milik magic EA. */
   bool              HasPendingOrders(void) const;
   /** Snapshot posisi milik EA (asumsi max 1; multi → yang pertama). */
   bool              PositionSnapshot(ulong &ticket,double &vol,double &price,
                                      double &sl,double &tp,double &pl,
                                      ENUM_HUNT_DIR &dir,int &session) const;

   /** Force-close per sesi: hanya posisi+pending dgn tag sesi == session.
       @return true bila dijalankan; nPos/nPend utk log & Alert. */
   bool              CloseSessionPositions(const int session,int &nPos,int &nPend);

   //--- query utk dashboard / validator --------------------------------------
   /** Sisa bar sebelum expiry pending (berbasis bar closed). */
   int               PendingBarsLeft(const CDataService &data) const;
   /** Floating P/L total milik magic EA (currency). */
   double            FloatingPl(void) const;
   /** true bila plan masih punya order/posisi hidup. */
   bool              IsPlanLive(const SSignalPlan &plan) const;
   /** Bersihkan tag yatim (ticket tak ada lagi di server). */
   void              ReconcileTags(void);
  };

#endif // ORB_SMC_HUNTER_TRADEEXECUTOR_MQH
//+------------------------------------------------------------------+
