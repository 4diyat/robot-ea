//+------------------------------------------------------------------+
//| ORB_SMC_NextGen — NewsFilter.mqh                                 |
//| Mengambil jadwal news dari https://sslecal2.investing.com/       |
//| (economic calendar investing.com) via WebRequest().              |
//|                                                                    |
//| SETUP WAJIB (bukan bagian kode): tambahkan URL berikut ke daftar |
//| "Allow WebRequest for listed URL" di MT5: Tools → Options →      |
//| Expert Advisors → Allow WebRequest. TANPA ini WebRequest gagal.  |
//|                                                                    |
//| Desain:                                                           |
//|  - Refresh saat OnInit + periodik per InpNewsRefreshHours —      |
//|    BUKAN tiap tick. Hasil disimpan dalam cache in-memory         |
//|    (array struct: waktu event, currency, impact, judul).         |
//|  - Parsing toleran: MQL5 TIDAK punya regex engine, jadi parsing  |
//|    memakai StringFind/StringSubstr yang toleran terhadap         |
//|    perubahan minor struktur HTML (mencari marker stabil:         |
//|    "js-event-item", "data-event-datetime", "ceFlags",            |
//|    "Volatility Expected").                                       |
//|  - FAIL-SAFE, bukan FAIL-BLOCK: gagal fetch/parse → log warning  |
//|    + pakai cache terakhir yang masih valid; tanpa cache sama     |
//|    sekali → EA tetap boleh trading + peringatan "news filter     |
//|    tidak aktif". Kegagalan fetch TIDAK menghentikan EA.          |
//|  - Filter hanya event high-impact (dan medium bila               |
//|    InpIncludeMediumImpact) untuk currency simbol (XAUUSD → USD;  |
//|    auto-detect base/quote dari _Symbol, override manual via      |
//|    InpNewsCurrencyOverride).                                     |
//|  - Hanya memblokir ENTRY BARU pada window [t-before, t+after];   |
//|    posisi terbuka tidak disentuh sama sekali.                    |
//| Fase 3: TERIMPLEMENTASI.                                         |
//+------------------------------------------------------------------+
#ifndef ORBSMC_NEWS_FILTER_MQH
#define ORBSMC_NEWS_FILTER_MQH

#include <ORB_SMC_NextGen\Defines.mqh>

//+------------------------------------------------------------------+
//| Satu event news dari kalender                                   |
//+------------------------------------------------------------------+
struct SNewsEvent
  {
   datetime        time;         // waktu event (broker time)
   string          currency;     // "USD", "EUR", ...
   string          title;        // judul event (dipotong agar label pendek)
   ENUM_NEWS_IMPACT impact;      // LOW/MEDIUM/HIGH
   bool            relevant;     // lolos filter currency + impact
  };

//+------------------------------------------------------------------+
//| Status fetch terakhir (untuk dashboard: fresh/stale/off)         |
//+------------------------------------------------------------------+
enum ENUM_NEWS_STATUS
  {
   NEWS_STATE_OFF = 0,        // filter dimatikan via input
   NEWS_STATE_OK,             // data segar
   NEWS_STATE_STALE_CACHE,    // fetch gagal — pakai cache lama
   NEWS_STATE_NO_DATA         // belum pernah sukses — filter tidak aktif (trading tetap boleh)
  };

//+------------------------------------------------------------------+
//| Util parsing lokal (bukan regex — string search toleran)         |
//+------------------------------------------------------------------+
static bool NFindBetween(const string &s, int from, const string &left, const string &right, string &out)
  {
   int l = StringFind(s, left, from);
   if(l < 0)
      return false;
   l += StringLen(left);
   int r = StringFind(s, right, l);
   if(r < 0)
      return false;
   out = StringSubstr(s, l, r - l);
   return true;
  }
//+------------------------------------------------------------------+
//| Ambil token 3 huruf besar (kode currency) mulai posisi tertentu  |
//+------------------------------------------------------------------+
static string NExtract3Upper(const string &s, int from)
  {
   int len = StringLen(s);
   for(int i = from; i < len - 2; i++)
     {
      bool ok = true;
      for(int k = 0; k < 3; k++)
        {
         ushort ch = StringGetCharacter(s, i + k);
         if(ch < 'A' || ch > 'Z')
           {
            ok = false;
            break;
           }
        }
      if(ok)
         return StringSubstr(s, i, 3);
     }
   return "";
  }
