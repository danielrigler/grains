local S = {}

local floor, abs, min, max, cos, exp, log, pi = math.floor, math.abs, math.min, math.max, math.cos, math.exp, math.log, math.pi

local DIV = {
  {0.125, "1/32"}, {1 / 6, "1/16t"}, {0.25, "1/16"}, {1 / 3, "1/8t"}, {0.375, "1/16."}, {0.5, "1/8"},
  {2 / 3, "1/4t"}, {0.75, "1/8."}, {1, "1/4"}, {4 / 3, "1/2t"}, {1.5, "1/4."}, {2, "1/2"}, {3, "1/2."},
  {4, "1 bar"}, {6, "1.5 bar"}, {8, "2 bar"}, {12, "3 bar"}, {16, "4 bar"}, {24, "6 bar"}, {32, "8 bar"},
  {48, "12 bar"}, {64, "16 bar"}, {128, "32 bar"}
}
S.NDIV, S.DIV_QUART, S.DIV_BAR, S.DIV_4BAR = #DIV, 9, 14, 18
S.SHAPES = {"sine", "triangle", "ramp up", "ramp down", "square", "smooth rand", "drunk", "sample+hold"}

local PP = {}
local function pv(id)
  local p = PP[id]
  if not p then p = params:lookup_param(id) PP[id] = p end
  return p:get()
end
local function beats(i) return DIV[i] and DIV[i][1] or 1 end
local function label(i) return DIV[i] and DIV[i][2] or "?" end

local clk = rawget(_G, "clock")
local gbs, gb = clk and clk.get_beat_sec, clk and clk.get_beats
if gbs and not pcall(gbs) then gbs = nil end
if gb and not pcall(gb) then gb = nil end
local function beat_sec() local v = gbs and gbs() return type(v) == "number" and v > 0 and v or 0.5 end
local function beats_now() local v = gb and gb() return type(v) == "number" and v or 0 end

local function fmt(id, sf)
  return function()
    local t = beats(pv(id)) * beat_sec()
    return label(pv(id)) .. "  " .. (t < 60 and string.format(sf, t) or string.format("%.1f min", t / 60))
  end
end
S.mo_fmt, S.vfmt, S.rfmt = fmt("morph_div", "%.1f s"), fmt("vlfo_div", "%.2f s"), fmt("rlfo_div", "%.2f s")

local dly_sent, dly_on = nil, false
function S.dly_synced() return pv("d_sync") == 2 end
local function dly_time()
  local t = beats(pv("d_div")) * beat_sec()
  while t > 5 do t = t * 0.5 end
  return max(t, 0.02)
end
function S.dly_refresh()
  dly_on = S.dly_synced()
  local t = dly_on and dly_time() or pv("d_time")
  if dly_sent and abs(dly_sent - t) < 1e-6 then return end
  dly_sent = t
  engine.d_time(t)
end
function S.dly_fmt()
  local t = dly_time()
  return label(pv("d_div")) .. "  " .. (t < 1 and string.format("%d ms", floor(t * 1000 + 0.5)) or string.format("%.2f s", t))
end

local function rnd(k, sd)
  local x = (k * 0x9E3779B1 + sd * 0x85EBCA77) & 0xFFFFFFFF
  x = x ~ (x >> 15)
  x = (x * 0x2C1B3C6D) & 0xFFFFFFFF
  x = x ~ (x >> 12)
  x = (x * 0x297A2D39) & 0xFFFFFFFF
  return (x ~ (x >> 15)) / 4294967296
end

local function reflect(v)
  while v < 0 or v > 1 do v = v < 0 and -v or 2 - v end
  return v
end

local wkk, wa, wb = {}, {}, {}
local function walk_to(k, sd, s)
  local kk, b = wkk[s], wb[s] or 0.5
  if kk == k then return end
  if not kk or k < kk or k - kk > 64 then kk = k - 1 end
  while kk < k do
    kk = kk + 1
    wa[s], b = b, reflect(b + (rnd(kk, sd) * 2 - 1) * 0.34)
  end
  wkk[s], wb[s] = kk, b
end

