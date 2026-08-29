//+------------------------------------------------------------------+
//| ORB_SMC_NextGen — Dashboard.mqh                                  |
//| Panel on-chart (OBJ_RECTANGLE_LABEL semi-transparan + OBJ_LABEL) |
//| di pojok chart (InpDashboardCorner).                             |
//|                                                                    |
//| Strategi update (sesuai spec):                                   |
//|  - Tiap tick  : rebuild penuh (~30 ObjectSetString — murah);     |
//|    data kritis (floating P/L, countdown news) selalu segar.      |
//|  - Tiap bar   : bias/state/RSI (RSI via handle, dibaca per bar). |
//|  - Tiap detik : candle timer countdown via OnTimer               |
//|    (EventSetTimer(1) di main EA) — bukan dihitung tiap tick.     |
//|  - Tidak recreate objek: objek dibuat SEKALI di Init, isi diubah |
//|    via ObjectSetString/ObjectSetInteger.                         |
//|                                                                    |
//| Section: SESI & RANGE / STRUKTUR & SINYAL / POSISI & RISIKO /     |
//| NEWS. Warna konsisten dengan palet chart (Ready entry = CLR_READY |
//| = warna panah entry).                                             |
//| Fase 3: TERIMPLEMENTASI.                                         |
//+------------------------------------------------------------------+
#ifndef ORBSMC_DASHBOARD_MQH
#define ORBSMC_DASHBOARD_MQH

#include <ORB_SMC_NextGen\Defines.mqh>
#include <ORB_SMC_NextGen\SessionManager.mqh>
#include <ORB_SMC_NextGen\ORBDetector.mqh>
#include <ORB_SMC_NextGen\SMCEngine.mqh>
#include <ORB_SMC_NextGen\ConfluenceValidator.mqh>
#include <ORB_SMC_NextGen\RiskManager.mqh>
#include <ORB_SMC_NextGen\TradeExecutor.mqh>
#include <ORB_SMC_NextGen\NewsFilter.mqh>

//--- instance global (didefinisikan di file utama)
extern CSessionManager      g_sessions;
extern CORBDetector         g_orb;
extern CSMCEngine           g_smc;
extern CConfluenceValidator g_confluence;
extern CRiskManager         g_risk;
extern CTradeExecutor       g_executor;
extern CNewsFilter          g_news;
extern ENUM_EA_STATE        g_state[SESS_COUNT]; // state per sesi (main EA)

//+------------------------------------------------------------------+
//| Satu baris panel (teks + warna)                                  |
//+------------------------------------------------------------------+
struct SDashLine
  {
   string text;
   color  clr;
  };

//+------------------------------------------------------------------+
//| CDashboard                                                       |
//+------------------------------------------------------------------+
class CDashboard
  {
public:
   //--- lifecycle ---
   bool              Init();                 // buat semua objek panel SEKALI
   void              Deinit();               // hapus semua objek PREFIX_DASH + release RSI
   void              OnTick();               // rebuild (data kritis segar)
   void              OnNewBar();             // rebuild + baca RSI (data non-kritis)
   void              OnTimer();              // candle countdown mm:ss (per detik)
   void              OnNewsRefresh();        // section news berubah

private:
   bool              m_created;              // objek sudah dibuat
   int               m_fontSize;
   int               m_rowH;                 // tinggi baris (px)
   int               m_panelW;
   int               m_baseX, m_baseY;       // offset px dari corner
   int               m_corner;
   int               m_rsiHandle;            // handle iRSI (dibaca per bar)
   double            m_rsiVal;
   string            m_timerText;            // cache countdown candle (OnTimer)
   int               m_candleSecondsPrev;

   SDashLine         m_lines[MAX_DASH_ROWS];
   int               m_lineCount;

   //--- render pipeline ---
   void              BeginRender();
   void              AddLine(string text, color clr);
   void              EndRender();
   void              Update();               // rebuild semua section

   //--- penyusun section ---
   void              AddHeader();
   void              AddSessionSection();
   void              AddStructureSection();
   void              AddPositionSection();
   void              AddNewsSection();

   //--- util ---
   string            StateName(ENUM_EA_STATE st);
   color             StateColor(ENUM_EA_STATE st);
   string            RangeStatusName(ENUM_RANGE_STATUS st);
   string            BiasName(ENUM_BIAS b);
   string            DirName(ENUM_BREAK_DIR d);
   string            ZoneName(ENUM_ZONE_TYPE z);
   int               SessionOfActiveSetup();   // sesi dgn setup aktif (utk baris state detail)
  };

