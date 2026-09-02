local S = {}

local floor, abs = math.floor, math.abs
local min, max = math.min, math.max
local cos, exp, log, pi = math.cos, math.exp, math.log, math.pi

local DIV = {
  {0.125,  "1/32"},   {1/6,    "1/16t"},  {0.25,   "1/16"},
  {1/3,    "1/8t"},   {0.375,  "1/16."},  {0.5,    "1/8"},
  {2/3,    "1/4t"},   {0.75,   "1/8."},   {1,      "1/4"},
  {4/3,    "1/2t"},   {1.5,    "1/4."},   {2,      "1/2"},
  {3,      "1/2."},   {4,      "1 bar"},  {6,      "1.5 bar"},
  {8,      "2 bar"},  {12,     "3 bar"},  {16,     "4 bar"},
  {24,     "6 bar"},  {32,     "8 bar"},  {48,     "12 bar"},
  {64,     "16 bar"}, {128,    "32 bar"}
}

S.NDIV      = #DIV
S.DIV_QUART = 9
S.DIV_BAR   = 14
S.DIV_4BAR  = 18

S.SHAPES = {
  "sine", "triangle", "ramp up", "ramp down",
  "square", "smooth rand", "drunk", "sample+hold"
}

local function div_beats(i)
  local d = DIV[i]
  return d and d[1] or 1
end

local function div_label(i)
  local d = DIV[i]
  return d and d[2] or "?"
end

local get_beat_sec, get_beats
do
  local c = rawget(_G, "clock")
  get_beat_sec = c and c.get_beat_sec
  get_beats = c and c.get_beats
  if get_beat_sec and not pcall(get_beat_sec) then get_beat_sec = nil end
  if get_beats and not pcall(get_beats) then get_beats = nil end
end

local function beat_sec()
  if get_beat_sec then
    local v = get_beat_sec()
    if type(v) == "number" and v > 0 then return v end
  end
  return 0.5
end

local function beats_now()
  if get_beats then
    local v = get_beats()
    if type(v) == "number" then return v end
  end
  return 0
end

local DLY_MIN, DLY_MAX = 0.02, 5.0
local dly_sent = nil

local dly_on = false

function S.dly_synced()
  return params:get("d_sync") == 2
end

local function dly_time()
  local t = div_beats(params:get("d_div")) * beat_sec()
  while t > DLY_MAX do t = t * 0.5 end
  return min(max(t, DLY_MIN), DLY_MAX)
end

function S.dly_refresh()
  dly_on = S.dly_synced()
  local t = dly_on and dly_time() or params:get("d_time")
  if dly_sent ~= nil and abs(dly_sent - t) < 1e-6 then return end
  if engine.d_time then
    dly_sent = t
    engine.d_time(t)
  end
end

function S.dly_fmt()
  local t = dly_time()
  local unit = (t < 1) and string.format("%d ms", floor(t * 1000 + 0.5))
                        or string.format("%.2f s", t)
  return div_label(params:get("d_div")) .. "  " .. unit
end

local mo = {
  v = 0, sent = nil, last = nil, catch = 0, was = false,
  fp = 0, k = 0
}

local wkk, wa, wb = {}, {}, {}

S.driving = false

local WALK_STEP = 0.34
local CATCH_TAU = 0.35
local CATCH_DUR = 1.2

local WRITE_EVERY = 4

local EDGE = 0.005

local mo_seed = 1

local function rnd(k, sd)
  local x = (k * 0x9E3779B1 + sd * 0x85EBCA77) & 0xFFFFFFFF
  x = x ~ (x >> 15)
  x = (x * 0x2C1B3C6D) & 0xFFFFFFFF
  x = x ~ (x >> 12)
  x = (x * 0x297A2D39) & 0xFFFFFFFF
  x = x ~ (x >> 15)
  return x / 4294967296
end

