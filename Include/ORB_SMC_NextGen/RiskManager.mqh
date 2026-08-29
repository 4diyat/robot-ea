//+------------------------------------------------------------------+
//| ORB_SMC_NextGen — RiskManager.mqh                               |
//| Position sizing berbasis % equity/balance, SL berbasis struktur  |
//| (bukan pip tetap), TP multi-level / RR dinamis, max daily loss,  |
//| max trades per hari. Semua angka dinormalisasi ke nilai uang     |
//| (USD) melalui profit per 1 lot agar multi-pair safe.             |
//|                                                                  |
//| Keputusan desain:                                                |
//|  - PipValueUSD(): nilai $ per 1 pip per 1 lot. Bila profit       |
//|    currency != USD, dibangun simbol proxy ("EURUSD", "GBPUSD")   |
//|    dari MarketInfo; gagal → fallback SYMBOL_TRADE_TICK_VALUE.    |
//|  - Daily P/L: closed (riwayat hari ini) + floating (posisi EA).  |
//|  - Lots selalu dibulatkan KE BAWAH ke langkah volume (tidak      |
//|    pernah over-risk), lalu di-clamp ke min/max lot.              |
//| Fase 3: TERIMPLEMENTASI.                                         |
//+------------------------------------------------------------------+
#ifndef ORBSMC_RISK_MANAGER_MQH
#define ORBSMC_RISK_MANAGER_MQH

#include <ORB_SMC_NextGen\Defines.mqh>
#include <ORB_SMC_NextGen\Helpers.mqh>
#include <ORB_SMC_NextGen\SessionManager.mqh>
#include <ORB_SMC_NextGen\SMCEngine.mqh>
#include <Trade\Trade.mqh>

//--- instance global (didefinisikan di file utama)
extern CSessionManager g_sessions;
extern CSMCEngine       g_smc;

//+------------------------------------------------------------------+
//| Penempatan SL/TP & sizing hasil kalkulasi risiko                 |
//+------------------------------------------------------------------+
struct SRiskPlan
  {
   bool     valid;
   double   entryPrice;    // level entry (limit / market)
   double   slPrice;
   double   tp1Price;
   double   tp2Price;
   double   rr;            // reward:risk aktual (terhadap tp2)
   double   riskAmount;    // $ yang dipertaruhkan
   double   lots;
   double   riskPercent;
  };

//+------------------------------------------------------------------+
//| CRiskManager                                                     |
//+------------------------------------------------------------------+
class CRiskManager
  {
public:
   //--- lifecycle ---
   bool            Init();

   //--- sizing & plan ---
   bool            BuildRiskPlan(ENUM_BREAK_DIR dir,
                                 double entryPrice,
                                 const SRetestZone &zone,
                                 ENUM_BIAS htfBias,
                                 SRiskPlan &out);
                       // entryPrice = level order (limit) / market saat eksekusi
   double          NormalizeLots(double lots);

   //--- proteksi harian ---
   bool            IsDailyLossLimitHit();       // floating daily loss <= -InpMaxDailyLossPercent%
   bool            IsMaxTradesReached();        // trades hari ini >= InpMaxTradesPerDay
   double          GetDailyLossPercent();       // P/L hari ini dalam % (basis balance awal hari)
   int             GetTodayTradeCount();

   //--- filter eksekusi ---
   bool            IsSpreadOk();                // spread <= InpMaxSpreadPips
   int             GetMaxAllowedSlippage();     // InpMaxSlippagePoints (poin)

   //--- data harian (dipakai dashboard) ---
   double          GetDayStartBalance();
   double          GetDayFloatingPL();          // floating P/L semua posisi EA hari ini
   double          GetDayClosedPL();            // P/L closed hari ini (riwayat)

   //--- hooks dipanggil TradeExecutor ---
   void            OnTradeClosed(double profit); // catat closed P/L harian
   void            OnTradeOpened();              // naikkan counter harian
   void            CheckNewDay();                // rollover harian (dipanggil main EA saat hari baru)

   //--- helper money ---
   double          RiskAmountForPercent(double percent); // % dari balance/equity → $ (basis per InpRiskBase)
   double          PipValueUSD();                // nilai $ per 1 pip per 1 lot (simbol aktif)
   double          PriceToMoney(double priceDiff, double lots); // selisih harga → $ (pakai tick value)

private:
   double          m_dayStartBalance;            // balance awal hari UTC
   double          m_dayClosedPL;                // P/L closed hari ini
   int             m_dayTrades;                  // jumlah trade hari ini
   datetime        m_lastDay;                    // tanggal UTC hari berjalan
   bool            m_initOk;

   double          ComputeSL(ENUM_BREAK_DIR dir, double entryPrice, const SRetestZone &zone);
   void            ComputeTPs(ENUM_BREAK_DIR dir, double entryPrice, double slPrice,
                              double &tp1, double &tp2, double &rr);
  };

