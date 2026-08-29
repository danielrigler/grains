local M = {}

M.RAW = 128
M.NMAX = 6

local floor, exp, abs, log, sqrt = math.floor, math.exp, math.abs, math.log, math.sqrt

local clamp = include("grains/lib/util").clamp

local TOP = 0
local ROW2 = 32

local LAYOUTS = {
  {w = 128, h = 62, cx = {0},                    cy = {TOP}},
  {w = 62,  h = 62, cx = {0, 65},                cy = {TOP, TOP}},
  {w = 62,  h = 30, cx = {0, 65, 0},             cy = {TOP, TOP, ROW2}},
  {w = 62,  h = 30, cx = {0, 65, 0, 65},         cy = {TOP, TOP, ROW2, ROW2}},
  {w = 40,  h = 30, cx = {0, 43, 86, 0, 43},     cy = {TOP, TOP, TOP, ROW2, ROW2}},
  {w = 40,  h = 30, cx = {0, 43, 86, 0, 43, 86}, cy = {TOP, TOP, TOP, ROW2, ROW2, ROW2}}
}

local CW, CH, WH
local CX, CY
local WALL_TOP, WALL_BOT, WALL_ROWS
local WAVE_DY
local PITCH_CENTER_DY, PITCH_HALF_ROWS
local RAILS
local NCELL = -1
local WALL = 15
local BASE = 1
local SEL_LIFT = 5
local FAINT_LEVEL = 3
local OVERLAP_STEP = 2
local END_LVL = 13
local CAP_HALF_MAX = 2
local LMAX = 16

local function ramp(nl, lo, hi, base)
  local step = OVERLAP_STEP
  if nl > 1 and (hi - lo) / (nl - 1) < step then step = (hi - lo) / (nl - 1) end
  local t = {[0] = base}
  for c = 1, LMAX do
    local lv = floor(lo + step * ((c > nl and nl or c) - 1) + 0.5)
    t[c] = lv > WALL and WALL or lv
  end
  return t
end

local FULL_CELLS = 1
local LVLS_DIM, LVLS_SEL, LVLS_FULL = {}, {}, {}
for nl = 1, LMAX do
  LVLS_DIM[nl]  = ramp(nl, FAINT_LEVEL, WALL - SEL_LIFT, BASE)
  LVLS_SEL[nl]  = ramp(nl, FAINT_LEVEL + SEL_LIFT, WALL, BASE + SEL_LIFT)
  LVLS_FULL[nl] = ramp(nl, FAINT_LEVEL, WALL, BASE)
end

local function tanh(z) local e = exp(2 * z) return (e - 1) / (e + 1) end

local TILT_P, TILT_W = 0.53, 0.30
local TILT_CURVE = {}
local TILT_CURVE_MAX, TILT_CURVE_MIN = -math.huge, math.huge
for c = 0, 127 do
  local v = tanh((c / 127 - TILT_P) / TILT_W)
  TILT_CURVE[c] = v
  if v > TILT_CURVE_MAX then TILT_CURVE_MAX = v end
  if v < TILT_CURVE_MIN then TILT_CURVE_MIN = v end
end
local CURVE_TOP, CURVE_BOT = 0, 58
local TILT_AMP = (CURVE_BOT - CURVE_TOP) / (TILT_CURVE_MAX - TILT_CURVE_MIN)
local TILT_CY = CURVE_TOP + (TILT_CURVE_MAX * TILT_AMP)

local FILT_AMP = CURVE_BOT - CURVE_TOP
local FILT_LOGN = 1 / log(1000)
local FILT_K = 0.35
local FILT_Q_LO, FILT_Q_HI, FILT_Q_EXP = 0.707, 4, 1.3
local FILT_IQ_HI = 1 / (FILT_Q_HI * FILT_Q_HI)
local FILT_FMAX = 1 / (1 + FILT_K * sqrt(FILT_IQ_HI * (1 - 0.25 * FILT_IQ_HI)))
local FILT_OCT = {}
for d = -127, 127 do FILT_OCT[d] = exp(2 * log(1000) / 127 * d) end

local cover, cdif = {}, {}
local lc0, lc1, lcok = {}, {}, {}
local COV, KC0, KC1, KOK, KNL = {}, {}, {}, {}, {}
for v = 1, M.NMAX do
  COV[v], KC0[v], KC1[v], KOK[v], KNL[v] = {}, {}, {}, {}, -1
end
local LVL = LVLS_FULL[1]
local TL, BL = {}, {}

