local M = {RAW = 128, NMAX = 6}

local floor, exp, abs, log, sqrt, min, max = math.floor, math.exp, math.abs, math.log, math.sqrt, math.min, math.max
local function clamp(x, lo, hi) return x < lo and lo or x > hi and hi or x end

local LAYOUTS = {
  {128, 62, {0}, {0}},
  {62, 62, {0, 65}, {0, 0}},
  {62, 30, {0, 65, 0}, {0, 0, 32}},
  {62, 30, {0, 65, 0, 65}, {0, 0, 32, 32}},
  {40, 30, {0, 43, 86, 0, 43}, {0, 0, 0, 32, 32}},
  {40, 30, {0, 43, 86, 0, 43, 86}, {0, 0, 0, 32, 32, 32}}
}

local WALL, LIFT, FAINT, ENDL, ARM, LMAX = 15, 5, 3, 13, 3, 16
local CW, CH, CX, CY, BOT, ROWS, WDY, WH, IH, PHALF
local NCELL, GEN, RAILS = -1, 0, {}

local function ramp(nl, lo, hi, base)
  local step = 2
  if nl > 1 and (hi - lo) / (nl - 1) < step then step = (hi - lo) / (nl - 1) end
  local t = {[0] = base}
  for c = 1, LMAX do t[c] = min(floor(lo + step * (min(c, nl) - 1) + 0.5), WALL) end
  return t
end

local DIM, SEL, FULL = {}, {}, {}
for nl = 1, LMAX do
  DIM[nl] = ramp(nl, FAINT, WALL - LIFT, 1)
  SEL[nl] = ramp(nl, FAINT + LIFT, WALL, 1 + LIFT)
  FULL[nl] = ramp(nl, FAINT, WALL, 1)
end

local s_level, s_rect, s_fill, s_img, s_draw
local IMG, DOT, ICON, icon_ver, icon_x = false, {}, nil, -1, 0
local Q, QN = {}, {}
for l = 1, 15 do Q[l], QN[l] = {}, 0 end

local function R(l, x, y, w, h)
  if w <= 0 or h <= 0 or l < 1 then return end
  local n, q = QN[l], Q[l]
  q[n + 1], q[n + 2], q[n + 3], q[n + 4] = x, y, w, h
  QN[l] = n + 4
end

local function flush()
  for l = 1, 15 do
    local n = QN[l]
    if n > 0 then
      local q = Q[l]
      s_level(l)
      for k = 1, n, 4 do s_rect(q[k], q[k + 1], q[k + 2], q[k + 3]) end
      s_fill()
      QN[l] = 0
    end
  end
end

function M.bind()
  s_level, s_rect, s_fill = screen.level, screen.rect, screen.fill
  s_img, s_draw = screen.display_image_region, screen.draw_to
  IMG = pcall(function()
    for _, l in ipairs({WALL, 7}) do
      local im = assert(screen.create_image(1, 64))
      s_draw(im, function()
        s_level(l)
        for y = 0, 63, 2 do s_rect(0, y, 1, 1) end
        s_fill()
      end)
      DOT[l] = im
    end
  end) and s_img ~= nil
end

function M.set_count(n)
  n = clamp(floor(n or 0), 0, M.NMAX)
  if n == NCELL then return false end
  local L = LAYOUTS[max(n, 1)]
  NCELL, GEN, RAILS = n, GEN + 1, {}
  CW, CH, CX, CY = L[1], L[2], L[3], L[4]
  BOT = CH - 4
  ROWS, WDY = BOT + 1, floor(BOT / 2)
  WH, PHALF = WDY - 1, min(WDY, BOT - WDY)
  IH = WH * 2 + 1
  M.CW, M.CH, M.WALL_ROWS = CW, CH, ROWS
  return true
end

local function wave(raw)
  local out, step = {}, M.RAW / CW
  for c = 0, CW - 1 do
    local a = floor(c * step)
    local mx = 0
    for k = a, max(floor((c + 1) * step) - 1, a) do mx = max(mx, raw[k] or 0) end
    out[c] = floor(mx * WH + 0.5)
  end
  return out
end

