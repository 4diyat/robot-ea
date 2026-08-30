# ORB_SMC_NextGen.mq5 — Expert Advisor ORB + Smart Money Concepts

EA MT5 modular (build baru dari nol, bukan iterasi `ORB_SMC_EA.mq5`/`SMCOB.mq5`): **Opening Range Breakout** per sesi (Asia/London/NY) yang wajib dikonfirmasi struktur **SMC** (liquidity sweep → BOS/CHoCH → order block / FVG) sebelum entry, dengan retest entry, risk adaptif, force-close per sesi, news filter, dan rendering chart penuh.

| | |
|---|---|
| Versi | 1.00 |
| Timeframe | M15 (default; bisa M5/H1 — sesuaikan `InpRangeMinutes`) |
| Instrumen | Multi-pair (auto-detect pip/point: XAUUSD, FX, indeks) |
| Entry | Retest OB/FVG saja — **tidak pernah entry di candle breakout** |
| Mode entry | `ENTRY_PENDING_ORDER` (limit di tepi zona) / `ENTRY_EXECUTION` (market setelah reaksi retest) |
| Bias HTF | H4 |

---

## 1. Instalasi cepat

1. Salin folder `Include/ORB_SMC_NextGen/` → `<Data Folder>\MQL5\Include\`.
2. Salin `ORB_SMC_NextGen.mq5` → `<Data Folder>\MQL5\Experts\`.
3. Buka MetaEditor → compile (F7).
4. **Setup wajib untuk NewsFilter** (bila `InpEnableNewsFilter=true`):
   MT5 → *Tools → Options → Expert Advisors → Allow WebRequest for listed URL*, tambahkan:
   ```
   https://sslecal2.investing.com/
   ```
   Tanpa ini fetch news gagal — **fail-safe**: EA tetap trading, filter news nonaktif (status `NO DATA` di dashboard).
5. Atur `InpGMTOffset` = offset broker terhadap UTC (mis. broker UTC+2 → `2`). Waktu sesi diinput **dalam UTC**.

## 2. Struktur modul

```
ORB_SMC_NextGen.mq5            ← input, wiring, state machine per sesi
Include/ORB_SMC_NextGen/
├── Defines.mqh                ← enum, konstanta, prefix objek, palet warna, struct, helper pip
├── Helpers.mqh                ← EAMagic(), GetATR()  (butuh input → di-include setelah blok input)
├── SessionManager.mqh         ← jadwal 3 sesi (UTC), OR per sesi tersimpan terpisah, reset hari baru
├── ORBDetector.mqh            ← breakout body-close vs wick, min range, false-breakout filter
├── SMCEngine.mqh              ← swing, liquidity pools, BOS/CHoCH, OB, FVG (closed-bar only)
├── ConfluenceValidator.mqh    ← gate tunggal 7 filter + skor confluence 0–100
├── RiskManager.mqh            ← sizing % risiko, SL struktural, TP multi-level, daily loss/trades
├── TradeExecutor.mqh          ← CTrade + retry, 2 mode entry, expiry berbasis bar, force-close sesi
├── VisualRenderer.mqh         ← 8 kategori objek chart, redraw per bar/event, cleanup per prefix
├── NewsFilter.mqh             ← kalender investing.com via WebRequest, fail-safe
└── Dashboard.mqh              ← panel 4 section, timer 1 detik (candle countdown)
```

## 3. Alur trading

```
Sesi mulai → OR forming (InpRangeMinutes) → OR formed
  → menunggu breakout → body-close menembus level OR (wick-only ditolak)
  → ConfluenceValidator (gate tunggal):
      1) ukuran OR ≥ InpMinRangePips      2) breakout tidak void (false-breakout)
      3) arah searah bias HTF H4          4) liquidity di arah breakout sudah di-sweep *
      5) ada OB/FVG aktif untuk retest    6) tidak dalam window blokir news
      7) spread ≤ InpMaxSpreadPips
  → WAITING_RETEST
      mode PENDING_ORDER : BuyLimit/SellLimit di tepi zona (SL/TP dipasang sekaligus,
                           dihitung dari level limit) — expiry otomatis setelah
                           InpRetestMaxBars bar (bukan waktu absolut)
      mode EXECUTION     : tunggu candle retest menyentuh zona + close kembali searah
                           breakout (wick rejection) di closed bar → market order
  → invalidasi retest: bar habis ATAU harga lari > InpMaxExtensionBeforeRetest% dari OR
  → kelola posisi: TP1 partial close (SL→breakeven) → trailing struktur setelah TP1
  → force-close: InpForceCloseMinutesBeforeEnd menit sebelum akhir sesi,
    posisi + pending SESI TERSEBUT saja ditutup; sesi lain tidak disentuh.
