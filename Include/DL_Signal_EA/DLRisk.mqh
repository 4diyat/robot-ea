//+------------------------------------------------------------------+
//| DL_Signal_EA — DLRisk.mqh                                       |
//| Position sizing berbasis % risiko + pengaman harian.             |
//| Tidak mereferensikan input: semua parameter lewat Init().        |
//+------------------------------------------------------------------+
#ifndef DL_RISK_MQH
#define DL_RISK_MQH

class CDLRisk
  {
private:
   string            m_symbol;
   long              m_magic;
   double            m_riskPercent;
   double            m_maxDailyLossPercent;
   int               m_maxTradesPerDay;
   double            m_maxSpreadPctOfSL;
   int               m_dayKey;
   double            m_dayStartBalance;

   int               DayKey(const datetime t) const
     {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      return dt.year * 1000 + dt.day_of_year;
     }

public:
                     CDLRisk() : m_symbol(""), m_magic(0), m_riskPercent(0.5), m_maxDailyLossPercent(3.0),
                                 m_maxTradesPerDay(0), m_maxSpreadPctOfSL(0.0), m_dayKey(-1), m_dayStartBalance(0.0) {}

   void              Init(const string symbol, const long magic, const double riskPercent,
                          const double maxDailyLossPercent, const int maxTradesPerDay,
                          const double maxSpreadPctOfSL)
     {
      m_symbol              = symbol;
      m_magic               = magic;
      m_riskPercent         = riskPercent;
      m_maxDailyLossPercent = maxDailyLossPercent;
      m_maxTradesPerDay     = maxTradesPerDay;
      m_maxSpreadPctOfSL    = maxSpreadPctOfSL;
      m_dayKey              = DayKey(TimeCurrent());
      m_dayStartBalance     = AccountInfoDouble(ACCOUNT_BALANCE);   // catatan: bila EA dipasang tengah hari,
                                                                    // basis = balance saat dipasang
     }

   //--- panggil tiap bar baru: reset basis harian saat tanggal server berganti
   void              CheckNewDay()
     {
      int key = DayKey(TimeCurrent());
      if(key != m_dayKey)
        {
         m_dayKey          = key;
         m_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        }
     }

   //--- P/L hari ini (closed + floating) dalam % balance awal hari
   double            DailyPnLPercent() const
     {
      if(m_dayStartBalance <= 0.0)
         return 0.0;
      return (AccountInfoDouble(ACCOUNT_EQUITY) - m_dayStartBalance) / m_dayStartBalance * 100.0;
     }

   bool              DailyLossHit() const
     {
      if(m_maxDailyLossPercent <= 0.0)
         return false;
      return DailyPnLPercent() <= -m_maxDailyLossPercent;
     }

   //--- jumlah entry EA ini pada simbol ini sejak 00:00 waktu server
   int               TradesToday() const
     {
      datetime now      = TimeCurrent();
      datetime dayStart = now - (now % 86400);
      if(!HistorySelect(dayStart, now + 60))
         return 0;
      int count = 0;
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0)
            continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != m_magic)
            continue;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) != m_symbol)
            continue;
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
            count++;
        }
      return count;
     }

   bool              MaxTradesReached() const
     {
      if(m_maxTradesPerDay <= 0)
         return false;
      return TradesToday() >= m_maxTradesPerDay;
     }

   //--- spread saat ini tidak boleh memakan terlalu banyak dari jarak SL (biaya dalam R)
   bool              SpreadOk(const double slDistance) const
     {
      if(m_maxSpreadPctOfSL <= 0.0 || slDistance <= 0.0)
         return true;
      MqlTick tick;
      if(!SymbolInfoTick(m_symbol, tick))
         return false;
      return (tick.ask - tick.bid) <= slDistance * m_maxSpreadPctOfSL / 100.0;
     }

   //--- lot sehingga rugi di SL ~= riskPercent% balance. 0 = tidak bisa trading
   //    (mis. lot minimum pun melebihi risiko yang diizinkan -> trade dilewati).
   double            LotsForRisk(const double slDistance) const
     {
      if(slDistance <= 0.0 || m_riskPercent <= 0.0)
         return 0.0;
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * m_riskPercent / 100.0;

      MqlTick tick;
      if(!SymbolInfoTick(m_symbol, tick))
         return 0.0;
      //--- rugi 1 lot bila harga bergerak sejauh slDistance (akurat utk semua jenis instrumen)
      double lossPerLot = 0.0;
      double profit = 0.0;
      if(OrderCalcProfit(ORDER_TYPE_BUY, m_symbol, 1.0, tick.ask, tick.ask - slDistance, profit))
         lossPerLot = MathAbs(profit);
      if(lossPerLot <= 0.0)
        {
         double tickSize  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
         double tickValue = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
         if(tickSize > 0.0 && tickValue > 0.0)
            lossPerLot = slDistance / tickSize * tickValue;
        }
      if(lossPerLot <= 0.0)
         return 0.0;

      double step   = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      double minLot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      if(step <= 0.0)
         step = 0.01;

      double lots = MathFloor(riskMoney / lossPerLot / step + 1e-9) * step;   // bulatkan KE BAWAH
      if(lots < minLot)
        {
         PrintFormat("[DLRisk] lot minimum %.2f berisiko %.2f > batas %.2f (%.2f%%) — trade dilewati",
                     minLot, minLot * lossPerLot, riskMoney, m_riskPercent);
         return 0.0;
        }
      if(lots > maxLot)
         lots = maxLot;
      return NormalizeDouble(lots, 8);
     }
  };

#endif // DL_RISK_MQH