local function shape(sh, k, ph, sd, s)
  if sh == 1 then return 0.5 - 0.5 * cos(2 * pi * ph)
  elseif sh == 2 then return ph < 0.5 and ph * 2 or 2 - ph * 2
  elseif sh == 3 then return ph
  elseif sh == 4 then return 1 - ph
  elseif sh == 5 then return ph < 0.5 and 0 or 1
  elseif sh == 6 then
    local p0, p1, p2, p3 = rnd(k - 1, sd), rnd(k, sd), rnd(k + 1, sd), rnd(k + 2, sd)
    local t2 = ph * ph
    return reflect(0.5 * (2 * p1 + (p2 - p0) * ph + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t2 * ph))
  elseif sh == 7 then
    walk_to(k, sd, s)
    return wa[s] + (wb[s] - wa[s]) * ph * ph * (3 - 2 * ph)
  end
  return rnd(k, sd)
end

local CHZ, EVERY, VSHOW = 30, 2, 2
function S.set_rate(hz)
  CHZ = hz
  EVERY = max(floor(hz / 15 + 0.5), 1)
  VSHOW = EVERY
end

S.driving = false
local mo = {v = 0, was = false, catch = 0, fp = 0, k = 0, acc = 0, n = 0}
local EDGE = 0.005

function S.mo_on() return pv("morph_auto") == 2 end
function S.mo_synced() return pv("morph_sync") == 2 end

local function mo_tick(dt)
  local on = S.mo_on()
  if on ~= mo.was then
    mo.was = on
    if not on then return end
    mo.v = min(max(pv("morph") * 0.01, EDGE), 1 - EDGE)
    mo.sent, mo.catch, mo.fp, mo.acc, mo.n = nil, 1.2, 0, 0, 0
    wa[0], wb[0], wkk[0] = mo.v, mo.v, nil
  end
  if not on then return end
  mo.acc, mo.n = mo.acc + dt, mo.n + 1
  if mo.n < EVERY then return end
  dt, mo.acc, mo.n = mo.acc, 0, 0
  local k, ph
  if S.mo_synced() then
    local b = beats_now() / beats(pv("morph_div"))
    k = floor(b)
    ph = b - k
  else
    mo.fp = mo.fp + dt / max(pv("morph_rate"), 0.05)
    while mo.fp >= 1 do mo.fp, mo.k = mo.fp - 1, mo.k + 1 end
    k, ph = mo.k, mo.fp
  end
  local x = shape(pv("morph_shape"), k, ph, pv("morph_seed"), 0) * min(max(pv("morph_depth") * 0.01, 0), 1)
  local tgt = min(max(EDGE + x * (1 - 2 * EDGE), 0), 1)
  local tau = pv("morph_slew")
  if mo.catch > 0 then
    mo.catch = abs(tgt - mo.v) < 0.01 and 0 or mo.catch - dt
    tau = max(tau, 0.35)
  end
  mo.v = tau > 0.001 and mo.v + (tgt - mo.v) * (1 - exp(-dt / tau)) or tgt
  if not mo.sent or abs(mo.v - mo.sent) > 4e-4 then
    mo.sent, S.driving = mo.v, true
    params:set("morph", mo.v * 100)
    S.driving = false
  end
end

local LK = log(10) / 20
S.von, S.vdirty, S.vshow, S.vlagdirty = false, true, false, false
local vshape, vfreq, vdepth, vndb = 1, 0.5, 0, 0
local vpos, vcyc, vframe, vsub, vdiv = 0, 0, 0, 0, 2
local vhz, vbeats, vsync = 0.5, 1, false

local function vnorm()
  if vdepth <= 0 then vndb = 0 return end
  local a, m = vdepth * LK
  if vshape == 1 then
    local t, x = 1, a * a * 0.25
    m = 1
    for j = 1, 9 do t = t * x / (j * j) m = m + t end
  elseif vshape == 5 then
    m = (exp(a) + exp(-a)) * 0.5
  else
    m = (exp(a) - exp(-a)) * 0.5 / a
  end
  vndb = -log(m) / LK
end

local function vrate()
  vsync, vbeats = pv("vlfo_sync") == 2, beats(pv("vlfo_div"))
  local f = vfreq
  if vsync then
    local t = vbeats * beat_sec()
    if t > 0.001 then f = 1 / t end
  end
  vhz = f
  vdiv = min(max(floor(CHZ / max(f * 48, 6)), 1), 5)
  S.vlagdirty = true
end

function S.vset(sh, f, d)
  vfreq = f
  if sh ~= vshape or d ~= vdepth then vshape, vdepth = sh, d vnorm() end
  vrate()
end

function S.venable(on)
  S.von = on
  if on then vpos, vcyc, vframe, vsub, S.vdirty = 0, 0, 0, 0, true end
end

