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
| A4 | **State machine PER SESI** (`g_state[3]`) | sesi boleh overlap (London 14–22 & NY 19–03); force-close tidak mengganggu sesi lain | orkestrasi lebih eksplisit di file utama |
| A5 | Prefix objek `HUNT_*` (bukan `ORBSMC_*`) + **ledger** nama objek | `OnDeinit`/rebuild tidak menabrak objek EA lain milik user | perlu ledger maintenance (di-renderer) |
| A6 | Jam sesi default **broker time** (`InpTimeBase` bisa di-switch ke UTC) | sesuai teks spesifikasi; DST broker-independent | user harus set `InpGMTOffset` benar utk news |
| A7 | UTC internal via `HuntNowUtc()` (tester-aware) | `TimeGMT()` tak reliable di Strategy Tester | offset GMT manual utk mode tester |

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
