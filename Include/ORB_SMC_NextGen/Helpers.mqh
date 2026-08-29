//+------------------------------------------------------------------+
//| ORB_SMC_NextGen — Helpers.mqh                                   |
//| Helper yang MEMBUTUHKAN variabel input — oleh karena itu file    |
//| ini di-include SETELAH blok input di file utama.                 |
//|                                                                  |
//| EAMagic(): magic unik per chart. Default = InpMagicNumber tetap  |
//|   (stabil lintas restart terminal). Bila InpMagicAutoChartOffset |
//|   diaktifkan, byte rendah ChartID ditambahkan agar multi-chart   |
//|   aman — CATATAN: ChartID bisa berubah bila chart ditutup/       |
//|   dibuka ulang, jadi offset aktif hanya direkomendasikan bila    |
//|   Anda menjalankan EA di banyak chart DAN menerima catatan itu.  |
//|                                                                  |
//| GetATR(): ATR rata-rata manual (closed-bar only).                |
//+------------------------------------------------------------------+
#ifndef ORBSMC_HELPERS_MQH
#define ORBSMC_HELPERS_MQH

#include <ORB_SMC_NextGen\Defines.mqh>

//+------------------------------------------------------------------+
//| Magic number aktif                                               |
//+------------------------------------------------------------------+
long EAMagic()
  {
   if(InpMagicAutoChartOffset)
      return (long)InpMagicNumber + (long)(ChartID() & 0xFF);
   return (long)InpMagicNumber;
  }
//+------------------------------------------------------------------+
//| ATR rata-rata (manual, closed-bar only)                          |
//+------------------------------------------------------------------+
double GetATR(int period)
  {
   if(period <= 0)
      period = 14;
   int bars = Bars(_Symbol, PERIOD_CURRENT);
   if(bars < period + 2)
      return 0.0;
   double sum = 0.0;
   for(int i = 1; i <= period; i++)
     {
      double h  = iHigh(_Symbol, PERIOD_CURRENT, i);
      double l  = iLow(_Symbol, PERIOD_CURRENT, i);
      double pc = iClose(_Symbol, PERIOD_CURRENT, i + 1);
      double tr = MathMax(h - l, MathMax(MathAbs(h - pc), MathAbs(l - pc)));
      sum += tr;
     }
   return sum / period;
  }

#endif // ORBSMC_HELPERS_MQH