//+------------------------------------------------------------------+
//| Bersihkan entity HTML dasar (&amp; &nbsp; &quot; dll)            |
//+------------------------------------------------------------------+
static string NCleanEntities(string s)
  {
   StringReplace(s, "&amp;", "&");
   StringReplace(s, "&nbsp;", " ");
   StringReplace(s, "&quot;", "\"");
   StringReplace(s, "&#39;", "'");
   StringReplace(s, "&lt;", "<");
   StringReplace(s, "&gt;", ">");
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
  }

//+------------------------------------------------------------------+
//| CNewsFilter                                                      |
//+------------------------------------------------------------------+
class CNewsFilter
  {
public:
   //--- lifecycle ---
   bool            Init();            // fetch pertama (async — tidak blocking) bila diaktifkan
   void            OnTick();          // cek jadwal refresh periodik (ringan)
   void            Refresh();         // fetch + parse + ganti cache bila sukses
   void            OnDeinit();        // (cadangan untuk teardown bila perlu)

   //--- query (dipakai ConfluenceValidator + Dashboard) ---
   bool            IsEnabled();                     // InpEnableNewsFilter
   ENUM_NEWS_STATUS GetStatus();                    // status data
   datetime        GetLastUpdate();                 // waktu cache terakhir diperbarui
   int             GetEventCount();                 // jumlah event relevan dalam cache
   const SNewsEvent& GetEvent(int i);               // guard index → dummy
   bool            IsBlockedNow(string &reason);    // sekarang dalam window blokir? (alasan utk dashboard)
   int             GetSecondsToNextEvent();         // detik ke event relevan terdekat (mendatang)
   int             GetSecondsBlockedRemaining();    // detik tersisa window blokir saat ini (0 = tidak diblokir)
   string          GetNextEventLabel();             // label ringkas event terdekat ("USD CPI 14:30")
   string          GetRelevantCurrency();           // auto-detect / override — untuk log & dashboard

private:
   SNewsEvent      m_events[MAX_NEWS_EVENTS];
   int             m_eventCount;
   datetime        m_lastUpdate;      // waktu cache terakhir valid
   datetime        m_lastAttempt;     // waktu percobaan fetch terakhir (retry saat NO_DATA)
   ENUM_NEWS_STATUS m_status;
   bool            m_initOk;

   //--- HTTP & parsing ---
   int             HttpGetCalendar(string &html);   // WebRequest ke investing.com → status code
   int             ParseCalendar(const string &html); // parse toleran → jumlah event baru (-1 = gagal)
   string          ExtractCurrency(const string &frag);
   string          ExtractTitle(const string &frag);
   datetime        ExtractEventTime(const string &frag);
   ENUM_NEWS_IMPACT ExtractImpact(const string &frag);
   bool            ImpactPasses(ENUM_NEWS_IMPACT impact);    // high (+medium bila input)
   bool            CurrencyMatches(const string &currency);  // vs simbol / override
  };

//+------------------------------------------------------------------+
//| Inisialisasi — fetch pertama (WebRequest tidak blocking)        |
//+------------------------------------------------------------------+
bool CNewsFilter::Init()
  {
   m_eventCount  = 0;
   m_lastUpdate  = 0;
   m_lastAttempt = 0;
   m_status      = NEWS_STATE_OFF;
   ZeroMemory(m_events);
   m_initOk = true;

   if(!InpEnableNewsFilter)
     {
      Print(EA_TITLE, " : news filter NONAKTIF (InpEnableNewsFilter=false)");
      return true;
     }

   Refresh();
   if(m_status == NEWS_STATE_NO_DATA)
      Print(EA_TITLE, " : PERINGATAN — data news belum tersedia, news filter TIDAK AKTIF untuk sementara (trading tetap diizinkan).");
   return true;
  }
//+------------------------------------------------------------------+
//| Cek jadwal refresh periodik (sekali per bar agar hemat)         |
//+------------------------------------------------------------------+
void CNewsFilter::OnTick()
  {
   if(!m_initOk || !InpEnableNewsFilter)
      return;

   // refresh per bar baru bila jadwal tiba
   static datetime lastBarCheck = 0;
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime == lastBarCheck)
      return;
   lastBarCheck = barTime;

   datetime now = TimeCurrent();
   bool needRefresh = false;
   if(m_lastUpdate == 0)
      needRefresh = true;   // belum pernah sukses
   else if(InpNewsRefreshHours > 0 && (now - m_lastUpdate) >= InpNewsRefreshHours * 3600)
      needRefresh = true;

   // status NO_DATA → coba lagi tiap 30 menit
   if(m_status == NEWS_STATE_NO_DATA && (now - m_lastAttempt) >= 1800)
      needRefresh = true;

   if(needRefresh)
      Refresh();
  }