//+------------------------------------------------------------------+
//| Inisialisasi — buat objek panel satu kali                         |
//+------------------------------------------------------------------+
bool CDashboard::Init()
  {
   m_created = false;
   m_lineCount = 0;
   m_timerText = "Candle --:--";
   m_candleSecondsPrev = -1;
   m_rsiVal = 0.0;

   if(!InpShowDashboard)
      return true;   // panel off — tidak ada objek

   m_fontSize = InpDashboardFontSize;
   if(m_fontSize < 6)  m_fontSize = 6;
   if(m_fontSize > 12) m_fontSize = 12;
   m_rowH    = m_fontSize + 6;
   m_panelW  = 360;

   switch(InpDashboardCorner)
     {
      case 1:  m_corner = CORNER_RIGHT_UPPER; break;
      case 2:  m_corner = CORNER_LEFT_LOWER;  break;
      case 3:  m_corner = CORNER_RIGHT_LOWER; break;
      default: m_corner = CORNER_LEFT_UPPER;  break;
     }
   m_baseX = 6;
   m_baseY = 26;

   //--- background semi-transparan ---
   ObjectCreate(0, PREFIX_DASH + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, PREFIX_DASH + "BG", OBJPROP_CORNER, m_corner);
   ObjectSetInteger(0, PREFIX_DASH + "BG", OBJPROP_XDISTANCE, m_baseX);
   ObjectSetInteger(0, PREFIX_DASH + "BG", OBJPROP_YDISTANCE, m_baseY);
   ObjectSetInteger(0, PREFIX_DASH + "BG", OBJPROP_XSIZE, m_panelW);
   ObjectSetInteger(0, PREFIX_DASH + "BG", OBJPROP_YSIZE, 100);
   ObjectSetInteger(0, PREFIX_DASH + "BG", OBJPROP_BGCOLOR, CLR_PANEL_BG);
   ObjectSetInteger(0, PREFIX_DASH + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, PREFIX_DASH + "BG", OBJPROP_COLOR, C'60,64,74');
   ObjectSetInteger(0, PREFIX_DASH + "BG", OBJPROP_BACK, false);
   ObjectSetInteger(0, PREFIX_DASH + "BG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, PREFIX_DASH + "BG", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, PREFIX_DASH + "BG", OBJPROP_ZORDER, 1000);

   //--- baris label (dibuat sekali) ---
   for(int i = 0; i < MAX_DASH_ROWS; i++)
     {
      string name = PREFIX_DASH + "R" + IntegerToString(i);
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, m_corner);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, m_baseX + 8);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, m_baseY + 6 + i * m_rowH);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, m_fontSize);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_COLOR, CLR_TEXT);
      ObjectSetString(0, name, OBJPROP_TEXT, "");
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 1001);
     }

   //--- handle RSI ---
   m_rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, InpOBOSPeriod, PRICE_CLOSE);

   m_created = true;
   Update();
   return true;
  }
//+------------------------------------------------------------------+
//| Bersihkan semua objek dashboard + release indikator               |
//+------------------------------------------------------------------+
void CDashboard::Deinit()
  {
   if(m_rsiHandle != INVALID_HANDLE)
     {
      IndicatorRelease(m_rsiHandle);
      m_rsiHandle = INVALID_HANDLE;
     }
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(name == "")
         continue;
      if(StringFind(name, PREFIX_DASH) == 0)
         ObjectDelete(0, name);
     }
  }
//+------------------------------------------------------------------+
void CDashboard::OnTick()
  {
   if(m_created)
      Update();
  }
//+------------------------------------------------------------------+
void CDashboard::OnNewBar()
  {
   // baca RSI closed bar (shift 1)
   if(m_rsiHandle != INVALID_HANDLE)
     {
      double buf[];
      if(CopyBuffer(m_rsiHandle, 0, 1, 1, buf) == 1)
         m_rsiVal = buf[0];
     }
   if(m_created)
      Update();
  }