local function wimg(v, l)
  local im = v.img[l]
  if im then return im end
  im = screen.create_image(CW, IH)
  local w = v.wf
  s_draw(im, function()
    s_level(l)
    local c = 0
    while c < CW do
      local h, e = w[c], c
      while e + 1 < CW and w[e + 1] == h do e = e + 1 end
      s_rect(c, WH - h, e - c + 1, h * 2 + 1)
      c = e + 1
    end
    s_fill()
  end)
  v.img[l] = im
  return im
end

local function rails(nl)
  local t = RAILS[nl]
  if t then return t end
  t = {}
  local span = BOT - 6
  if nl < 2 then
    t[1] = floor(BOT / 2)
  elseif nl == 2 then
    t[1], t[2] = clamp(2 + floor(span / 3 + 0.5), 2, BOT - 2), clamp(4 + floor(span * 2 / 3 + 0.5), 2, BOT - 2)
  else
    for L = 1, nl do t[L] = 3 + floor((L - 1) * span / (nl - 1) + 0.5) end
  end
  local gap = 99
  for L = 2, nl do gap = min(gap, t[L] - t[L - 1]) end
  t.half = clamp(floor((gap - 2) / 2), 1, 2)
  RAILS[nl] = t
  return t
end

local cov, K0, K1, RUNS, RN, KEY = {}, {}, {}, {}, {}, {}
for i = 1, M.NMAX do K0[i], K1[i], RUNS[i], RN[i], KEY[i] = {}, {}, {}, 0, {} end

local function prep(v, i, nl, lvl)
  local k0, k1, ls, le, key, top = K0[i], K1[i], v.ls, v.le, KEY[i], CW - 1
  local same = key.nl == nl and key.lvl == lvl and key.gen == GEN
  for L = 1, nl do
    local c0 = floor(ls[L] * CW)
    c0 = c0 < 0 and 0 or c0 > top and top or c0
    local c1 = floor(le[L] * CW + 0.999) - 1
    c1 = c1 < c0 and c0 or c1 > top and top or c1
    if same and (k0[L] ~= c0 or k1[L] ~= c1) then same = false end
    k0[L], k1[L] = c0, c1
  end
  if same then return end
  key.nl, key.lvl, key.gen = nl, lvl, GEN
  for c = 0, CW do cov[c] = 0 end
  for L = 1, nl do
    local a, b = k0[L], k1[L] + 1
    cov[a], cov[b] = cov[a] + 1, cov[b] - 1
  end
  local rr, m, run, pl = RUNS[i], 0, 0, -1
  for c = 0, top do
    run = run + cov[c]
    local l = lvl[run]
    if l == pl then rr[m - 1] = c else rr[m + 1], rr[m + 2], rr[m + 3], m, pl = c, c, l, m + 3, l end
  end
  RN[i] = m
end

local function cell_wave(v, i)
  local x, y, sx, sy = CX[i], CY[i], 0, 0
  if v.xf then sx, sy = floor(v.xx + 0.5), floor(v.xy + 0.5) end
  local top = y + WDY - WH + sy
  local r0, r1 = max(0, y - top), min(IH - 1, y + BOT - top)
  if r1 < r0 then return end
  local i0, i1, rr, h, w = max(0, -sx), min(CW - 1, CW - 1 - sx), RUNS[i], r1 - r0 + 1, v.wf
  for k = 1, RN[i], 3 do
    local a, b, l = max(rr[k], i0), min(rr[k + 1], i1), rr[k + 2]
    if a <= b then
      if IMG then
        s_img(wimg(v, l), a, r0, b - a + 1, h, x + sx + a, top + r0)
      else
        for c = a, b do
          local ya, yb = max(WH - w[c], r0), min(WH + w[c], r1)
          R(l, x + sx + c, top + ya, 1, yb - ya + 1)
        end
      end
    end
  end
end