local s_level, s_rect, s_fill
local xfp, xfw, xfx, xfy
local s_wf, s_on, s_loaded, s_nl, s_ls, s_le, s_pos
local s_b0, s_b1, s_volf, s_pitchf, s_frz, s_lck
local s_sel, s_blink
local lastlevel = -1
local pending = false

function M.set_count(n)
  n = clamp(floor(n or 0), 0, M.NMAX)
  if n == NCELL then return false end
  NCELL = n
  local L = LAYOUTS[n < 1 and 1 or n]
  CW, CH, CX, CY = L.w, L.h, L.cx, L.cy
  WALL_TOP, WALL_BOT = 0, CH - 4
  WALL_ROWS = WALL_BOT - WALL_TOP + 1
  WAVE_DY = floor((WALL_TOP + WALL_BOT) / 2)
  WH = WAVE_DY - 1
  PITCH_CENTER_DY = WAVE_DY
  PITCH_HALF_ROWS = PITCH_CENTER_DY - WALL_TOP
  local down = WALL_BOT - PITCH_CENTER_DY
  if down < PITCH_HALF_ROWS then PITCH_HALF_ROWS = down end
  RAILS = {}
  for i = 0, CW - 1 do cover[i] = 0 end
  for v = 1, M.NMAX do KNL[v] = -1 end
  M.CW, M.CH = CW, CH
  return true
end

local function rails(nl)
  local t = RAILS[nl]
  if t then return t end
  t = {}
  local span = WALL_BOT - WALL_TOP - 6
  if nl < 2 then
    t[1] = WALL_TOP + floor((WALL_BOT - WALL_TOP) / 2)
  elseif nl == 2 then
    t[1] = clamp(WALL_TOP + 2 + floor(span / 3 + 0.5), WALL_TOP + 2, WALL_BOT - 2)
    t[2] = clamp(WALL_TOP + 4 + floor(span * 2 / 3 + 0.5), WALL_TOP + 2, WALL_BOT - 2)
  else
    for L = 1, nl do
      t[L] = WALL_TOP + 3 + floor((L - 1) * span / (nl - 1) + 0.5)
    end
  end
  local gap = 99
  for L = 2, nl do
    local d = t[L] - t[L - 1]
    if d < gap then gap = d end
  end
  t.half = clamp(floor((gap - 2) / 2), 1, CAP_HALF_MAX)
  RAILS[nl] = t
  return t
end

function M.wave(raw)
  if raw == nil then return nil end
  local out = {}
  local step = M.RAW / CW
  for c = 0, CW - 1 do
    local a = floor(c * step)
    local b = floor((c + 1) * step) - 1
    if b < a then b = a end
    local mx = 0
    for k = a, b do
      local v = raw[k]
      if v and v > mx then mx = v end
    end
    out[c] = floor(mx * WH + 0.5)
  end
  return out
end

local function R(l, x, y, w, h)
  if w <= 0 or h <= 0 or l < 1 then return end
  if l ~= lastlevel then
    if pending then s_fill() pending = false end
    s_level(l) lastlevel = l
  end
  s_rect(x, y, w, h)
  pending = true
end

local function Rflush()
  if pending then s_fill() pending = false end
end

local function wall_cols(v)
  local w0 = floor((s_b0[v] or 0) * CW + 0.5)
  local w1 = floor((s_b1[v] or 1) * CW + 0.5) - 1
  if w0 < 0 then w0 = 0 elseif w0 > CW - 2 then w0 = CW - 2 end
  if w1 < w0 + 1 then w1 = w0 + 1 elseif w1 > CW - 1 then w1 = CW - 1 end
  return w0, w1
end

local function draw_wave(w, xo, yc, i0, i1, ytop, ybot, a0)
  local lvl, cov = LVL, cover
  local rx, rlv, rh = i0, -1, -1
  for i = i0, i1 do
    local lv, h = lvl[cov[i]], w[i]
    if lv ~= rlv or h ~= rh then
      if rh >= 0 then
        local a, b = yc - rh + a0, yc + rh
        if a < ytop then a = ytop end
        if b > ybot then b = ybot end
        if b >= a then R(rlv, xo + rx, a, i - rx, b - a + 1) end
      end
      rx, rlv, rh = i, lv, h
    end
  end
  if rh >= 0 then
    local a, b = yc - rh + a0, yc + rh
    if a < ytop then a = ytop end
    if b > ybot then b = ybot end
    if b >= a then R(rlv, xo + rx, a, i1 + 1 - rx, b - a + 1) end
  end
end