//+------------------------------------------------------------------+
//| Per detik: perbarui teks countdown candle, rebuild bila detik    |
//| berubah (format mm:ss).                                          |
//+------------------------------------------------------------------+
void CDashboard::OnTimer()
  {
   if(!m_created)
      return;
   int secondsLeft = (int)(iTime(_Symbol, PERIOD_CURRENT, 0) + PeriodSeconds(PERIOD_CURRENT) - TimeCurrent());
   if(secondsLeft < 0)
      secondsLeft = 0;
   if(secondsLeft == m_candleSecondsPrev)
      return;   // belum ada detik baru
   m_candleSecondsPrev = secondsLeft;
   m_timerText = StringFormat("Candle %s %s", StringSubstr(EnumToString((ENUM_TIMEFRAMES)PERIOD_CURRENT), 7),
                              FormatClock(secondsLeft));
   Update();
  }
//+------------------------------------------------------------------+
void CDashboard::OnNewsRefresh()
  {
   if(m_created)
      Update();
  }
//+------------------------------------------------------------------+
//| === RENDER PIPELINE ===                                          |
//+------------------------------------------------------------------+
void CDashboard::BeginRender()
  {
   m_lineCount = 0;
  }
//+------------------------------------------------------------------+
void CDashboard::AddLine(string text, color clr)
  {
   if(m_lineCount >= MAX_DASH_ROWS)
      return;
   m_lines[m_lineCount].text = text;
   m_lines[m_lineCount].clr  = clr;
   m_lineCount++;
  }
//+------------------------------------------------------------------+
//| Terapkan baris ke objek label yang sudah ada (tanpa recreate)     |
//+------------------------------------------------------------------+
void CDashboard::EndRender()
  {
   for(int i = 0; i < MAX_DASH_ROWS; i++)
     {
      string name = PREFIX_DASH + "R" + IntegerToString(i);
      if(i < m_lineCount)
        {
         ObjectSetString(0, name, OBJPROP_TEXT, m_lines[i].text);
         ObjectSetInteger(0, name, OBJPROP_COLOR, m_lines[i].clr);
        }
      else
         ObjectSetString(0, name, OBJPROP_TEXT, "");
     }
   // tinggi panel mengikuti jumlah baris
   ObjectSetInteger(0, PREFIX_DASH + "BG", OBJPROP_YSIZE, m_lineCount * m_rowH + 10);
  }
//+------------------------------------------------------------------+
//| Rebuild semua section                                            |
//+------------------------------------------------------------------+
void CDashboard::Update()
  {
   if(!m_created)
      return;
   BeginRender();
   AddHeader();
   AddSessionSection();
   AddStructureSection();
   AddPositionSection();
   AddNewsSection();
   EndRender();
  }
//+------------------------------------------------------------------+
void CDashboard::AddHeader()
  {
   AddLine(StringFormat("%s v%s | %s %s", EA_TITLE, EA_VERSION, _Symbol,
                        StringSubstr(EnumToString((ENUM_TIMEFRAMES)PERIOD_CURRENT), 7)), CLR_TEXT);
  }
//+------------------------------------------------------------------+
//| Section SESI & RANGE: sesi aktif + sisa waktu; OR per sesi       |
//| TERPISAH (high/low/size/status) + candle timer.                  |
//+------------------------------------------------------------------+
void CDashboard::AddSessionSection()
  {
   AddLine("─ SESI & RANGE ─", CLR_TEXT_DIM);

   int cur = g_sessions.GetCurrentSession();
   if(cur != SESS_NONE)
     {
      int left = g_sessions.GetSecondsToSessionEnd(cur);
      AddLine(StringFormat("Aktif: %s | sisa %s", g_sessions.SessionName(cur), FormatClock(left)),
              g_sessions.SessionColor(cur));
     }
   else
      AddLine("Aktif: none", CLR_NEUTRAL);

   for(int s = 0; s < SESS_COUNT; s++)
     {
      const SSessionTimes &t  = g_sessions.GetTimes(s);
      const SSessionRange &r  = g_sessions.GetRange(s);
      color   c = g_sessions.SessionColor(s);
      string  line;

      if(!t.enabled || !t.valid)
         line = StringFormat("%-6s OFF", g_sessions.SessionName(s));
      else if(!r.formed)
        {
         datetime nowUtc = g_sessions.ToUtc(TimeCurrent());
         if(nowUtc < t.startUtc)
            line = StringFormat("%-6s -- (mulai %02d:%02d)", g_sessions.SessionName(s), t.startHour, t.startMin);
         else if(nowUtc < t.rangeEndUtc)
            line = StringFormat("%-6s OR forming…", g_sessions.SessionName(s));
         else
            line = StringFormat("%-6s OR pending", g_sessions.SessionName(s));
        }
      else
        {
         string st = RangeStatusName(r.status);
         line = StringFormat("%-6s OR %s/%s (%.1fp) %s",
                             g_sessions.SessionName(s), FmtPrice(r.high), FmtPrice(r.low), r.sizePips, st);
         if(r.status == RANGE_BREAKOUT_UP)
            c = CLR_BULL;
         else if(r.status == RANGE_BREAKOUT_DOWN)
            c = CLR_BEAR;
        }
      AddLine(line, c);
     }

   AddLine(m_timerText, CLR_TEXT);
  }