local function cell_over(v, i, nl, sel, blink)
  local x, y = CX[i], CY[i]
  if nl > 0 and not v.xf then
    local k0, k1, pos, rd = K0[i], K1[i], v.pos, rails(nl)
    local half = rd.half
    local ch, rl, frz = half * 2 + 1, sel and 15 or 9, v.frz
    local caps = not frz or blink
    for L = 1, nl do
      local ry, a, b = y + rd[L], k0[L], k1[L]
      local xa, xb = x + a, x + b
      if caps then
        R(rl, xa + 1, ry, b - a - 1, 1)
        R(ENDL, xa, ry - half, 1, ch)
        R(ENDL, xb, ry - half, 1, ch)
        if frz and b - a >= 2 then
          R(ENDL, xa + 1, ry - half, 1, 1) R(ENDL, xa + 1, ry + half, 1, 1)
          R(ENDL, xb - 1, ry - half, 1, 1) R(ENDL, xb - 1, ry + half, 1, 1)
        end
      else
        R(rl, xa, ry, b - a + 1, 1)
      end
      local p = pos[L]
      if p then
        local c = floor(p * CW)
        R(15, x + (c < a and a or c > b and b or c), ry - half, 1, ch)
      end
    end
  end
  if v.lck then
    local wl, x1, yb = sel and WALL or 7, x + CW - 1, y + BOT
    R(wl, x, y, ARM, 1) R(wl, x1 - ARM + 1, y, ARM, 1) R(wl, x, yb, ARM, 1) R(wl, x1 - ARM + 1, yb, ARM, 1)
    R(wl, x, y, 1, ARM) R(wl, x1, y, 1, ARM) R(wl, x, yb - ARM + 1, 1, ARM) R(wl, x1, yb - ARM + 1, 1, ARM)
  end
end

local function cell_walls(v, i, sel)
  local x, y = CX[i], CY[i]
  local wl, hi = sel and WALL or 7, sel and WALL or 9
  local w0 = clamp(floor(v.b0 * CW + 0.5), 0, CW - 2)
  local w1 = clamp(floor(v.b1 * CW + 0.5) - 1, w0 + 1, CW - 1)
  local xa, xb = x + w0, x + w1
  if IMG then
    s_img(DOT[wl], 0, 0, 1, ROWS, xa, y)
    s_img(DOT[wl], 0, 0, 1, ROWS, xb, y)
  else
    for yy = y, y + BOT, 2 do R(wl, xa, yy, 1, 1) R(wl, xb, yy, 1, 1) end
  end
  local hv = floor((v.volf or 0) * ROWS + 0.5)
  R(hi, xa, y + BOT - hv + 1, 1, hv)
  local yc = y + WDY
  R(wl, xb, yc, 1, 1)
  local pf = clamp(v.pitchf or 0, -1, 1)
  local hp = floor(abs(pf) * PHALF + 0.5)
  if hp > 0 then R(hi, xb, pf > 0 and yc - hp or yc, 1, hp + 1) end
end

function M.draw(V, sel, blink)
  local full = NCELL <= 1
  for i = 1, NCELL do
    local v = V[i]
    if v.raw then
      if v.wgen ~= GEN then v.wgen, v.wf, v.img = GEN, wave(v.raw), {} end
      local nl = v.on and min(v.nl, LMAX) or 0
      local lv = max(nl, 1)
      prep(v, i, nl, full and FULL[lv] or sel == i and SEL[lv] or DIM[lv])
      cell_wave(v, i)
    end
  end
  if not IMG then flush() end
  for i = 1, NCELL do
    local v = V[i]
    if v.raw then cell_over(v, i, v.on and min(v.nl, LMAX) or 0, sel == i, blink) end
  end
  flush()
  for i = 1, NCELL do
    local v = V[i]
    if v.raw and v.on then cell_walls(v, i, sel == i) end
  end
  flush()
end

function M.icons(F)
  if F.n == 0 then return end
  local r = F.runs
  if not IMG then
    for k = 1, F.n, 4 do R(r[k], r[k + 1], r[k + 2], r[k + 3], 1) end
    return flush()
  end
  if icon_ver ~= F.ver then
    icon_ver, icon_x = F.ver, 128
    for k = 2, F.n, 4 do icon_x = min(icon_x, r[k]) end
    ICON = screen.create_image(128, 3)
    s_draw(ICON, function()
      for l = 1, 15 do
        local any = false
        for k = 1, F.n, 4 do
          if r[k] == l then
            if not any then s_level(l) any = true end
            s_rect(r[k + 1], r[k + 2] - 61, r[k + 3], 1)
          end
        end
        if any then s_fill() end
      end
    end)
  end
  s_img(ICON, icon_x, 0, 128 - icon_x, 3, icon_x, 61)
end

local function bar(x, y, w, f)
  local fw = floor(clamp(f, 0, 1) * w + 0.5)
  s_level(4) s_rect(x, y, w, 1) s_fill()
  if fw > 0 then s_level(15) s_rect(x, y, fw, 1) s_fill() end
end

