#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Mock-up visual elemen chart EA "ORB_SMC_NextGen.mq5".
Bukan screenshot MT5 asli — replika akurat (warna/format dari Defines.mqh)
untuk memperlihatkan apa yang digambar VisualRenderer + Dashboard.
Output: docs/chart-preview.png + docs/dashboard-preview.png
"""
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from matplotlib.patches import Rectangle, FancyArrow
from datetime import datetime, timedelta

# ---------- Palet dari Defines.mqh ----------
CLR_ASIA     = "#3094D2"
CLR_LONDON   = "#E18228"
CLR_NY       = "#965FCD"
CLR_BULL     = "#00A078"
CLR_BEAR     = "#E14155"
CLR_NEUTRAL  = "#96989E"
CLR_TEXT     = "#E8EAEE"
CLR_TEXT_DIM = "#A5A8AE"
CLR_PANEL_BG = "#10141C"
CLR_NEWS_HIGH= "#EB4646"
CLR_NEWS_MED = "#EBA53C"
CLR_SWEEP    = "#FF00BE"
CLR_READY    = "#46D75A"
CLR_BOS      = "#00B9E1"
CLR_CHOCH    = "#FFA000"
CLR_OB_BULL  = "#2DBEA0"
CLR_FVG_BULL = "#78C85A"
CLR_PIVOT    = "#8C919B"
CLR_POC      = "#FFD75A"
CLR_VAH_VAL  = "#C896F0"
BG           = "#0D0F14"
GRID         = "#1A1D25"

BASE = datetime(2026, 8, 28)          # tanggal chart (UTC)
NOW  = BASE + timedelta(hours=13, minutes=21, seconds=30)   # waktu "sekarang" (broker)

def t(hh, mm=0):
    return BASE + timedelta(hours=hh, minutes=mm)

# ---------- Data candle M15 (O, H, L, C) ----------
# Narasi: Asia ranging (OR 00:00-00:30) → breakdown → LL + reversal (CHoCH kandidat)
# London open sweep EQH 2653.50 → grab candle (OB) → displacement breakout OR →
# retest → BuyLimit fill di tepi OB → rally (TP1 hit) → news CPI 13:30 (blokir aktif)
BARS = [
 # prev day (untuk swing 00:15 & pivot)
 (23,0, 2652.00,2652.30,2651.70,2652.10), (23,15, 2652.10,2652.40,2651.90,2652.20),
 (23,30, 2652.20,2652.50,2652.00,2652.40), (23,45, 2652.40,2652.50,2652.10,2652.30),
 # Asia
 (0,0, 2652.30,2652.60,2651.95,2652.20), (0,15, 2652.20,2653.52,2652.10,2652.80),
 (0,30, 2652.80,2653.30,2652.60,2653.00), (0,45, 2653.00,2653.10,2652.30,2652.30),
 (1,0, 2652.30,2652.40,2651.90,2651.90), (1,15, 2651.90,2652.90,2651.80,2652.40),
 (1,30, 2652.40,2652.40,2651.90,2652.00), (1,45, 2652.00,2652.10,2651.70,2651.80),
 (2,0, 2651.80,2651.90,2651.70,2651.70), (2,15, 2651.70,2652.20,2651.60,2651.90),
 (2,30, 2651.90,2652.00,2651.45,2651.60), (2,45, 2651.60,2651.60,2651.30,2651.40),
 (3,0, 2651.40,2651.50,2651.20,2651.30), (3,15, 2651.30,2651.60,2651.55,2651.50),
 (3,30, 2651.50,2652.30,2651.10,2652.00), (3,45, 2652.00,2652.90,2651.90,2652.50),
 (4,0, 2652.50,2653.20,2652.40,2652.90), (4,15, 2652.90,2653.20,2652.70,2653.10),
 (4,30, 2653.10,2653.45,2652.90,2653.40), (4,45, 2653.40,2653.50,2653.10,2653.50),
 (5,0, 2653.30,2653.45,2653.00,2653.00), (5,15, 2653.00,2653.10,2652.60,2652.60),
 (5,30, 2652.60,2652.80,2652.20,2652.20), (5,45, 2652.20,2652.60,2652.00,2652.00),
 (6,0, 2652.00,2652.80,2651.90,2652.30), (6,15, 2652.30,2652.70,2652.10,2652.10),
 (6,30, 2652.10,2653.00,2652.00,2652.50), (6,45, 2652.50,2652.80,2652.30,2652.30),
 (7,0, 2652.30,2652.90,2652.30,2652.60), (7,15, 2652.60,2652.70,2652.30,2652.40),
 (7,30, 2652.40,2652.90,2652.40,2652.70), (7,45, 2652.70,2652.80,2652.40,2652.50),
 # London
 (8,0, 2652.50,2653.30,2652.94,2653.10), (8,15, 2653.10,2654.82,2653.00,2654.20),
 (8,30, 2654.20,2654.60,2653.90,2654.00), (8,45, 2654.00,2654.30,2653.40,2653.70),
 (9,0, 2653.70,2654.30,2653.60,2654.20), (9,15, 2654.60,2654.60,2652.10,2652.90),
 (9,30, 2652.90,2653.40,2652.80,2653.20), (9,45, 2653.20,2655.60,2653.10,2655.40),
 (10,0, 2655.40,2655.40,2654.50,2654.60), (10,15, 2654.60,2654.70,2653.00,2653.20),
 (10,30, 2653.20,2654.00,2653.20,2653.90), (10,45, 2653.90,2654.00,2653.40,2653.50),
 (11,0, 2653.50,2654.40,2653.40,2654.20), (11,15, 2654.20,2655.00,2654.10,2654.90),
 (11,30, 2654.90,2655.20,2654.90,2655.00), (11,45, 2655.00,2655.60,2655.20,2655.50),
 (12,0, 2655.50,2656.10,2655.40,2655.90), (12,15, 2655.90,2656.20,2655.60,2656.00),
 (12,30, 2656.00,2656.50,2655.90,2656.40), (12,45, 2656.40,2656.40,2655.80,2656.00),
 (13,0, 2656.00,2657.90,2656.50,2657.80), (13,15, 2657.80,2657.80,2657.00,2657.50),
]
CUR_PRICE = 2657.62

# =============================================================
# FIGURE 1 : CHART LENGKAP
# =============================================================
fig = plt.figure(figsize=(16, 9), dpi=150)
fig.patch.set_facecolor(BG)
ax = fig.add_axes([0.055, 0.11, 0.745, 0.80])
ax.set_facecolor(BG)

# --- candles ---
for (h, m, o, hi, lo, c) in BARS:
    x = mdates.date2num(t(h, m))
    body_h = max(o, c); body_l = min(o, c)
    clr = CLR_BULL if c >= o else CLR_BEAR
    ax.plot([x, x], [lo, body_l], color=clr, lw=0.7, zorder=2)
    ax.plot([x, x], [body_h, hi], color=clr, lw=0.7, zorder=2)
    w = 0.0085
    ax.add_patch(Rectangle((x - w/2, body_l), w, max(body_h-body_l, 0.02),
                 facecolor=clr, edgecolor=clr, lw=0.4, zorder=3))

# --- pivot harian (D1 sebelumnya) ---
ph, pl, pc = 2660.0, 2649.0, 2652.0
PP = (ph+pl+pc)/3.0
pivots = [("PP", PP), ("R1", 2*PP-pl), ("S1", 2*PP-ph),
          ("R2", PP+(ph-pl)), ("S2", PP-(ph-pl)),
          ("R3", ph+2*(PP-pl)), ("S3", pl-2*(ph-pl))]
for name, pv in pivots:
    ax.axhline(pv, color=CLR_PIVOT, lw=0.8, ls=":", zorder=1)
    if 2648.5 < pv < 2660.6:
        ax.text(mdates.date2num(t(14, 40)), pv, f"{name} {pv:.2f}", color=CLR_PIVOT,
                fontsize=7, va="center", ha="left", family="monospace")

# --- Opening Range per sesi (garis dibatasi jendela sesi, warna per sesi) ---
def or_lines(x0h, x0m, x1h, x1m, hi, lo, color, label):
    x0, x1 = mdates.date2num(t(x0h, x0m)), mdates.date2num(t(x1h, x1m))
    ax.plot([x0, x1], [hi, hi], color=color, lw=1.4, zorder=4)
    ax.plot([x0, x1], [lo, lo], color=color, lw=1.4, zorder=4)
    ax.text(x0+0.004, hi+0.16, label, color=color, fontsize=7.5, family="monospace")
    ax.text(x1+0.004, hi+0.05, f"{hi:.2f}", color=color, fontsize=6.8, family="monospace")
    ax.text(x1+0.004, lo-0.18, f"{lo:.2f}", color=color, fontsize=6.8, family="monospace")

or_lines(0,0, 0,30, 2653.52, 2651.95, CLR_ASIA,   "ASIA OR 15.7p")
or_lines(8,0, 8,30, 2654.82, 2652.94, CLR_LONDON, "LDN OR 18.8p")

# --- Order Block (bullish, kotak) ---
x_ob0 = mdates.date2num(t(9, 15)); x_ob1 = mdates.date2num(NOW)
ax.add_patch(Rectangle((x_ob0, 2652.10), x_ob1-x_ob0, 2654.60-2652.10,
             facecolor=CLR_OB_BULL, alpha=0.16, edgecolor=CLR_OB_BULL, lw=1.0, zorder=4))
ax.text(x_ob0+0.004, 2653.55, "OB+", color=CLR_OB_BULL, fontsize=7.5,
        family="monospace", weight="bold")
ax.text(x_ob0+0.004, 2654.66, "2654.60", color=CLR_OB_BULL, fontsize=6.8, family="monospace")
ax.text(x_ob0+0.004, 2652.04-0.10, "2652.10", color=CLR_OB_BULL, fontsize=6.8, family="monospace")

# --- FVG (kotak border putus-putus) ---
x_f0 = mdates.date2num(t(12, 45))
ax.add_patch(Rectangle((x_f0, 2656.40), x_ob1-x_f0, 2657.00-2656.40,
             facecolor="none", edgecolor=CLR_FVG_BULL, lw=1.0, ls=(0,(4,2)), zorder=4))
ax.text(x_f0+0.004, 2656.62, "FVG+", color=CLR_FVG_BULL, fontsize=7.5, family="monospace")
ax.text(x_f0+0.004, 2657.04, "2657.00", color=CLR_FVG_BULL, fontsize=6.8, family="monospace")
ax.text(x_f0+0.004, 2656.34-0.10, "2656.40", color=CLR_FVG_BULL, fontsize=6.8, family="monospace")

# --- Swing label HH/HL/LH/LL ---
swings = [
    (t(0,15),  2653.52, "HH", +1), (t(3,30),  2651.10, "LL", -1),
    (t(4,45),  2653.50, "LH", +1), (t(6,30),  2653.00, "LH", +1),
    (t(8,15),  2654.82, "HH", +1), (t(9,45),  2655.60, "HH", +1),
    (t(12,45), 2655.80, "HL", -1), (t(13,0),  2657.90, "HH", +1),
]
for (tm, pr, lbl, sgn) in swings:
    off = 0.13 if sgn > 0 else -0.17
    ax.text(mdates.date2num(tm), pr+off, f"{lbl} {pr:.2f}", color=CLR_TEXT_DIM,
            fontsize=6.8, ha="center", family="monospace")

# --- BOS / CHoCH ---
def struct_marker(tm, pr, lbl, clr, dy, side="right"):
    x = mdates.date2num(tm)
    ax.annotate("", xy=(x, pr), xytext=(x, pr-dy),
                arrowprops=dict(arrowstyle="-|>", color=clr, lw=1.3,
                                mutation_scale=10), zorder=6)
    tx = x+0.004 if side == "right" else x-0.030
    ha = "left" if side == "right" else "right"
    ax.text(tx, pr+0.06, f"{lbl} {pr:.2f}", color=clr, fontsize=7, family="monospace",
            weight="bold", ha=ha)
struct_marker(t(8,15),  2654.82, "CHoCH", CLR_CHOCH, 0.45, side="left")
struct_marker(t(9,45),  2655.60, "BOS",   CLR_BOS,   0.40)
struct_marker(t(13,0),  2657.90, "BOS",   CLR_BOS,   0.40, side="left")

# --- Liquidity sweep (marker magenta di wick) ---
x = mdates.date2num(t(8, 15))
ax.annotate("", xy=(x+0.005, 2654.95), xytext=(x+0.005, 2654.55),
            arrowprops=dict(arrowstyle="-|>", color=CLR_SWEEP, lw=1.6,
                            mutation_scale=12), zorder=7)
ax.text(x+0.011, 2654.95, "SWEEP EQH 2653.50", color=CLR_SWEEP, fontsize=6.8,
        family="monospace", va="center")

# --- Entry arrow + label (retest ter-fill di tepi OB) ---
x = mdates.date2num(t(11, 15))
ax.annotate("", xy=(x, 2654.66), xytext=(x, 2654.38),
            arrowprops=dict(arrowstyle="-|>", color=CLR_READY, lw=1.6,
                            mutation_scale=12), zorder=7)
ax.text(x+0.004, 2656.15,
        "BUY ENTRY 0.20 @2654.60 (limit fill)\nSL 2652.00 | TP 2659.80 | RR 2.0",
        color=CLR_READY, fontsize=6.8, family="monospace", va="bottom",
        bbox=dict(boxstyle="round,pad=0.25", fc=BG, ec=CLR_READY, lw=0.6, alpha=0.75))

# --- TP1 partial close ---
ax.text(mdates.date2num(t(13,0))+0.004, 2657.32, "TP1 50% ✓ → SL BE",
        color=CLR_POC, fontsize=6.8, family="monospace")

# --- News: shading window blokir + VLINE + label ---
x0 = mdates.date2num(t(13, 0)); x1 = mdates.date2num(t(14, 0))
ax.axvspan(x0, x1, color=CLR_NEWS_HIGH, alpha=0.10, zorder=0)
ax.axvline(mdates.date2num(t(13, 30)), color=CLR_NEWS_HIGH, lw=1.1, ls=(0,(5,3)), zorder=5)
ax.text(mdates.date2num(t(13, 30))+0.004, 2659.9, "USD CPI (High) 13:30",
        color=CLR_NEWS_HIGH, fontsize=7, family="monospace")
ax.text(mdates.date2num(t(13, 0))+0.004, 2659.35, "jendela blokir entry [13:00–14:00]",
        color=CLR_NEWS_HIGH, fontsize=6.2, family="monospace", alpha=0.85)

# --- Volume Profile (VAH/VAL/POC) di sisi kanan chart ---
bins = np.linspace(2648.5, 2660.6, 42)
c = (bins[:-1]+bins[1:])/2
vol = (420*np.exp(-((c-2654.50)**2)/(2*0.55**2)) +
       270*np.exp(-((c-2656.90)**2)/(2*0.22**2)) +
       np.random.default_rng(7).uniform(0, 14, len(c)))
poc_idx = int(np.argmax(vol)); total = vol.sum(); accum = vol[poc_idx]
lo_i = hi_i = poc_idx
while accum < total*0.70 and (lo_i > 0 or hi_i < len(vol)-1):
    vlo = vol[lo_i-1] if lo_i > 0 else -1
    vhi = vol[hi_i+1] if hi_i < len(vol)-1 else -1
    if vhi >= vlo and hi_i < len(vol)-1:
        hi_i += 1; accum += vol[hi_i]
    elif lo_i > 0:
        lo_i -= 1; accum += vol[lo_i]
    else:
        break
poc_p = c[poc_idx]; vah_p = bins[hi_i+1]; val_p = bins[lo_i]
xvp0 = mdates.date2num(t(14, 28)); xvp1 = mdates.date2num(t(15, 0))
vmax = vol.max()
for i, v in enumerate(vol):
    if v < 4: continue
    w = (v/vmax) * (xvp1-xvp0)
    ax.add_patch(Rectangle((xvp1-w, bins[i]), w, bins[1]-bins[0],
                 facecolor=CLR_POC if i == poc_idx else "#3A3F4C",
                 alpha=0.85 if i == poc_idx else 0.55, edgecolor="none", zorder=4))
ax.plot([xvp0, xvp1], [poc_p, poc_p], color=CLR_POC, lw=1.8, zorder=6)
ax.plot([xvp0, xvp1], [vah_p, vah_p], color=CLR_VAH_VAL, lw=1.0, ls=(0,(4,2)), zorder=6)
ax.plot([xvp0, xvp1], [val_p, val_p], color=CLR_VAH_VAL, lw=1.0, ls=(0,(4,2)), zorder=6)
ax.text(xvp1+0.001, poc_p, f"POC {poc_p:.2f}", color=CLR_POC, fontsize=6.8, va="center", family="monospace", weight="bold")
ax.text(xvp1+0.001, vah_p, f"VAH {vah_p:.2f}", color=CLR_VAH_VAL, fontsize=6.8, va="center", family="monospace")
ax.text(xvp1+0.001, val_p, f"VAL {val_p:.2f}", color=CLR_VAH_VAL, fontsize=6.8, va="center", family="monospace")
ax.text(mdates.date2num(t(14, 28)), 2649.2, "VP sesi London", color="#3A3F4C",
        fontsize=6.5, family="monospace")

# --- harga sekarang ---
ax.axhline(CUR_PRICE, color=CLR_TEXT, lw=0.6, ls=(0,(2,2)), alpha=0.5, zorder=5)
ax.text(mdates.date2num(t(13, 21))-0.003, CUR_PRICE+0.08, "2657.62", color=CLR_TEXT,
        fontsize=6.5, family="monospace", ha="right")

# --- axes styling ---
ax.set_xlim(mdates.date2num(t(0,0)), mdates.date2num(t(15,0)))
ax.set_ylim(2648.5, 2660.6)
ax.xaxis.set_major_locator(mdates.MinuteLocator(interval=120))
ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
ax.tick_params(colors=CLR_TEXT_DIM, labelsize=8, length=0)
for s in ax.spines.values(): s.set_color(GRID)
ax.grid(True, color=GRID, lw=0.5, alpha=0.8)
ax.set_axisbelow(True)

# --- DASHBOARD PANEL (overlay, seperti OBJ_RECTANGLE_LABEL + OBJ_LABEL) ---
DASH = [
 ("ORB_SMC_NextGen v1.00 | XAUUSD M15", CLR_TEXT),
 ("─ SESI & RANGE ─", CLR_TEXT_DIM),
 ("Aktif: London | sisa 02:38:30", CLR_LONDON),
 ("Asia   OR 2653.52/2651.95 (15.7p) Breakout Down", CLR_ASIA),
 ("London OR 2654.82/2652.94 (18.8p) Breakout Up", CLR_BULL),
 ("New York OR forming…", CLR_NY),
 ("Candle 08:30", CLR_TEXT),
 ("─ STRUKTUR & SINYAL ─", CLR_TEXT_DIM),
 ("Bias HTF: Bullish | Lokal: Bullish", CLR_BULL),
 ("State ASIA:Idle  LDN:Traded  NY:Forming", CLR_TEXT),
 ("Breakout London UP | skor 85/100", CLR_BULL),
 ("Zona OB [2652.10-2654.60]", CLR_TEXT),
 ("Sweep: Yes (EQH @2653.50)", CLR_SWEEP),
 ("RSI(14): 62.4 Neutral", CLR_TEXT),
 ("─ POSISI & RISIKO ─", CLR_TEXT_DIM),
 ("Pos: BUY 0.20 @2654.60", CLR_TEXT),
 ("  SL 2652.00 | TP 2659.80", CLR_TEXT_DIM),
 ("  P/L +60.40 (+0.60%)", CLR_BULL),
 ("Force-close LDN: 02:08:30", CLR_TEXT),
 ("Hari ini: 1/3 trade | P/L +0.60%", CLR_BULL),
 ("─ NEWS ─", CLR_TEXT_DIM),
 ("Filter: ON [OK] upd 06:12 | USD", CLR_BULL),
 ("BLOKIR: USD CPI 13:30 (sisa 00:38:30)", CLR_NEWS_HIGH),
]

def draw_panel(axis, x, y_top, width, n_lines, step, fontsize):
    h = n_lines * step
    axis.add_patch(Rectangle((x, y_top - h), width, h + step*0.55, transform=axis.transAxes,
                   facecolor=CLR_PANEL_BG, alpha=0.90, edgecolor="#3C404A",
                   lw=0.8, zorder=50))
    for i, (txt, clr) in enumerate(DASH):
        axis.text(x+0.006, y_top - step/2 - i*step, txt, transform=axis.transAxes,
                  color=clr, fontsize=fontsize, family="monospace", va="center",
                  ha="left", zorder=51)

draw_panel(ax, 0.008, 0.995, 0.30, 23, 0.0415, 7.0)

# --- caption ---
fig.text(0.055, 0.045,
         "Mock-up visual — contoh elemen chart yang digambar EA (bukan screenshot MT5 asli). "
         "Semua elemen level harga (OR, OB, FVG, swing, BOS/CHoCH, sweep, pivot, VP) menampilkan label harga — format FmtPrice() sesuai digit simbol; dapat dimatikan via InpShowPriceLabels. Warna & format mengikuti palet Defines.mqh; toggle masing-masing lewat input InpShowOB/InpShowFVG/InpShowStructure/"
         "InpShowSweep/InpShowEntryArrows/InpShowPivot/InpShowVolumeProfile/InpShowNewsMarkers/InpShowDashboard.",
         color=CLR_TEXT_DIM, fontsize=7.5, family="monospace", wrap=True)
fig.text(0.055, 0.012,
         "Skenario: XAUUSD M15 — Asia OR + breakdown ditolak bias HTF (Idle) → London open sweep EQH → OB terbentuk → "
         "breakout OR → retest → BuyLimit ter-fill di tepi OB → TP1 hit (SL breakeven) → news USD CPI 13:30 memblokir entry baru.",
         color="#6E7380", fontsize=7.5, family="monospace", wrap=True)

fig.savefig("docs/chart-preview.png", facecolor=fig.get_facecolor(), bbox_inches="tight")
plt.close(fig)

# =============================================================
# FIGURE 2 : DASHBOARD CLOSE-UP
# =============================================================
fig2 = plt.figure(figsize=(5.4, 6.4), dpi=200)
fig2.patch.set_facecolor(BG)
ax2 = fig2.add_axes([0, 0, 1, 1]); ax2.set_facecolor(BG); ax2.axis("off")
draw_panel(ax2, 0.05, 0.99, 0.90, 23, 0.0415, 9.5)
fig2.text(0.05, 0.015, "Format persis dari CDashboard::Update() — section SESI & RANGE / STRUKTUR & SINYAL / "
         "POSISI & RISIKO / NEWS (contoh angka).", color=CLR_TEXT_DIM, fontsize=7,
         family="monospace", wrap=True)
fig2.savefig("docs/dashboard-preview.png", facecolor=fig2.get_facecolor(), bbox_inches="tight")
plt.close(fig2)

print("OK: docs/chart-preview.png + docs/dashboard-preview.png")