//+------------------------------------------------------------------+
//| Section STRUKTUR & SINYAL: bias HTF, state per sesi, sinyal SMC  |
//| terakhir, sisa bar retest, RSI OB/OS.                            |
//+------------------------------------------------------------------+
void CDashboard::AddStructureSection()
  {
   AddLine("─ STRUKTUR & SINYAL ─", CLR_TEXT_DIM);

   ENUM_BIAS htf   = g_smc.GetHTFBias();
   ENUM_BIAS local = g_smc.GetBias();
   AddLine(StringFormat("Bias HTF: %s | Lokal: %s", BiasName(htf), BiasName(local)),
           (htf == BIAS_BULLISH) ? CLR_BULL : (htf == BIAS_BEARISH ? CLR_BEAR : CLR_NEUTRAL));

   // state machine per sesi (compact) + detail sesi dengan setup aktif
   string states = "";
   for(int s = 0; s < SESS_COUNT; s++)
      states += g_sessions.SessionShortName(s) + ":" + StateName(g_state[s]) + "  ";
   AddLine("State " + states, CLR_TEXT);

   int actSess = SessionOfActiveSetup();
   if(actSess != SESS_NONE)
     {
      const SValidationResult &res = g_confluence.LastResult(actSess);
      AddLine(StringFormat("Breakout %s %s | skor %d/100", g_sessions.SessionName(actSess),
                           DirName(res.dir), res.score), ColorForDir(res.dir));
      string zoneTxt = StringFormat("Zona %s [%s-%s]", ZoneName(res.zone.type),
                                    FmtPrice(res.zone.bottom), FmtPrice(res.zone.top));
      AddLine(zoneTxt, CLR_TEXT);

      if(g_state[actSess] == STATE_WAITING_RETEST)
        {
         int left = g_confluence.GetRetestBarsLeft(actSess);
         AddLine(StringFormat("Retest: %d bar tersisa (limit %d)", left, InpRetestMaxBars),
                 (left <= 3) ? CLR_BEAR : CLR_TEXT);
        }

      // info sweep terakhir
      SLiqPool pool;
      const SSessionRange &r = g_sessions.GetRange(actSess);
      if(g_smc.HasRecentSweep(g_sessions.ToBroker(r.rangeStart),
                              (res.dir == BREAK_UP) ? BREAK_UP : BREAK_DOWN, pool))
         AddLine(StringFormat("Sweep: Yes (%s @%s)", (pool.isHigh ? "EQH" : "EQL"), FmtPrice(pool.level)), CLR_SWEEP);
      else
         AddLine("Sweep: No", CLR_TEXT_DIM);
     }
   else
      AddLine("Breakout: belum ada", CLR_TEXT_DIM);

   // RSI OB/OS (info dashboard — bukan gate entry)
   string rsiTxt;
   color  rsiClr = CLR_TEXT;
   if(m_rsiVal >= InpOBOSUpperLevel)
     {
      rsiTxt = StringFormat("RSI(%d): %.1f Overbought", InpOBOSPeriod, m_rsiVal);
      rsiClr = CLR_BEAR;
     }
   else if(m_rsiVal <= InpOBOSLowerLevel)
     {
      rsiTxt = StringFormat("RSI(%d): %.1f Oversold", InpOBOSPeriod, m_rsiVal);
      rsiClr = CLR_BULL;
     }
   else
      rsiTxt = StringFormat("RSI(%d): %.1f Neutral", InpOBOSPeriod, m_rsiVal);
   AddLine(rsiTxt, rsiClr);
  }
