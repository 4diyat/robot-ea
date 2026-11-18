//+------------------------------------------------------------------+
//| DL_Signal_EA — DLTrade.mqh                                      |
//| Eksekusi order (CTrade) + pencarian posisi milik EA.             |
//| Tidak mereferensikan input: semua parameter lewat Init().        |
//+------------------------------------------------------------------+
#ifndef DL_TRADE_MQH
#define DL_TRADE_MQH

#include <Trade\Trade.mqh>

class CDLTrade
  {
private:
   CTrade            m_trade;
   string            m_symbol;
   long              m_magic;

public:
                     CDLTrade() : m_symbol(""), m_magic(0) {}

   void              Init(const string symbol, const long magic, const int slippagePoints)
     {
      m_symbol = symbol;
      m_magic  = magic;
      m_trade.SetExpertMagicNumber((ulong)magic);
      m_trade.SetDeviationInPoints((ulong)slippagePoints);
      m_trade.SetTypeFillingBySymbol(symbol);
     }

   //--- tiket posisi EA ini pada simbol ini (0 = tidak ada)
   ulong             FindPosition() const
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic)
            continue;
         return ticket;
        }
      return 0;
     }

   //--- dir > 0 = BUY, dir < 0 = SELL; SL/TP berupa JARAK harga dari harga entry
   bool              Open(const int dir, const double lots, const double slDistance,
                          const double tpDistance, const string comment)
     {
      MqlTick tick;
      if(!SymbolInfoTick(m_symbol, tick))
         return false;
      int    digits  = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double point   = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double minDist = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
      if(slDistance <= minDist || tpDistance <= minDist)
        {
         PrintFormat("[DLTrade] jarak SL/TP (%.5f / %.5f) <= stops level broker (%.5f) — trade dilewati",
                     slDistance, tpDistance, minDist);
         return false;
        }

      double price, sl, tp;
      bool   ok;
      if(dir > 0)
        {
         price = tick.ask;
         sl    = NormalizeDouble(price - slDistance, digits);
         tp    = NormalizeDouble(price + tpDistance, digits);
         ok    = m_trade.Buy(lots, m_symbol, price, sl, tp, comment);
        }
      else
        {
         price = tick.bid;
         sl    = NormalizeDouble(price + slDistance, digits);
         tp    = NormalizeDouble(price - tpDistance, digits);
         ok    = m_trade.Sell(lots, m_symbol, price, sl, tp, comment);
        }

      uint rc = m_trade.ResultRetcode();
      if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL && rc != TRADE_RETCODE_PLACED))
        {
         PrintFormat("[DLTrade] order %s gagal: retcode %u (%s)", dir > 0 ? "BUY" : "SELL",
                     rc, m_trade.ResultRetcodeDescription());
         return false;
        }
      return true;
     }

   bool              Close(const ulong ticket, const string reason)
     {
      bool ok = m_trade.PositionClose(ticket);
      uint rc = m_trade.ResultRetcode();
      if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL && rc != TRADE_RETCODE_PLACED))
        {
         PrintFormat("[DLTrade] gagal menutup posisi #%I64u (%s): retcode %u (%s)", ticket, reason,
                     rc, m_trade.ResultRetcodeDescription());
         return false;
        }
      PrintFormat("[DLTrade] posisi #%I64u ditutup: %s", ticket, reason);
      return true;
     }
  };

#endif // DL_TRADE_MQH
