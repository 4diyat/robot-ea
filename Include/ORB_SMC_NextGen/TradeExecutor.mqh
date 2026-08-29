//+------------------------------------------------------------------+
//| ORB_SMC_NextGen — TradeExecutor.mqh                              |
//| Eksekusi order via CTrade: magic number, slippage, retry pada    |
//| error trade server. Dua mode entry (InpEntryMode):               |
//|  - ENTRY_EXECUTION   : market order setelah reaksi retest valid  |
//|  - ENTRY_PENDING_ORDER: Buy/Sell Limit di tepi zona OB/FVG,      |
//|    SL/TP dipasang SEKALIGUS saat order dibuat (dihitung dari     |
//|    level pending, bukan harga market), expiry otomatis berbasis  |
//|    BAR (bukan waktu absolut).                                    |
//| Juga menangani force-close posisi/pending per sesi.              |
//|                                                                  |
//| Pelacakan internal (ticket → sesi asal → arah → lot → TP/SL):    |
//|  - MT5 mempertahankan ticket saat pending ter-fill → konversi    |
//|    otomatis dideteksi di SyncTracked().                          |
//|  - Komentar order "ORBSMC|ASIA/LDN/NY" membawa sesi asal —       |
//|    dipakai untuk recovery sesi saat EA di-restart dengan posisi  |
//|    masih terbuka, dan untuk force-close selektif per sesi.       |
//|  - Partial close di TP1 (InpPartialClosePct%) → SL ke breakeven. |
//|  - Trailing struktur setelah TP1 (InpTrailAfterTP1) — ketatkan   |
//|    SL ke struktur terdekat, hanya ke arah profit, per bar baru.  |
//| Fase 3: TERIMPLEMENTASI.                                         |
//+------------------------------------------------------------------+
#ifndef ORBSMC_TRADE_EXECUTOR_MQH
#define ORBSMC_TRADE_EXECUTOR_MQH

#include <ORB_SMC_NextGen\Defines.mqh>
#include <ORB_SMC_NextGen\Helpers.mqh>
#include <ORB_SMC_NextGen\SessionManager.mqh>
#include <ORB_SMC_NextGen\RiskManager.mqh>
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- instance global (didefinisikan di file utama)
extern CSessionManager g_sessions;
extern CSMCEngine       g_smc;
extern CRiskManager     g_risk;

//+------------------------------------------------------------------+
//| Catatan posisi/pending order milik EA (basis tracking ticket)    |
//+------------------------------------------------------------------+
struct STrackedPosition
  {
   ulong           ticket;
   bool            isOrder;          // true = pending order, false = posisi
   int             session;          // sesi asal (Asia/London/NY)
   ENUM_BREAK_DIR  dir;
   double          lots;
   double          entryPrice;
   double          sl;
   double          tp;
   double          tp1;              // level partial-close pertama (0 = off)
   datetime        openTime;         // waktu pemasangan (basis bar expiry pending)
   int             barsSinceOpen;    // counter bar (expiry pending order)
   bool            partialClosed;    // partial TP1 sudah dieksekusi
   bool            trailingActive;   // trailing SL struktur aktif
  };