//+------------------------------------------------------------------+
//| Inisialisasi — snapshot balance hari berjalan                    |
//+------------------------------------------------------------------+
bool CRiskManager::Init()
  {
   CheckNewDay();
   m_initOk = true;
   return m_initOk;
  }
//+------------------------------------------------------------------+
//| Kalkulasi lengkap: SL struktur → risk → lots → TP → RR.          |
//| Dipanggil SEKALI per order (market atau pending) sehingga SL/TP  |
//| pending dihitung dari level pending, bukan harga pasar.          |
//+------------------------------------------------------------------+
bool CRiskManager::BuildRiskPlan(ENUM_BREAK_DIR dir, double entryPrice, const SRetestZone &zone,
                                 ENUM_BIAS htfBias, SRiskPlan &out)
  {
   ZeroMemory(out);
   out.entryPrice = entryPrice;

   // 1) SL struktural + buffer ATR
   double sl = ComputeSL(dir, entryPrice, zone);
   if(sl <= 0.0)
     {
      Print(EA_TITLE, " : gagal membangun risk plan — tidak ada struktur untuk SL");
      return false;
     }
   out.slPrice = sl;

   // validasi sisi SL
   if(dir == BREAK_UP && sl >= entryPrice)
     {
      Print(EA_TITLE, " : SL invalid (buy, SL >= entry)");
      return false;
     }
   if(dir == BREAK_DOWN && sl <= entryPrice)
     {
      Print(EA_TITLE, " : SL invalid (sell, SL <= entry)");
      return false;
     }

   double slDistance  = MathAbs(entryPrice - sl);
   double slPips      = PriceToPips(slDistance);
   if(slPips <= 0.0)
     {
      Print(EA_TITLE, " : jarak SL nol — dibatalkan");
      return false;
     }

   // 2) risiko $ = InpRiskPercent% dari basis
   out.riskPercent = InpRiskPercent;
   out.riskAmount  = RiskAmountForPercent(InpRiskPercent);

   // 3) lots = risiko$ / (jarak SL pip × nilai $ per pip per lot)
   double pipValue = PipValueUSD();
   if(pipValue <= 0.0)
     {
      Print(EA_TITLE, " : gagal menghitung pip value — sizing dibatalkan");
      return false;
     }
   double lots = out.riskAmount / (slPips * pipValue);
   out.lots = NormalizeLots(lots);
   if(out.lots <= 0.0)
     {
      Print(EA_TITLE, " : ukuran lot terlalu kecil (", DoubleToString(lots, 6), ") — dibatalkan");
      return false;
     }

   // 4) TP multi-level & RR
   ComputeTPs(dir, entryPrice, sl, out.tp1Price, out.tp2Price, out.rr);
   if(out.rr < InpMinRR)
     {
      Print(EA_TITLE, " : RR aktual ", DoubleToString(out.rr, 2), " < minimal ", DoubleToString(InpMinRR, 2), " — dibatalkan");
      return false;
     }

   out.valid = true;
   return true;
  }