//+------------------------------------------------------------------+
//| Fetch + parse — berhasil → ganti cache; gagal → pertahankan cache|
//+------------------------------------------------------------------+
void CNewsFilter::Refresh()
  {
   if(!InpEnableNewsFilter)
     {
      m_status = NEWS_STATE_OFF;
      return;
     }

   m_lastAttempt = TimeCurrent();

   string html = "";
   int code = HttpGetCalendar(html);

   if(code == 200 && StringLen(html) > 2000)
     {
      int n = ParseCalendar(html);
      if(n > 0)
        {
         m_status     = NEWS_STATE_OK;
         m_lastUpdate = TimeCurrent();
         Print(EA_TITLE, " : news filter di-refresh — ", n, " event relevan (",
               GetRelevantCurrency(), ")");
         return;
        }
      Print(EA_TITLE, " : parsing news menghasilkan 0 event relevan — cache lama dipertahankan");
     }
   else
      Print(EA_TITLE, " : fetch news gagal (HTTP ", code, ") — pakai cache lama bila ada");

   m_status = (m_eventCount > 0) ? NEWS_STATE_STALE_CACHE : NEWS_STATE_NO_DATA;
  }
//+------------------------------------------------------------------+
void CNewsFilter::OnDeinit()
  {
   // tidak ada resource persist — disediakan untuk ekspansi
  }
//+------------------------------------------------------------------+
bool CNewsFilter::IsEnabled()
  {
   return InpEnableNewsFilter;
  }
//+------------------------------------------------------------------+
ENUM_NEWS_STATUS CNewsFilter::GetStatus()
  {
   if(!InpEnableNewsFilter)
      return NEWS_STATE_OFF;
   return m_status;
  }
//+------------------------------------------------------------------+
datetime CNewsFilter::GetLastUpdate()
  {
   return m_lastUpdate;
  }
//+------------------------------------------------------------------+
int CNewsFilter::GetEventCount()
  {
   return m_eventCount;
  }
//+------------------------------------------------------------------+
const SNewsEvent& CNewsFilter::GetEvent(int i)
  {
   static SNewsEvent dummy;
   if(i < 0 || i >= m_eventCount)
      return dummy;
   return m_events[i];
  }