local function draw_slide(w, x, y0, ym, dx, dy, nl)
  local sx = floor(dx + 0.5)
  local i0, i1 = -sx, CW - 1 - sx
  if i0 < 0 then i0 = 0 end
  if i1 > CW - 1 then i1 = CW - 1 end
  if i1 < i0 then return end
  local iy = floor(dy)
  local fr = dy - iy
  local ytop, ybot = y0 + WALL_TOP, y0 + WALL_BOT
  local yc = ym + iy
  if yc - WH > ybot or yc + WH < ytop then return end
  local xo = x + sx
  local sub = fr > 0.02
  local anyt, anyb = false, false
  if sub then
    local g = 1 - fr
    for c = 0, nl do
      local lv = LVL[c]
      local t, b = floor(lv * g + 0.5), floor(lv * fr + 0.5)
      TL[c], BL[c] = t, b
      if t > 0 then anyt = true end
      if b > 0 then anyb = true end
    end
  end
  draw_wave(w, xo, yc, i0, i1, ytop, ybot, sub and 1 or 0)
  if anyt then
    for i = i0, i1 do
      local a = yc - w[i]
      if a >= ytop and a <= ybot then R(TL[cover[i]], xo + i, a, 1, 1) end
    end
  end
  if anyb then
    for i = i0, i1 do
      local b = yc + 1 + w[i]
      if b >= ytop and b <= ybot then R(BL[cover[i]], xo + i, b, 1, 1) end
    end
  end
end

local function draw_cell(v)
  local x, y0 = CX[v], CY[v]
  local ym = y0 + WAVE_DY
  local wf = s_wf[v]
  local ph = xfp[v]
  local is_loaded = s_loaded[v]
  if ph == nil and not (is_loaded and wf) then return end
  local live = s_on[v]
  local nl = live and (s_nl[v] or 1) or 0
  if nl > LMAX then nl = LMAX end
  local ls, le = s_ls[v], s_le[v]
  local cache = COV[v]
  cover = cache
  if nl > 0 then
    local k0, k1, kok = KC0[v], KC1[v], KOK[v]
    local same = KNL[v] == nl
    for L = 1, nl do
      local a = ls[L]
      local c0, c1, ok
      if a then
        c0 = floor(a * CW)
        if c0 < 0 then c0 = 0 elseif c0 > CW - 1 then c0 = CW - 1 end
        c1 = floor(le[L] * CW + 0.999) - 1
        if c1 < c0 then c1 = c0 elseif c1 > CW - 1 then c1 = CW - 1 end
        ok = true
      else
        c0, c1, ok = 0, 0, false
      end
      lc0[L], lc1[L], lcok[L] = c0, c1, ok
      if same and (k0[L] ~= c0 or k1[L] ~= c1 or kok[L] ~= ok) then same = false end
    end
    if not same then
      for i = 0, CW do cdif[i] = 0 end
      for L = 1, nl do
        if lcok[L] then
          local c0, c1 = lc0[L], lc1[L]
          cdif[c0] = cdif[c0] + 1
          cdif[c1 + 1] = cdif[c1 + 1] - 1
        end
        k0[L], k1[L], kok[L] = lc0[L], lc1[L], lcok[L]
      end
      local run = 0
      for i = 0, CW - 1 do
        run = run + cdif[i]
        cache[i] = run
      end
      KNL[v] = nl
    end
  elseif KNL[v] ~= 0 then
    for i = 0, CW - 1 do cache[i] = 0 end
    KNL[v] = 0
  end

  local is_sel = s_sel == v
  local frz_v = s_frz and s_frz[v]
  local lck = s_lck and s_lck[v]
  local lvn = nl > 0 and nl or 1
  if NCELL <= FULL_CELLS then
    LVL = LVLS_FULL[lvn]
  elseif is_sel then
    LVL = LVLS_SEL[lvn]
  else
    LVL = LVLS_DIM[lvn]
  end

  if ph then
    local w = xfw[v]
    if w then draw_slide(w, x, y0, ym, xfx[v], xfy[v], nl) end
  else
    draw_wave(wf, x, ym, 0, CW - 1, y0 + WALL_TOP, y0 + WALL_BOT, 0)
    if live and nl > 0 then
      local pos = s_pos[v]
      local rd = rails(nl)
      local rail_level = is_sel and 15 or 9
      for L = 1, nl do
        R(rail_level, x + lc0[L], y0 + rd[L], lc1[L] - lc0[L] + 1, 1)
      end
      local half = rd.half
      local caph = half * 2 + 1
      if not frz_v or s_blink then
        for L = 1, nl do
          local ry = y0 + rd[L]
          local e0, e1 = x + lc0[L], x + lc1[L]
          R(END_LVL, e0, ry - half, 1, caph)
          R(END_LVL, e1, ry - half, 1, caph)
          if frz_v and e1 - e0 >= 2 then
            R(END_LVL, e0 + 1, ry - half, 1, 1)
            R(END_LVL, e0 + 1, ry + half, 1, 1)
            R(END_LVL, e1 - 1, ry - half, 1, 1)
            R(END_LVL, e1 - 1, ry + half, 1, 1)
          end
        end
      end
      for L = 1, nl do
        local p = pos[L]
        if p then
          local pc = floor(p * CW)
          local a, b = lc0[L], lc1[L]
          if pc < a then pc = a elseif pc > b then pc = b end
          R(15, x + pc, y0 + rd[L] - half, 1, caph)
        end
      end
    end
  end

  if live and is_loaded then
    local w0, w1 = wall_cols(v)
    local xw0, xw1 = x + w0, x + w1
    local ytop, ybot = y0 + WALL_TOP, y0 + WALL_BOT
    local wall_level = is_sel and WALL or 7
    local lvl_hi = is_sel and WALL or 9

    for yy = ytop, ybot, 2 do
      R(wall_level, xw0, yy, 1, 1)
      R(wall_level, xw1, yy, 1, 1)
    end

    if lck then
      local span = w1 - w0
      local hl = span < 5 and (floor(span / 2) + 1) or 3
      local vl = ybot - ytop
      vl = vl < 5 and (floor(vl / 2) + 1) or 3
      local xhl = xw1 - hl + 1
      R(wall_level, xw0, ytop, hl, 1)
      R(wall_level, xhl, ytop, hl, 1)
      R(wall_level, xw0, ybot, hl, 1)
      R(wall_level, xhl, ybot, hl, 1)
      R(wall_level, xw0, ytop, 1, vl)
      R(wall_level, xw1, ytop, 1, vl)
      R(wall_level, xw0, ybot - vl + 1, 1, vl)
      R(wall_level, xw1, ybot - vl + 1, 1, vl)
    end

    local hvol = floor((s_volf[v] or 0) * WALL_ROWS + 0.5)
    if hvol > 0 then
      R(lvl_hi, xw0, y0 + WALL_BOT - hvol + 1, 1, hvol)
    end

    local ycenter = y0 + PITCH_CENTER_DY
    R(wall_level, xw1, ycenter, 1, 1)
    local pf = clamp((s_pitchf and s_pitchf[v]) or 0, -1, 1)
    local hpit = floor(abs(pf) * PITCH_HALF_ROWS + 0.5)
    if hpit > 0 then
      if pf > 0 then
        R(lvl_hi, xw1, ycenter - hpit, 1, hpit + 1)
      else
        R(lvl_hi, xw1, ycenter, 1, hpit + 1)
      end
    end
  end