//+------------------------------------------------------------------+
//| Section POSISI & RISIKO: posisi terbuka, pending + expiry,       |
//| force-close countdown, trade harian, daily P/L.                  |
//+------------------------------------------------------------------+
void CDashboard::AddPositionSection()
  {
   AddLine("─ POSISI & RISIKO ─", CLR_TEXT_DIM);

   // posisi terbuka
   ulong posTicket = g_executor.GetPositionTicket();
   if(posTicket != 0)
     {
      string dir; double lots, entry, sl, tp, profit, pct;
      if(g_executor.GetPositionInfo(posTicket, dir, lots, entry, sl, tp, profit, pct))
        {
         color plc = (profit >= 0.0) ? CLR_BULL : CLR_BEAR;
         AddLine(StringFormat("Pos: %s %.2f @%s", dir, lots, FmtPrice(entry)), CLR_TEXT);
         AddLine(StringFormat("  SL %s | TP %s", FmtPrice(sl), FmtPrice(tp)), CLR_TEXT_DIM);
         AddLine(StringFormat("  P/L %+.2f (%+.2f%%)", profit, pct), plc);
        }
     }
   else
      AddLine("Pos: tidak ada", CLR_TEXT_DIM);

   // pending order
   ulong pendTicket = g_executor.GetPendingTicket();
   if(pendTicket != 0)
     {
      const STrackedPosition *tp = g_executor.GetTracked(pendTicket);
      if(tp != NULL)
        {
         int barsLeft = MathMax(0, InpRetestMaxBars - tp->barsSinceOpen);
         AddLine(StringFormat("Pending: %s LIMIT %.2f @%s | %d bar sisa",
                              (tp->dir == BREAK_UP ? "BUY" : "SELL"), tp->lots,
                              FmtPrice(tp->entryPrice), barsLeft), CLR_READY);
        }
     }
   else
      AddLine("Pending: tidak ada", CLR_TEXT_DIM);

   // force-close countdown sesi berjalan
   int cur = g_sessions.GetCurrentSession();
   if(cur != SESS_NONE)
     {
      int toFC = g_sessions.GetSecondsToForceClose(cur);
      if(toFC > 0)
         AddLine(StringFormat("Force-close %s: %s", g_sessions.SessionShortName(cur), FormatClock(toFC)), CLR_TEXT);
      else
         AddLine(StringFormat("Force-close %s: AKTIF", g_sessions.SessionShortName(cur)), CLR_BEAR);
     }

   // trade harian
   int todayTrades = g_risk.GetTodayTradeCount();
   double dailyPL = g_risk.GetDailyLossPercent();
   color  dcl = (dailyPL >= 0.0) ? CLR_BULL : CLR_BEAR;
   string limitTxt = (InpMaxTradesPerDay > 0) ? StringFormat("/%d", InpMaxTradesPerDay) : "";
   AddLine(StringFormat("Hari ini: %d%s trade | P/L %+.2f%%", todayTrades, limitTxt, dailyPL), dcl);
  }
//+------------------------------------------------------------------+
//| Section NEWS: status filter, blokir aktif + countdown, update    |
//| terakhir.                                                        |
//+------------------------------------------------------------------+
void CDashboard::AddNewsSection()
  {
   AddLine("─ NEWS ─", CLR_TEXT_DIM);

   if(!InpEnableNewsFilter)
     {
      AddLine("Filter: OFF", CLR_NEUTRAL);
      return;
     }

   string statusTxt;
   color  statusClr = CLR_TEXT;
   switch(g_news.GetStatus())
     {
      case NEWS_STATE_OK:           statusTxt = "OK";            statusClr = CLR_BULL; break;
      case NEWS_STATE_STALE_CACHE:  statusTxt = "STALE (cache)"; statusClr = CLR_NEWS_MED; break;
      case NEWS_STATE_NO_DATA:      statusTxt = "NO DATA";       statusClr = CLR_BEAR; break;
      default:                      statusTxt = "OFF";           statusClr = CLR_NEUTRAL; break;
     }

   string updTxt = (g_news.GetLastUpdate() > 0) ? TimeHHMM(g_news.GetLastUpdate()) : "--:--";
   AddLine(StringFormat("Filter: ON [%s] upd %s | %s", statusTxt, updTxt, g_news.GetRelevantCurrency()),
           statusClr);

   string reason;
   if(g_news.IsBlockedNow(reason))
     {
      int left = g_news.GetSecondsBlockedRemaining();
      AddLine(StringFormat("BLOKIR: %s (sisa %s)", reason, FormatClock(left)), CLR_NEWS_HIGH);
     }
   else
     {
      string next = g_news.GetNextEventLabel();
      if(next != "")
        {
         int sec = g_news.GetSecondsToNextEvent();
         AddLine(StringFormat("Event: %s (dalam %s)", next, FormatClock(sec)), CLR_NEWS_MED);
        }
      else
         AddLine("Event: tidak ada", CLR_TEXT_DIM);
     }
  }