//+------------------------------------------------------------------+
//| CTradeExecutor                                                   |
//+------------------------------------------------------------------+
class CTradeExecutor
  {
public:
   //--- lifecycle ---
   bool            Init();
   void            OnTick();          // monitoring posisi (tick-based, aman)
   void            OnNewBar();        // expiry pending order berbasis bar + trailing

   //--- eksekusi ---
   bool            OpenMarket(ENUM_BREAK_DIR dir, const SRiskPlan &plan, int session);
                                       // mode EXECUTION — market order + SL/TP + magic + retry
   bool            PlacePending(ENUM_BREAK_DIR dir, const SRiskPlan &plan, int session);
                                       // mode PENDING — limit di level entry + SL/TP sekaligus
   bool            DeletePending(ulong ticket);   // hapus order (expiry / invalidation / force-close)

   //--- force-close per sesi ---
   int             ForceCloseSession(int session);
                                       // tutup posisi + hapus pending milik sesi tsb → jumlah aksi
   void            PreventNewEntries(int session);
                                       // blokir entry baru sesi ini (setelah force-close)

   //--- query status (dashboard) ---
   bool            HasOpenPosition();
   bool            HasPendingOrder();
   int             GetPositionCount();
   int             GetPendingCount();
   ulong           GetPositionTicket();
   ulong           GetPendingTicket();
   double          GetFloatingPL();   // floating P/L semua posisi EA
   const STrackedPosition* GetTracked(ulong ticket);
   int             GetTrackedCount();
   const STrackedPosition& GetTrackedAt(int i);
   bool            SessionHasPosition(int session);
   bool            SessionHasPending(int session);

   //--- informasi posisi untuk dashboard ---
   bool            GetPositionInfo(ulong ticket, string &dir, double &lots, double &entry,
                                   double &sl, double &tp, double &profit, double &profitPct);

private:
   CTrade          m_trade;           // Standard Library
   CPositionInfo   m_posInfo;
   COrderInfo      m_ordInfo;
   STrackedPosition m_tracked[MAX_TRACKED];
   int             m_trackedCount;
   bool            m_sessionEntryBlocked[SESS_COUNT]; // blokir entry baru per sesi
   bool            m_initOk;

   void            SyncTracked();                    // sinkronkan tracking dgn server (posisi/order aktual)
   int             FindTracked(ulong ticket);        // index pelacakan / -1
   void            AddTracked(ulong ticket, bool isOrder, int session, ENUM_BREAK_DIR dir,
                              double lots, double entry, double sl, double tp, double tp1,
                              datetime openTime, int barsSinceOpen);
   void            RemoveTracked(int index);
   bool            IsEAMagic(ulong magic);           // magic milik EA
   bool            SendOrderWithRetry(bool isMarket, ENUM_BREAK_DIR dir, double price, double sl,
                                      double tp, double lots, int session, string comment,
                                      ulong &ticket);
                                       // retry max InpOrderRetries + log alasan gagal per percobaan
   string          BuildOrderComment(int session);
                                       // EA_COMMENT_BASE + "|" + SessionShortName
   bool            CheckEntryBlocked(int session);   // gate internal sebelum order
   int             ParseSessionFromComment(const string &comment);
   double          NormalizeCloseLots(double lots);  // lots untuk partial close
  };

//+------------------------------------------------------------------+
//| Inisialisasi — konfigurasi CTrade + sinkron awal                 |
//+------------------------------------------------------------------+
bool CTradeExecutor::Init()
  {
   for(int s = 0; s < SESS_COUNT; s++)
      m_sessionEntryBlocked[s] = false;
   m_trackedCount = 0;
   ZeroMemory(m_tracked);

   m_trade.SetExpertMagicNumber(EAMagic());
   m_trade.SetDeviationInPoints(InpMaxSlippagePoints);
   m_trade.SetTypeFillingBySymbol(_Symbol);

   SyncTracked();   // recovery posisi/pending yang sudah ada (EA restart)
   m_initOk = true;
   return m_initOk;
  }
//+------------------------------------------------------------------+
//| Monitoring per tick: sinkron server, partial close TP1,          |
//| breakeven setelah TP1.                                           |
//+------------------------------------------------------------------+
void CTradeExecutor::OnTick()
  {
   if(!m_initOk)
      return;

   SyncTracked();

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = 0; i < m_trackedCount; i++)
     {
      STrackedPosition &t = m_tracked[i];
      if(t.isOrder)
         continue;

      // --- partial close di TP1 + SL ke breakeven ---
      if(!t.partialClosed && t.tp1 > 0.0)
        {
         bool hit = (t.dir == BREAK_UP) ? (bid >= t.tp1) : (ask <= t.tp1);
         if(hit)
           {
            double closeLots = NormalizeCloseLots(t.lots * InpPartialClosePct / 100.0);
            if(closeLots > 0.0 && closeLots < t.lots)
              {
               m_trade.SetDeviationInPoints(InpMaxSlippagePoints);
               if(m_trade.PositionClosePartial(t.ticket, closeLots))
                 {
                  t.partialClosed = true;
                  double newSL = t.entryPrice;   // breakeven (CTrade normalisasi)
                  m_trade.PositionModify(t.ticket, newSL, t.tp);
                  t.sl = newSL;
                  Print(EA_TITLE, " : TP1 tercapai — partial close ", DoubleToString(closeLots, 2),
                        " lot, SL → breakeven (", g_sessions.SessionName(t.session), ")");
                 }
               else
                  Print(EA_TITLE, " : partial close gagal — retcode ", m_trade.ResultRetcode());
              }
           }
        }
     }
  }