function S.vlag() return S.von and min(max(0.55 / vhz, 0.02), 1) or 1 end

function S.vdb(i, o)
  if vdepth <= 0 then return vndb end
  local ph = vpos
  if vshape < 6 then
    ph = ph + o
    if ph >= 1 then ph = ph - 1 end
  end
  return (shape(vshape, vcyc, ph, i * 65537, i) * 2 - 1) * vdepth + vndb
end

local function advance(pos, cyc, dt, hz, sync, bts)
  if sync then
    local b = beats_now() / bts
    local c = floor(b)
    return b - c, c
  end
  pos = pos + dt * hz
  if pos >= 1 then
    local w = floor(pos)
    return pos - w, cyc + w
  end
  return pos, cyc
end

S.ron = false
local rmode, rshape, rdepth, rspread, rhz, rbeats, rsync, rpos, rcyc = 1, 1, 0, 0, 0.05, 8, false, 0, 0

function S.rset()
  S.ron, rmode, rshape = pv("rlfo") == 2, pv("rlfo_mode"), pv("rlfo_shape")
  rdepth, rspread = pv("rlfo_depth") * 0.01, pv("rlfo_spread") * 0.01
  rhz, rsync, rbeats = pv("rlfo_freq"), pv("rlfo_sync") == 2, beats(pv("rlfo_div"))
end

local function rval(i, n, off, s)
  local ph = rpos + off + rspread * (i - 1) / n
  local w = floor(ph)
  local v = shape(rshape, rcyc + w, ph - w, rspread > 0 and i * 7919 or 7919, s)
  return rshape == 5 and v * 0.7 + 0.15 or v
end

function S.region(i, a, b, n)
  if rdepth <= 0 then return a, b end
  n = max(n, 1)
  local w = b - a
  local t = w < 1 and a / (1 - w) or 0.5
  if rmode ~= 1 then
    local lo, hi = max(w * (1 - rdepth), min(w, 0.03)), min(w * (1 + rdepth), 1)
    w = lo + rval(i, n, rmode == 3 and 0.25 or 0, 20 + i) * (hi - lo)
  end
  if rmode ~= 2 then
    local lo, hi = max(t - rdepth * 0.5, 0), min(t + rdepth * 0.5, 1)
    t = lo + rval(i, n, 0, 10 + i) * (hi - lo)
  end
  a = t * (1 - w)
  return a, a + w
end

local function vis(on, ...)
  for _, id in ipairs({...}) do if on then params:show(id) else params:hide(id) end end
end

function S.vis()
  local pl, d, on, v, r = pv("rev_type") == 1, S.dly_synced(), S.mo_on(), S.von, S.ron
  local m = on and S.mo_synced()
  vis(pl, "rev_series", "d_series", "rev_decay", "rev_damp", "rev_pre", "rev_mdepth", "rev_mrate")
  vis(d, "d_div") vis(not d, "d_time")
  vis(on, "morph_depth", "morph_shape", "morph_sync", "morph_slew")
  vis(m, "morph_div") vis(on and not m, "morph_rate")
  vis(v, "vlfo_shape", "vlfo_depth", "vlfo_sync") vis(v and vsync, "vlfo_div") vis(v and not vsync, "vlfo_freq")
  vis(r, "rlfo_mode", "rlfo_shape", "rlfo_depth", "rlfo_spread", "rlfo_sync") vis(r and rsync, "rlfo_div") vis(r and not rsync, "rlfo_freq")
  if _menu and type(_menu.rebuild_params) == "function" then _menu.rebuild_params() end
end

local last_t, last_bs = nil, nil

function S.tick(now)
  local dt = last_t and now - last_t or 0
  last_t = now
  if dt < 0 or dt > 0.5 then dt = 1 / CHZ end
  local vclk = S.von and vsync
  if dly_on or vclk then
    local bs = beat_sec()
    if bs ~= last_bs then
      last_bs = bs
      if dly_on then S.dly_refresh() end
      if vclk then vrate() end
    end
  end
  mo_tick(dt)
  if S.von then
    vpos, vcyc = advance(vpos, vcyc, dt, vhz, vsync, vbeats)
    vframe = vframe + 1
    if vframe >= vdiv then
      vframe, vsub = 0, vsub + vdiv
      if vsub >= VSHOW then vsub, S.vshow = 0, true end
      if S.vpush then S.vpush() end
    end
  end
  if S.ron then rpos, rcyc = advance(rpos, rcyc, dt, rhz, rsync, rbeats) end
end

return S