```

\* Bila `InpRequireLiquiditySweep=true` (default): bullish breakout butuh equal-high tersapu, bearish butuh equal-low tersapu — pool di arah breakout yang belum tersapu menolak sinyal.

## 4. Jadwal sesi default (UTC)

| Sesi | Mulai | Selesai | Warna |
|---|---|---|---|
| Asia | 00:00 | 06:00 | Biru |
| London | 08:00 | 16:00 | Oranye |
| New York | 13:00 | 21:00 | Ungu |

OR = `InpRangeMinutes` menit pertama tiap sesi (default 30). Ketiga range tersimpan **terpisah** sepanjang hari dan tampil semua di dashboard; reset terjadi pukul 00:00 UTC.

## 5. Referensi input (ringkas)

| Grup | Input penting | Default | Keterangan |
|---|---|---|---|
| Session | `InpGMTOffset` | 2 | Offset broker → UTC |
| ORB | `InpRangeMinutes` | 30 | Durasi OR |
| | `InpMinRangePips` | 0.0 | Filter ukuran minimum OR (0 = off) |
| | `InpRequireBodyClose` | true | Body-close wajib (wick-only ditolak) |
| SMC | `InpSwingLookback` | 5 | Konfirmasi swing kiri/kanan |
| | `InpRequireLiquiditySweep` | true | Wajib sweep sebelum entry |
| | `InpRequireFVGRetest` | true | Wajib retest OB/FVG |
| | `InpRetestMaxBars` | 10 | Batas bar menunggu retest |
| | `InpMaxExtensionBeforeRetest` | 50.0 | Batas ekstensi % OR sebelum invalid |
| Entry | `InpEntryMode` | PENDING_ORDER | `0`=Execution, `1`=Pending |
| Risk | `InpRiskPercent` | 1.0 | Risiko per trade (%) |
| | `InpMinRR` | 2.0 | RR minimum vs TP akhir |
| | `InpTP1RR` / `InpPartialClosePct` | 1.0 / 50 | Partial close TP1 |
| | `InpMaxTradesPerDay` / `InpMaxDailyLossPercent` | 3 / 3.0 | Proteksi harian |
| | `InpForceCloseMinutesBeforeEnd` | 30 | Force-close sebelum akhir sesi |
| OB/OS | `InpOBOSPeriod` / ±Level | 14 / 70 / 30 | Info RSI di dashboard (bukan gate) |
| News | `InpEnableNewsFilter` | true | Blokir entry baru di sekitar news |
| | `InpNewsRefreshHours` | 6 | Interval refresh kalender |
| | `InpNewsBufferBeforeMin/AfterMin` | 30 / 30 | Jendela blokir |
| | `InpNewsCurrencyOverride` | "" | Auto-detect dari `_Symbol`; isi mis. `USD` untuk override |
| Visual | `InpShowOB/FVG/Structure/Sweep/EntryArrows/Pivot/VolumeProfile/NewsMarkers` | true | Toggle per kategori objek |
| | `InpShowPriceLabels` | true | Label harga pada elemen level (OR/OB/FVG/swing/BOS-CHoCH/sweep/pivot/VP) — toggle terpisah |
| General | `InpMagicNumber` | 20260801 | Magic dasar (`InpMagicAutoChartOffset` untuk multi-chart) |
| | `InpShowDashboard` / `InpDashboardCorner` / `InpDashboardFontSize` | true / 0 / 8 | Panel dashboard |

## 6. Elemen visual & prefix objek

| Elemen | Prefix | Catatan |
|---|---|---|
| Opening Range per sesi | `ORBSMC_RANGE_` | Garis high/low dibatasi jendela sesi; warna per sesi |
| Order Block | `ORBSMC_OB_` | Kotak hijau (bull) / merah (bear); hilang saat termitigasi |
| FVG | `ORBSMC_FVG_` | Kotak border putus-putus; hilang saat fully filled |
| BOS/CHoCH + swing label | `ORBSMC_STRUCT_` | HH/HL/LH/LL abu kecil; BOS cyan, CHoCH oranye terang |
| Liquidity sweep | `ORBSMC_SWEEP_` | Panah magenta di wick penyapu |
| Entry/retest arrow | `ORBSMC_ENTRY_` | Panah + label entry/SL/TP/RR aktual |
| Pivot harian | `ORBSMC_PIVOT_` | PP/R1–R3/S1–S3, garis titik-titik + label kanan |
| Volume Profile | `ORBSMC_VP_` | Histogram sisi kanan; POC emas, VAH/VAL ungu |
| News marker + shading | `ORBSMC_NEWS_` | VLINE + label; shading window blokir; high=merah, medium=oranye |
| Dashboard | `ORBSMC_DASH_` | Panel semi-transparan, 4 section |

Semua objek dihapus **per prefix** (tidak pakai `ObjectsDeleteAll`) dan dibersihkan total di `OnDeinit`. Redraw statis hanya saat bar baru/event; news marker hanya saat data di-refresh; candle countdown via `EventSetTimer(1)`.

**Label harga:** setiap elemen level-harga kini menampilkan label harganya (format `FmtPrice()` sesuai digit simbol): garis OR (label di ujung kanan tiap garis high/low), tepi atas & bawah kotak OB/FVG, label swing `HH/HL/LH/LL + harga`, label `BOS/CHoCH + harga`, marker `SWEEP + harga level liquidity`, pivot `PP/R1…/S3 + harga`, dan `POC/VAH/VAL + harga`. Semua label harga ini bisa dimatikan/dihidupkan terpisah via `InpShowPriceLabels`. Marker news tidak diberi label harga karena berbasis **waktu** (event), bukan level harga.

## 7. News filter — perilaku & fail-safe

- Sumber: `https://sslecal2.investing.com/` (economic calendar investing.com), diambil via `WebRequest` (URL wajib di-allow — lihat §1).
- Parsing berbasis marker stabil HTML (toleran perubahan minor struktur halaman).
- Hanya memblokir **entry baru** pada window `[event − InpNewsBufferBeforeMin, event + InpNewsBufferAfterMin]`. **Posisi terbuka tidak disentuh** (SL/TP tidak diubah, tidak ditutup).
- Status di dashboard: `OK` (segar) / `STALE` (fetch gagal, cache lama dipakai) / `NO DATA` (belum pernah sukses — trading tetap diizinkan). Kegagalan fetch **tidak pernah** menghentikan EA.

