local S = {}

local floor, abs = math.floor, math.abs
local min, max = math.min, math.max
local cos, exp, pi = math.cos, math.exp, math.pi

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

local function beat_sec()
  local ok, v = pcall(clock.get_beat_sec)
  if ok and type(v) == "number" and v > 0 then return v end
  return 0.5
end

local function beats_now()
  local ok, v = pcall(clock.get_beats)
  if ok and type(v) == "number" then return v end
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
  fp = 0, k = 0, kk = nil, wa = 0.5, wb = 0.5
}

S.driving = false

local WALK_STEP = 0.34
local CATCH_TAU = 0.35
local CATCH_DUR = 1.2
local WRITE_EVERY = 4

local EDGE = 0.005

local mo_seed = 1

local function rnd(k)
  local x = (k * 0x9E3779B1 + mo_seed * 0x85EBCA77) & 0xFFFFFFFF
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

local function walk_to(k)
  if mo.kk == k then return end
  if mo.kk == nil or k < mo.kk or k - mo.kk > 64 then
    mo.kk = k - 1
    mo.wa = mo.wb
  end
  while mo.kk < k do
    mo.kk = mo.kk + 1
    mo.wa = mo.wb
    mo.wb = reflect(mo.wb + (rnd(mo.kk) * 2 - 1) * WALK_STEP)
  end
end

local function mo_shape(shape, k, ph)
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
    return reflect(crom(rnd(k - 1), rnd(k), rnd(k + 1), rnd(k + 2), ph))
  elseif shape == 7 then
    walk_to(k)
    return mo.wa + (mo.wb - mo.wa) * smoothstep(ph)
  end
  return rnd(k)
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
  mo.wb = mo.v
  mo.wa = mo.v
  mo.kk = nil
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

  local u = mo_shape(params:get("morph_shape"), k, ph)

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

local MO_CTL = {"morph_depth", "morph_shape", "morph_sync", "morph_slew"}

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

function S.tick()
  local now = util.time()
  local dt = mo.last and (now - mo.last) or 0
  mo.last = now
  if dt < 0 or dt > 0.5 then dt = 1 / 60 end

  if dly_on then
    local bs = beat_sec()
    if bs ~= last_bs then
      last_bs = bs
      S.dly_refresh()
    end
  end

  mo_tick(dt)
end

return S