local function crom(p0, p1, p2, p3, t)
  local t2 = t * t
  local t3 = t2 * t
  return 0.5 * ((2 * p1)
    + (-p0 + p2) * t
    + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
    + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
end

local function smoothstep(t) return t * t * (3 - 2 * t) end

local function reflect(v)
  while v < 0 or v > 1 do
    if v < 0 then v = -v end
    if v > 1 then v = 2 - v end
  end
  return v
end

local function walk_to(k, sd, s)
  local kk, b = wkk[s], wb[s] or 0.5
  if kk == k then return end
  if kk == nil or k < kk or k - kk > 64 then kk = k - 1 end
  while kk < k do
    kk = kk + 1
    wa[s] = b
    b = reflect(b + (rnd(kk, sd) * 2 - 1) * WALK_STEP)
  end
  wkk[s], wb[s] = kk, b
end

local function mo_shape(shape, k, ph, sd, s)
  if shape == 1 then
    return 0.5 - 0.5 * cos(2 * pi * ph)
  elseif shape == 2 then
    return (ph < 0.5) and (ph * 2) or (2 - ph * 2)
  elseif shape == 3 then
    return ph
  elseif shape == 4 then
    return 1 - ph
  elseif shape == 5 then
    return (ph < 0.5) and 0 or 1
  elseif shape == 6 then
    return reflect(crom(rnd(k - 1, sd), rnd(k, sd), rnd(k + 1, sd), rnd(k + 2, sd), ph))
  elseif shape == 7 then
    walk_to(k, sd, s)
    return wa[s] + (wb[s] - wa[s]) * smoothstep(ph)
  end
  return rnd(k, sd)
end

function S.mo_on()
  return params:get("morph_auto") == 2
end

function S.mo_synced()
  return params:get("morph_sync") == 2
end

function S.mo_fmt()
  local t = div_beats(params:get("morph_div")) * beat_sec()
  local unit = (t < 60) and string.format("%.1f s", t)
                         or string.format("%.1f min", t / 60)
  return div_label(params:get("morph_div")) .. "  " .. unit
end

local function mo_arm()
  mo.v = min(max(params:get("morph") * 0.01, EDGE), 1 - EDGE)
  mo.sent = nil
  mo.catch = CATCH_DUR
  wa[0], wb[0], wkk[0] = mo.v, mo.v, nil
  mo.fp = 0
end

local function mo_depth()
  local d = params:get("morph_depth") * 0.01
  if d < 0 then return 0 elseif d > 1 then return 1 end
  return d
end

local function mo_tick(dt)
  local on = S.mo_on()
  if on ~= mo.was then
    mo.was = on
    if on then mo_arm() else return end
  end
  if not on then return end
  mo_seed = params:get("morph_seed")

  local k, ph
  if S.mo_synced() then
    local b = beats_now() / div_beats(params:get("morph_div"))
    k = floor(b)
    ph = b - k
  else
    local len = params:get("morph_rate")
    if len < 0.05 then len = 0.05 end
    mo.fp = mo.fp + dt / len
    while mo.fp >= 1 do
      mo.fp = mo.fp - 1
      mo.k = mo.k + 1
    end
    k, ph = mo.k, mo.fp
  end

  local u = mo_shape(params:get("morph_shape"), k, ph, mo_seed, 0)

  local x = u * mo_depth()
  local tgt = min(max(EDGE + x * (1 - 2 * EDGE), 0), 1)

  local tau = params:get("morph_slew")
  if mo.catch > 0 then
    mo.catch = mo.catch - dt
    if abs(tgt - mo.v) < 0.01 then mo.catch = 0 end
    if tau < CATCH_TAU then tau = CATCH_TAU end
  end
  if tau > 0.001 then
    mo.v = mo.v + (tgt - mo.v) * (1 - exp(-dt / tau))
  else
    mo.v = tgt
  end

  mo.n = (mo.n or 0) + 1
  if mo.n < WRITE_EVERY then return end
  mo.n = 0
  if mo.sent == nil or abs(mo.v - mo.sent) > 4e-4 then
    mo.sent = mo.v
    S.driving = true
    params:set("morph", mo.v * 100)
    S.driving = false
  end
end

local VFAST = 2
local VLAG_MIN, VLAG_OFF, VLAG_K = 0.02, 1, 0.55
local LK = log(10) / 20

S.von = false
S.vdirty = true
S.vshow = false
S.vlagdirty = false
S.vpush = nil
S.vbase, S.vph, S.va, S.vg, S.vd = {}, {}, {}, {}, {}

local VSHOW = 4
local VDIV_SLOW = 2

function S.set_rate(hz)
  if type(hz) ~= "number" or hz < 1 then return end
  local q = floor(hz / 15 + 0.5)
  if q < 1 then q = 1 end
  WRITE_EVERY = q
  VSHOW = q

  VDIV_SLOW = floor(hz / 30 + 0.5)
  if VDIV_SLOW < 1 then VDIV_SLOW = 1 end
end
local vshape, vfreq, vdepth, vndb = 1, 0.5, 0, 0
local vpos, vcyc, vframe, vsub, vdiv = 0, 0, 0, 0, 2
local vhz, vbeats, vsync = 0.5, 1, false

local function vnorm()
  if vdepth <= 0 then vndb = 0 return end
  local a, m = vdepth * LK, nil
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
  vsync = params:get("vlfo_sync") == 2
  vbeats = div_beats(params:get("vlfo_div"))
  local f = vfreq
  if vsync then
    local t = vbeats * beat_sec()
    if t > 0.001 then f = 1 / t end
  end
  vhz = f
  vdiv = (f > VFAST) and 1 or VDIV_SLOW
  S.vlagdirty = true
end

function S.vsynced() return vsync end

function S.vfmt()
  local t = div_beats(params:get("vlfo_div")) * beat_sec()
  local unit = (t < 60) and string.format("%.2f s", t)
                        or string.format("%.1f min", t / 60)
  return div_label(params:get("vlfo_div")) .. "  " .. unit
end

function S.vset(sh, f, d)
  vfreq = f
  if sh ~= vshape or d ~= vdepth then
    vshape, vdepth = sh, d
    vnorm()
  end
  vrate()
end

function S.venable(on)
  S.von = on
  if on then
    vpos, vcyc, vframe, vsub = 0, 0, 0, 0
    S.vdirty = true
  end
end

function S.vlag()
  if not S.von then return VLAG_OFF end
  return min(max(VLAG_K / vhz, VLAG_MIN), VLAG_OFF)
end

function S.vdb(i, o)
  if vdepth <= 0 then return vndb end
  local ph = vpos
  if vshape < 6 then
    ph = ph + o
    if ph >= 1 then ph = ph - 1 end
  end
  return (mo_shape(vshape, vcyc, ph, i * 65537, i) * 2 - 1) * vdepth + vndb
end

local function v_tick(dt)
  if vsync then
    local b = beats_now() / vbeats
    vcyc = floor(b)
    vpos = b - vcyc
  else
    vpos = vpos + dt * vhz
    if vpos >= 1 then
      local w = floor(vpos)
      vpos = vpos - w
      vcyc = vcyc + w
    end
  end
  vframe = vframe + 1
  if vframe >= vdiv then
    vframe = 0
    vsub = vsub + vdiv
    if vsub >= VSHOW then
      vsub = 0
      S.vshow = true
    end
    if S.vpush then S.vpush() end
  end
end

local MO_CTL = {"morph_depth", "morph_shape", "morph_sync", "morph_slew"}
local V_CTL = {"vlfo_shape", "vlfo_depth", "vlfo_sync"}

function S.vis()
  local d = S.dly_synced()
  local on = S.mo_on()
  local m = on and S.mo_synced()
  if d then params:show("d_div") else params:hide("d_div") end
  if d then params:hide("d_time") else params:show("d_time") end
  for _, id in ipairs(MO_CTL) do
    if on then params:show(id) else params:hide(id) end
  end
  if m then params:show("morph_div") else params:hide("morph_div") end
  if on and not m then params:show("morph_rate") else params:hide("morph_rate") end
  local v = S.von
  for _, id in ipairs(V_CTL) do
    if v then params:show(id) else params:hide(id) end
  end
  if v and vsync then params:show("vlfo_div") else params:hide("vlfo_div") end
  if v and not vsync then params:show("vlfo_freq") else params:hide("vlfo_freq") end
  if _menu and type(_menu.rebuild_params) == "function" then
    _menu.rebuild_params()
  end
end

local DEPTH_STEP = 2

function S.mo_depth_delta(d)
  if d == 0 then return nil end
  local on = S.mo_on()
  local cur = on and params:get("morph_depth") or 0
  local want = min(max(cur + d * DEPTH_STEP, 0), 100)
  if want <= 0 then
    if not on then return "depth: off" end
    params:set("morph_auto", 1)
    params:set("morph_depth", 0)
    return "depth: off"
  end
  params:set("morph_depth", want)
  if not on then params:set("morph_auto", 2) end
  return string.format("depth: %d%%", floor(want + 0.5))
end

function S.mo_freq_delta(d)
  if d == 0 then return nil end
  if S.mo_synced() then
    params:delta("morph_div", -d)
    return "rate: " .. div_label(params:get("morph_div"))
  end
  params:delta("morph_rate", -d)
  local t = params:get("morph_rate")
  return "rate: " .. ((t < 10) and string.format("%.2f s", t)
                              or string.format("%d s", floor(t + 0.5)))
end

local last_bs = nil

function S.tick(now)
  now = now or util.time()
  local dt = mo.last and (now - mo.last) or 0
  mo.last = now
  if dt < 0 or dt > 0.5 then dt = 1 / 60 end

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
  if S.von then v_tick(dt) end
end

return S