end

function M.draw(S)
  s_level, s_rect, s_fill = screen.level, screen.rect, screen.fill
  xfp, xfw, xfx, xfy = S.xfp, S.xfw, S.xfx, S.xfy
  s_wf, s_on, s_loaded, s_nl = S.wf, S.on, S.loaded, S.nl
  s_ls, s_le, s_pos = S.ls, S.le, S.pos
  s_b0, s_b1, s_volf, s_pitchf = S.b0, S.b1, S.volf, S.pitchf
  s_frz, s_lck, s_sel, s_blink = S.frz, S.lck, S.sel, S.blink
  lastlevel = -1
  pending = false
  for v = 1, NCELL do draw_cell(v) end
  Rflush()
end

local BAR_Y = 62

local function P(l, x, y) R(l, x, y, 1, 1) end

function M.icons(drawfn)
  s_level, s_rect, s_fill = screen.level, screen.rect, screen.fill
  lastlevel = -1
  pending = false
  drawfn(P)
  Rflush()
end

function M.volbar(frac)
  local w = floor(frac * 128 + 0.5)
  if w <= 0 then return end
  Rflush()
  screen.level(15)
  screen.rect(0, BAR_Y, w, 1)
  screen.fill()
  lastlevel = -1
end

local THUMB_W = 7
function M.morphbar(frac)
  Rflush()
  screen.level(1)
  screen.rect(0, BAR_Y, 128, 1)
  screen.fill()
  screen.level(15)
  screen.rect(floor(frac * (128 - THUMB_W) + 0.5), BAR_Y, THUMB_W, 1)
  screen.fill()
  lastlevel = -1
end