//+------------------------------------------------------------------+
//| Sekarang berada dalam window blokir entry?                       |
//+------------------------------------------------------------------+
bool CNewsFilter::IsBlockedNow(string &reason)
  {
   if(!InpEnableNewsFilter || m_eventCount <= 0)
      return false;
   datetime now = TimeCurrent();
   for(int i = 0; i < m_eventCount; i++)
     {
      const SNewsEvent &e = m_events[i];
      if(!e.relevant)
         continue;
      datetime t0 = e.time - InpNewsBufferBeforeMin * 60;
      datetime t1 = e.time + InpNewsBufferAfterMin * 60;
      if(now >= t0 && now < t1)
        {
         reason = e.currency + " " + e.title + " (" + TimeHHMM(e.time) + ")";
         return true;
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
//| Detik menuju event relevan terdekat di masa depan                |
//+------------------------------------------------------------------+
int CNewsFilter::GetSecondsToNextEvent()
  {
   datetime now = TimeCurrent();
   int best = INT_MAX;
   for(int i = 0; i < m_eventCount; i++)
     {
      const SNewsEvent &e = m_events[i];
      if(!e.relevant || e.time <= now)
         continue;
      int d = (int)(e.time - now);
      if(d < best)
         best = d;
     }
   return best;
  }
//+------------------------------------------------------------------+
//| Detik tersisa window blokir saat ini (0 = tidak diblokir)        |
//+------------------------------------------------------------------+
int CNewsFilter::GetSecondsBlockedRemaining()
  {
   if(!InpEnableNewsFilter || m_eventCount <= 0)
      return 0;
   datetime now = TimeCurrent();
   for(int i = 0; i < m_eventCount; i++)
     {
      const SNewsEvent &e = m_events[i];
      if(!e.relevant)
         continue;
      datetime t0 = e.time - InpNewsBufferBeforeMin * 60;
      datetime t1 = e.time + InpNewsBufferAfterMin * 60;
      if(now >= t0 && now < t1)
         return (int)(t1 - now);
     }
   return 0;
  }
//+------------------------------------------------------------------+
//| Label ringkas event terdekat (blokir sekarang / akan datang)     |
//+------------------------------------------------------------------+
string CNewsFilter::GetNextEventLabel()
  {
   datetime now = TimeCurrent();
   datetime bestTime = 0;
   int      bestIdx  = -1;
   for(int i = 0; i < m_eventCount; i++)
     {
      const SNewsEvent &e = m_events[i];
      if(!e.relevant)
         continue;
      // event dalam window blokir saat ini paling relevan
      datetime t0 = e.time - InpNewsBufferBeforeMin * 60;
      datetime t1 = e.time + InpNewsBufferAfterMin * 60;
      if(now >= t0 && now < t1)
         return e.currency + " " + e.title + " " + TimeHHMM(e.time);
      if(e.time > now && (bestTime == 0 || e.time < bestTime))
        {
         bestTime = e.time;
         bestIdx  = i;
        }
     }
   if(bestIdx >= 0)
      return m_events[bestIdx].currency + " " + m_events[bestIdx].title + " " + TimeHHMM(m_events[bestIdx].time);
   return "";
  }
//+------------------------------------------------------------------+
//| Currency relevan: auto-detect dari _Symbol / override manual     |
//+------------------------------------------------------------------+
string CNewsFilter::GetRelevantCurrency()
  {
   if(StringTrimLeft(InpNewsCurrencyOverride) != "" || StringTrimRight(InpNewsCurrencyOverride) != "")
     {
      string ov = InpNewsCurrencyOverride;
      StringToUpper(ov);
      StringTrimLeft(ov);
      StringTrimRight(ov);
      return ov;
     }

   string sym = _Symbol;
   StringToUpper(sym);

   // Metallic
   if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0)
      return "USD";
   if(StringFind(sym, "XAG") >= 0 || StringFind(sym, "SILVER") >= 0)
      return "USD";
   if(StringFind(sym, "XPT") >= 0 || StringFind(sym, "XPD") >= 0)
      return "USD";

   // Indeks populer
   if(StringFind(sym, "US30") >= 0 || StringFind(sym, "NAS") >= 0 ||
      StringFind(sym, "SPX") >= 0  || StringFind(sym, "USTEC") >= 0 ||
      StringFind(sym, "DJ") >= 0   || StringFind(sym, "US500") >= 0 ||
      StringFind(sym, "US100") >= 0)
      return "USD";
   if(StringFind(sym, "GER") >= 0 || StringFind(sym, "DAX") >= 0 || StringFind(sym, "DE30") >= 0 ||
      StringFind(sym, "FRA") >= 0 || StringFind(sym, "CAC") >= 0)
      return "EUR";
   if(StringFind(sym, "UK100") >= 0 || StringFind(sym, "FTSE") >= 0)
      return "GBP";
   if(StringFind(sym, "JP225") >= 0 || StringFind(sym, "NIKKEI") >= 0)
      return "JPY";

   // Pair forex standar: 6 huruf, potong suffix bila ada
   string base = sym;
   int sep = StringFind(base, ".");
   if(sep >= 0)
      base = StringSubstr(base, 0, sep);
   sep = StringFind(base, "#");
   if(sep >= 0)
      base = StringSubstr(base, 0, sep);
   sep = StringFind(base, "-");
   if(sep >= 0)
      base = StringSubstr(base, 0, sep);

   StringTrimLeft(base);
   StringTrimRight(base);
   if(StringLen(base) >= 6)
     {
      // ambil 3 huruf terakhir (quote currency)
      return StringSubstr(base, StringLen(base) - 3, 3);
     }
   return "";
  }
//+------------------------------------------------------------------+
//| HTTP GET ke investing.com (WebRequest)                           |
//+------------------------------------------------------------------+
int CNewsFilter::HttpGetCalendar(string &html)
  {
   // URL kalender dengan parameter currency & impact; timeZone sesuai offset broker
   string url = "https://sslecal2.investing.com/?columns=exc_currency,exc_importance"
                "&importance__1,2,3&calType=day&timeZone=" + IntegerToString(InpGMTOffset) + "&lang=1";

   char   post[];
   char   result[];
   string headers = "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)\r\n"
                    "Accept: text/html,application/xhtml+xml\r\n"
                    "Accept-Language: en-US,en;q=0.9\r\n";
   int timeout = 10000;   // ms

   int res = WebRequest("GET", url, headers, timeout, post, result);
   if(res != 200)
      return res;

   html = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return 200;
  }
//+------------------------------------------------------------------+
//| Parse toleran: pisahkan baris kalender per "js-event-item",      |
//| ekstrak waktu/currency/impact/title per baris, filter & simpan.  |
//+------------------------------------------------------------------+
int CNewsFilter::ParseCalendar(const string &html)
  {
   SNewsEvent parsed[MAX_NEWS_EVENTS];
   int parsedCount = 0;

   int pos = 0;
   while(parsedCount < MAX_NEWS_EVENTS)
     {
      int rowPos = StringFind(html, "js-event-item", pos);
      if(rowPos < 0)
         break;
      pos = rowPos + 1;

      // fragmen baris: sedikit sebelum marker, cukup panjang utk seluruh row
      int fragStart = MathMax(0, rowPos - 300);
      int fragLen   = MathMin(8000, StringLen(html) - fragStart);
      string frag   = StringSubstr(html, fragStart, fragLen);

      SNewsEvent ev;
      ZeroMemory(ev);
      ev.time     = ExtractEventTime(frag);
      ev.currency = ExtractCurrency(frag);
      ev.impact   = ExtractImpact(frag);
      ev.title    = ExtractTitle(frag);

      if(ev.time <= 0 || ev.currency == "" || ev.impact == IMPACT_NONE)
         continue;

      ev.relevant = ImpactPasses(ev.impact) && CurrencyMatches(ev.currency);
      if(ev.relevant)
         parsed[parsedCount++] = ev;
     }

   if(parsedCount <= 0)
      return -1;   // gagal / tidak ada event relevan — JANGAN timpa cache

   // ganti cache atomik
   ArrayCopy(m_events, parsed, 0, 0, parsedCount);
   m_eventCount = parsedCount;
   return parsedCount;
  }
//+------------------------------------------------------------------+
//| Waktu event: atribut data-event-datetime → datetime broker       |
//| Format "2024/05/01 13:30:00" (timezone sudah sesuai offset).     |
//+------------------------------------------------------------------+
datetime CNewsFilter::ExtractEventTime(const string &frag)
  {
   string raw;
   if(!NFindBetween(frag, 0, "data-event-datetime=\"", "\"", raw))
      return 0;
   StringReplace(raw, "/", ".");
   if(StringLen(raw) < 16)
      return 0;
   raw = StringSubstr(raw, 0, 16);   // "2024.05.01 13:30"
   return StringToTime(raw);
  }
//+------------------------------------------------------------------+
//| Currency: span ceFlags berisi kode 3 huruf (class="ceFlags USD") |
//+------------------------------------------------------------------+
string CNewsFilter::ExtractCurrency(const string &frag)
  {
   int p = StringFind(frag, "ceFlags");
   if(p < 0)
      return "";
   p += 7;
   // lewati atribut sampai token 3 huruf besar
   string cur = NExtract3Upper(frag, p);
   return cur;
  }
//+------------------------------------------------------------------+
//| Judul event: anchor pertama setelah "event" (potong & bersihkan) |
//+------------------------------------------------------------------+
string CNewsFilter::ExtractTitle(const string &frag)
  {
   string title;
   if(!NFindBetween(frag, 0, "<a", "</a>", title))
      return "";
   // buang atribut sampai '>'
   int gt = StringFind(title, ">");
   if(gt >= 0)
      title = StringSubstr(title, gt + 1);
   title = NCleanEntities(title);
   if(StringLen(title) > 40)
      title = StringSubstr(title, 0, 40);
   return title;
  }
//+------------------------------------------------------------------+
//| Impact: teks "High/Medium/Low Volatility Expected" pada row      |
//+------------------------------------------------------------------+
ENUM_NEWS_IMPACT CNewsFilter::ExtractImpact(const string &frag)
  {
   if(StringFind(frag, "High Volatility") >= 0)
      return IMPACT_HIGH;
   if(StringFind(frag, "Medium Volatility") >= 0 || StringFind(frag, "Moderate Volatility") >= 0)
      return IMPACT_MEDIUM;
   if(StringFind(frag, "Low Volatility") >= 0)
      return IMPACT_LOW;
   return IMPACT_NONE;
  }
//+------------------------------------------------------------------+
bool CNewsFilter::ImpactPasses(ENUM_NEWS_IMPACT impact)
  {
   if(impact == IMPACT_HIGH)
      return true;
   if(impact == IMPACT_MEDIUM && InpIncludeMediumImpact)
      return true;
   return false;
  }
//+------------------------------------------------------------------+
bool CNewsFilter::CurrencyMatches(const string &currency)
  {
   string want = GetRelevantCurrency();
   if(want == "")
      return false;
   return (currency == want);
  }

#endif // ORBSMC_NEWS_FILTER_MQH
