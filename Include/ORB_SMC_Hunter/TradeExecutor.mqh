//+------------------------------------------------------------------+
//|                                                TradeExecutor.mqh |
//| Satu-satunya modul yang menyentuh pasar. Semua order lewat CTrade  |
//| (MqlTradeRequest dibangun internal CTrade).                        |
//|                                                                  |
//|  - Magic + comment "HUNT|<KODE-SESI>" + ledger internal ticket→    |
//|    session: sumber utama atribusi sesi (fallback: parse comment);   |
//|  - Retry InpOrderRetries× utk retcode transient (requote, price    |
//|    changed/off, timeout, connection, order changed), Sleep antar    |
//|    retry; retcode lain → fail cepat dengan pesan deskriptif;        |
//|  - ENTRY_EXECUTION: market Buy/Sell + SL/TP atomik; entry di-update |
//|    ke harga fill;                                                     |
//|  - ENTRY_PENDING_ORDER: limit di tepi zona + SL/TP sejak pasang     |
//|    (dihitung dari LEVEL LIMIT, bukan harga market); expiry          |
//|    berbasis BAR (iBarShift), bukan jam;                              |
//|  - CloseSessionPositions: hanya posisi+pending dgn tag sesi tsb.    |
//+------------------------------------------------------------------+
#ifndef ORB_SMC_HUNTER_TRADEEXECUTOR_MQH
#define ORB_SMC_HUNTER_TRADEEXECUTOR_MQH

#include <Trade\Trade.mqh>
#include "DataService.mqh"

#define HUNT_TAG_MAX 64