//+------------------------------------------------------------------+
//| Tiap bar baru: expiry pending order berbasis bar + trailing      |
//+------------------------------------------------------------------+
void CTradeExecutor::OnNewBar()
  {
   if(!m_initOk)
      return;

   // 1) expiry pending (berbasis jumlah bar baru, konsisten dgn invalidasi retest)
   for(int i = m_trackedCount - 1; i >= 0; i--)
     {
      STrackedPosition &t = m_tracked[i];
      if(!t.isOrder)
         continue;
      t.barsSinceOpen++;
      if(InpRetestMaxBars > 0 && t.barsSinceOpen >= InpRetestMaxBars)
        {
         if(DeletePending(t.ticket))
           {
            Print(EA_TITLE, " : pending order ", t.ticket, " expired (", t.barsSinceOpen,
                  " bar) — dihapus (", g_sessions.SessionName(t.session), ")");
            RemoveTracked(i);
           }
        }
     }

   // 2) trailing struktur setelah TP1 (hanya ketatkan SL)
   if(!InpTrailAfterTP1)
      return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = 0; i < m_trackedCount; i++)
     {
      STrackedPosition &t = m_tracked[i];
      if(t.isOrder || !t.partialClosed)
         continue;
      double ref = (t.dir == BREAK_UP) ? bid : ask;
      double newSL = g_smc.GetStructStopLevel(t.dir, ref);
      if(newSL <= 0.0)
         continue;
      bool tighten = (t.dir == BREAK_UP) ? (newSL > t.sl) : (newSL < t.sl);
      if(tighten)
        {
         m_trade.SetDeviationInPoints(InpMaxSlippagePoints);
         if(m_trade.PositionModify(t.ticket, newSL, t.tp))
           {
            Print(EA_TITLE, " : trailing SL struktur → ", FmtPrice(newSL),
                  " (", g_sessions.SessionName(t.session), ")");
            t.sl = newSL;
           }
        }
     }
  }
//+------------------------------------------------------------------+
//| Market order (mode EXECUTION) — setelah reaksi retest valid      |
//+------------------------------------------------------------------+
bool CTradeExecutor::OpenMarket(ENUM_BREAK_DIR dir, const SRiskPlan &plan, int session)
  {
   if(!m_initOk || !plan.valid)
      return false;
   if(CheckEntryBlocked(session))
      return false;

   string comment = BuildOrderComment(session);
   ulong  ticket  = 0;
   if(!SendOrderWithRetry(true, dir, 0.0, plan.slPrice, plan.tp2Price, plan.lots, session, comment, ticket))
      return false;

   double fillPrice = m_trade.ResultPrice();
   if(fillPrice <= 0.0)
      fillPrice = plan.entryPrice;

   AddTracked(ticket, false, session, dir, plan.lots, fillPrice, plan.slPrice,
              plan.tp2Price, plan.tp1Price, TimeCurrent(), 0);
   g_risk.OnTradeOpened();
   Print(EA_TITLE, " : MARKET ", (dir == BREAK_UP ? "BUY" : "SELL"), " ", DoubleToString(plan.lots, 2),
         " lot @ ", FmtPrice(fillPrice), " | SL ", FmtPrice(plan.slPrice), " | TP2 ", FmtPrice(plan.tp2Price),
         " (", g_sessions.SessionName(session), ")");
   return true;
  }