function M.notice(l1, l2)
  Rflush()
  screen.level(15)
  screen.move(64, 28)
  screen.text_center(l1)
  if l2 then
    screen.level(3)
    screen.move(64, 40)
    screen.text_center(l2)
  end
  lastlevel = -1
end

function M.fxpopup(txt)
  local w = #txt * 5 + 8
  Rflush()
  screen.level(1)
  screen.rect(64 - floor(w * 0.5), 26, w, 10)
  screen.fill()
  screen.level(15)
  screen.move(64, 34)
  screen.text_center(txt)
  lastlevel = -1
end

local REC_W, REC_H, REC_Y = 92, 27, 20

function M.recpopup(title, sub, frac, note)
  local x = 64 - floor(REC_W / 2)
  local bw = REC_W - 10
  local plain = not (sub or note or frac)
  local h = plain and 16 or REC_H
  Rflush()
  screen.level(0)
  screen.rect(x, REC_Y, REC_W, h)
  screen.fill()
  screen.level(4)
  screen.line_width(1)
  screen.rect(x + 0.5, REC_Y + 0.5, REC_W - 1, h - 1)
  screen.stroke()
  screen.level(15)
  if plain then
    screen.move(64, REC_Y + 11)
    screen.text_center(title)
  else
    screen.move(x + 5, REC_Y + 11)
    screen.text(title)
  end
  if sub then
    screen.level(6)
    screen.move(x + REC_W - 5, REC_Y + 11)
    screen.text_right(sub)
  end
  if note then
    screen.level(5)
    screen.move(x + 5, REC_Y + 21)
    screen.text(note)
  elseif type(frac) == "table" then
    for k = 1, 2 do
      local y = REC_Y + 12 + k * 4
      local fw = floor(clamp(frac[k] or 0, 0, 1) * bw + 0.5)
      screen.level(2)
      screen.rect(x + 5, y, bw, 3)
      screen.fill()
      if fw > 0 then
        screen.level(15)
        screen.rect(x + 5, y, fw, 3)
        screen.fill()
      end
    end
  elseif frac then
    local fw = floor(clamp(frac, 0, 1) * bw + 0.5)
    screen.level(2)
    screen.rect(x + 5, REC_Y + 16, bw, 4)
    screen.fill()
    if fw > 0 then
      screen.level(15)
      screen.rect(x + 5, REC_Y + 16, fw, 4)
      screen.fill()
    end
  end
  lastlevel = -1
end

local function stroke_curve(b)
  Rflush()
  screen.level(15)
  screen.line_width(1)
  screen.move(0, b[0])
  for c = 1, 127 do screen.line(c, b[c]) end
  screen.stroke()
  lastlevel = -1
end

local tbuf, tkey = {}, 1e9

function M.tilteq(t)
  if tkey ~= t then
    tkey = t
    for c = 0, 127 do
      local dy = clamp(t * TILT_CURVE[c] * TILT_AMP, -TILT_AMP, TILT_AMP)
      tbuf[c] = clamp(floor(TILT_CY - dy + 0.5), 0, 63)
    end
  end
  stroke_curve(tbuf)
end

local FILT_IQ_LO = 1 / (FILT_Q_LO * FILT_Q_LO)

local function knee_of(cut)
  return floor(clamp(log(cut / 20) * FILT_LOGN, 0, 1) * 127 + 0.5)
end

local function fill_filter(buf, knee, iq, up)
  for c = 0, 127 do
    local r2 = FILT_OCT[up * (c - knee)]
    local m = 1 - r2
    local f = 1 / (1 + FILT_K * sqrt(m * m + r2 * iq)) / FILT_FMAX
    if f > 1 then f = 1 end
    buf[c] = CURVE_BOT - floor(f * FILT_AMP + 0.5)
  end
end

local fbuf, fkey_c, fkey_r = {}, -1, -1

function M.filter(cut, res)
  if fkey_c ~= cut or fkey_r ~= res then
    fkey_c, fkey_r = cut, res
    local q = FILT_Q_LO + clamp(res, 0, 1) ^ FILT_Q_EXP * (FILT_Q_HI - FILT_Q_LO)
    fill_filter(fbuf, knee_of(cut), 1 / (q * q), 1)
  end
  stroke_curve(fbuf)
end

local hbuf, hkey = {}, -1

function M.hpf(cut)
  if hkey ~= cut then
    hkey = cut
    fill_filter(hbuf, knee_of(cut), FILT_IQ_LO, -1)
  end
  stroke_curve(hbuf)
end

M.set_count(6)

return M