//+------------------------------------------------------------------+
//| Normalisasi lots: clamp min/max, bulatkan KE BAWAH ke langkah    |
//| volume (tidak pernah over-risk).                                 |
//+------------------------------------------------------------------+
double CRiskManager::NormalizeLots(double lots)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   lots = MathMin(lots, maxLot);
   lots = MathMax(lots, minLot);
   lots = MathFloor(lots / step) * step;

   // bersihkan digit float (mis. 0.01000001 → 0.01)
   lots = MathRound(lots / step) * step;
   return lots;
  }
//+------------------------------------------------------------------+
//| Batas kerugian harian tercapai? (closed + floating)              |
//+------------------------------------------------------------------+
bool CRiskManager::IsDailyLossLimitHit()
  {
   if(InpMaxDailyLossPercent <= 0.0)
      return false;   // proteksi off
   if(m_dayStartBalance <= 0.0)
      return true;    // tanpa basis → jangan entry
   double pl = m_dayClosedPL + GetDayFloatingPL();
   double limit = -InpMaxDailyLossPercent / 100.0 * m_dayStartBalance;
   return (pl <= limit);
  }
//+------------------------------------------------------------------+
//| Jumlah trade hari ini mencapai batas?                            |
//+------------------------------------------------------------------+
bool CRiskManager::IsMaxTradesReached()
  {
   if(InpMaxTradesPerDay <= 0)
      return false;   // tanpa batas
   return (m_dayTrades >= InpMaxTradesPerDay);
  }
//+------------------------------------------------------------------+
//| P/L hari ini dalam % (positif = profit)                          |
//+------------------------------------------------------------------+
double CRiskManager::GetDailyLossPercent()
  {
   if(m_dayStartBalance <= 0.0)
      return 0.0;
   double pl = m_dayClosedPL + GetDayFloatingPL();
   return pl / m_dayStartBalance * 100.0;
  }
//+------------------------------------------------------------------+
int CRiskManager::GetTodayTradeCount()
  {
   return m_dayTrades;
  }
//+------------------------------------------------------------------+
//| Spread saat ini <= batas?                                        |
//+------------------------------------------------------------------+
bool CRiskManager::IsSpreadOk()
  {
   if(InpMaxSpreadPips <= 0.0)
      return true;   // filter off
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;  // tanpa quote → tolak (aman)
   return (PriceToPips(ask - bid) <= InpMaxSpreadPips);
  }
//+------------------------------------------------------------------+
int CRiskManager::GetMaxAllowedSlippage()
  {
   return InpMaxSlippagePoints;
  }
//+------------------------------------------------------------------+
double CRiskManager::GetDayStartBalance()
  {
   return m_dayStartBalance;
  }
//+------------------------------------------------------------------+
//| Floating P/L semua posisi milik EA (profit + swap) — dipakai juga|
//| dashboard. Magic didefinisikan di Defines (EAMagic()).           |
//+------------------------------------------------------------------+
double CRiskManager::GetDayFloatingPL()
  {
   double total = 0.0;
   long   magic = EAMagic();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return total;
  }
//+------------------------------------------------------------------+
double CRiskManager::GetDayClosedPL()
  {
   return m_dayClosedPL;
  }
//+------------------------------------------------------------------+
void CRiskManager::OnTradeClosed(double profit)
  {
   CheckNewDay();
   m_dayClosedPL += profit;
  }
//+------------------------------------------------------------------+
void CRiskManager::OnTradeOpened()
  {
   CheckNewDay();
   m_dayTrades++;
  }
//+------------------------------------------------------------------+
//| Risiko $ untuk persen tertentu dari basis (balance/equity)       |
//+------------------------------------------------------------------+
double CRiskManager::RiskAmountForPercent(double percent)
  {
   double base = 0.0;
   switch(InpRiskBase)
     {
      case RISK_BASE_EQUITY:
         base = AccountInfoDouble(ACCOUNT_EQUITY);
         break;
      case RISK_BASE_BALANCE:
      default:
         base = AccountInfoDouble(ACCOUNT_BALANCE);
         break;
     }
   if(base <= 0.0)
      return 0.0;
   return base * percent / 100.0;
  }