class CTradeExecutor
  {
private:
   CTrade              m_trade;
   SHunterSettings     m_cfg;
   STicketTag          m_tags[HUNT_TAG_MAX];
   int                 m_tagCount;

   bool                IsRetryableRetcode(const uint code) const
     {
      switch(code)
        {
         case TRADE_RETCODE_REQUOTE:
         case TRADE_RETCODE_PRICE_CHANGED:
         case TRADE_RETCODE_PRICE_OFF:
         case TRADE_RETCODE_ORDER_CHANGED:
         case TRADE_RETCODE_TIMEOUT:
         case TRADE_RETCODE_CONNECTION:
            return(true);
        }
      return(false);
     }
   bool                IsOkRetcode(const uint code) const
     {
      return(code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL ||
             code==TRADE_RETCODE_PLACED);
     }
   void                LogResult(const string op) const
     {
      uint rc=m_trade.ResultRetcode();
      PrintFormat("%s | EXEC %s: ret=%u %s",HUNT_NAME,op,rc,
                  m_trade.ResultRetcodeDescription());
     }
   void                Tag(const ulong ticket,const int session,const ENUM_HUNT_DIR dir,
                           const ulong planId)
     {
      for(int i=0;i<m_tagCount;i++)
        {
         if(m_tags[i].ticket==ticket)
           {
            m_tags[i].session=(ENUM_HUNT_SESSION)session;
            m_tags[i].dir=dir;
            m_tags[i].planId=planId;
            m_tags[i].openTime=TimeCurrent();
            return;
           }
        }
      if(m_tagCount<HUNT_TAG_MAX)
        {
         m_tags[m_tagCount].ticket=ticket;
         m_tags[m_tagCount].session=(ENUM_HUNT_SESSION)session;
         m_tags[m_tagCount].dir=dir;
         m_tags[m_tagCount].planId=planId;
         m_tags[m_tagCount].openTime=TimeCurrent();
         m_tagCount++;
        }
     }
   bool                TagOf(const ulong ticket,STicketTag &dstTag) const
     {
      for(int i=0;i<m_tagCount;i++)
         if(m_tags[i].ticket==ticket)
           {
            dstTag=m_tags[i];
            return(true);
           }
      return(false);
     }
   void                Untag(const ulong ticket)
     {
      for(int i=0;i<m_tagCount;i++)
         if(m_tags[i].ticket==ticket)
           {
            for(int k=i;k<m_tagCount-1;k++)
               m_tags[k]=m_tags[k+1];
            m_tagCount--;
            return;
           }
     }
   string              MakeComment(const int session) const
     {
      string code=HUNT_CODE_ASIA;
      if(session==HUNT_SESSION_LONDON)
         code=HUNT_CODE_LONDON;
      if(session==HUNT_SESSION_NY)
         code=HUNT_CODE_NY;
      return("HUNT|"+code);
     }
   /** Atribusi sesi utk ticket server: ledger dulu, fallback parse comment
       "HUNT|XXX". Return false bila bukan milik EA. */
   bool                SessionOfTicket(const ulong ticket,int &session,const string comment) const
     {
      STicketTag tg;
      if(TagOf(ticket,tg))
        {
         session=(int)tg.session;
         return(true);
        }
      if(StringFind(comment,"HUNT|")==0)
        {
         if(StringFind(comment,HUNT_CODE_ASIA)>=0)   { session=HUNT_SESSION_ASIA;   return(true); }
         if(StringFind(comment,HUNT_CODE_LONDON)>=0) { session=HUNT_SESSION_LONDON; return(true); }
         if(StringFind(comment,HUNT_CODE_NY)>=0)     { session=HUNT_SESSION_NY;     return(true); }
        }
      return(false);
     }
   /** Jarak minimum SL/TP (stops level broker) dlm units harga. */
   double              MinStopDistance(void) const
     {
      long stops =SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
      long freeze=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
      return((double)MathMax(stops,freeze)*m_cfg.point);
     }
   /** rc khas 'market tutup/disabled' (gap maintenance kripto): jangan
       retry & jangan spam log — pemanggil cukup note + coba lagi nanti. */
   static bool         IsClosedishRc(const uint rc)
     {
      return(rc==TRADE_RETCODE_MARKET_CLOSED || rc==TRADE_RETCODE_PRICE_OFF ||
             rc==TRADE_RETCODE_TRADE_DISABLED);
     }
   /** Tipe waktu pending sesuai mode simbol: FX umumnya GTC; sebagian
       broker kripto/indeks MENOLAK GTC (hanya DAY/SPECIFIED) → error 10022
       'Invalid expiration'. Pilih otomatis dr flag mode simbol. */
   void                ResolvePendingTime(ENUM_ORDER_TYPE_TIME &t,datetime &exp) const
     {
      t=ORDER_TIME_GTC;
      exp=0;
      //--- SYMBOL_EXPIRATION_MODE = bitmask flag ENUM_SYMBOL_EXPIRATION_MODE
      //--- (GTC=1, DAY=2, SPECIFIED=4). Jangan pakai nama flag sbg properti.
      long mode=SymbolInfoInteger(_Symbol,SYMBOL_EXPIRATION_MODE);
      if((mode&(long)SYMBOL_EXPIRATION_GTC)!=0)
         return;                                   // mode normal: GTC
      int hrs=m_cfg.pendingExpireHours;
      if(hrs<1)
         hrs=24;
      if((mode&(long)SYMBOL_EXPIRATION_SPECIFIED)!=0)
        {
         t=ORDER_TIME_SPECIFIED;
         exp=TimeTradeServer()+(datetime)(hrs*3600);
         return;
        }
      if((mode&(long)SYMBOL_EXPIRATION_DAY)!=0)
         t=ORDER_TIME_DAY;
     }

   /** Bulatkan ke grid tick size (aman utk simbol tick≠10^-digits). */
   double              Grid(const double price) const
     {
      double ts=(m_cfg.tickSize>0.0 ? m_cfg.tickSize : m_cfg.point);
      double v=price;
      if(ts>0.0)
         v=MathRound(v/ts)*ts;
      return(NormalizeDouble(v,m_cfg.digits));
     }
   /** Estimasi margin perlu utk lot tsb vs free margin (95% buffer).
       False = kemungkinan besar ditolak server → jangan kirim order. */
   bool                MarginOk(const double lots,const ENUM_ORDER_TYPE type)
     {
      double px=(type==ORDER_TYPE_BUY || type==ORDER_TYPE_SELL)
                ? (type==ORDER_TYPE_BUY ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                                        : SymbolInfoDouble(_Symbol,SYMBOL_BID))
                : (type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP
                   ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                   : SymbolInfoDouble(_Symbol,SYMBOL_BID));
      if(px<=0.0 || lots<=0.0)
         return(true);
      double need=0.0;
      if(!OrderCalcMargin(type,_Symbol,lots,px,need))
         return(true);                          // tak bisa hitung → server saja
      return(need<=AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.95);
     }

public:
                     CTradeExecutor(void) : m_tagCount(0) {}

   /** Set magic/deviation/filling/comment mode. Return true. */
   bool              Init(const SHunterSettings &cfg)
     {
      m_cfg=cfg;
      m_trade.SetExpertMagicNumber((ulong)cfg.magic);
      m_trade.SetDeviationInPoints((ulong)(cfg.maxSlippagePoints>0 ? cfg.maxSlippagePoints : 30));
      m_trade.SetTypeFillingBySymbol(_Symbol);
      m_trade.LogLevel(LOG_LEVEL_ERRORS);
      return(true);
     }

   //+---------------------------------------------------------------+
   //| Mode ENTRY_EXECUTION — market order + SL/TP atomik dengan retry.  |
   //| [in] data utk harga. [in,out] plan: entry→harga fill, submitted.  |
   //| Return true = terisi (posisi live).                                |
   //+---------------------------------------------------------------+
   bool              OpenMarket(SSignalPlan &plan,CDataService &data)
     {
      if(plan.dir!=HUNT_DIR_BUY && plan.dir!=HUNT_DIR_SELL)
         return(false);
      if(!MarginOk(plan.lots,plan.dir==HUNT_DIR_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL))
        {
         plan.note="margin tidak cukup utk lot ini";
         return(false);
        }
      double minStop=MinStopDistance();
      bool filled=false;
      for(int attempt=0;attempt<=m_cfg.orderRetries;attempt++)
        {
         double price=(plan.dir==HUNT_DIR_BUY ? data.Ask() : data.Bid());
         //--- jaga jarak stops dari harga eksekusi
         if(plan.dir==HUNT_DIR_BUY && (price-plan.sl)<minStop)
            plan.sl=data.NormalizePrice(price-minStop);
         if(plan.dir==HUNT_DIR_SELL && (plan.sl-price)<minStop)
            plan.sl=data.NormalizePrice(price+minStop);
         bool ok=(plan.dir==HUNT_DIR_BUY)
                 ? m_trade.Buy(plan.lots,_Symbol,price,plan.sl,plan.tp2,MakeComment(plan.session))
                 : m_trade.Sell(plan.lots,_Symbol,price,plan.sl,plan.tp2,MakeComment(plan.session));
         uint rc=m_trade.ResultRetcode();
         if(ok && IsOkRetcode(rc))
           {
            filled=true;
            break;
           }
         if(!IsRetryableRetcode(rc))
           {
            LogResult("market");
            break;
           }
         if(attempt<m_cfg.orderRetries)
           {
            Sleep(m_cfg.orderRetryDelayMs);
            data.RefreshQuotes();
           }
        }
      if(!filled)
        {
         LogResult("market FAIL");
         return(false);
        }
      plan.entry=m_trade.ResultPrice()>0.0 ? m_trade.ResultPrice() : plan.entry;
      plan.submitted=true;
      ulong posTicket=m_trade.ResultOrder();
      if(posTicket>0)
         Tag(posTicket,(int)plan.session,plan.dir,plan.planId);
      LogResult("market OK");
      return(true);
     }

   /** Mode ENTRY_PENDING_ORDER — limit di tepi zona, SL/TP dr level limit.
       [in] data utk bar-anchor expiry. Return true + pendingTicket terisi. */
   bool              PlacePending(SSignalPlan &plan,CDataService &data)
     {
      if(plan.dir!=HUNT_DIR_BUY && plan.dir!=HUNT_DIR_SELL)
         return(false);
      if(!MarginOk(plan.lots,plan.dir==HUNT_DIR_BUY ? ORDER_TYPE_BUY_LIMIT
                                                     : ORDER_TYPE_SELL_LIMIT))
        {
         plan.note="margin tidak cukup utk lot ini";
         return(false);
        }
      double minStop=MinStopDistance();
      //--- validasi jarak thd harga sekarang SEBELUM kirim
      double mark=(plan.dir==HUNT_DIR_BUY ? data.Bid() : data.Ask());
      if(plan.dir==HUNT_DIR_BUY && (plan.entry-mark)<minStop)
        {
         plan.note="limit terlalu dekat dgn harga";
         return(false);
        }
      if(plan.dir==HUNT_DIR_SELL && (mark-plan.entry)<minStop)
        {
         plan.note="limit terlalu dekat dgn harga";
         return(false);
        }
      ulong ticket=0;
      ENUM_ORDER_TYPE_TIME ptt=ORDER_TIME_GTC;
      datetime             pexp=0;
      ResolvePendingTime(ptt,pexp);
      for(int attempt=0;attempt<=m_cfg.orderRetries;attempt++)
        {
         bool ok=(plan.dir==HUNT_DIR_BUY)
                 ? m_trade.BuyLimit(plan.lots,plan.entry,_Symbol,plan.sl,plan.tp2,
                                    ptt,pexp,MakeComment(plan.session))
                 : m_trade.SellLimit(plan.lots,plan.entry,_Symbol,plan.sl,plan.tp2,
                                     ptt,pexp,MakeComment(plan.session));
         uint rc=m_trade.ResultRetcode();
         if(ok && IsOkRetcode(rc))
           {
            ticket=m_trade.ResultOrder();
            break;
           }
         if(!IsRetryableRetcode(rc))
           {
            LogResult("pending");
            break;
           }
         if(attempt<m_cfg.orderRetries)
            Sleep(m_cfg.orderRetryDelayMs);
        }
      if(ticket==0)
        {
         LogResult("pending FAIL");
         return(false);
        }
      plan.pendingTicket=ticket;
      plan.validUntilBarTime=data.CurrentBarTime();  // anchor expiry berbasis bar
      Tag(ticket,(int)plan.session,plan.dir,plan.planId);
      LogResult("pending OK");
      return(true);
     }

   /** Hapus pending order by ticket (expiry/invalidasi/force-close). */
   bool              CancelOrder(const ulong ticket,const string why)
     {
      if(ticket==0)
         return(false);
      for(int attempt=0;attempt<=m_cfg.orderRetries;attempt++)
        {
         if(m_trade.OrderDelete(ticket) && IsOkRetcode(m_trade.ResultRetcode()))
           {
            Untag(ticket);
            PrintFormat("%s | pending %I64u dihapus (%s)",HUNT_NAME,ticket,why);
            return(true);
           }
         uint rc=m_trade.ResultRetcode();
         if(IsClosedishRc(rc))
            break;                     // market tutup → jangan bakar retry
         if(rc==TRADE_RETCODE_ORDER_CHANGED || rc==TRADE_RETCODE_DONE)
           {
            Untag(ticket);            // order sudah tereksekusi/terhapus sendiri
            return(false);
           }
         if(attempt<m_cfg.orderRetries)
            Sleep(m_cfg.orderRetryDelayMs);
        }
      if(!IsClosedishRc(m_trade.ResultRetcode()))
         LogResult("OrderDelete FAIL");
      return(false);
     }

   /** Tutup posisi by ticket (volume=0 → penuh). */
   bool              ClosePosition(const ulong ticket,const double volume,const string why)
     {
      if(ticket==0)
         return(false);
      if(volume<=0.0)
        {
         if(m_trade.PositionClose(ticket) && IsOkRetcode(m_trade.ResultRetcode()))
           {
            Untag(ticket);
            return(true);
           }
         if(!IsClosedishRc(m_trade.ResultRetcode()))
            LogResult("close");
         return(false);
        }
      if(m_trade.PositionClosePartial(ticket,volume) && IsOkRetcode(m_trade.ResultRetcode()))
         return(true);
      if(!IsClosedishRc(m_trade.ResultRetcode()))
         LogResult("partial");
      return(false);
     }

   //+---------------------------------------------------------------+
   //| Query posisi/order milik EA.                                    |
   //+---------------------------------------------------------------+
   /** true bila ada posisi open milik magic+symbol. */
   bool              HasOpenPosition(void)
     {
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0)
            continue;
         if(PositionGetInteger(POSITION_MAGIC)==(long)m_cfg.magic &&
            PositionGetString(POSITION_SYMBOL)==_Symbol)
            return(true);
        }
      return(false);
     }
   bool              HasPendingOrders(void)
     {
      for(int i=OrdersTotal()-1;i>=0;i--)
        {
         ulong tk=OrderGetTicket(i);
         if(tk==0)
            continue;
         if(OrderGetInteger(ORDER_MAGIC)==(long)m_cfg.magic && OrderGetString(ORDER_SYMBOL)==_Symbol)
            return(true);
        }
      return(false);
     }
   /** Ticket posisi utk plan (via ledger tag planId; fallback magic-first). */
   bool              FindPlanPositionTicket(const ulong planId,ulong &ticket)
     {
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0 || PositionGetInteger(POSITION_MAGIC)!=(long)m_cfg.magic ||
            PositionGetString(POSITION_SYMBOL)!=_Symbol)
            continue;
         STicketTag tg;
         if(TagOf(tk,tg) && tg.planId==planId)
           {
            ticket=tk;
            return(true);
           }
        }
      return(false);
     }
   /** Order pending masih ada di server? */
   bool              OrderStillLive(const ulong ticket)
     {
      for(int i=OrdersTotal()-1;i>=0;i--)
         if(OrderGetTicket(i)==ticket)
            return(true);
      return(false);
     }
   //+---------------------------------------------------------------+
   //| Sinkronisasi lifecycle plan (dipanggil utk sesi dlm MANAGING atau     |
   //| WAIT_RETEST+pending). Return bitwise ENUM_HUNT_EXEC_EVENT:            |
   //|  PENDING_FILLED : posisi utk plan muncul (order ticket → posisi).      |
   //|  PENDING_EXPIRED: bar closed sejak pasang > retestMaxBars → delete.    |
   //|  POS_CLOSED     : submitted && posisi plan hilang (TP/SL/manual).      |
   //+---------------------------------------------------------------+
   int               Manage(const CDataService &data,SSignalPlan &plan)
     {
      int evt=HUNT_EVT_NONE;
      if(plan.pendingTicket!=0 && !plan.submitted)
        {
         //--- sudah terisi?
         if(HasOpenPosition())
           {
            plan.submitted=true;
            ulong tk=0;
            if(FindPlanPositionTicket(plan.planId,tk))
               Tag(tk,(int)plan.session,plan.dir,plan.planId);
            plan.pendingTicket=0;
            evt|=HUNT_EVT_PENDING_FILLED;
           }
         else if(OrderStillLive(plan.pendingTicket))
           {
            int barsPassed=0;
            datetime tNow=data.CurrentBarTime();
            if(plan.validUntilBarTime>0 && tNow>plan.validUntilBarTime)
               barsPassed=(int)((tNow-plan.validUntilBarTime)/PeriodSeconds(_Period));
            if(barsPassed>=m_cfg.retestMaxBars)
              {
               CancelOrder(plan.pendingTicket,"expiry bar tercapai");
               plan.pendingTicket=0;
               evt|=HUNT_EVT_PENDING_EXPIRED;
              }
           }
         else
           {
            plan.pendingTicket=0;      // hilang dari server (manual/ECN)
            evt|=HUNT_EVT_PENDING_EXPIRED;
           }
        }
      if(plan.submitted && plan.pendingTicket==0)
        {
         ulong tk=0;
         if(!FindPlanPositionTicket(plan.planId,tk))
           {
            evt|=HUNT_EVT_POS_CLOSED;
            plan.Reset();
           }
        }
      return(evt);
     }

   /** Snapshot posisi EA (max 1; multi→terlama). Session via tag/comment. */
   bool              PositionSnapshot(ulong &ticket,double &vol,double &price,double &sl,
                                      double &tp,double &pl,ENUM_HUNT_DIR &dir,
                                      int &session)
     {
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0 || PositionGetInteger(POSITION_MAGIC)!=(long)m_cfg.magic ||
            PositionGetString(POSITION_SYMBOL)!=_Symbol)
            continue;
         ticket=tk;
         vol=PositionGetDouble(POSITION_VOLUME);
         price=PositionGetDouble(POSITION_PRICE_OPEN);
         sl=PositionGetDouble(POSITION_SL);
         tp=PositionGetDouble(POSITION_TP);
         pl=PositionGetDouble(POSITION_PROFIT);
         dir=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? HUNT_DIR_BUY : HUNT_DIR_SELL);
         if(!SessionOfTicket(ticket,session,PositionGetString(POSITION_COMMENT)))
            session=HUNT_SESSION_NONE;
         return(true);
        }
      return(false);
     }

   //+---------------------------------------------------------------+
   //| Force-close per sesi: hanya posisi + pending dgn tag sesi tsb.     |
   //| [out] nPos/nPend utk log & Alert. Return true bila dijalankan.      |
   //+---------------------------------------------------------------+
   bool              CloseSessionPositions(const int session,int &nPos,int &nPend,int &nFail)
     {
      nPos=0;
      nPend=0;
      nFail=0;
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0 || PositionGetInteger(POSITION_MAGIC)!=(long)m_cfg.magic ||
            PositionGetString(POSITION_SYMBOL)!=_Symbol)
            continue;
         int s2;
         if(SessionOfTicket(tk,s2,PositionGetString(POSITION_COMMENT)) && s2==session)
            if(ClosePosition(tk,0.0,"force-close sesi"))
               nPos++;
        }
      for(int i=OrdersTotal()-1;i>=0;i--)
        {
         ulong tk=OrderGetTicket(i);
         if(tk==0 || OrderGetInteger(ORDER_MAGIC)!=(long)m_cfg.magic ||
            OrderGetString(ORDER_SYMBOL)!=_Symbol)
            continue;
         int s2;
         if(SessionOfTicket(tk,s2,OrderGetString(ORDER_COMMENT)) && s2==session)
            if(CancelOrder(tk,"force-close sesi"))
               nPend++;
        }
      //--- sisa yang masih hidup di server (gagal tutup: market closed /
      //--- requote habis retry) → pemanggil wajib retry sebelum lanjut state.
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0 || PositionGetInteger(POSITION_MAGIC)!=(long)m_cfg.magic ||
            PositionGetString(POSITION_SYMBOL)!=_Symbol)
            continue;
         int s2;
         if(SessionOfTicket(tk,s2,PositionGetString(POSITION_COMMENT)) && s2==session)
            nFail++;
        }
      for(int i=OrdersTotal()-1;i>=0;i--)
        {
         ulong tk=OrderGetTicket(i);
         if(tk==0 || OrderGetInteger(ORDER_MAGIC)!=(long)m_cfg.magic ||
            OrderGetString(ORDER_SYMBOL)!=_Symbol)
            continue;
         int s2;
         if(SessionOfTicket(tk,s2,OrderGetString(ORDER_COMMENT)) && s2==session)
            nFail++;
        }
      return(nPos>0 || nPend>0 || nFail>0);
     }

   /** Sisa bar sebelum expiry pending (anchor per-plan, berbasis bar). */
   int               PendingBarsLeft(const SSignalPlan &plan,const CDataService &data) const
     {
      datetime tNow=data.CurrentBarTime();
      int passed=0;
      if(plan.validUntilBarTime>0 && tNow>plan.validUntilBarTime)
         passed=(int)((tNow-plan.validUntilBarTime)/PeriodSeconds(_Period));
      return(MathMax(0,m_cfg.retestMaxBars-passed));
     }
   /** Floating P/L total milik magic+symbol (currency). */
   double            FloatingPl(void)
     {
      double s=0.0;
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0 || PositionGetInteger(POSITION_MAGIC)!=(long)m_cfg.magic ||
            PositionGetString(POSITION_SYMBOL)!=_Symbol)
            continue;
         s+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
        }
      return(s);
     }
   bool              IsPlanLive(const SSignalPlan &plan) const
     {
      return(plan.pendingTicket!=0 || plan.submitted);
     }
   /** Buang tag utk ticket yang sudah tak ada di server. */
   void              ReconcileTags(void)
     {
      for(int i=m_tagCount-1;i>=0;i--)
        {
         ulong tk=m_tags[i].ticket;
         bool live=false;
         for(int p=PositionsTotal()-1;p>=0 && !live;p--)
            if(PositionGetTicket(p)==tk)
               live=true;
         for(int o=OrdersTotal()-1;o>=0 && !live;o--)
            if(OrderGetTicket(o)==tk)
               live=true;
         if(!live)
            Untag(tk);
        }
     }
   /** Update harga SL utk plan yang sudah terisi (breakeven/trailing). */
   bool              ModifySl(const ulong ticket,const double newSl,const double newTp)
     {
      double sl=newSl;                               // salinan lokal (param const)
      //--- clamp multi-simbol: SL harus ≥ stops-level dari harga pasar DAN
      //--- hanya boleh maju (perketat) — jangan pernah longgarkan SL.
      {
       ENUM_POSITION_TYPE pt=POSITION_TYPE_BUY;
       double oldSl=0.0;
       bool found=false;
       for(int p=PositionsTotal()-1;p>=0;p--)
         {
          if(PositionGetTicket(p)==ticket)
            {
             pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
             oldSl=PositionGetDouble(POSITION_SL);
             found=true;
             break;
            }
         }
       if(found)
         {
          double minStop=MinStopDistance();
          double mkt=(pt==POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                                            : SymbolInfoDouble(_Symbol,SYMBOL_ASK));
          double lim=(pt==POSITION_TYPE_BUY ? mkt-minStop : mkt+minStop);
          double cand=Grid(sl);
          if(pt==POSITION_TYPE_BUY ? cand>lim : cand<lim)
             cand=Grid(lim);
          bool forward=(oldSl==0.0 ? true
                        :(pt==POSITION_TYPE_BUY ? cand>oldSl : cand<oldSl));
          if(!forward)
             return(true);                        // tak ada perbaikan → no-op
          sl=cand;
         }
      }
      for(int attempt=0;attempt<=m_cfg.orderRetries;attempt++)
        {
         if(m_trade.PositionModify(ticket,sl,newTp) && IsOkRetcode(m_trade.ResultRetcode()))
            return(true);
         uint rc=m_trade.ResultRetcode();
         if(rc==TRADE_RETCODE_NO_CHANGES)
            return(true);
         if(!IsRetryableRetcode(rc))
            break;
         if(attempt<m_cfg.orderRetries)
            Sleep(m_cfg.orderRetryDelayMs);
        }
      LogResult("modify FAIL");
      return(false);
     }
  };

#endif // ORB_SMC_HUNTER_TRADEEXECUTOR_MQH
//+------------------------------------------------------------------+
