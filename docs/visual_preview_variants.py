#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Varian mock-up visual EA "ORB_SMC_NextGen.mq5":
  1) chart-preview-bearish.png  — skenario bearish: NY session, sweep EQH → breakout
     down → retest → SellLimit ter-fill di tepi OB → TP1 hit; news MEDIUM memblokir.
  2) entry-modes-preview.png    — perbandingan mode ENTRY_PENDING_ORDER vs
     ENTRY_EXECUTION (schematic).
Warna/format mengikuti palet Defines.mqh.
"""
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from matplotlib.patches import Rectangle
from datetime import datetime, timedelta

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
CLR_OB_BEAR  = "#EB5F69"
CLR_OB_BULL  = "#2DBEA0"
CLR_PIVOT    = "#8C919B"
CLR_POC      = "#FFD75A"
CLR_VAH_VAL  = "#C896F0"
BG           = "#0D0F14"
GRID         = "#1A1D25"

BASE = datetime(2026, 8, 28)
NOW  = BASE + timedelta(hours=16, minutes=21, seconds=30)

def t(hh, mm=0):
    return BASE + timedelta(hours=hh, minutes=mm)

# ---------- candle M15: O,H,L,C ----------
BARS = [
 (21,30, 2659.20,2661.50,2658.90,2660.40), (21,45, 2660.40,2660.90,2659.80,2660.20),
 (22,0, 2660.20,2660.40,2659.20,2659.40), (22,15, 2659.40,2659.70,2658.60,2659.00),
 (22,30, 2659.00,2659.30,2658.40,2658.60), (22,45, 2658.60,2659.60,2658.40,2659.30),
 (23,0, 2659.30,2659.80,2658.80,2659.60), (23,15, 2659.60,2660.20,2659.40,2660.10),
 (23,30, 2660.10,2660.30,2659.40,2659.60), (23,45, 2659.60,2659.90,2659.30,2659.80),
 # Asia
 (0,0, 2659.80,2660.00,2658.60,2659.00), (0,15, 2659.00,2659.20,2658.10,2658.40),
 (0,30, 2658.40,2658.60,2657.70,2657.90), (0,45, 2657.90,2658.30,2657.80,2658.10),
 (1,0, 2658.10,2658.40,2657.90,2658.20), (1,15, 2658.20,2659.90,2658.00,2659.60),
 (1,30, 2659.60,2660.10,2659.40,2659.90), (1,45, 2659.90,2660.20,2659.60,2660.20),  # EQH #1 (Asia high)
 (2,0, 2660.20,2660.20,2659.20,2659.20), (2,15, 2659.20,2659.20,2658.30,2658.50),
 (2,30, 2658.50,2658.70,2658.20,2658.30), (2,45, 2658.30,2658.50,2657.80,2658.00),
 (3,0, 2658.00,2658.00,2657.60,2657.60), (3,15, 2657.60,2658.30,2657.55,2658.10),
 (3,30, 2658.10,2658.90,2657.90,2658.70), (3,45, 2658.70,2659.10,2658.50,2658.90),
 (4,0, 2658.90,2659.10,2658.60,2658.70), (4,15, 2658.70,2658.80,2658.20,2658.30),
 (4,30, 2658.30,2658.50,2658.00,2658.10), (4,45, 2658.10,2658.40,2657.90,2658.20),
 (5,0, 2658.20,2658.30,2657.80,2657.90), (5,15, 2657.90,2658.00,2657.60,2657.60),  # EQL #1
 (5,30, 2657.60,2658.20,2657.50,2658.10), (5,45, 2658.10,2658.50,2657.90,2658.40),
 (6,0, 2658.40,2659.20,2658.30,2659.00), (6,15, 2659.00,2659.20,2658.60,2658.70),
 (6,30, 2658.70,2659.40,2658.60,2659.20), (6,45, 2659.20,2659.30,2658.70,2658.80),
 (7,0, 2658.80,2659.20,2658.80,2659.10), (7,15, 2659.10,2659.20,2658.70,2658.80),
 (7,30, 2658.80,2659.10,2658.70,2659.00), (7,45, 2659.00,2659.10,2658.60,2658.70),
 # London
 (8,0, 2658.70,2659.40,2658.65,2659.20), (8,15, 2659.20,2660.20,2659.10,2660.20),  # EQH #2 (LDN OR high)
 (8,30, 2660.20,2660.30,2659.40,2659.50), (8,45, 2659.50,2659.90,2659.10,2659.40),
 (9,0, 2659.40,2659.70,2659.10,2659.60), (9,15, 2659.60,2659.60,2657.60,2658.00),   # EQL #2
 (9,30, 2658.00,2658.40,2657.90,2658.30), (9,45, 2658.30,2658.70,2658.20,2658.50),
 (10,0, 2658.50,2658.90,2658.40,2658.70), (10,15, 2658.70,2658.90,2658.30,2658.60),
 (10,30, 2658.60,2658.70,2658.20,2658.40), (10,45, 2658.40,2658.60,2658.10,2658.30),
 (11,0, 2658.30,2658.50,2658.20,2658.40), (11,15, 2658.40,2658.60,2658.20,2658.30),
 (11,30, 2658.30,2658.50,2658.10,2658.40), (11,45, 2658.40,2658.50,2658.10,2658.20),
 (12,0, 2658.20,2658.60,2658.20,2658.50), (12,15, 2658.50,2658.60,2658.20,2658.30),
 (12,30, 2658.30,2658.50,2658.20,2658.40), (12,45, 2658.40,2658.50,2658.10,2658.20),
 # New York
 (13,0, 2658.20,2659.30,2658.90,2659.20), (13,15, 2659.20,2659.80,2658.95,2659.40),
 (13,30, 2659.40,2659.70,2659.10,2659.20), (13,45, 2659.20,2660.70,2659.00,2660.30),  # sweep EQH → grab candle (OB bearish)
 (14,0, 2660.30,2660.40,2658.30,2658.30),  # displacement down — breakout OR
 (14,15, 2658.30,2658.40,2656.80,2658.10),  # EQL sweep
 (14,30, 2658.10,2658.40,2657.80,2658.00), (14,45, 2658.00,2658.30,2657.90,2658.20),
 (15,0, 2658.20,2659.05,2658.10,2658.40),   # retest → SellLimit fill di 2659.00
 (15,15, 2658.40,2658.50,2657.60,2657.70), (15,30, 2657.70,2657.80,2657.00,2657.10),
 (15,45, 2657.10,2657.20,2656.30,2656.40),  # TP1 hit (RR1)
 (16,0, 2656.40,2656.60,2655.80,2656.00), (16,15, 2656.00,2656.10,2655.30,2655.70),
]
CUR_PRICE = 2655.65

fig = plt.figure(figsize=(16, 9), dpi=150)
fig.patch.set_facecolor(BG)
ax = fig.add_axes([0.055, 0.11, 0.745, 0.80])
ax.set_facecolor(BG)

for (h, m, o, hi, lo, c) in BARS:
    x = mdates.date2num(t(h, m))
    clr = CLR_BULL if c >= o else CLR_BEAR
    ax.plot([x, x], [lo, min(o, c)], color=clr, lw=0.7, zorder=2)
    ax.plot([x, x], [max(o, c), hi], color=clr, lw=0.7, zorder=2)
    w = 0.0085
    ax.add_patch(Rectangle((x - w/2, min(o, c)), w, max(abs(c-o), 0.02),
                 facecolor=clr, edgecolor=clr, lw=0.4, zorder=3))

# --- pivot ---
ph, pl, pc = 2664.0, 2656.0, 2658.0
PP = (ph+pl+pc)/3.0
for name, pv in [("PP", PP), ("R1", 2*PP-pl), ("S1", 2*PP-ph), ("R2", PP+(ph-pl)), ("S2", PP-(ph-pl))]:
    ax.axhline(pv, color=CLR_PIVOT, lw=0.8, ls=":", zorder=1)
    if 2654.0 < pv < 2662.5:
        ax.text(mdates.date2num(t(17, 40)), pv, f"{name} {pv:.2f}", color=CLR_PIVOT,
                fontsize=7, va="center", ha="left", family="monospace")

# --- OR per sesi ---
def or_lines(x0h, x1h, hi, lo, color, label):
    x0, x1 = mdates.date2num(t(x0h, 0)), mdates.date2num(t(x1h, 0))
    ax.plot([x0, x1], [hi, hi], color=color, lw=1.4, zorder=4)
    ax.plot([x0, x1], [lo, lo], color=color, lw=1.4, zorder=4)
    ax.text(x0+0.004, hi+0.16, label, color=color, fontsize=7.5, family="monospace")
    ax.text(x1+0.004, hi+0.05, f"{hi:.2f}", color=color, fontsize=6.8, family="monospace")
    ax.text(x1+0.004, lo-0.18, f"{lo:.2f}", color=color, fontsize=6.8, family="monospace")

or_lines(0, 0.5, 2660.00, 2657.70, CLR_ASIA,   "ASIA OR 23.0p")
or_lines(8, 8.5, 2660.20, 2658.65, CLR_LONDON, "LDN OR 15.5p")
or_lines(13, 13.5, 2659.80, 2658.90, CLR_NY,   "NY OR 9.0p")

# --- Order Block bearish (kotak merah) ---
x0 = mdates.date2num(t(13, 45)); x1 = mdates.date2num(NOW)
ax.add_patch(Rectangle((x0, 2659.00), x1-x0, 2660.70-2659.00,
             facecolor=CLR_OB_BEAR, alpha=0.16, edgecolor=CLR_OB_BEAR, lw=1.0, zorder=4))
ax.text(x0+0.004, 2660.30, "OB-", color=CLR_OB_BEAR, fontsize=7.5,
        family="monospace", weight="bold")
ax.text(x0+0.004, 2660.74, "2660.70", color=CLR_OB_BEAR, fontsize=6.8, family="monospace")
ax.text(x0+0.004, 2658.94-0.10, "2659.00", color=CLR_OB_BEAR, fontsize=6.8, family="monospace")

# --- swing label ---
for (tm, pr, lbl, sgn) in [
    (t(21,30), 2661.50, "HH", +1), (t(1,45), 2660.20, "LH", +1),
    (t(8,15), 2660.20, "LH", +1), (t(3,0), 2657.60, "HL", -1),
    (t(9,15), 2657.60, "HL", -1), (t(14,15), 2656.80, "LL", -1),
    (t(15,45), 2656.30, "LL", -1),
]:
    off = 0.13 if sgn > 0 else -0.17
    ax.text(mdates.date2num(tm), pr+off, f"{lbl} {pr:.2f}", color=CLR_TEXT_DIM,
            fontsize=6.8, ha="center", family="monospace")

# --- BOS ---
def struct_marker(tm, pr, lbl, clr, dy, side="right"):
    x = mdates.date2num(tm)
    ax.annotate("", xy=(x, pr), xytext=(x, pr-dy),
                arrowprops=dict(arrowstyle="-|>", color=clr, lw=1.3,
                                mutation_scale=10), zorder=6)
    tx = x+0.004 if side == "right" else x-0.030
    ax.text(tx, pr+0.06, f"{lbl} {pr:.2f}", color=clr, fontsize=7, family="monospace",
            weight="bold", ha="left" if side == "right" else "right")
struct_marker(t(14,15), 2656.80, "BOS", CLR_BOS, 0.40)
struct_marker(t(15,45), 2656.30, "BOS", CLR_BOS, 0.40)

# --- liquidity sweep markers ---
x = mdates.date2num(t(13, 45))
ax.annotate("", xy=(x+0.005, 2660.55), xytext=(x+0.005, 2660.20),
            arrowprops=dict(arrowstyle="-|>", color=CLR_SWEEP, lw=1.6,
                            mutation_scale=12), zorder=7)
ax.text(x+0.013, 2660.62, "SWEEP EQH 2660.20", color=CLR_SWEEP,
        fontsize=6.8, family="monospace", va="center")
x = mdates.date2num(t(14, 15))
ax.annotate("", xy=(x-0.005, 2656.95), xytext=(x-0.005, 2657.60),
            arrowprops=dict(arrowstyle="-|>", color=CLR_SWEEP, lw=1.6,
                            mutation_scale=12), zorder=7)
ax.text(x-0.013, 2656.85, "SWEEP EQL 2657.60", color=CLR_SWEEP,
        fontsize=6.8, family="monospace", va="center", ha="right")

# --- entry arrow (SellLimit fill di tepi OB) ---
x = mdates.date2num(t(15, 0))
ax.annotate("", xy=(x, 2659.02), xytext=(x, 2659.38),
            arrowprops=dict(arrowstyle="-|>", color=CLR_READY, lw=1.6,
                            mutation_scale=12), zorder=7)
ax.text(x+0.004, 2657.10,
        "SELL ENTRY 0.20 @2659.00 (limit fill)\nSL 2661.00 | TP 2655.00 | RR 2.0",
        color=CLR_READY, fontsize=6.8, family="monospace", va="top",
        bbox=dict(boxstyle="round,pad=0.25", fc=BG, ec=CLR_READY, lw=0.6, alpha=0.75))

ax.text(mdates.date2num(t(15,45))+0.004, 2657.95, "TP1 50% ✓ → SL BE", color=CLR_POC,
        fontsize=6.8, family="monospace")

# --- news MEDIUM (oranye) ---
x0 = mdates.date2num(t(16, 30)); x1 = mdates.date2num(t(17, 30))
ax.axvspan(x0, x1, color=CLR_NEWS_MED, alpha=0.10, zorder=0)
ax.axvline(mdates.date2num(t(17, 0)), color=CLR_NEWS_MED, lw=1.1, ls=(0,(5,3)), zorder=5)
ax.text(mdates.date2num(t(17, 0))+0.004, 2662.3, "GBP BoE Gov Speaks (Medium) 17:00",
        color=CLR_NEWS_MED, fontsize=7, family="monospace")
ax.text(mdates.date2num(t(16, 30))+0.004, 2661.8, "jendela blokir entry [16:30–17:30]",
        color=CLR_NEWS_MED, fontsize=6.2, family="monospace", alpha=0.85)

# --- volume profile NY ---
bins = np.linspace(2654.0, 2662.5, 42)
c = (bins[:-1]+bins[1:])/2
vol = (430*np.exp(-((c-2658.00)**2)/(2*0.5**2)) +
       240*np.exp(-((c-2659.40)**2)/(2*0.18**2)) +
       np.random.default_rng(11).uniform(0, 12, len(c)))
poc_i = int(np.argmax(vol)); total = vol.sum(); acc = vol[poc_i]; lo_i = hi_i = poc_i
while acc < total*0.70 and (lo_i > 0 or hi_i < len(vol)-1):
    vlo = vol[lo_i-1] if lo_i > 0 else -1
    vhi = vol[hi_i+1] if hi_i < len(vol)-1 else -1
    if vhi >= vlo and hi_i < len(vol)-1:
        hi_i += 1; acc += vol[hi_i]
    elif lo_i > 0:
        lo_i -= 1; acc += vol[lo_i]
    else:
        break
xvp0 = mdates.date2num(t(17, 58)); xvp1 = mdates.date2num(t(18, 30))
vmax = vol.max()
for i, v in enumerate(vol):
    if v < 4: continue
    wd = (v/vmax) * (xvp1-xvp0)
    ax.add_patch(Rectangle((xvp1-wd, bins[i]), wd, bins[1]-bins[0],
                 facecolor=CLR_POC if i == poc_i else "#3A3F4C",
                 alpha=0.85 if i == poc_i else 0.55, edgecolor="none", zorder=4))
ax.plot([xvp0, xvp1], [c[poc_i], c[poc_i]], color=CLR_POC, lw=1.8, zorder=6)
ax.plot([xvp0, xvp1], [bins[hi_i+1], bins[hi_i+1]], color=CLR_VAH_VAL, lw=1.0, ls=(0,(4,2)), zorder=6)
ax.plot([xvp0, xvp1], [bins[lo_i], bins[lo_i]], color=CLR_VAH_VAL, lw=1.0, ls=(0,(4,2)), zorder=6)
ax.text(xvp1+0.001, c[poc_i], f"POC {c[poc_i]:.2f}", color=CLR_POC, fontsize=6.8, va="center", family="monospace", weight="bold")
ax.text(xvp1+0.001, bins[hi_i+1], f"VAH {bins[hi_i+1]:.2f}", color=CLR_VAH_VAL, fontsize=6.8, va="center", family="monospace")
ax.text(xvp1+0.001, bins[lo_i], f"VAL {bins[lo_i]:.2f}", color=CLR_VAH_VAL, fontsize=6.8, va="center", family="monospace")
ax.text(mdates.date2num(t(17, 58)), 2654.6, "VP sesi NY", color="#3A3F4C",
        fontsize=6.5, family="monospace")

ax.axhline(CUR_PRICE, color=CLR_TEXT, lw=0.6, ls=(0,(2,2)), alpha=0.5, zorder=5)
ax.text(mdates.date2num(t(16, 21))-0.003, CUR_PRICE+0.07, "2655.65", color=CLR_TEXT,
        fontsize=6.5, family="monospace", ha="right")

ax.set_xlim(mdates.date2num(t(0,0)), mdates.date2num(t(18,30)))
ax.set_ylim(2654.0, 2662.5)
ax.xaxis.set_major_locator(mdates.MinuteLocator(interval=120))
ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
ax.tick_params(colors=CLR_TEXT_DIM, labelsize=8, length=0)
for s in ax.spines.values(): s.set_color(GRID)
ax.grid(True, color=GRID, lw=0.5, alpha=0.8)
ax.set_axisbelow(True)

# --- dashboard ---
DASH = [
 ("ORB_SMC_NextGen v1.00 | XAUUSD M15", CLR_TEXT),
 ("─ SESI & RANGE ─", CLR_TEXT_DIM),
 ("Aktif: New York | sisa 04:38:30", CLR_NY),
 ("Asia   OR 2660.00/2657.70 (23.0p) Breakout Down", CLR_ASIA),
 ("London OR 2660.20/2658.65 (15.5p) Breakout Up", CLR_LONDON),
 ("New York OR 2659.80/2658.90 (9.0p) Breakout Down", CLR_BEAR),
 ("Candle 11:30", CLR_TEXT),
 ("─ STRUKTUR & SINYAL ─", CLR_TEXT_DIM),
 ("Bias HTF: Bearish | Lokal: Bearish", CLR_BEAR),
 ("State ASIA:Idle  LDN:Idle  NY:Traded", CLR_TEXT),
 ("Breakout New York DOWN | skor 82/100", CLR_BEAR),
 ("Zona OB [2659.00-2660.70]", CLR_TEXT),
 ("Sweep: Yes (EQL @2657.60)", CLR_SWEEP),
 ("RSI(14): 44.6 Neutral", CLR_TEXT),
 ("─ POSISI & RISIKO ─", CLR_TEXT_DIM),
 ("Pos: SELL 0.20 @2659.00", CLR_TEXT),
 ("  SL 2661.00 | TP 2655.00", CLR_TEXT_DIM),
 ("  P/L +67.00 (+0.67%)", CLR_BULL),
 ("Force-close NY: 04:08:30", CLR_TEXT),
 ("Hari ini: 1/3 trade | P/L +0.67%", CLR_BULL),
 ("─ NEWS ─", CLR_TEXT_DIM),
 ("Filter: ON [OK] upd 06:12 | USD", CLR_BULL),
 ("BLOKIR: GBP BoE Gov Speaks 17:00 (sisa 01:08:30)", CLR_NEWS_MED),
]
def draw_panel(axis, x, y_top, width, n, step, fs):
    h = n * step
    axis.add_patch(Rectangle((x, y_top-h), width, h+step*0.55, transform=axis.transAxes,
                   facecolor=CLR_PANEL_BG, alpha=0.90, edgecolor="#3C404A",
                   lw=0.8, zorder=50))
    for i, (txt, clr) in enumerate(DASH):
        axis.text(x+0.006, y_top-step/2-i*step, txt, transform=axis.transAxes,
                  color=clr, fontsize=fs, family="monospace", va="center",
                  ha="left", zorder=51)
draw_panel(ax, 0.008, 0.995, 0.30, 23, 0.0415, 7.0)

fig.text(0.055, 0.045,
         "Mock-up varian — skenario BEARISH (mode ENTRY_PENDING_ORDER): NY session, sweep EQH 2660.20 (grab candle) → "
         "OB bearish [2659.00–2660.70] → displacement down menembus OR low → sweep EQL 2657.60 → retest naik ke zona → "
         "SellLimit ter-fill di zone.bottom (2659.00) → TP1 hit, SL breakeven → news MEDIUM (oranye) memblokir entry baru.",
         color=CLR_TEXT_DIM, fontsize=7.5, family="monospace", wrap=True)
fig.text(0.055, 0.012,
         "Catatan: sell-side liquidity (EQL) wajib tersapu sejak OR terbentuk (gate ConfluenceValidator) — ditandai marker "
         "SWEEP magenta kedua. Warna OB bearish = CLR_OB_BEAR; SellLimit selalu di tepi zona yang tersentuh lebih dulu.",
         color="#6E7380", fontsize=7.5, family="monospace", wrap=True)
fig.savefig("docs/chart-preview-bearish.png", facecolor=fig.get_facecolor(), bbox_inches="tight")
plt.close(fig)

# =============================================================
# FIGURE 2 : PERBANDINGAN MODE ENTRY (schematic)
# =============================================================
fig2, (axL, axR) = plt.subplots(1, 2, figsize=(13.5, 5.6), dpi=170,
                                gridspec_kw={"wspace": 0.16})
fig2.patch.set_facecolor(BG)

def mini_candles(axis, bars, zone):
    for i, (o, hi, lo, c) in enumerate(bars):
        x = i
        clr = CLR_BULL if c >= o else CLR_BEAR
        axis.plot([x, x], [lo, min(o, c)], color=clr, lw=1.1, zorder=3)
        axis.plot([x, x], [max(o, c), hi], color=clr, lw=1.1, zorder=3)
        axis.add_patch(Rectangle((x-0.30, min(o, c)), 0.60, max(abs(c-o), 0.05),
                       facecolor=clr, edgecolor=clr, lw=0.5, zorder=4))
    zl, zh = zone
    axis.add_patch(Rectangle((-0.5, zl), len(bars)-0.5, zh-zl, facecolor=CLR_OB_BULL,
                   alpha=0.14, edgecolor=CLR_OB_BULL, lw=1.0, zorder=2))
    axis.text(-0.45, zh+0.03, f"{zh:.2f}", color=CLR_OB_BULL, fontsize=6.5, family="monospace", zorder=6)
    axis.text(-0.45, zl-0.11, f"{zl:.2f}", color=CLR_OB_BULL, fontsize=6.5, family="monospace", zorder=6)

for axis in (axL, axR):
    axis.set_facecolor(BG)
    axis.grid(True, color=GRID, lw=0.5, alpha=0.7)
    axis.set_axisbelow(True)
    for s in axis.spines.values(): s.set_color(GRID)
    axis.tick_params(colors=CLR_TEXT_DIM, labelsize=8, length=0)

# Panel kiri: PENDING_ORDER — BuyLimit di zone.top, fill saat harga menyentuh
bars_p = [(100.0, 101.0, 99.6, 100.7), (100.7, 101.2, 100.4, 101.1),
          (101.1, 101.4, 100.9, 101.2), (101.2, 101.3, 100.2, 100.4),
          (100.4, 100.5, 99.80, 99.85), (99.85, 100.1, 99.70, 100.0)]
zone_p = (99.80, 100.30)   # OB di bawah harga
mini_candles(axL, bars_p, zone_p)
axL.axhline(100.30, color=CLR_READY, lw=1.2, ls=(0,(6,3)), zorder=5)
axL.annotate("", xy=(4.4, 100.30), xytext=(3.6, 100.75),
             arrowprops=dict(arrowstyle="-|>", color=CLR_READY, lw=1.5, mutation_scale=12))
axL.text(5.06, 101.25, "BuyLimit @ zone.top (100.30)\nSL/TP dipasang SEKALIGUS\nfill otomatis saat harga\nmenyentuh level (MT5)",
         color=CLR_READY, fontsize=8.2, family="monospace", va="top",
         bbox=dict(boxstyle="round,pad=0.3", fc=BG, ec=CLR_READY, lw=0.7, alpha=0.8))
axL.annotate("", xy=(4.0, 100.28), xytext=(4.0, 100.10),
             arrowprops=dict(arrowstyle="-|>", color=CLR_POC, lw=1.3, mutation_scale=10))
axL.text(4.06, 100.12, "touch → ter-fill", color=CLR_POC, fontsize=7, family="monospace")
axL.set_title("ENTRY_PENDING_ORDER (default)", color=CLR_TEXT, fontsize=10,
              family="monospace", pad=10)
axL.set_xlim(-0.8, 6.2); axL.set_ylim(99.4, 101.6)
axL.set_xticks([]); axL.set_yticks([])
axL.text(-0.45, 99.52, "bar breakout →\nlimit langsung\nterpasang", color=CLR_TEXT_DIM,
         fontsize=7, family="monospace")

# Panel kanan: EXECUTION — tunggu candle reaksi (wick rejection) → market di close
bars_e = [(100.0, 101.0, 99.6, 100.7), (100.7, 101.2, 100.4, 101.1),
          (101.1, 101.4, 100.9, 101.2), (101.2, 101.3, 100.2, 100.4),
          (100.4, 100.5, 99.80, 99.85), (99.85, 100.1, 99.70, 100.0),
          (100.0, 100.6, 99.95, 100.5)]
zone_e = (99.80, 100.30)
mini_candles(axR, bars_e, zone_e)
axR.annotate("", xy=(5.0, 100.05), xytext=(5.0, 99.80),
             arrowprops=dict(arrowstyle="-|>", color=CLR_SWEEP, lw=1.3, mutation_scale=9))
axR.text(5.06, 99.72, "wick touch\n(rejection)", color=CLR_SWEEP, fontsize=6.8,
         family="monospace", va="top")
axR.annotate("", xy=(6.0, 100.5), xytext=(5.55, 100.5),
             arrowprops=dict(arrowstyle="-|>", color=CLR_READY, lw=1.5, mutation_scale=12))
axR.text(6.06, 101.25, "Market BUY @ close\ncandle reaksi (100.50)\n\nsyarat: sentuh zona + close\nkembali searah breakout\n(wick rejection)",
         color=CLR_READY, fontsize=8.2, family="monospace", va="top",
         bbox=dict(boxstyle="round,pad=0.3", fc=BG, ec=CLR_READY, lw=0.7, alpha=0.8))
axR.set_title("ENTRY_EXECUTION (market setelah reaksi)", color=CLR_TEXT, fontsize=10,
              family="monospace", pad=10)
axR.set_xlim(-0.8, 8.4); axR.set_ylim(99.4, 101.6)
axR.set_xticks([]); axR.set_yticks([])
axR.text(-0.45, 99.52, "tunggu candle retest\nCLOSE dulu → bar\nberikutnya market order", color=CLR_TEXT_DIM,
         fontsize=7, family="monospace")

fig2.text(0.5, 0.015,
          "Perbandingan mode entry (schematic, bukan skala sesi nyata). Kiri: limit terpasang begitu breakout lolos "
          "confluence — eksekusi oleh MT5 saat harga menyentuh level, expiry berbasis bar (InpRetestMaxBars). "
          "Kanan: EA menunggu reaksi retest di CLOSED bar, lalu kirim market order — lebih selektif, entry 1 bar lebih lambat.",
          color=CLR_TEXT_DIM, fontsize=7.5, family="monospace", ha="center", wrap=True)
fig2.savefig("docs/entry-modes-preview.png", facecolor=fig2.get_facecolor(), bbox_inches="tight")
plt.close(fig2)

print("OK: docs/chart-preview-bearish.png + docs/entry-modes-preview.png")