//+------------------------------------------------------------------+
//| Pending limit di tepi zona (mode PENDING_ORDER).                 |
//| SL/TP dihitung dari LEVEL PENDING (sudah ada di plan) — dipasang |
//| bersamaan, bukan setelah fill.                                   |
//+------------------------------------------------------------------+
bool CTradeExecutor::PlacePending(ENUM_BREAK_DIR dir, const SRiskPlan &plan, int session)
  {
   if(!m_initOk || !plan.valid)
      return false;
   if(CheckEntryBlocked(session))
      return false;

   // Harga pending harus di sisi yang masuk akal relatif pasar
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(dir == BREAK_UP && plan.entryPrice >= ask)
     {
      Print(EA_TITLE, " : BuyLimit ", FmtPrice(plan.entryPrice), " >= ask — order akan langsung ter-fill; dibatalkan");
      return false;
     }
   if(dir == BREAK_DOWN && plan.entryPrice <= bid)
     {
      Print(EA_TITLE, " : SellLimit ", FmtPrice(plan.entryPrice), " <= bid — order akan langsung ter-fill; dibatalkan");
      return false;
     }

   string comment = BuildOrderComment(session);
   ulong  ticket  = 0;
   if(!SendOrderWithRetry(false, dir, plan.entryPrice, plan.slPrice, plan.tp2Price, plan.lots, session, comment, ticket))
      return false;

   AddTracked(ticket, true, session, dir, plan.lots, plan.entryPrice, plan.slPrice,
              plan.tp2Price, plan.tp1Price, TimeCurrent(), 0);
   Print(EA_TITLE, " : PENDING ", (dir == BREAK_UP ? "BUY LIMIT" : "SELL LIMIT"),
         " ", DoubleToString(plan.lots, 2), " @ ", FmtPrice(plan.entryPrice),
         " | SL ", FmtPrice(plan.slPrice), " | TP2 ", FmtPrice(plan.tp2Price),
         " (", g_sessions.SessionName(session), ")");
   return true;
  }
//+------------------------------------------------------------------+
//| Hapus pending order dengan retry                                  |
//+------------------------------------------------------------------+
bool CTradeExecutor::DeletePending(ulong ticket)
  {
   int attempts = MathMax(1, InpOrderRetries);
   for(int a = 1; a <= attempts; a++)
     {
      if(m_trade.OrderDelete(ticket))
         return true;
      uint rc = m_trade.ResultRetcode();
      Print(EA_TITLE, " : hapus order ", ticket, " gagal (percobaan ", a, "/", attempts, ") retcode=", rc);
      if(a < attempts)
         Sleep(InpOrderRetryDelayMs);
     }
   return false;
  }
//+------------------------------------------------------------------+
//| Force-close semua posisi & pending milik SATU sesi — sesi lain   |
//| tidak disentuh. Kembalikan jumlah aksi yang dilakukan.           |
//+------------------------------------------------------------------+
int CTradeExecutor::ForceCloseSession(int session)
  {
   int actions   = 0;
   int posClosed = 0;
   int ordDel    = 0;

   for(int i = m_trackedCount - 1; i >= 0; i--)
     {
      STrackedPosition &t = m_tracked[i];
      if(t.session != session)
         continue;

      if(t.isOrder)
        {
         if(DeletePending(t.ticket))
           {
            ordDel++;
            actions++;
            RemoveTracked(i);
           }
        }
      else
        {
         m_trade.SetDeviationInPoints(InpMaxSlippagePoints);
         if(m_trade.PositionClose(t.ticket))
           {
            posClosed++;
            actions++;
            // pelacakan dihapus SyncTracked() setelah posisi lenyap dari server
           }
         else
            Print(EA_TITLE, " : gagal force-close posisi ", t.ticket, " retcode=", m_trade.ResultRetcode());
        }
     }

   if(actions > 0)
      Alert(EA_TITLE, " : FORCE-CLOSE ", g_sessions.SessionName(session),
            " — posisi ditutup: ", posClosed, ", pending dihapus: ", ordDel);
   return actions;
  }
//+------------------------------------------------------------------+
void CTradeExecutor::PreventNewEntries(int session)
  {
   if(session < 0 || session >= SESS_COUNT)
      return;
   m_sessionEntryBlocked[session] = true;
  }
//+------------------------------------------------------------------+
bool CTradeExecutor::HasOpenPosition()
  {
   return GetPositionCount() > 0;
  }
//+------------------------------------------------------------------+
bool CTradeExecutor::HasPendingOrder()
  {
   return GetPendingCount() > 0;
  }
//+------------------------------------------------------------------+
int CTradeExecutor::GetPositionCount()
  {
   int n = 0;
   for(int i = 0; i < m_trackedCount; i++)
      if(!m_tracked[i].isOrder)
         n++;
   return n;
  }
//+------------------------------------------------------------------+
int CTradeExecutor::GetPendingCount()
  {
   int n = 0;
   for(int i = 0; i < m_trackedCount; i++)
      if(m_tracked[i].isOrder)
         n++;
   return n;
  }
