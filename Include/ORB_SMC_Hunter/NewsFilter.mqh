//+------------------------------------------------------------------+
//|                                                    NewsFilter.mqh|
//| Kalender ekonomi investing.com via WebRequest():                   |
//|   https://sslecal2.investing.com/                                   |
//| CATATAN SETUP WAJIB: URL tsb harus didaftarkan di MT5 → Tools →    |
//| Options → Expert Advisors → "Allow WebRequest for listed URL".      |
//| Tanpa izin, request SELALU gagal — EA tetap jalan (fail-safe).      |
//|                                                                  |
//| Fail-safe, bukan fail-block:                                       |
//|  - WebRequest/parse gagal → warning + pakai cache terakhir valid;   |
//|  - tidak ada cache sama sekali → filter NONAKTIF + peringatan        |
//|    (dashboard + log), trading lanjut;                                 |
//|  - Strategy Tester: WebRequest tidak tersedia → tanpa data.          |
//|                                                                  |
//| Parsing TOLERAN terhadap perubahan markup:                           |
//|  - unit = blok "<tr…</tr>"; sel = teks antar-tag;                    |
//|  - event butuh sel waktu HH:MM + sel currency 3 huruf kapital +      |
//|    judul; baris rusak di-skip tanpa membatalkan batch;               |
//|  - tanggal dari header hari ("Monday, August 31, 2026") — feed       |
//|    kronologis, header mendahului barisnya;                             |
//|  - impact via heuristik token; server-side `importance=` sudah         |
//|    membatasi set, jadi impact heuristik hanya menentukan WARNA marker. |
//| Waktu: feed dianggap GMT+0 (timeZone=11) + koreksi InpNewsTzShiftMin; |
//| dikonversi ke jam BROKER via gmtOffset utk blokade & render.           |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_NEWSFILTER_MQH
#define ORB_SMC_HUNTER_NEWSFILTER_MQH

#include "HunterSettings.mqh"

