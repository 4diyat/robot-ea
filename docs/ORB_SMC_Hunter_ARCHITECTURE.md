# ORB_SMC_Hunter_EA — Arsitektur (skeleton v0.10)

Build **baru dari nol** (bukan iterasi `ORB_SMC_EA.mq5` / `SMCOB.mq5` / `ORB_SMC_NextGen`).
Target: MT5, M15, multi-pair generik (auto pip/point), sesi Asia/London/NY.

## 1. Layout file

```
ORB_SMC_Hunter_EA.mq5                  ← input, snapshot, orkestrasi state machine
Include/ORB_SMC_Hunter/
├── HunterDefines.mqh                  ← enum, prefix HUNT_*, struct bersama, helper pip/%
├── HunterSettings.mqh                 ← SHunterSettings (config frozen) + defaults
├── DataService.mqh                    ← CDataService  : SATU sumber data (bar cache + ATR/RSI handles + CSymbolInfo)
├── SessionManager.mqh                 ← CSessionManager: 3 sesi, SOpenRange per sesi (persisten seharian), force-close window
├── ORBDetector.mqh                    ← CORBDetector  : body-close vs wick, min-range, false-breakout
├── SMCEngine.mqh                      ← CSMCEngine    : swing, pools, BOS/CHoCH, bias HTF, SZone (OB+FVG terunifikasi)
├── ConfluenceValidator.mqh            ← CConfluenceValidator: 7 hard-gate + skor 0..100
├── RiskManager.mqh                    ← CRiskManager    : sizing %, SL struktural+ATR, TP1 partial, daily limit
├── TradeExecutor.mqh                  ← CTradeExecutor  : CTrade+retry, 2 mode entry, expiry bar, force-close per sesi
├── VisualRenderer.mqh                 ← CVisualRenderer : 9 kategori objek + ledger hapus-presisi
├── NewsFilter.mqh                     ← CNewsFilter     : sslecal2.investing.com, fail-safe, cache
└── Dashboard.mqh                      ← CHunterDashboard: 16 baris 4 section, diff-only update
```

Urutan include: `Defines → Settings → DataService → Session → ORB → SMC → News → Risk → Conf → Exec → Visual → Dash` (dependensi satu arah; setiap file di-guard `#ifndef`).

## 2. Keputusan arsitektur (berbeda dari NextGen)