## 8. Backtesting

Gunakan preset di folder `presets/`:

| Preset | Untuk |
|---|---|
| `ORB_SMC_NextGen_Backtest.set` | Tester — news filter OFF (WebRequest tidak jalan di tester) |
| `ORB_SMC_NextGen_Default.set` | Demo/live — Pending Order, semua sesi, news ON |
| `ORB_SMC_NextGen_Execution.set` | Demo/live — mode Execution (market setelah reaksi) |

Catatan backtest:
- Mode **Every tick based on real ticks** disarankan (XAUUSD volatil); minimal *1 minute OHLC*.
- Tidak ada repaint/lookahead: seluruh deteksi berbasis closed bar (`shift ≥ 1`).
- `InpGMTOffset` harus sesuai riwayat broker Anda (periksa perubahan DST).
- Visual (OR/OB/FVG/dashboard) hanya tampil di **visual mode** tester; tidak memengaruhi hasil.
- NewsFilter di tester otomatis `NO DATA` bila diaktifkan — hasil trading tidak berubah (fail-safe), hanya log peringatan.

## 9. Dokumentasi visual

Folder `docs/` berisi mock-up tampilan chart (replika warna/format asli, bukan screenshot MT5):

- `chart-preview.png` — skenario bullish London + BuyLimit + news high
- `chart-preview-bearish.png` — skenario bearish NY + SellLimit + news medium
- `dashboard-preview.png` — close-up panel dashboard 4 section
- `entry-modes-preview.png` — perbandingan Pending Order vs Execution
## 10. ORB_SMC_Hunter — build modular penuh (v0.90)