function M.volbar(f)
  local w = floor(f * 128 + 0.5)
  if w > 0 then s_level(15) s_rect(0, 62, w, 1) s_fill() end
end

function M.morphbar(f)
  s_level(1) s_rect(0, 62, 128, 1) s_fill()
  s_level(15) s_rect(floor(f * 121 + 0.5), 62, 7, 1) s_fill()
end

function M.notice(l1, l2, l3)
  s_level(15) screen.move(64, 24) screen.text_center(l1)
  s_level(3) screen.move(64, 36) screen.text_center(l2) screen.move(64, 46) screen.text_center(l3)
end

function M.fxpopup(txt, f)
  local w = #txt * 5 + 8
  local x = 64 - floor(w * 0.5)
  s_level(1) s_rect(x, 26, w, f and 12 or 10) s_fill()
  s_level(15) screen.move(64, 34) screen.text_center(txt)
  if f then bar(x, 37, w, f) end
end

function M.recpopup(title, sub, frac, note, prog)
  local x, plain = 18, not (sub or note or frac)
  local h = plain and 16 or 27
  s_level(0) s_rect(x, 20, 92, h) s_fill()
  s_level(4) screen.line_width(1) screen.rect(x + 0.5, 20.5, 91, h - 1) screen.stroke()
  s_level(15)
  if plain then screen.move(64, 31) screen.text_center(title) else screen.move(x + 5, 31) screen.text(title) end
  if sub then s_level(6) screen.move(x + 87, 31) screen.text_right(sub) end
  if note then
    s_level(5) screen.move(x + 5, 41) screen.text(note)
  elseif frac then
    for k = 1, 2 do
      local y, fw = 32 + k * 4, floor(clamp(frac[k] or 0, 0, 1) * 82 + 0.5)
      s_level(2) s_rect(x + 5, y, 82, 3) s_fill()
      if fw > 0 then s_level(15) s_rect(x + 5, y, fw, 3) s_fill() end
    end
  end
  if prog then bar(x, 20 + h - 1, 92, prog) end
end

local function curve(b)
  s_level(15) screen.line_width(1) screen.move(0, b[0])
  for c = 1, 127 do screen.line(c, b[c]) end
  screen.stroke()
end

local function tanh(z) local e = exp(2 * z) return (e - 1) / (e + 1) end
local TILT, TMAX, TMIN = {}, -math.huge, math.huge
for c = 0, 127 do
  TILT[c] = tanh((c / 127 - 0.53) / 0.3)
  TMAX, TMIN = max(TMAX, TILT[c]), min(TMIN, TILT[c])
end
local TAMP = 58 / (TMAX - TMIN)
local TCY = TMAX * TAMP
local tbuf, tkey = {}, nil

function M.tilteq(t)
  if tkey ~= t then
    tkey = t
    for c = 0, 127 do tbuf[c] = clamp(floor(TCY - clamp(t * TILT[c] * TAMP, -TAMP, TAMP) + 0.5), 0, 63) end
  end
  curve(tbuf)
end

local FK, LN = 0.35, 1 / log(1000)
local IQ_HI = 1 / 16
local FMAX = 1 / (1 + FK * sqrt(IQ_HI * (1 - 0.25 * IQ_HI)))
local OCT = {}
for d = -127, 127 do OCT[d] = exp(2 * log(1000) / 127 * d) end

local function fill(buf, cut, iq, up)
  local knee = floor(clamp(log(cut / 20) * LN, 0, 1) * 127 + 0.5)
  for c = 0, 127 do
    local r2 = OCT[up * (c - knee)]
    local m = 1 - r2
    buf[c] = 58 - floor(min(1 / (1 + FK * sqrt(m * m + r2 * iq)) / FMAX, 1) * 58 + 0.5)
  end
end

local fbuf, fkey, hbuf, hkey = {}, nil, {}, nil

function M.filter(cut, res)
  local key = cut * 1000 + res
  if fkey ~= key then
    fkey = key
    local q = 0.707 + clamp(res, 0, 1) ^ 1.3 * (4 - 0.707)
    fill(fbuf, cut, 1 / (q * q), 1)
  end
  curve(fbuf)
end

function M.hpf(cut)
  if hkey ~= cut then hkey = cut fill(hbuf, cut, 1 / (0.707 * 0.707), -1) end
  curve(hbuf)
end

M.set_count(6)

return M