//+------------------------------------------------------------------+
ulong CTradeExecutor::GetPositionTicket()
  {
   for(int i = 0; i < m_trackedCount; i++)
      if(!m_tracked[i].isOrder)
         return m_tracked[i].ticket;
   return 0;
  }
//+------------------------------------------------------------------+
ulong CTradeExecutor::GetPendingTicket()
  {
   for(int i = 0; i < m_trackedCount; i++)
      if(m_tracked[i].isOrder)
         return m_tracked[i].ticket;
   return 0;
  }
//+------------------------------------------------------------------+
double CTradeExecutor::GetFloatingPL()
  {
   double total = 0.0;
   for(int i = 0; i < m_trackedCount; i++)
     {
      const STrackedPosition &t = m_tracked[i];
      if(t.isOrder)
         continue;
      if(m_posInfo.SelectByTicket(t.ticket))
         total += m_posInfo.Profit() + m_posInfo.Swap();
     }
   return total;
  }
//+------------------------------------------------------------------+
const STrackedPosition* CTradeExecutor::GetTracked(ulong ticket)
  {
   int idx = FindTracked(ticket);
   if(idx < 0)
      return NULL;
   return &m_tracked[idx];
  }
//+------------------------------------------------------------------+
int CTradeExecutor::GetTrackedCount()
  {
   return m_trackedCount;
  }
//+------------------------------------------------------------------+
const STrackedPosition& CTradeExecutor::GetTrackedAt(int i)
  {
   static STrackedPosition dummy;
   if(i < 0 || i >= m_trackedCount)
      return dummy;
   return m_tracked[i];
  }
//+------------------------------------------------------------------+
bool CTradeExecutor::SessionHasPosition(int session)
  {
   for(int i = 0; i < m_trackedCount; i++)
      if(!m_tracked[i].isOrder && m_tracked[i].session == session)
         return true;
   return false;
  }
//+------------------------------------------------------------------+
bool CTradeExecutor::SessionHasPending(int session)
  {
   for(int i = 0; i < m_trackedCount; i++)
      if(m_tracked[i].isOrder && m_tracked[i].session == session)
         return true;
   return false;
  }
//+------------------------------------------------------------------+
//| Informasi posisi untuk baris dashboard                           |
//+------------------------------------------------------------------+
bool CTradeExecutor::GetPositionInfo(ulong ticket, string &dir, double &lots, double &entry,
                                     double &sl, double &tp, double &profit, double &profitPct)
  {
   if(!m_posInfo.SelectByTicket(ticket))
      return false;
   dir    = (m_posInfo.PositionType() == POSITION_TYPE_BUY) ? "BUY" : "SELL";
   lots   = m_posInfo.Volume();
   entry  = m_posInfo.PriceOpen();
   sl     = m_posInfo.StopLoss();
   tp     = m_posInfo.TakeProfit();
   profit = m_posInfo.Profit() + m_posInfo.Swap();

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   profitPct = (balance > 0.0) ? profit / balance * 100.0 : 0.0;
   return true;
  }