| # | Keputusan | Alasan | Trade-off |
|---|---|---|---|
| A1 | **Settings snapshot** (`SHunterSettings`) — modul TIDAK membaca `Inp*` | validasi terpusat, modul teruji terpisah, tanpa magic global | input baru butuh reinit (MT5 memang me-reload EA) |
| A2 | **CDataService** satu sumber bar/handle/quotes | `CopyRates`/`CopyBuffer` sekali per bar (NextGen: beberapa modul memanggil sendiri) | cache butuh invalidasi manual saat bar baru — sudah dikontrol `UpdateOnBar` |
| A3 | **SZone terunifikasi** (OB & FVG satu tipe+enum) | satu jalur kode retest/mitigasi/expiry/render | label spesifik OB vs FVG tetap tersimpan via `type` |
| A4 | **State machine PER SESI** (`g_state[3]`) | sesi boleh overlap (London 07–16 & NY 12–20 UTC = overlap 12–16); force-close tidak mengganggu sesi lain | orkestrasi lebih eksplisit di file utama |
| A5 | Prefix objek `HUNT_*` (bukan `ORBSMC_*`) + **ledger** nama objek | `OnDeinit`/rebuild tidak menabrak objek EA lain milik user | perlu ledger maintenance (di-renderer) |
| A6 | Jam sesi default **UTC kanonik** (Asia 0–6, London 7–16, NY 12–20) + `InpTimeBase=UTC`; offset broker−UTC auto-ukur `InpAutoGmt` (TimeGMT) | benar di server timezone apa pun; drift musiman ±1 jam tetap ada (jam pasar fixed vs DST lokal) | user bisa switch basis BROKER + manual offset |
| A7 | UTC internal via `HuntNowUtc()` (tester-aware) | `TimeGMT()` tak reliable di Strategy Tester → hasil auto-ukur di-clamp −12..14; di luar itu fallback `InpGMTOffset` (diuji saat OnInit) | — |
| A8 | v1.06 SMC: guard `ZoneStillActive` (zona plan mati → setup invalid; match geometri krn `zone.id` berotasi tiap rebuild); opsi `InpSmcScopeDay` (anchor sweep/BOS/zona: sesi vs hari broker); floor toleransi likuiditas 10%×ATR (non-FX); klaster equal-H/L di-anchor ke swing pertama (kanonik) | deterministik, non-repaint; tanpa guard, pending bisa menunggu di level zona yang sudah INVALID sampai timeout | scope-hari = trade-off vs 'hanya struktur intra-sesi' — default OFF (perilaku lama) |
| A10 | v1.07 fitur SMC **opt-in** (default OFF = perilaku lama): `InpUseBreakerBlocks` (OB patah → breaker ACTIVE, createdTime=bar pematah, anti-recursion `isBrk`), `InpRequireInducement` (G3b: minor swing tersapu antara anchor & bar break), `InpRequireDiscountZone` (G4b: zona vs equilibrium range hari), `InpTpLiquidity` (TP2 = pool un-swept terdekat; cap 4×ATR, RR-min dijaga, TP1 auto-off bila ≥TP2). Preset `SMCplus.set` mengaktifkan keempatnya | bobot skor TETAP 7 komponen (constraint); determinis (closed bars saja) | inducement = aproksimasi (bukan sweep eksplisit antara zona & ekstrem); discount pakai range hari, bukan OTE 62–79% per-leg |
| A11 | v1.08: `HUNT_BrokerDayStart` diankorifikasi ke offset SERVER (m_cfg.gmtOffset; auto-ukur v1.05), BUKAN TimeToStruct TZ mesin | dulu midnight-anchor bergeser sebatas (TZ PC − TZ broker) → seluruh jendela sesi/OR/force-close ikut geser; PC WIB vs broker GMT+2/+3 bisa membuat sesi 'tidak pernah hidup' saat dites | tester: bergantung InpGMTOffset manual (pastikan = TZ data broker) |
| A12 | v1.09: (a) ROLLOVER FIX — `g_sessions.ResetDaily()` kini dipanggil tiap ganti hari (sebelumnya jendela sesi tidak pernah dibangun ulang → sesi mati mulai hari ke-2, gejala 'tanpa breakout/entry' di backtest multi-hari); (b) basis waktu ke-3 `InpTimeBase=AUTO-DST`: jam London/NY diinterpretasi JAM LOKAL bursa lalu dikonversi via aturan DST legal EU/US (MqlDateTime-free, aritmetika civil_from_days) — murni dihitung lokal/offline, TANPA sumber/API pihak ketiga (keputusan 2026-08-31: opsi tabel pihak ketiga DITIADAKAN; verifikasi = kolom UTC di log saja); `SessionManager::ApplySessionHours` | deterministik per hari, termasuk minggu 'gap' ketika AS & EU ganti DST pada tanggal berbeda | tanggal switch (malam Minggu) pakai aturan se-hari penuh — deviasi ≤1 jam hanya pada 4 hari/tahun; Sydney tidak dimodelkan (Asia = input UTC) |
| A13 | v1.12: offset broker−UTC di-ukur ulang + jam sesi dibangun ulang TIAP ROLLOVER via `ReapplyTimeBaseWindows()` (init juga); chart=auto(TimeGMT), tester=manual (`TimeGMT()` di tester == jam server simulasi → pengukuran selalu 0/silent-wrong, dihindari eksplisit); sinkron ke `SessionManager::UpdateGmtOffset` (day-anchor) & `NewsFilter::UpdateGmtOffset` (fetch berikutnya) | broker yg server-nya geser mengikuti DST kini ikut ter-follow tanpa re-attach | jam sesi berubah ≤1 jam pada hari transisi; deviasi half-hour server tetap di-round ke jam penuh |
| A14 | v1.13–v1.14: (a) **band latar sesi** — `VisualRenderer::RenderSessionBands()`: OBJ_RECTANGLE fill full-height per jendela sesi (hari ini + 3 hari; solid gelap tanpa alpha, `BACK=true`, ZORDER −1, ledger `HUNT_LED_SESS`, input `InpShowSessionBands`, sesi live = varian terang); (b) **deskripsi news** — katalog internal deterministik `NewsFilter::DescribeEvent()` (keyword → deskripsi singkat; fallback per-impact berlabel mata uang; murni lokal, TANPA fetch/pihak ketiga — konsisten kanon determinasi sesi) mengisi `SNewsEvent.desc`; `SNewsStatus.nextInfo` → baris dashboard baru `HUNT_DASH_NEWS_DESC` (prioritas jendela blokir aktif, lalu event terdekat); chart: label news 2-baris (currency+judul \n deskripsi) + tooltip vline/label berisi judul penuh, desc, rentang buffer | visual context & konteks event tanpa mengubah logika trading; deskripsi selalu tersedia offline, deterministik | judul tak dikenal → deskripsi generik per-impact; bukan terjemahan komentar fundamental lengkap |
| A15 | v1.15: gate **G2 HTF bias** kini ber-input `InpRequireHtfBias` (default ON = perilaku identik versi sebelumnya; OFF = arah berlawanan/None lolos hard-gate) — checklista dashboard tampil `(gate off)`; bobot skor soft tidak disentuh (bias memang bukan komponen skor); preset semua tetap true | user bisa uji strategi counter-trend OR tanpa mengubah kode | dengan OFF, kontrapremium proteksi arah hilang → evaluasi ulang sebelum pakai akun riil |

## 3. State machine (per sesi)