//+------------------------------------------------------------------+
//| === UTIL ===                                                     |
//+------------------------------------------------------------------+
string CDashboard::StateName(ENUM_EA_STATE st)
  {
   switch(st)
     {
      case STATE_IDLE:               return "Idle";
      case STATE_RANGE_FORMING:      return "Forming";
      case STATE_WAITING_BREAKOUT:   return "WaitBreak";
      case STATE_BREAKOUT_CONFIRMED: return "BrkConf";
      case STATE_WAITING_RETEST:     return "WaitRetest";
      case STATE_READY_ENTRY:        return "READY";
      case STATE_TRADED:             return "Traded";
     }
   return "?";
  }
//+------------------------------------------------------------------+
color CDashboard::StateColor(ENUM_EA_STATE st)
  {
   switch(st)
     {
      case STATE_IDLE:               return CLR_NEUTRAL;
      case STATE_RANGE_FORMING:      return CLR_ASIA;
      case STATE_WAITING_BREAKOUT:   return C'255,210,80';
      case STATE_BREAKOUT_CONFIRMED: return CLR_CHOCH;
      case STATE_WAITING_RETEST:     return CLR_BOS;
      case STATE_READY_ENTRY:        return CLR_READY;   // SAMA dengan warna panah entry
      case STATE_TRADED:             return CLR_NY;
     }
   return CLR_NEUTRAL;
  }
//+------------------------------------------------------------------+
string CDashboard::RangeStatusName(ENUM_RANGE_STATUS st)
  {
   switch(st)
     {
      case RANGE_RANGING:       return "Ranging";
      case RANGE_BREAKOUT_UP:   return "Breakout Up";
      case RANGE_BREAKOUT_DOWN: return "Breakout Down";
     }
   return "-";
  }
//+------------------------------------------------------------------+
string CDashboard::BiasName(ENUM_BIAS b)
  {
   switch(b)
     {
      case BIAS_BULLISH: return "Bullish";
      case BIAS_BEARISH: return "Bearish";
     }
   return "None";
  }
//+------------------------------------------------------------------+
string CDashboard::DirName(ENUM_BREAK_DIR d)
  {
   switch(d)
     {
      case BREAK_UP:   return "UP";
      case BREAK_DOWN: return "DOWN";
     }
   return "?";
  }
//+------------------------------------------------------------------+
string CDashboard::ZoneName(ENUM_ZONE_TYPE z)
  {
   switch(z)
     {
      case ZONE_ORDER_BLOCK: return "OB";
      case ZONE_FVG:         return "FVG";
     }
   return "-";
  }
//+------------------------------------------------------------------+
//| Warna arah breakout (konsisten dgn panah entry)                  |
//+------------------------------------------------------------------+
color CDashboard::ColorForDir(ENUM_BREAK_DIR d)
  {
   switch(d)
     {
      case BREAK_UP:   return CLR_BULL;
      case BREAK_DOWN: return CLR_BEAR;
     }
   return CLR_NEUTRAL;
  }
//+------------------------------------------------------------------+
//| Sesi dengan setup aktif (utk detail struktur)                    |
//+------------------------------------------------------------------+
int CDashboard::SessionOfActiveSetup()
  {
   int cur = g_sessions.GetCurrentSession();
   if(cur != SESS_NONE && g_confluence.HasActiveSetup(cur))
      return cur;
   // fallback: cari sesi lain yang masih punya setup aktif
   for(int s = 0; s < SESS_COUNT; s++)
      if(g_confluence.HasActiveSetup(s))
         return s;
   return SESS_NONE;
  }

#endif // ORBSMC_DASHBOARD_MQH