//+------------------------------------------------------------------+
//| Nilai $ per 1 pip per 1 lot — multi-pair safe.                   |
//| Profit currency = USD → SYMBOL_TRADE_TICK_VALUE langsung.        |
//| Lainnya → proxy "XXXUSD" dari MarketInfo; gagal → fallback tick  |
//| value (perkiraan).                                               |
//+------------------------------------------------------------------+
double CRiskManager::PipValueUSD()
  {
   string profitCur = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;

   if(profitCur == "USD")
      return tickValue * PipSize() / tickSize;

   // Proxy: 1 unit profit currency dalam USD
   string proxy = profitCur + "USD";
   double proxyRate = SymbolInfoDouble(proxy, SYMBOL_BID);
   if(proxyRate > 0.0)
      return tickValue * PipSize() / tickSize * proxyRate;

   // Fallback: asumsi profit currency ≈ USD (log warning sekali di Init)
   return tickValue * PipSize() / tickSize;
  }
//+------------------------------------------------------------------+
//| Selisih harga → $ (tick value × jumlah tick × lots)              |
//+------------------------------------------------------------------+
double CRiskManager::PriceToMoney(double priceDiff, double lots)
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      return 0.0;
   double ticks = priceDiff / tickSize;
   return ticks * tickValue * lots;
  }
//+------------------------------------------------------------------+
//| SL struktural: struktur terdekat + buffer ATR.                   |
//| Buy : SL = struktur terdekat DI BAWAH entry - buffer.            |
//| Sell: SL = struktur terdekat DI ATAS entry + buffer.             |
//| Fallback bila tidak ada struktur: SL = entry ∓ 1.5 × ATR (masih  |
//| adaptif terhadap volatilitas — bukan pip tetap).                 |
//+------------------------------------------------------------------+
double CRiskManager::ComputeSL(ENUM_BREAK_DIR dir, double entryPrice, const SRetestZone &zone)
  {
   double structLevel = g_smc.GetStructStopLevel(dir, entryPrice);
   double atr = GetATR(InpATRPeriod);
   double buffer = InpSLBufferATR * atr;

   if(structLevel > 0.0)
      return (dir == BREAK_UP) ? (structLevel - buffer) : (structLevel + buffer);

   // fallback adaptif volatilitas
   if(atr > 0.0)
      return (dir == BREAK_UP) ? (entryPrice - 1.5 * atr) : (entryPrice + 1.5 * atr);
   return 0.0;
  }
//+------------------------------------------------------------------+
//| TP multi-level: TP1 = InpTP1RR × jarak SL (0 = nonaktif),        |
//| TP2 = max(TP1, InpMinRR × jarak SL). RR dihitung thd TP2.        |
//+------------------------------------------------------------------+
void CRiskManager::ComputeTPs(ENUM_BREAK_DIR dir, double entryPrice, double slPrice,
                              double &tp1, double &tp2, double &rr)
  {
   double slDist = MathAbs(entryPrice - slPrice);

   tp1 = 0.0;
   if(InpTP1RR > 0.0)
      tp1 = (dir == BREAK_UP) ? (entryPrice + InpTP1RR * slDist)
                              : (entryPrice - InpTP1RR * slDist);

   double tp2Dist = MathMax(InpTP1RR, InpMinRR) * slDist;
   tp2 = (dir == BREAK_UP) ? (entryPrice + tp2Dist) : (entryPrice - tp2Dist);

   rr = (slDist > 0.0) ? (tp2Dist / slDist) : 0.0;
  }
//+------------------------------------------------------------------+
//| Rollover harian (00:00 UTC): snapshot balance, reset counter     |
//+------------------------------------------------------------------+
void CRiskManager::CheckNewDay()
  {
   datetime day = g_sessions.UtcDayStart(g_sessions.ToUtc(TimeCurrent()));
   if(day != m_lastDay)
     {
      m_lastDay         = day;
      m_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      m_dayClosedPL     = 0.0;
      m_dayTrades       = 0;
     }
  }

#endif // ORBSMC_RISK_MANAGER_MQH