```
IDLE → RANGE_FORMING → WAIT_BREAKOUT → BREAKOUT_CONFIRMED → WAIT_RETEST → READY_ENTRY → MANAGING → (TP1/trail) → IDLE
              (range minutes lewat)   (ORBDetector: body-close valid)   │            │
                     ↑                          ↑                       │ zone hilang/extension>max% → INVALID (→WAIT_BREAKOUT)
                     │                          └ ConfluenceValidator: 7 gates + skor ≥ minScore
                     └ FORCE_CLOSED (lock s/d sesi selesai) — dari MANAGING/WAIT_* via timer
```

Pending order (`ENTRY_PENDING_ORDER`) hidup di `WAIT_RETEST`: limit di tepi zona + SL/TP sejak pasang; `TradeExecutor.Manage()` menghitung bar sejak pemasangan → `HUNT_EVT_PENDING_EXPIRED` bila > `InpRetestMaxBars`, atau dibatalkan lebih awal oleh aturan extension (`InpMaxExtensionBeforeRetest`).

## 4. Hard-gates ConfluenceValidator

G1 breakout valid · G2 searah bias HTF · G3 pool searah sudah di-sweep · G4 zona OB/FVG tersedia untuk retest · G5 non-window news · G6 spread · G7 risk-ok.
**Catatan G4:** default spesifikasi = retest wajib, entry di candle breakout tidak pernah diizinkan. `InpRequireFVGRetest=false` = opt-in sadar melepas G4 (entry langsung saat breakout confirmed, skor tetap diverifikasi) — dipakai hanya utk backtest perbandingan, bukan untuk live default.
Skor lunak: sweep presisi 25 · BOS-post-sweep 20 · zona fresh 15 · range>2×ATR 15 · extension kecil 10 · non-RSI-extreme 10 · London/NY 5 → `InpMinConfluenceScore`.

## 5. Kontrak mutu

- Closed-bar only (`back=0` = shift 1); bar berjalan tak pernah masuk kalkulasi sinyal → non-repaint, non-lookahead (konfirmasi swing butuh lookback kanan closed).
- Indikator via handle (dibuat `OnInit`, `IndicatorRelease` di `OnDeinit`).
- Semua order via `CTrade` + retry retcode transient + `ResultRetcodeDescription()`.
- OnTick ringan; pipeline heavy di gerbang `NewBarArrived`; countdown & refresh terjadwal di `OnTimer(1)`.
- Tanpa `#property strict` (deprecated di MQL5 → menimbulkan *warning*; target: nol warning).
- Volume Profile: approximasi **per-bar** (bukan tick-level) — murah & deterministik, konsistensi backtest/forward terjamin.


---

## 11. Implementasi vs skeleton (perbedaan final)

- `CLockSession` dihapus; force-close dieksekusi via
  `CSessionManager::InForceCloseWindow()` + `CTradeExecutor::CloseSessionPositions()`
  dari OnTimer sweep 1-detik (bukan event terpisah).
- `CORBDetector::Assess(session, orIn, data, nowBrk, SBreakout &res)` — keluaran
  lewat out-param + return bool (bukan struct by-value); ditambahkan
  `RefreshStatus(session, orIn, data)` utk re-arm status saat price balik ke range.
- `CSessionManager::SetOrStatus(session, status)` ditambahkan (helper re-arm
  RANGING; clear breakoutTime/dir, barsSince di-reset oleh ORBDetector.Reset).
- `SSignalPlan` memakai `validUntilBarTime` sbg jangkar expiry pending PER PLAN
  (bukan field global bar-patch di executor) + flag `partialDone`.
- `SSMCContext` membawa `zoneFresh/rangeBigAtr/extensionPct` + salinan zone utk
  re-check; `zoneTopSnap/zoneBottomSnap` di plan dipakai gate retest snap-safe.
- Konfluensi = gate keras G1–G7 (hard reject) + skor 7 komponen (≥60 default);
  re-check saat entry memakai `StillValid()` (freshness ≤3 bar, belum broken/used).
- Risk: `BuildPlan(plan,data,structLevel)`; SL = ekstrem struktur −/+ buffer
  (min 1×ATR); TP2 fallback 2R bila swing target tak ada (no pool-target API).
- News: parsing toleran dari HTML investing.com (bukan JSON) — kolom waktu/hari
  dideteksi struktural, impact difilter SERVER-side via URL `importance=`,
  heuristik utk medium; cache di-`TimeTradeServer`-space; veto hanya utk entry.
- Eksekusi: retcode transien (REQUOTE/PRICE_CHANGED/PRICE_OFF/TIMEOUT/CONNECTION/
  ORDER_CHANGED) → retry ≤ InpOrderRetries dg refresh quote; re-pricing pending
  HANYA mode Execution sebelum market entry.
- Renderer memakai ledger `{category,name,expire}` — cleanup per kategori +
  kedaluwarsa (OB 6 jam, marker entry 48 jam), `Finish()` = 1 ChartRedraw;
  tanpa `ObjectsDeleteAll`.
- Dashboard: 1 rectangle label bg + label per baris (OBJ_RECTANGLE_LABEL tidak
  punya alpha — bg solid gelap sebagai workaround transparansi), SetRow
  diff-only (hanya write saat teks/ warna berubah), countdown detik by OnTimer.
