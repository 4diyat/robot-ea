//+------------------------------------------------------------------+
//| DL_Signal_EA — DLModel.mqh                                      |
//| Pembungkus model ONNX (runtime ONNX bawaan MT5).                 |
//|   masukan : float32 [1, lookback, DL_NUM_FEATURES] (fitur mentah;|
//|             normalisasi z-score sudah ada di dalam model)        |
//|   keluaran: float32 [1, 3] = [P(SELL), P(HOLD), P(BUY)]          |
//+------------------------------------------------------------------+
#ifndef DL_MODEL_MQH
#define DL_MODEL_MQH

#include <DL_Signal_EA\DLDefines.mqh>

class CDLModel
  {
private:
   long              m_handle;
   int               m_lookback;

public:
                     CDLModel() : m_handle(INVALID_HANDLE), m_lookback(0) {}
                    ~CDLModel() { Release(); }

   bool              IsReady() const { return m_handle != INVALID_HANDLE; }

   //--- file dicari di MQL5\Files (atau folder Common\Files bila inCommonFolder)
   bool              Init(const string fileName, const bool inCommonFolder, const int lookback)
     {
      Release();
      m_lookback = lookback;
      m_handle = OnnxCreate(fileName, inCommonFolder ? ONNX_COMMON_FOLDER : ONNX_DEFAULT);
      if(m_handle == INVALID_HANDLE)
        {
         PrintFormat("[DLModel] OnnxCreate('%s') gagal, error %d. Pastikan file ada di MQL5\\Files%s.",
                     fileName, GetLastError(), inCommonFolder ? " (Common)" : "");
         return false;
        }
      //--- bentuk tensor harus sama dengan saat ekspor; salah lookback/jumlah fitur -> gagal di sini
      long inShape[3];
      inShape[0] = 1;
      inShape[1] = lookback;
      inShape[2] = DL_NUM_FEATURES;
      if(!OnnxSetInputShape(m_handle, 0, inShape))
        {
         PrintFormat("[DLModel] OnnxSetInputShape [1,%d,%d] gagal, error %d. InpLookback / versi fitur tidak cocok dengan model.",
                     lookback, DL_NUM_FEATURES, GetLastError());
         Release();
         return false;
        }
      long outShape[2];
      outShape[0] = 1;
      outShape[1] = DL_NUM_CLASSES;
      if(!OnnxSetOutputShape(m_handle, 0, outShape))
        {
         PrintFormat("[DLModel] OnnxSetOutputShape [1,%d] gagal, error %d.", DL_NUM_CLASSES, GetLastError());
         Release();
         return false;
        }
      return true;
     }

   //--- x: matriks [lookback x DL_NUM_FEATURES]; probs[3] = P(SELL), P(HOLD), P(BUY)
   bool              Predict(matrixf &x, double &probs[])
     {
      if(m_handle == INVALID_HANDLE)
         return false;
      if((int)x.Rows() != m_lookback || (int)x.Cols() != DL_NUM_FEATURES)
         return false;

      vectorf out(DL_NUM_CLASSES);
      if(!OnnxRun(m_handle, ONNX_NO_CONVERSION, x, out))
        {
         PrintFormat("[DLModel] OnnxRun gagal, error %d", GetLastError());
         return false;
        }
      ArrayResize(probs, DL_NUM_CLASSES);
      double sum = 0.0;
      for(int k = 0; k < DL_NUM_CLASSES; k++)
        {
         probs[k] = (double)out[k];
         if(!MathIsValidNumber(probs[k]) || probs[k] < 0.0)
            return false;
         sum += probs[k];
        }
      //--- keluaran softmax harus berjumlah ~1; selain itu model/bentuk tensor salah
      if(MathAbs(sum - 1.0) > 0.01)
        {
         PrintFormat("[DLModel] keluaran bukan distribusi probabilitas (jumlah=%.4f) — sinyal diabaikan", sum);
         return false;
        }
      return true;
     }

   void              Release()
     {
      if(m_handle != INVALID_HANDLE)
        {
         OnnxRelease(m_handle);
         m_handle = INVALID_HANDLE;
        }
     }
  };

#endif // DL_MODEL_MQH