Build produksi `ORB_SMC_Hunter_EA.mq5` + 12 modul di `Include/ORB_SMC_Hunter/`
(fresh build; NextGen dibiarkan utuh sbg referensi). Per- sesi Opening Range
disimpan **terpisah** (Asia/London/NY) dengan state machine per sesi, konfluensi
OB/FVG/sweep/struktur/HTF, force-close per sesi via ledger tag sesi
(comment order `HUNT:<code>:<dir>:<planId>` — sumber kebenaran = server comment,
bukan file state), news filter investing.com (WebRequest, cache, fail-safe),
render chart penuh ber-prefix `HUNT_*`, dan dashboard 4 seksi non-flicker.

| File | Isi |
|---|---|
| `ORB_SMC_Hunter_EA.mq5` | Entry point + state machine + pipeline per bar |
| `HunterDefines.mqh` | enum, struct, warna, prefix objek |
| `HunterSettings.mqh` | input + snapshot (auto-detect pip, UTC→broker) |
| `DataService.mqh` | cache bar closed anti-repaint, ATR/RSI handle |
| `SessionManager.mqh` | jendela sesi + OR per sesi (persisten s/d rollover) |
| `ORBDetector.mqh` | breakout: body-close + buffer + filter wick-only |
| `SMCEngine.mqh` | swing/structure, OB, FVG, sweep pool, HTF bias |
| `ConfluenceValidator.mqh` | gate keras G1–G7 + skor + re-check validasi |
| `RiskManager.mqh` | lot %risk, SL struktural+ATR buffer, TP1/TP2, limit harian |
| `TradeExecutor.mqh` | CTrade retry, tag/ledger sesi, close-by-session, expiry pending per plan |
| `NewsFilter.mqh` | fetch+parse kalender, cache, veto entry (posisi tak tersentuh) |
| `VisualRenderer.mqh` | ledger objek per kategori, cleanup prefix-scoped |
| `Dashboard.mqh` | seksi Session/Status/Signal/News, countdown detik |
| `presets/ORB_SMC_Hunter_{Backtest,Default,Execution}.set` | preset ready-use |

**Wajib untuk news filter**: `Tools → Options → Expert Advisors → Allow WebRequest`
tambahkan `https://sslecal2.investing.com`. Tanpa allowlist EA tetap jalan
(news veto nonaktif, dashboard menampilkan status no-data/stale).

**Status**: implementasi selesai; belum dikompilasi MetaEditor & belum
diuji-di-chart dari lingkungan dev ini — lakukan compile (target 0 warning)
+ visual smoke test + backtest sebelum live. Known trade-offs (10 butir)
terdokumentasi di header `ORB_SMC_Hunter_EA.mq5` dan seksi 11 arsitektur.


---

**Disclaimer:** EA ini alat bantu, bukan jaminan profit. Uji di akun demo minimal 1–2 bulan sebelum live; pantau `InpMaxDailyLossPercent` dan ukuran risiko Anda.