//+------------------------------------------------------------------+
//| Sinkronkan pelacakan dengan server:                              |
//|  - pending ter-fill → konversi jadi posisi (ticket sama di MT5)  |
//|  - posisi tertutup → catat P/L ke RiskManager, hapus pelacakan   |
//|  - recovery posisi/pending yang belum dilacak (EA restart)       |
//+------------------------------------------------------------------+
void CTradeExecutor::SyncTracked()
  {
   long magic = EAMagic();

   // --- 1) periksa item yang sudah dilacak ---
   for(int i = m_trackedCount - 1; i >= 0; i--)
     {
      STrackedPosition &t = m_tracked[i];
      if(t.isOrder)
        {
         if(m_ordInfo.Select(t.ticket))
            continue;   // masih pending

         if(m_posInfo.SelectByTicket(t.ticket))
           {
            // pending ter-fill → posisi (MT5 mempertahankan ticket)
            t.isOrder    = false;
            t.lots       = m_posInfo.Volume();
            t.entryPrice = m_posInfo.PriceOpen();
            t.sl         = m_posInfo.StopLoss();
            t.tp         = m_posInfo.TakeProfit();
            g_risk.OnTradeOpened();
            Print(EA_TITLE, " : pending ", t.ticket, " TER-FILL → posisi ",
                  (m_posInfo.PositionType() == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                  " @ ", FmtPrice(t.entryPrice), " (", g_sessions.SessionName(t.session), ")");
           }
         else
           {
            // dihapus server (expiry/invalidasi/force-close)
            RemoveTracked(i);
           }
        }
      else
        {
         if(m_posInfo.SelectByTicket(t.ticket))
           {
            // refresh nilai aktual (partial close bisa mengubah lots/SL/TP)
            t.lots = m_posInfo.Volume();
            t.sl   = m_posInfo.StopLoss();
            t.tp   = m_posInfo.TakeProfit();
           }
         else
           {
            // posisi tertutup → ambil P/L dari riwayat
            double profit = 0.0;
            if(HistorySelectByPosition(t.ticket))
              {
               int deals = HistoryDealsTotal();
               for(int d = 0; d < deals; d++)
                 {
                  ulong dt = HistoryDealGetTicket(d);
                  if(dt == 0)
                     continue;
                  if(HistoryDealGetInteger(dt, DEAL_POSITION_ID) != t.ticket)
                     continue;
                  if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY) == DEAL_ENTRY_OUT)
                     profit += HistoryDealGetDouble(dt, DEAL_PROFIT) + HistoryDealGetDouble(dt, DEAL_SWAP);
                 }
              }
            g_risk.OnTradeClosed(profit);
            Print(EA_TITLE, " : posisi ", t.ticket, " ditutup — P/L ", DoubleToString(profit, 2),
                  " (", g_sessions.SessionName(t.session), ")");
            RemoveTracked(i);
           }
        }
     }

   // --- 2) posisi milik EA yang belum dilacak (recovery) ---
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      if(FindTracked(ticket) >= 0)
         continue;

      string comment = PositionGetString(POSITION_COMMENT);
      int    sess    = ParseSessionFromComment(comment);
      long   type    = PositionGetInteger(POSITION_TYPE);
      ENUM_BREAK_DIR dir = (type == POSITION_TYPE_BUY) ? BREAK_UP : BREAK_DOWN;
      AddTracked(ticket, false, sess, dir, PositionGetDouble(POSITION_VOLUME),
                 PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL),
                 PositionGetDouble(POSITION_TP), 0.0, PositionGetInteger(POSITION_TIME), 0);
     }

   // --- 3) pending order milik EA yang belum dilacak (recovery) ---
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic)
         continue;
      if(FindTracked(ticket) >= 0)
         continue;

      string comment = OrderGetString(ORDER_COMMENT);
      int    sess    = ParseSessionFromComment(comment);
      long   type    = OrderGetInteger(ORDER_TYPE);
      ENUM_BREAK_DIR dir = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP) ? BREAK_UP : BREAK_DOWN;
      AddTracked(ticket, true, sess, dir, OrderGetDouble(ORDER_VOLUME_CURRENT),
                 OrderGetDouble(ORDER_PRICE_OPEN), OrderGetDouble(ORDER_SL),
                 OrderGetDouble(ORDER_TP), 0.0, OrderGetInteger(ORDER_TIME_SETUP), 0);
     }
  }
//+------------------------------------------------------------------+
int CTradeExecutor::FindTracked(ulong ticket)
  {
   for(int i = 0; i < m_trackedCount; i++)
      if(m_tracked[i].ticket == ticket)
         return i;
   return -1;
  }
//+------------------------------------------------------------------+
void CTradeExecutor::AddTracked(ulong ticket, bool isOrder, int session, ENUM_BREAK_DIR dir,
                                double lots, double entry, double sl, double tp, double tp1,
                                datetime openTime, int barsSinceOpen)
  {
   if(m_trackedCount >= MAX_TRACKED)
     {
      Print(EA_TITLE, " : PERINGATAN — kapasitas pelacakan penuh (", MAX_TRACKED, ")");
      return;
     }
   STrackedPosition &t = m_tracked[m_trackedCount++];
   ZeroMemory(t);
   t.ticket        = ticket;
   t.isOrder       = isOrder;
   t.session       = session;
   t.dir           = dir;
   t.lots          = lots;
   t.entryPrice    = entry;
   t.sl            = sl;
   t.tp            = tp;
   t.tp1           = tp1;
   t.openTime      = openTime;
   t.barsSinceOpen = barsSinceOpen;
  }