class CNewsFilter
  {
private:
   SHunterSettings     m_cfg;
   SNewsEvent          m_events[HUNT_MAX_NEWS];    // cache (hanya relevan)
   int                 m_count;
   datetime            m_lastFetchBrk;              // ruang waktu broker
   bool                m_hasData;
   string              m_cur1;                      // currency target #1
   string              m_cur2;                      // currency target #2 ("" = tak ada)
   string              m_lastError;

   static string       MonthName(const int i)
     {
      string names[12]={"January","February","March","April","May","June",
                         "July","August","September","October","November","December"};
      if(i<0 || i>11)
         return("");
      return(names[i]);
     }
   /** Index bulan (1..12) dari teks (case-insensitive); 0 = tak ada. */
   static int          MonthIndexLower(const string low)
     {
      for(int i=0;i<12;i++)
         if(StringFind(low,HUNT_ToLower(MonthName(i)))>=0)
            return(i+1);
      return(0);
     }
   static bool         IsTimeCell(const string cell)
     {
      if(StringLen(cell)!=5)
         return(false);
      if(StringGetCharacter(cell,2)!=':')
         return(false);
      for(int k=0;k<5;k++)
        {
         if(k==2)
            continue;
         ushort ch=StringGetCharacter(cell,k);
         if(ch<'0' || ch>'9')
            return(false);
        }
      return(true);
     }
   static bool         IsCurrencyCell(const string cell)
     {
      if(StringLen(cell)!=3)
         return(false);
      for(int k=0;k<3;k++)
        {
         ushort ch=StringGetCharacter(cell,k);
         if(ch<'A' || ch>'Z')
            return(false);
        }
      return(true);
     }
   /** Auto-detect currency target dr _Symbol (posisi 0-2 & 3-5, tahan
       suffix). Base fiat ikut; non-fiat (XAU/XAG/US500) → quote saja. */
   void                ResolveCurrency(void)
     {
      m_cur1="";
      m_cur2="";
      string over=m_cfg.newsCurrencyOverride;
      StringTrimLeft(over);
      StringTrimRight(over);
      if(over!="")
        {
         int c=StringFind(over,",");
         if(c>0)
           {
            m_cur1=HUNT_ToUpper(StringSubstr(over,0,c));
            m_cur2=HUNT_ToUpper(HUNT_Trim(StringSubstr(over,c+1)));
           }
         else
            m_cur1=HUNT_ToUpper(over);
         return;
        }
      string sym=_Symbol;
      if(StringLen(sym)<6)
         return;
      string base=HUNT_ToUpper(StringSubstr(sym,0,3));
      string quote=HUNT_ToUpper(StringSubstr(sym,3,3));
      m_cur1=quote;
      bool fiat=(base=="EUR"||base=="GBP"||base=="JPY"||base=="CHF"||
                 base=="AUD"||base=="NZD"||base=="CAD"||base=="CNH"||base=="CNY");
      if(fiat)
         m_cur2=base;
     }

   /** GET feed; [out] html. Return true + HTTP 200. */
   bool                FetchCalendar(string &html)
     {
      html="";
      if(MQLInfoInteger(MQL_TESTER))
        {
         m_lastError="WebRequest tidak tersedia di Strategy Tester";
         return(false);
        }
      string url=m_cfg.newsUrlBase+"/?columns=exc_currency,exc_importance,exc_actual,"
                  "exc_forecast,exc_previous&features=datepicker&calType=week&count=250"
                  "&timeZone=11"+(m_cfg.newsIncludeMedium ? "&importance=2,3" : "&importance=3");
      string headers="User-Agent: Mozilla/5.0\r\n";
      uchar   post[];
      uchar   recv[];
      string  hdrOut;
      ArrayResize(post,0);
      ResetLastError();
      int code=WebRequest(WEB_REQ_TYPE_GET,url,headers,(uint)m_cfg.newsFetchTimeoutMs,post,recv,hdrOut);
      if(code<=0)
        {
         m_lastError=StringFormat("WebRequest err=%d (cek Allow WebRequest URL)",GetLastError());
         return(false);
        }
      if(code!=200)
        {
         m_lastError=StringFormat("HTTP %d",code);
         return(false);
        }
      html=CharArrayToString(recv,0,WHOLE_ARRAY,CP_UTF8);
      if(StringLen(html)<100)
        {
         m_lastError="response kosong";
         return(false);
        }
      return(true);
     }
   /** Ekstrak teks antar-tag satu baris <tr> → cells[] tertrim. */
   void                ExtractCells(const string line,string &cells[],int &nCells,const int maxCells) const
     {
      nCells=0;
      string buf="";
      bool inTag=false;
      int len=StringLen(line);
      for(int i=0;i<len;i++)
        {
         ushort ch=StringGetCharacter(line,i);
         if(ch=='<')
           {
            if(buf!="")
              {
               if(nCells<maxCells)
                  cells[nCells++]=buf;
               buf="";
              }
            inTag=true;
           }
         else if(ch=='>')
            inTag=false;
         else if(!inTag)
            buf+=ShortToString(ch);
        }
      if(buf!="" && nCells<maxCells)
         cells[nCells++]=buf;
      for(int c=0;c<nCells;c++)
        {
         string t=cells[c];
         StringReplace(t,"\t"," ");
         StringReplace(t,"\r"," ");
         StringReplace(t,"\n"," ");
         StringReplace(t,"&nbsp;"," ");
         StringReplace(t,"&amp;","&");
         StringTrimLeft(t);
         StringTrimRight(t);
         cells[c]=t;
        }
     }
   /** Heuristik impact dr raw line (lowercase). Return 1..3. */
   int                 HeuristikImpact(const string lineLow) const
     {
      if(StringFind(lineLow,"importance=\"3\"")>=0 || StringFind(lineLow,"imp3")>=0 ||
         StringFind(lineLow,"impact-high")>=0 || StringFind(lineLow,"\"high impact\"")>=0)
         return(3);
      if(StringFind(lineLow,"importance=\"2\"")>=0 || StringFind(lineLow,"imp2")>=0 ||
         StringFind(lineLow,"impact-medium")>=0 || StringFind(lineLow,"\"medium impact\"")>=0)
         return(2);
      if(StringFind(lineLow,"importance=\"1\"")>=0 || StringFind(lineLow,"imp1")>=0)
         return(1);
      return(m_cfg.newsIncludeMedium ? 2 : 3);   // lihat catatan header
     }
   /** Parse header hari: "Monday, August 31, 2026" → date (jam 00). */
   bool                ParseDayHeader(const string cellLow,const string cellRaw,datetime &dayOut) const
     {
      int mi=MonthIndexLower(cellLow);
      if(mi==0 || StringLen(cellRaw)<8 || StringLen(cellRaw)>120)
         return(false);
      int yp=StringFind(cellLow,"20");
      if(yp<0)
         return(false);
      int year=(int)StringToInteger(StringSubstr(cellRaw,yp,4));
      if(year<2000 || year>2100)
         return(false);
      int mp=StringFind(cellLow,HUNT_ToLower(MonthName(mi-1)));
      if(mp<0)
         return(false);
      int dp=mp+(int)StringLen(MonthName(mi-1));
      while(dp<StringLen(cellRaw) && !(StringGetCharacter(cellRaw,dp)>='0' &&
            StringGetCharacter(cellRaw,dp)<='9'))
         dp++;
      int dd=0;
      while(dp<StringLen(cellRaw) && StringGetCharacter(cellRaw,dp)>='0' &&
            StringGetCharacter(cellRaw,dp)<='9')
        {
         dd=dd*10+(StringGetCharacter(cellRaw,dp)-'0');
         dp++;
        }
      if(dd<1 || dd>31)
         return(false);
      MqlDateTime dt;
      dt.year=year; dt.mon=mi; dt.day=dd; dt.hour=0; dt.min=0; dt.sec=0;
      dayOut=StructToTime(dt);
      return(true);
     }

public:
                     CNewsFilter(void) : m_count(0), m_lastFetchBrk(0),
                                         m_hasData(false) {}

   bool              Init(const SHunterSettings &cfg)
     {
      m_cfg=cfg;
      ResolveCurrency();
      if(!m_cfg.newsEnabled)
         PrintFormat("%s | NewsFilter DINONAKTIFKAN via input",HUNT_NAME);
      else if(m_cur1=="")
        {
         m_lastError="currency target tidak terdeteksi dari simbol";
         PrintFormat("%s | WARNING: %s — isi InpNewsCurrencyOverride manual",HUNT_NAME,m_lastError);
        }
      return(true);
     }

   /** Refresh terjadwal (per newsRefreshHours). Kegagalan ditelan
       (fail-safe). [in] nowBrk TimeCurrent(). Return true data BARU. */
   bool              RefreshIfNeeded(const datetime nowBrk)
     {
      if(!m_cfg.newsEnabled)
         return(false);
      int maxAge=m_cfg.newsRefreshHours*3600;
      if(maxAge<3600)
         maxAge=3600;
      if(m_lastFetchBrk!=0 && (nowBrk-m_lastFetchBrk)<maxAge)
         return(false);
      return(Refresh(nowBrk));
     }
   /** Force fetch+parse. Gagal → warning, cache lama dipakai. */
   bool              Refresh(const datetime nowBrk)
     {
      m_lastFetchBrk=nowBrk;
      if(!m_cfg.newsEnabled)
         return(false);
      string html;
      if(!FetchCalendar(html))
        {
         PrintFormat("%s | NEWS FETCH GAGAL: %s — %s",HUNT_NAME,m_lastError,
                     m_hasData ? "memakai cache lama" : "FILTER NEWS TIDAK AKTIF (warning)");
         return(false);
        }
      SNewsEvent tmp[HUNT_MAX_NEWS];
      int n=0;
      datetime curDay=0;
      const int maxC=16;
      string cells[];
      int nc=0;
      int pos=0;
      int hlen=(int)StringLen(html);
      for(;;)
        {
         int p1=StringFind(html,"<tr",pos);
         if(p1<0)
            break;
         int p2=StringFind(html,"</tr",p1);
         if(p2<0)
            p2=hlen;
         string line=StringSubstr(html,p1,p2-p1);
         pos=p2+1;
         string low=HUNT_ToLower(line);
         ArrayResize(cells,maxC);
         nc=0;
         ExtractCells(line,cells,nc,maxC);
         if(nc<=0)
            continue;
         //--- header hari?
         datetime dd0;
         if(ParseDayHeader(HUNT_ToLower(cells[0]),cells[0],dd0))
           {
            curDay=dd0;
            continue;
           }
         if(curDay==0)
            continue;                              // sebelum header pertama
         //--- sel waktu event
         int tCell=-1;
         for(int c=0;c<nc;c++)
            if(IsTimeCell(cells[c]))
              {
               tCell=c;
               break;
              }
         if(tCell<0)
            continue;
         int cc=-1;
         for(int c=tCell+1;c<nc;c++)
            if(IsCurrencyCell(cells[c]))
              {
               cc=c;
               break;
              }
         if(cc<0)
            continue;
         string title="";
         for(int c=cc+1;c<nc;c++)
           {
            string t=cells[c];
            if(StringLen(t)<4)
               continue;
            ushort ch0=StringGetCharacter(t,0);
            if(ch0>='0' && ch0<='9')
               continue;
            if(StringFind(t,"%")==0)
               continue;
            title=t;
            break;
           }
         if(title=="")
            continue;
         int hh=(int)StringToInteger(StringSubstr(cells[tCell],0,2));
         int mm=(int)StringToInteger(StringSubstr(cells[tCell],3,2));
         if(hh<0 || hh>23 || mm<0 || mm>59)
            continue;
         int imp=HeuristikImpact(low);
         string cur=cells[cc];
         bool curOk=(cur==m_cur1 || (m_cur2!="" && cur==m_cur2));
         bool impOk=(imp>=3 || (m_cfg.newsIncludeMedium && imp>=2));
         if(!curOk || !impOk)
            continue;
         if(n>=HUNT_MAX_NEWS)
            break;
         SNewsEvent ev;
         ev.timeUtc=curDay+hh*3600+mm*60+m_cfg.newsTzShiftMin*60;
         ev.timeBroker=ev.timeUtc+m_cfg.gmtOffset*3600;
         ev.currency=cur;
         ev.title=title;
         ev.impact=(ENUM_HUNT_NEWS_IMPACT)imp;
         ev.relevant=true;
         ev.blockFrom=ev.timeBroker-m_cfg.newsBeforeMin*60;
         ev.blockTo=ev.timeBroker+m_cfg.newsAfterMin*60;
         int ins=n;
         while(ins>0 && tmp[ins-1].timeBroker>ev.timeBroker)
           {
            tmp[ins]=tmp[ins-1];
            ins--;
           }
         tmp[ins]=ev;
         n++;
        }
      if(n==0 && m_hasData && curDay==0)
        {
         m_lastError="parse 0 event & tanpa header hari — markup mungkin berubah";
         PrintFormat("%s | WARNING: %s — cache lama dipakai",HUNT_NAME,m_lastError);
         return(false);
        }
      for(int i=0;i<n && i<HUNT_MAX_NEWS;i++)
         m_events[i]=tmp[i];
      m_count=(n<HUNT_MAX_NEWS ? n : HUNT_MAX_NEWS);
      m_hasData=true;
      m_lastError="";
      PrintFormat("%s | news refreshed: %d event relevan utk %s%s",HUNT_NAME,m_count,m_cur1,
                  (m_cur2!="" ? ","+m_cur2 : ""));
      return(true);
     }

   //--- query ---------------------------------------------------------------
   /** Blokir entry baru sekarang? [out] label utk log/dashboard. */
   bool              IsEntryBlocked(const datetime nowBrk,string &label) const
     {
      label="";
      if(!m_cfg.newsEnabled || !m_hasData)
         return(false);
      for(int i=0;i<m_count;i++)
         if(nowBrk>=m_events[i].blockFrom && nowBrk<=m_events[i].blockTo)
           {
            int mins=(int)((m_events[i].timeBroker-nowBrk)/60);
            label=StringFormat("%s · %s (%+dm)",m_events[i].currency,m_events[i].title,mins);
            return(true);
           }
      return(false);
     }
   /** Event dlm jendela display utk renderer. Return jumlah disalin. */
   int               GetVisibleEvents(SNewsEvent &dst[],const int dstMax,
                                      const datetime nowBrk) const
     {
      int k=0;
      for(int i=0;i<m_count && k<dstMax;i++)
         if(m_events[i].blockTo>nowBrk-8*3600 && m_events[i].timeBroker<nowBrk+40*3600)
            dst[k++]=m_events[i];
      return(k);
     }
   /** Status ringkas utk dashboard. */
   SNewsStatus       Status(const datetime nowBrk) const
     {
      SNewsStatus st;
      st.enabled=m_cfg.newsEnabled;
      st.hasData=m_hasData;
      st.stale=(m_hasData && m_cfg.newsCacheMaxAgeHours>0 &&
                (nowBrk-m_lastFetchBrk)>m_cfg.newsCacheMaxAgeHours*3600);
      st.blockedNow=false;
      st.blockedEvent="";
      st.lastFetchUtc=0;
      st.nextEventUtc=0;
      st.eventCount=m_count;
      string lab;
      if(IsEntryBlocked(nowBrk,lab))
        {
         st.blockedNow=true;
         st.blockedEvent=lab;
        }
      st.lastFetchUtc=m_lastFetchBrk;
      for(int i=0;i<m_count;i++)
         if(m_events[i].timeBroker>nowBrk)
           {
            st.nextEventUtc=m_events[i].timeBroker;
            break;
           }
      return(st);
     }
   bool              IsStale(const datetime nowBrk) const
     {
      if(!m_hasData)
         return(true);
      if(m_cfg.newsCacheMaxAgeHours<=0)
         return(false);
      return((nowBrk-m_lastFetchBrk)>m_cfg.newsCacheMaxAgeHours*3600);
     }
   string            LastError(void) const   { return(m_lastError); }
   string            Currency1(void) const   { return(m_cur1); }
   string            Currency2(void) const   { return(m_cur2); }
  };

#endif // ORB_SMC_HUNTER_NEWSFILTER_MQH
//+------------------------------------------------------------------+