//+------------------------------------------------------------------+
void CTradeExecutor::RemoveTracked(int index)
  {
   if(index < 0 || index >= m_trackedCount)
      return;
   for(int i = index; i < m_trackedCount - 1; i++)
      m_tracked[i] = m_tracked[i + 1];
   m_trackedCount--;
  }
//+------------------------------------------------------------------+
bool CTradeExecutor::IsEAMagic(ulong magic)
  {
   return (magic == (ulong)EAMagic());
  }
//+------------------------------------------------------------------+
//| Kirim order dengan retry — log alasan gagal tiap percobaan       |
//+------------------------------------------------------------------+
bool CTradeExecutor::SendOrderWithRetry(bool isMarket, ENUM_BREAK_DIR dir, double price, double sl,
                                        double tp, double lots, int session, string comment,
                                        ulong &ticket)
  {
   int attempts = MathMax(1, InpOrderRetries);
   for(int a = 1; a <= attempts; a++)
     {
      m_trade.SetExpertMagicNumber(EAMagic());
      m_trade.SetDeviationInPoints(InpMaxSlippagePoints);
      m_trade.SetTypeFillingBySymbol(_Symbol);

      bool ok = false;
      if(isMarket)
        {
         if(dir == BREAK_UP)
            ok = m_trade.Buy(lots, _Symbol, 0.0, sl, tp, comment);
         else
            ok = m_trade.Sell(lots, _Symbol, 0.0, sl, tp, comment);
        }
      else
        {
         if(dir == BREAK_UP)
            ok = m_trade.BuyLimit(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
         else
            ok = m_trade.SellLimit(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
        }

      if(ok)
        {
         ticket = m_trade.ResultOrder();
         return true;
        }

      uint rc = m_trade.ResultRetcode();
      Print(EA_TITLE, " : order GAGAL (percobaan ", a, "/", attempts, ") retcode=", rc,
            " — ", m_trade.ResultRetcodeDescription(),
            " [", (isMarket ? "market" : "pending"), ", ", g_sessions.SessionName(session), "]");
      if(a < attempts)
         Sleep(InpOrderRetryDelayMs);
     }
   return false;
  }
//+------------------------------------------------------------------+
//| Komentar order membawa sesi asal — dipakai recovery & force-close|
//+------------------------------------------------------------------+
string CTradeExecutor::BuildOrderComment(int session)
  {
   return EA_COMMENT_BASE + "|" + g_sessions.SessionShortName(session);
  }
//+------------------------------------------------------------------+
//| Gate internal sebelum order (lapis terakhir, defense in depth)   |
//+------------------------------------------------------------------+
bool CTradeExecutor::CheckEntryBlocked(int session)
  {
   if(session >= 0 && session < SESS_COUNT && m_sessionEntryBlocked[session])
     {
      Print(EA_TITLE, " : entry sesi ", g_sessions.SessionName(session), " diblokir (force-close sudah dieksekusi)");
      return true;
     }
   if(g_risk.IsMaxTradesReached())
     {
      Print(EA_TITLE, " : entry ditolak — batas trade harian tercapai");
      return true;
     }
   if(g_risk.IsDailyLossLimitHit())
     {
      Print(EA_TITLE, " : entry ditolak — batas kerugian harian tercapai");
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
//| Sesi dari komentar order "ORBSMC|ASIA/LDN/NY" — SESS_NONE bila   |
//| tidak dikenali (mis. order manual / versi lain).                 |
//+------------------------------------------------------------------+
int CTradeExecutor::ParseSessionFromComment(const string &comment)
  {
   if(StringFind(comment, "|ASIA") >= 0)
      return SESS_ASIA;
   if(StringFind(comment, "|LDN") >= 0)
      return SESS_LONDON;
   if(StringFind(comment, "|NY") >= 0)
      return SESS_NY;
   return SESS_NONE;
  }
//+------------------------------------------------------------------+
//| Lots untuk partial close — normalisasi ke step, jangan sampai    |
//| menutup seluruh posisi.                                          |
//+------------------------------------------------------------------+
double CTradeExecutor::NormalizeCloseLots(double lots)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   return MathFloor(lots / step) * step;
  }

#endif // ORBSMC_TRADE_EXECUTOR_MQH
