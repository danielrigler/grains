--
--
--
--          Grains v0.01
--          by: @dddstudio
--
--
--
-- K1+E1 Density - Start Here
-- E1 Master Volume
-- K2/K3 Select
-- E2/E3 Set Boundaries
-- K2+E1 Shuffle Volumes
-- K2+E2 Selected Volume
-- K2+E3 Other Volumes
-- K3+E1 Shuffle Pitches
-- K3+E2 Selected Pitch
-- K3+E3 Other Pitches
-- K1+E2 Layers
-- K1+E3 Movement
-- K2+K3 Lock Voice
-- K1+K2+K3 Reseed Voices
-- K2+K3+E1/E2/E3 Effect Mix
-- K1+K2+E1 Tilt EQ
-- K1+K2+E2 HPF
-- K1+K2+E3 LPF
-- K1 hold: Morph Toggle
-- K1+K2 hold: Freeze Voice
-- K1+K3 hold: Freeze All
--
--
--
--
--
--
--
--
-- Based on Graintopia by
-- @infinitedigits

engine.name = "grains"

local MusicUtil = require("musicutil")
local Installer = include("grains/lib/installer/installer")
local installer = Installer:new{requirements = {"AnalogTape"}, zip = "https://github.com/schollz/portedplugins/releases/download/v0.4.6/PortedPlugins-RaspberryPi.zip"}
local boot_screen = not installer:ready()
local function installer_screen() return boot_screen or installer:pending() end
local tape    = include("grains/lib/tape")
local Pit     = include("grains/lib/pit")
local Dice    = include("grains/lib/dice")
local matrix  = include("grains/lib/matrix")
local Morph   = include("grains/lib/morph")
local Shuffle = include("grains/lib/shuffle")
local NV = 6
local NL = 8
local DEFAULT_NV = 4
local LCAPS = {8, 8, 4, 4, 3, 3}
local RAW = matrix.RAW
local CW = matrix.CW
local SPAN = Pit.SPAN
local TREF = 15
local FPS = 60
local TSTEP = TREF / FPS
local phys_acc = 0
local ENERGY_BASE = 200
local REPORT_RATE = 30
local sel = 0
local key_state = {false, false, false}
local key_gesture = nil
local LONGPRESS = 1.2
local POP_DUR = 0.5
local pop = {kind = nil, txt = nil, t = 0}
local volbar = {frac = nil, t = 0}
local DB_FLOOR = -60
local LEVEL_MAX_DB = 6
local LEVEL_STEP_DB = 1
local initial_reverb, initial_rev_send
local ui_metro
local pits = {}
local morph_on = false
local MORPH_SKIP = {morph = true, source = true, chunk = true, lseed = true}

local function morph_skip(id)
  return MORPH_SKIP[id] ~= nil
      or id:find("^do_") ~= nil
      or id:find("^lock_") ~= nil
      or id:find("^freeze") ~= nil
end
local morph_first, morph_last

local nva, lcap = -1, -1

local S = {
  wf = {}, raw = {}, pos = {}, on = {}, loaded = {},
  ls = {}, le = {}, files = {},
  b0 = {}, b1 = {}, sel = 0, nl = {},
  volf = {},
  pitchf = {}
}

local PID = {}
for i = 1, NV do
  PID[i] = {}
  for _, k in ipairs({"bstart", "bwidth", "vol", "tune", "file"}) do
    PID[i][k] = i .. k
  end
end

local dirty = true

do
  local vol_ids, tune_ids = {}, {}
  for i = 1, NV do
    vol_ids[i], tune_ids[i] = PID[i].vol, PID[i].tune
  end
  Shuffle.init{
    vol_ids = vol_ids, tune_ids = tune_ids,
    count = function() return nva end,
    dirty = function() dirty = true end
  }
end

local GLIDE_FRAMES = 24
local GLIDE_K = 0.18
local glide = 0
local CH = matrix.CH

local XF_EASE = 0.7
local xfp, xfw, xfx, xfy = {}, {}, {}, {}
local xfing = false
S.xfp, S.xfw, S.xfx, S.xfy = xfp, xfw, xfx, xfy

local function xf_in(i, w)
  local d = math.random(4)
  xfw[i] = w
  xfx[i] = (d == 1 and -CW) or (d == 2 and CW) or 0
  xfy[i] = (d == 3 and -CH) or (d == 4 and CH) or 0
  xfp[i] = true
  xfing, dirty = true, true
end

local function xf_clear(i)
  if xfp[i] then
    xfp[i], xfw[i] = nil, nil
    dirty = true
  end
end

local cls, cle = {}, {}
local lastcol = {}
local poscol = {}
local file_list = {}
local scanned_dir = nil
local DEFAULT_DIR = _path.tape
local vfrozen, vlocked, ovr = {}, {}, {}
S.frz, S.lck = vfrozen, vlocked
S.blink = false
local frz_any = false
local blink_n = 0
local BLINK_FRAMES = 24
local vseed = {}
local vmr = {}
local last_win = {}
local wbuf = {}
for k = 1, NL * 2 do wbuf[k] = (k % 2 == 0) and 1 or 0 end

local floor, abs, sqrt = math.floor, math.abs, math.sqrt

local function clamp(x, lo, hi)
  if x < lo then return lo elseif x > hi then return hi end return x
end

local function vol_frac(db, hi)
  return clamp((db - DB_FLOOR) / (hi - DB_FLOOR), 0, 1)
end

local function stratified(n, lo, hi)
  local t, span = {}, hi - lo
  for i = 1, n do t[i] = lo + ((i - 0.5) / n) * span end
  for i = 1, n do t[i] = clamp(t[i] + (math.random() - 0.5) * (span * 0.9 / n), lo, hi) end
  for i = n, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

local EMPTY = {}
local VSEED_FIELDS = {"tune", "mr", "cut", "lvl", "floor"}
local function reroll_seeds()
  for _, f in ipairs(VSEED_FIELDS) do
    local vals = stratified(NV, -1, 1)
    for i = 1, NV do
      vseed[i] = vseed[i] or {}
      if not vlocked[i] then vseed[i][f] = vals[i] end
    end
  end
end

local RESO_VOICINGS = {
  {0, 7, 12, 19, 24}, {0, 7, 14, 21, 28}, {0, 4, 7, 12, 16}, {0, 3, 7, 12, 15},
  {0, 4, 7, 11, 14}, {0, 3, 7, 10, 14}, {0, 12, 19.0196, 24, 27.8631}, {0, 12, 24, 36, 48}
}
local RESO_NAMES = {"5th+oct", "fifths", "major", "minor", "maj7", "min7", "harmonic", "octaves"}
local reso_ratios = {}

local function reso_voicing(idx)
  local d = RESO_VOICINGS[idx] or RESO_VOICINGS[1]
  for i = 1, 5 do reso_ratios[i] = 2 ^ (d[i] / 12) end
end
reso_voicing(1)

local function reso_update()
  if params:get("reso_mix") <= 0 then return end
  local f = 440 * 2 ^ ((params:get("reso_root") - 69) / 12)
  engine.reso_freqs(f * reso_ratios[1], f * reso_ratios[2], f * reso_ratios[3],
    f * reso_ratios[4], f * reso_ratios[5])
end

local bounce_until = 0

local function start_bounce()
  if bounce_until > 0 then return end
  local d = params:get("bounce_len")
  bounce_until = util.time() + d + 1.5
  engine.bounce(d, "grains_" .. os.date("%y%m%d_%H%M%S"), params:get("bounce_xf"))
  dirty = true
end

local function rolls(id) return params:get("lock_" .. id) == 1 end

local function nrev_set_mix(db)
  if initial_reverb == nil then return end
  if db <= -40 then
    params:set("reverb", 1)
    return
  end
  params:set("reverb", 2)
  params:set("rev_eng_input", db)
end

local function fast_db(v)
  if v <= -40 then return "OFF" end
  return string.format("%d dB", floor(v + 0.5))
end

local sent = {}
local function eset(key, val)
  if sent[key] ~= nil and abs(sent[key] - val) < 1e-6 then return end
  sent[key] = val
  engine.set_all(key, val)
end

local sent_one = {}
local function eset_one(i, key, val)
  local t = sent_one[key]
  if not t then t = {} sent_one[key] = t end
  if t[i] ~= nil and abs(t[i] - val) < 1e-6 then return end
  t[i] = val
  engine.set_one(i - 1, key, val)
end

local VOICE_PARAMS = {
  {"revprob",  "reverse",  0.01},
  {"rateSlew", "rateslew"},
  {"panwidth", "panwidth", 0.01},
  {"res",      "res",      function(v) return (100 - v) * 0.007 end},
  {"hpf",      "vhpf"}
}
for i = 1, 5 do
  VOICE_PARAMS[#VOICE_PARAMS + 1] = {"weight" .. i,   "weight" .. i}
  VOICE_PARAMS[#VOICE_PARAMS + 1] = {"mididiff" .. i, "mididiff" .. i}
  VOICE_PARAMS[#VOICE_PARAMS + 1] = {"db" .. i,       "vdb" .. i}
end

local SCALARS = {"tuning", "chord", "spread", "variance", "motionrate", "cutoff", "ampfloor"}
local DICE_GLOBALS = {}
for _, id in ipairs(SCALARS) do DICE_GLOBALS[#DICE_GLOBALS + 1] = id end
for _, p in ipairs(VOICE_PARAMS) do
  if p[2] ~= "res" then DICE_GLOBALS[#DICE_GLOBALS + 1] = p[2] end
end

local DICE_SET = {}
for _, id in ipairs(DICE_GLOBALS) do DICE_SET[id] = true end

local dicing = false
local ovr_n = 0
local bcast = true

local function lget(i, id)
  local t = ovr[i]
  local v = t and t[id]
  if v ~= nil then return v end
  return params:get(id)
end

local function push_one(p)
  local key, id, xf = p[1], p[2], p[3]
  local fn = type(xf) == "function"
  local g = params:get(id)
  local gval = fn and xf(g) or g * (xf or 1)
  if ovr_n == 0 and bcast then
    eset(key, gval)
    return
  end
  for i = 1, NV do
    local t = ovr[i]
    local hv = t and t[id]
    if hv == nil then
      eset_one(i, key, gval)
    else
      eset_one(i, key, fn and xf(hv) or hv * (xf or 1))
    end
  end
end

local function push_voice_params()
  for _, p in ipairs(VOICE_PARAMS) do push_one(p) end
end

local function drop_shadows()
  for _, p in ipairs(VOICE_PARAMS) do
    local key = p[1]
    local t = sent_one[key]
    if t then
      for i = 1, NV do
        if t[i] ~= nil then
          t[i] = nil
          engine.clear_param(i - 1, key)
        end
      end
    end
  end
end

local function ovr_sync()
  local n = 0
  for i = 1, NV do
    local t = ovr[i]
    if t then
      if next(t) == nil then ovr[i] = nil else n = n + 1 end
    end
  end
  if n == ovr_n then return end
  if ovr_n == 0 and n > 0 then
    for _, p in ipairs(VOICE_PARAMS) do
      local g, t = sent[p[1]], sent_one[p[1]]
      if t == nil then t = {} sent_one[p[1]] = t end
      for i = 1, NV do if t[i] == nil then t[i] = g end end
    end
  end
  ovr_n = n
  if n == 0 and bcast and not pcall(drop_shadows) then
    bcast = false
  end
  push_voice_params()
end

local function ovr_clear(id)
  if ovr_n == 0 then return end
  local drop = false
  for i = 1, NV do
    local t = ovr[i]
    if t and t[id] ~= nil then
      t[id] = nil
      drop = true
    end
  end
  if drop then ovr_sync() end
end

local function ovr_capture()
  for i = 1, NV do
    if vlocked[i] then
      local t = ovr[i]
      if t == nil then t = {} ovr[i] = t end
      for _, id in ipairs(DICE_GLOBALS) do
        if t[id] == nil then t[id] = params:get(id) end
      end
    end
  end
  ovr_sync()
end

local LAYER_TRIM = {}
for n = 1, NL do LAYER_TRIM[n] = -10 * (math.log(n) / math.log(10)) end

local voices_dirty = false
local function push_voices() voices_dirty = true end

local function freeze_refresh()
  local all = params:get("freeze_all") == 1
  local any = false
  for i = 1, NV do
    vfrozen[i] = (all or params:get("freeze" .. i) == 1) or nil
    if vfrozen[i] then any = true end
  end
  frz_any = any
  if not any then
    S.blink = false
    blink_n = 0
  end
  push_voices()
  dirty = true
end

local function lock_refresh()
  for i = 1, NV do
    local on = params:get("lock_v" .. i) == 1
    vlocked[i] = on or nil
    if not on then ovr[i] = nil end
  end
  ovr_sync()
  push_voice_params()
  push_voices()
  dirty = true
end

local act_nl = {}

local function push_per_voice()
  voices_dirty = false
  dirty = true
  local gvar    = params:get("variance") / 100
  local groot   = params:get("tuning")
  local gspread = params:get("spread") / 100
  local gchord  = params:get("chord")
  local gmr     = params:get("motionrate")
  local gcut    = params:get("cutoff")
  local gflr    = params:get("ampfloor") / 100
  local lvl     = params:get("level")
  for i = 1, nva do
    local s = vseed[i]
    local trim = LAYER_TRIM[act_nl[i]] or 0
    local ivol = params:get(PID[i].vol)
    S.volf[i] = vol_frac(ivol, Shuffle.VOL_MAX_DB)
    S.pitchf[i] = clamp(params:get(PID[i].tune) / Shuffle.PITCH_HI, -1, 1)
    if s then
      local frz = vfrozen[i]
      local var, root, spread, chord, mr, cut, flr
      if ovr[i] then
        var    = lget(i, "variance") / 100
        root   = lget(i, "tuning")
        spread = lget(i, "spread") / 100
        chord  = lget(i, "chord")
        mr     = lget(i, "motionrate")
        cut    = lget(i, "cutoff")
        flr    = lget(i, "ampfloor") / 100
      else
        var, root, spread, chord = gvar, groot, gspread, gchord
        mr, cut, flr = gmr, gcut, gflr
      end
      eset_one(i, "miditune",
        root + Dice.snap(s.tune * spread * 24, chord) + params:get(PID[i].tune))
      local m = frz and 0 or clamp(mr * 2 ^ (s.mr * var * 1.3), 0.02, 12)
      vmr[i] = m
      eset_one(i, "mrate", m)
      eset_one(i, "cutoff",   clamp(cut * 2 ^ ((s.cut - 0.25) * var * 2.6), 90, 15000))
      local db = clamp(lvl + ivol + trim + s.lvl * var * 7, -100, 6)
      if lvl <= -59.5 or ivol <= -59.5 then db = -100 end
      eset_one(i, "db", db)
      eset_one(i, "ampfloor", frz and 1 or clamp(flr + s.floor * var * 0.35, 0, 1))
    end
  end
end

local pop_dirty = true
local function push_population() pop_dirty = true end

local lord, lord_n, lord_key = {}, 0, nil
local lord_pend = nil

local function build_order()
  local seed = floor(params:get("lseed"))
  local key = (seed * 8 + nva) * 16 + lcap
  if lord_key == key then return end
  lord_key = key
  local s = (seed * 1103515245 + 12345) % 2147483648
  local v, n = {}, 0
  for i = 1, nva do v[i] = i end
  for _ = 1, lcap do
    for k = nva, 2, -1 do
      s = (s * 1103515245 + 12345) % 2147483648
      local j = floor(s / 65536) % k + 1
      v[k], v[j] = v[j], v[k]
    end
    for k = 1, nva do n = n + 1 lord[n] = v[k] end
  end
  lord_n = n
  local p = lord_pend
  if p and p.nva == nva and p.lcap == lcap and #p.seq == n then
    for k = 1, n do lord[k] = p.seq[k] end
    lord_pend = nil
  end
end

local function spread_density()
  build_order()
  local d = floor(params:get("density"))
  if d > lord_n then d = lord_n end
  for i = 1, NV do act_nl[i] = 0 end
  for k = 1, d do
    local i = lord[k]
    act_nl[i] = act_nl[i] + 1
  end
end

local function order_move(from, to)
  local v = lord[from]
  if from < to then
    for k = from, to - 1 do lord[k] = lord[k + 1] end
  elseif from > to then
    for k = from, to + 1, -1 do lord[k] = lord[k - 1] end
  end
  lord[to] = v
end

local function nudge_voice_layers(i, step)
  build_order()
  local d = floor(params:get("density"))
  if d > lord_n then d = lord_n end
  local n = 0
  if step > 0 then
    for _ = 1, step do
      local at = nil
      for k = d + n + 1, lord_n do if lord[k] == i then at = k break end end
      if at == nil then break end
      order_move(at, d + n + 1)
      n = n + 1
    end
  else
    for _ = 1, -step do
      local at = nil
      for k = d - n, 1, -1 do if lord[k] == i then at = k break end end
      if at == nil then break end
      order_move(at, d - n)
      n = n + 1
    end
    n = -n
  end
  if n ~= 0 then params:set("density", d + n) end
end

local function flush_population()
  if not pop_dirty then return end
  spread_density()
  for i = 1, NV do
    local n = act_nl[i]
    if S.nl[i] ~= n then
      local prev = S.nl[i] or 0
      S.nl[i] = n
      if n > prev then
        local pit, tls, tle = pits[i], cls[i], cle[i]
        local sls, sle = S.ls[i], S.le[i]
        for L = prev + 1, n do
          local a, b = pit:window(L)
          tls[L], tle[L] = a, b
          sls[L], sle[L] = a, b
        end
      end
      if n > 0 then engine.layers(i - 1, n) end
      push_voices()
      dirty = true
    end
    local on = n > 0
    if S.on[i] ~= on then
      S.on[i] = on
      engine.active(i - 1, on and 1 or 0)
      if on then for k = 1, lcap * 2 do last_win[i][k] = nil end end
      dirty = true
    end
  end
  pop_dirty = false
  if nva < 1 then
    sel = 0
  else
    if sel > nva then sel = nva end
    if sel < 1 then sel = 1 end
  end
end

local PSET_EXT = {".gstate", ".lorder", ".morph"}
local PSET_WAIT = 6

local function pset_write(fn)
  local f = io.open(fn, "w")
  if not f then return end
  build_order()
  f:write("grains 1\n")
  f:write(string.format("geom %d %d %d\n", nva, lcap, floor(params:get("density"))))
  if lord_n > 0 then f:write("ord ", table.concat(lord, " ", 1, lord_n), "\n") end
  for i = 1, NV do
    local sd = S.files[i] and vseed[i]
    if sd then
      f:write(string.format("seed %d %.9g %.9g %.9g %.9g %.9g\n", i,
        sd.tune, sd.mr, sd.cut, sd.lvl, sd.floor))
    end
    local pit = sd and pits[i]
    if pit then
      f:write("pit ", i, " ", pit.n)
      for k = 1, pit.n do
        local b = pit.beads[k]
        f:write(string.format(" %.7g %.7g %d", b.pos, b.vel, b.r))
      end
      f:write("\n")
    end
    for id, v in pairs(ovr[i] or EMPTY) do
      f:write(string.format("ovr %d %s %.9g\n", i, id, v))
    end
  end
  f:write(string.format("mpos %.6f\n", Morph.pos))
  for k = 1, Morph.slots() do
    f:write(string.format("mp %s %.6f %.6f\n", Morph.slot(k)))
  end
  f:close()
end

local tok = {}

local function pset_line(line, r)
  local n = 0
  for w in line:gmatch("%S+") do n = n + 1 tok[n] = w end
  if n < 2 then return false end
  local tag = tok[1]
  local i = tonumber(tok[2]) or 0
  local voice = i >= 1 and i <= NV and floor(i)

  if tag == "geom" then
    local c, d = tonumber(tok[3]), tonumber(tok[4])
    if voice and c and c >= 1 and c <= NL then
      r.geom = {nva = voice, lcap = floor(c), dens = d and floor(d) or nil}
      return true
    end

  elseif tag == "ord" then
    local seq = {}
    for k = 2, n do
      local v = tonumber(tok[k])
      if v == nil then return false end
      seq[k - 1] = floor(v)
    end
    r.ord = seq
    return true

  elseif tag == "seed" and voice and n >= 7 then
    local sd = {}
    for k = 1, 5 do
      local v = tonumber(tok[k + 2])
      if v == nil or v ~= v then return false end
      sd[VSEED_FIELDS[k]] = v
    end
    r.seed[voice] = sd
    return true

  elseif tag == "pit" and voice then
    local nb = tonumber(tok[3])
    if nb == nil or nb < 2 or nb > NL * 2 or n < 3 + nb * 3 then return false end
    local b = {}
    for k = 1, nb * 3 do
      local v = tonumber(tok[k + 3])
      if v == nil or v ~= v then return false end
      b[k] = v
    end
    r.pit[voice] = {n = floor(nb), b = b}
    return true

  elseif tag == "ovr" and voice and DICE_SET[tok[3]] then
    local v = tonumber(tok[4])
    if v and v == v then
      local h = r.hold[voice]
      if h == nil then h = {} r.hold[voice] = h end
      h[tok[3]] = v
      return true
    end

  elseif tag == "mpos" then
    r.mpos = tonumber(tok[2])
    return r.mpos ~= nil

  elseif tag == "mp" then
    local a, b = tonumber(tok[3]), tonumber(tok[4])
    if a and b and Morph.put(tok[2], a, b) then
      r.morph = true
      return true
    end
  end
  return false
end

local function pset_scan(fn, r)
  local f = io.open(fn, "r")
  if not f then return false end
  local hit = false
  for line in f:lines() do
    if pset_line(line, r) then hit = true end
  end
  f:close()
  return hit
end

local function pset_scan_old(fn, r)
  local hit = false
  local f = io.open(fn .. ".lorder", "r")
  if f then
    hit = pset_line("geom " .. (f:read("*l") or ""), r)
    hit = pset_line("ord " .. (f:read("*l") or ""), r) or hit
    f:close()
  end
  f = io.open(fn .. ".morph", "r")
  if f then
    hit = pset_line("mpos " .. (f:read("*l") or ""), r) or hit
    for line in f:lines() do hit = pset_line("mp " .. line, r) or hit end
    f:close()
  end
  return hit
end

local pset_pend = nil

local function pset_read(fn)
  freeze_refresh()
  lock_refresh()
  dirty = true
  local r = {seed = {}, pit = {}, hold = {}}
  if not (pset_scan(fn .. ".gstate", r) or pset_scan_old(fn, r)) then return end
  for i = 1, NV do
    if r.seed[i] then vseed[i] = r.seed[i] end
    ovr[i] = (vlocked[i] and r.hold[i]) or nil
  end
  ovr_sync()
  push_voice_params()
  push_voices()
  if r.morph or r.mpos then
    Morph.settled(r.mpos)
    params:set("morph", Morph.pos * 100, true)
  end
  pset_pend = (r.geom or r.ord or next(r.pit)) and
    {geom = r.geom, ord = r.ord, pit = r.pit, t = util.time()} or nil
end

local function pset_apply()
  local pd = pset_pend
  local g = pd.geom
  if g and (nva ~= g.nva or lcap ~= g.lcap) then
    if util.time() - pd.t > PSET_WAIT then pset_pend = nil end
    return
  end
  pset_pend = nil
  if g and g.dens then
    local mx = params:lookup_param("density").max
    local d = g.dens > mx and mx or g.dens
    if floor(params:get("density")) ~= d then params:set("density", d) end
  end
  local seq = pd.ord
  if seq and #seq == nva * lcap then
    local seen = {}
    for k = 1, nva do seen[k] = 0 end
    for k = 1, #seq do
      local c = seen[seq[k]]
      seen[seq[k]] = c and c + 1 or nil
    end
    for k = 1, nva do if seen[k] ~= lcap then seq = nil break end end
    if seq then
      lord_pend = {nva = nva, lcap = lcap, seq = seq}
      lord_key = nil
      push_population()
    end
  end
  for i = 1, NV do
    local rec = pd.pit[i]
    local pit = rec and pits[i]
    if pit and pit.n == rec.n and pit:load(rec.b, rec.n) then
      local tls, tle, lw = cls[i], cle[i], last_win[i]
      for L = 1, lcap do
        local a, b = pit:window(L)
        local k = (L - 1) * 2
        if tls and tle then tls[L], tle[L] = a, b end
        if lw then lw[k + 1], lw[k + 2] = a, b end
        wbuf[k + 1], wbuf[k + 2] = a, b
      end
      if S.on[i] then engine.set_win(i - 1, table.unpack(wbuf, 1, NL * 2)) end
    end
  end
  dirty = true
end

local trimming = false
local blo, bhi = {}, {}

local function trim_width(i)
  if trimming then return end
  trimming = true
  local a, w = params:get(PID[i].bstart), params:get(PID[i].bwidth)
  if a + w > 100 then
    w = 100 - a
    params:set(PID[i].bwidth, w)
  end
  blo[i], bhi[i] = a / 100, (a + w) / 100
  if glide <= 0 then S.b0[i], S.b1[i] = blo[i], bhi[i] end
  dirty = true
  trimming = false
end

local layout_busy = false
local dfrac = 0

local function count_files()
  local n = 0
  for i = 1, NV do if S.files[i] then n = i end end
  return n
end

local function refresh_layout()
  if layout_busy then return end
  local n = count_files()
  local cap = LCAPS[n] or (lcap > 0 and lcap) or LCAPS[1]
  if n == nva and cap == lcap then return end
  layout_busy = true
  nva, lcap = n, cap
  local nm = (n < 1 and 1 or n) * cap
  Morph.hold(function()
    params:lookup_param("density").max = nm
    params:set("density", clamp(floor(dfrac * nm + 0.5), 0, nm))
  end)
  for k = cap * 2 + 1, NL * 2, 2 do wbuf[k], wbuf[k + 1] = 0, 1 end
  for i = 1, NV do
    pits[i]:resize(cap * 2, (blo[i] or 0) * SPAN, (bhi[i] or 1) * SPAN)
    last_win[i] = {}
    lastcol[i], poscol[i] = {}, {}
    S.nl[i] = 0
  end
  if matrix.set_count(n) then
    CW, CH = matrix.CW, matrix.CH
    for i = 1, NV do
      S.wf[i] = matrix.wave(S.raw[i])
      if S.wf[i] == nil then S.loaded[i] = false end
      if xfp[i] then
        xfw[i] = S.wf[i]
        if xfw[i] == nil then xf_clear(i) end
      end
    end
  end
  layout_busy = false
  engine.report_voices(n)
  push_population()
  push_voices()
  dirty = true
end

local function xf_step(i)
  if xfp[i] == nil then return end
  local x, y = xfx[i] * XF_EASE, xfy[i] * XF_EASE
  dirty = true
  if x > -0.5 and x < 0.5 and y > -0.5 and y < 0.5 then
    xfp[i], xfw[i] = nil, nil
    return
  end
  xfx[i], xfy[i] = x, y
  xfing = true
end

local function physics_tick()
  phys_acc = phys_acc + TSTEP
  local steps = floor(phys_acc)
  phys_acc = phys_acc - steps

  if steps > 0 and Morph.dirty then Morph.apply() end

  flush_population()
  if pset_pend then pset_apply() end
  if voices_dirty then push_per_voice() end

  if xfing then
    xfing = false
    for i = 1, NV do xf_step(i) end
  end

  local gliding = glide > 0
  if gliding then
    glide = glide - 1
    dirty = true
    if glide == 0 then
      for i = 1, NV do S.b0[i], S.b1[i] = blo[i], bhi[i] end
      gliding = false
    else
      for i = 1, NV do
        local x, y = S.b0[i], S.b1[i]
        S.b0[i] = x + (blo[i] - x) * GLIDE_K
        S.b1[i] = y + (bhi[i] - y) * GLIDE_K
      end
    end
  elseif steps == 0 then
    return
  end

  for i = 1, nva do
    if S.on[i] then
      local tls, tle = cls[i], cle[i]
      local nl = act_nl[i] or 1

      if steps > 0 and not vfrozen[i] then
        local pit = pits[i]
        local a, b = blo[i] * SPAN, bhi[i] * SPAN
        local m = vmr[i] or 1
        local energy = clamp(ENERGY_BASE * m * m, 10, 300000)
        local vmax   = clamp(2.5 * m, 0.15, 10)
        for _ = 1, steps do pit:update(a, b, energy, vmax) end

        local lw = last_win[i]
        local changed = false
        for L = 1, nl do
          local st, en = pit:window(L)
          tls[L], tle[L] = st, en
          local k = (L - 1) * 2
          local o1, o2 = lw[k + 1], lw[k + 2]
          if o1 == nil or abs(st - o1) > 2e-4 or abs(en - o2) > 2e-4 then
            changed = true
          end
          wbuf[k + 1], wbuf[k + 2] = st, en
        end
        if changed then
          for k = 1, nl * 2 do lw[k] = wbuf[k] end
          for L = nl + 1, lcap do
            local st, en = pit:window(L)
            local k = (L - 1) * 2
            wbuf[k + 1], wbuf[k + 2] = st, en
          end
          engine.set_win(i - 1, table.unpack(wbuf, 1, NL * 2))
        end
      end

      local sls, sle, lc = S.ls[i], S.le[i], lastcol[i]
      for L = 1, nl do
        local x0, x1 = tls[L], tle[L]
        if x0 then
          if gliding then
            local o0, o1 = sls[L], sle[L]
            x0 = o0 + (x0 - o0) * GLIDE_K
            x1 = o1 + (x1 - o1) * GLIDE_K
          end
          sls[L], sle[L] = x0, x1
          local k = (L - 1) * 2
          local c0 = floor(x0 * CW)
          local c1 = floor(x1 * CW)
          if lc[k + 1] ~= c0 or lc[k + 2] ~= c1 then
            lc[k + 1], lc[k + 2] = c0, c1
            dirty = true
          end
        end
      end
    end
  end
end

local RETRIES = 8
local tries = {}

local function load_voice(i, path)
  S.files[i] = path
  dirty = true
  for L = 1, NL do S.pos[i][L] = 0 end
  xf_clear(i)
  S.loaded[i] = false
  S.wf[i], S.raw[i] = nil, nil
  params:set(PID[i].file, path, true)
  refresh_layout()
  engine.read(i - 1, path, params:get("chunk"), 1)
end

local function clear_voice(i)
  S.files[i] = nil
  xf_clear(i)
  S.loaded[i] = false
  S.wf[i], S.raw[i] = nil, nil
  tries[i] = 0
  for L = 1, NL do S.pos[i][L] = 0 end
  params:set(PID[i].file, DEFAULT_DIR, true)
  engine.clear(i - 1)
end

local function clear_all()
  for i = 1, NV do clear_voice(i) end
  scanned_dir = nil
  refresh_layout()
  dirty = true
end

local function retry_voice(i)
  tries[i] = (tries[i] or 0) + 1
  if tries[i] > RETRIES or #file_list == 0 then
    xf_clear(i)
    S.loaded[i] = false
    return
  end
  local pool = {}
  for _, f in ipairs(file_list) do
    if f ~= S.files[i] then pool[#pool + 1] = f end
  end
  if #pool == 0 then pool = file_list end
  load_voice(i, pool[math.random(#pool)])
end

local function scan_source()
  local dir = params:get("source")
  if dir == nil or dir == "" or dir == "-" then dir = _path.tape end
  if dir:sub(-1) ~= "/" then dir = dir:match("^(.*/)") or _path.tape end
  if dir ~= scanned_dir then
    file_list = tape.scan(dir, 900, 3)
    scanned_dir = #file_list > 0 and dir or nil
  end
  return #file_list > 0
end

local function load_random(n, scanned)
  n = clamp(floor(n or (nva < 1 and DEFAULT_NV or nva)), 1, NV)
  if not (scanned or scan_source()) then return end
  local chosen = tape.pick(file_list, n)
  layout_busy = true
  for i = 1, n do
    tries[i] = 0
    if chosen[i] then load_voice(i, chosen[i]) end
  end
  layout_busy = false
  refresh_layout()
end

local function load_n(n)
  n = clamp(floor(n), 1, NV)
  for i = n + 1, NV do clear_voice(i) end
  for i = 1, n do
    xf_clear(i)
    S.loaded[i] = false
    S.wf[i], S.raw[i] = nil, nil
  end
  dirty = true
  redraw()
  if not scan_source() then
    for i = 1, n do clear_voice(i) end
    refresh_layout()
    return
  end
  load_random(n, true)
end

local held = {}
local prev_ord, ord_buf = {}, {}
local reseed_one_ok = true

local function order_keep_held(prevn)
  build_order()
  if prevn ~= lord_n or lord_n < 1 then return end
  local j = 0
  for k = 1, lord_n do
    local v = prev_ord[k]
    if held[v] then
      ord_buf[k] = v
    else
      repeat j = j + 1 until j > lord_n or not held[lord[j]]
      ord_buf[k] = (j <= lord_n) and lord[j] or v
    end
  end
  for k = 1, lord_n do lord[k] = ord_buf[k] end
end

local function reseed_engine()
  local any = false
  for i = 1, nva do
    if held[i] then any = true break end
  end
  if any and reseed_one_ok then
    local ok = pcall(function()
      for i = 1, nva do
        if not held[i] then engine.reseed_one(i - 1) end
      end
    end)
    if ok then return end
    reseed_one_ok = false
  end
  engine.reseed()
end

local function reseed_voices()
  glide = GLIDE_FRAMES
  lord_pend = nil
  local anyheld = false
  for i = 1, NV do
    held[i] = (vfrozen[i] or vlocked[i]) or nil
    if held[i] then anyheld = true end
  end
  local prevn = 0
  if anyheld then
    build_order()
    prevn = lord_n
    for k = 1, lord_n do prev_ord[k] = lord[k] end
  end
  params:set("lseed", math.random(9999))
  if anyheld then order_keep_held(prevn) end
  flush_population()
  for i = 1, nva do
    if not held[i] then
      pits[i]:reroll(blo[i] * SPAN, bhi[i] * SPAN)
      for L = 1, lcap do
        local s, e = pits[i]:window(L)
        local k = (L - 1) * 2
        cls[i][L], cle[i][L] = s, e
        wbuf[k + 1], wbuf[k + 2] = s, e
        last_win[i][k + 1], last_win[i][k + 2] = s, e
      end
      if S.on[i] then
        engine.set_win(i - 1, table.unpack(wbuf, 1, NL * 2))
      end
    end
  end
  reroll_seeds()
  push_per_voice()
  reseed_engine()
end

local DICE = {
  tune = function()
    local c = Dice.pick(Dice.TUNING)
    local rows = Dice.tuning_rows(c)
    for i = 1, 5 do
      params:set("mididiff" .. i, rows[i].interval)
      params:set("weight" .. i, rows[i].weight)
      params:set("vdb" .. i, rows[i].db)
    end
    params:set("tuning", Dice.roll_root())
    params:set("chord", math.random(#Dice.CHORDS))
    params:set("spread", Dice.rnd(15, 100) * c.spread)
  end,
  motion = function()
    local c = Dice.pick(Dice.MOTION)
    params:set("motionrate", Dice.rndexp(c.mr[1], c.mr[2]))
    params:set("rateslew", Dice.rndexp(c.slew[1], c.slew[2]))
    params:set("reverse", Dice.rnd(c.rev[1], c.rev[2]) * 100)
    params:set("ampfloor", Dice.rnd(c.floor[1], c.floor[2]))
  end,
  space = function()
    local c = Dice.pick(Dice.SPACE)
    params:set("panwidth", Dice.rnd(c.pan[1], c.pan[2]))
    params:set("cutoff", Dice.rndexp(c.cut[1], c.cut[2]))
    params:set("vhpf", Dice.rnd(20, 400))
    params:set("variance", Dice.rnd(0, 100))

    local d = c.dly
    params:set("d_time",    Dice.rndexp(d.time[1], d.time[2]))
    params:set("d_fb",      Dice.rnd(d.fb[1], d.fb[2]))
    params:set("d_lpf",     Dice.rndexp(d.lpf[1], d.lpf[2]))
    params:set("d_hpf",     Dice.rndexp(d.hpf[1], d.hpf[2]))
    params:set("d_stereo",  Dice.rnd(d.stereo[1], d.stereo[2]))
    params:set("d_duck",    Dice.rnd(d.duck[1], d.duck[2]))
    params:set("d_wrate",   Dice.rnd(d.wrate[1], d.wrate[2]))
    params:set("d_wdepth",  Dice.rnd(d.wdepth[1], d.wdepth[2]))

    local h = c.shm
    params:set("sh_oct",     math.random(h.oct[1], h.oct[2]))
    params:set("sh_fb",      Dice.rnd(h.fb[1], h.fb[2]))
    params:set("sh_pitchv",  Dice.rnd(h.pitchv[1], h.pitchv[2]))
    params:set("sh_fbdelay", Dice.rnd(h.fbdelay[1], h.fbdelay[2]))
    params:set("sh_lowpass", Dice.rndexp(h.lpf[1], h.lpf[2]))
    params:set("sh_hipass",  Dice.rndexp(h.hpf[1], h.hpf[2]))
  end,
  shape = function()
    local c = Dice.pick(Dice.SHAPE)
    for i = 1, NV do
      if not vlocked[i] then
        local cc = (math.random() < 0.35) and Dice.pick(Dice.SHAPE) or c
        local a = Dice.rnd(cc.start[1], cc.start[2])
        local w = Dice.rnd(cc.width[1], cc.width[2])
        if a + w > 1 then a = math.max(0, 1 - w) end
        params:set(PID[i].bstart, a * 100)
        params:set(PID[i].bwidth, w * 100)
      end
    end
  end
}

local function dice()
  glide = GLIDE_FRAMES
  ovr_capture()
  dicing = true
  for _, k in ipairs({"tune", "motion", "space", "shape"}) do
    if rolls(k) then DICE[k]() end
  end
  if rolls("voice") then
    for i = 1, NV do
      if not vlocked[i] then
        params:set(PID[i].vol, Dice.rnd(-50, 5))
        params:set(PID[i].tune, math.random(Shuffle.PITCH_LO, Shuffle.PITCH_HI))
      end
    end
  end
  dicing = false
  push_voice_params()
  reseed_voices()
end

local HIDDEN = {"grains_tune", "grains_bounds", "grains_reverb", "reverb_mix", "level", "chord", "lseed"}

local function setup_params()
  morph_first = #params.params + 1

  params:add_separator("  ", "  ")

  for i = 1, NV do
    params:add_file(PID[i].file, "S" ..i, DEFAULT_DIR) params:set_action(PID[i].file, function(path)
      if path == nil or path == "" or path == "-" then return end
      if path:sub(-1) == "/" then
        if S.files[i] then
          clear_voice(i)
          refresh_layout()
          dirty = true
        end
        return
      end
      if path == S.files[i] then return end
      tries[i] = 0
      load_voice(i, path)
    end)
  end
  params:add_binary("do_clear", "Unload All", "trigger", 0) params:set_action("do_clear", function(v) if v == 1 then clear_all() end end)

  params:add_separator(" ", " ")

  params:add_group("grains_main", "VOICES", 11)
  params:add_control("level", "Level", controlspec.new(DB_FLOOR, LEVEL_MAX_DB, "lin", 0.5, -20, "dB"))
  params:add_number("density", "Density", 0, NV * NL, 0) params:set_action("density", function(v) if not layout_busy then local m = params:lookup_param("density").max dfrac = m > 0 and clamp(v / m, 0, 1) or 0 end push_population() end)
  params:add_control("tuning", "Tuning", controlspec.new(-36, 24, "lin", 1, 0, "st"))
  params:add_control("spread", "Pitch Spread", controlspec.new(0, 100, "lin", 1, 75, "%"))
  params:add_option("chord", "Chord", Dice.CHORD_NAMES, 6)
  params:add_control("variance", "Voice Variance", controlspec.new(0, 100, "lin", 1, 50, "%"))
  params:add_control("motionrate", "Motion Rate", controlspec.new(0.05, 8, "exp", 0, 1, "x"))
  params:add_control("reverse", "Reverse Chance", controlspec.new(0, 100, "lin", 1, 40, "%"))
  params:add_control("rateslew", "Rate Slew", controlspec.new(0.005, 10, "exp", 0, 1.5, "s"))
  params:add_control("panwidth", "Pan Width", controlspec.new(0, 100, "lin", 1, 90, "%"))
  params:add_control("ampfloor", "Level Floor", controlspec.new(0, 100, "lin", 1, 25, "%"))

  params:add_group("grains_tune", "TUNING", 15)
  local defaults = {
    {w = 14, t = 0,   d = 0},
    {w = 8,  t = -12, d = 4},
    {w = 3,  t = 24,  d = -18},
    {w = 6,  t = 12,  d = -8},
    {w = 4,  t = -24, d = 2}
  }
  for i = 1, 5 do
    params:add_control("weight" .. i, i .. ") weight", controlspec.new(0, 100, "lin", 1, defaults[i].w, ""))
    params:add_control("mididiff" .. i, i .. ") tuning", controlspec.new(-48, 48, "lin", 1, defaults[i].t, "st"))
    params:add_control("vdb" .. i, i .. ") level", controlspec.new(-48, 24, "lin", 0.5, defaults[i].d, "dB"))
    HIDDEN[#HIDDEN + 1] = "weight" .. i
    HIDDEN[#HIDDEN + 1] = "mididiff" .. i
    HIDDEN[#HIDDEN + 1] = "vdb" .. i
  end

  params:add_group("grains_bounds", "PER VOICE", NV * 4)
  for i = 1, NV do
    params:add_control(PID[i].bstart, i .. " start", controlspec.new(0, 100, "lin", 0.2, 0, "%"))
    params:add_control(PID[i].bwidth, i .. " width", controlspec.new(0, 100, "lin", 0.2, 100, "%"))
    params:set_action(PID[i].bstart, function() trim_width(i) end)
    params:set_action(PID[i].bwidth, function() trim_width(i) end)
    params:add_control(PID[i].vol, i .. " volume", controlspec.new(Shuffle.VOL_MIN_DB, Shuffle.VOL_MAX_DB, "lin", 0.5, -6, "dB")) params:set_action(PID[i].vol, function() Shuffle.vol:touched(i) push_voices() end)
    params:add_number(PID[i].tune, i .. " pitch", Shuffle.PITCH_LO, Shuffle.PITCH_HI, 0) params:set_action(PID[i].tune, function() Shuffle.pitch:touched(i) push_voices() end)
    for _, k in ipairs({"bstart", "bwidth", "vol", "tune"}) do
      HIDDEN[#HIDDEN + 1] = PID[i][k]
    end
  end

  params:add_group("grains_reverb", "R3VERB", 1)
  params:add_taper("reverb_mix", "Mix", -40, 18, -40, 0, "dB") params:set_action("reverb_mix", nrev_set_mix)

  params:add_group("grains_delay", "DELAY", 9)
  params:add_control("d_mix", "Mix", controlspec.new(0, 100, "lin", 1, 0, "%")) params:set_action("d_mix", function(x) engine.d_mix(x * 0.01) end)
  params:add_control("d_time", "Time", controlspec.new(0.02, 5, "exp", 0, 0.5, "s")) params:set_action("d_time", function(x) engine.d_time(x) end)
  params:add_control("d_fb", "Feedback", controlspec.new(0, 120, "lin", 1, 40, "%")) params:set_action("d_fb", function(x) engine.d_fb(x * 0.01) end)
  params:add_control("d_lpf", "LPF", controlspec.new(20, 20000, "exp", 1, 7500, "Hz")) params:set_action("d_lpf", function(x) engine.d_lpf(x) end)
  params:add_control("d_hpf", "HPF", controlspec.new(20, 20000, "exp", 1, 200, "Hz")) params:set_action("d_hpf", function(x) engine.d_hpf(x) end)
  params:add_control("d_wdepth", "Mod Depth", controlspec.new(0, 100, "lin", 1, 25, "%")) params:set_action("d_wdepth", function(x) engine.d_wdepth(x * 0.01) end)
  params:add_control("d_wrate", "Mod Freq", controlspec.new(0, 20, "lin", 0.1, 2, "Hz")) params:set_action("d_wrate", function(x) engine.d_wrate(x) end)
  params:add_control("d_stereo", "Ping-Pong", controlspec.new(0, 100, "lin", 1, 20, "%")) params:set_action("d_stereo", function(x) engine.d_stereo(x * 0.01) end)
  params:add_control("d_duck", "Ducking", controlspec.new(0, 100, "lin", 1, 17, "%")) params:set_action("d_duck", function(x) engine.d_duck(x * 0.01) end)

  params:add_group("grains_shimmer", "SHIMMER", 8)
  params:add_control("sh_mix", "Mix", controlspec.new(0, 100, "lin", 1, 0, "%")) params:set_action("sh_mix", function(x) engine.sh_mix(x * 0.01) end)
  params:add_option("sh_mod", "Mix Mod", {"off", "on"}, 1) params:set_action("sh_mod", function(x) engine.sh_mod(x - 1) end)
  params:add_option("sh_oct", "Pitch Shift", {"-2 oct", "-1 oct", "0", "+1 oct", "+2 oct"}, 4) params:set_action("sh_oct", function(x) engine.sh_oct(({0.25, 0.5, 1, 2, 4})[x]) end)
  params:add_control("sh_pitchv", "Variance", controlspec.new(0, 100, "lin", 1, 2, "%")) params:set_action("sh_pitchv", function(x) engine.sh_pitchv(x * 0.01) end)
  params:add_control("sh_lowpass", "LPF", controlspec.new(20, 20000, "lin", 1, 13000, "Hz")) params:set_action("sh_lowpass", function(x) engine.sh_lowpass(x) end)
  params:add_control("sh_hipass", "HPF", controlspec.new(20, 20000, "exp", 1, 1400, "Hz")) params:set_action("sh_hipass", function(x) engine.sh_hipass(x) end)
  params:add_control("sh_fbdelay", "Delay", controlspec.new(0.01, 0.5, "lin", 0.01, 0.2, "s")) params:set_action("sh_fbdelay", function(x) engine.sh_fbdelay(x) end)
  params:add_control("sh_fb", "Feedback", controlspec.new(0, 100, "lin", 1, 20, "%")) params:set_action("sh_fb", function(x) engine.sh_fb(x * 0.01) end)

  params:add_group("grains_dimension", "STEREO", 4)
  params:add_control("m_width", "Width", controlspec.new(0, 200, "lin", 1, 100, "%")) params:set_action("m_width", function(v) engine.m_width(v / 100) end)
  params:add_control("dimension_mix", "Dimension", controlspec.new(0, 100, "lin", 1, 0, "%")) params:set_action("dimension_mix", function(x) engine.dimension_mix(x * 0.01) end)
  params:add_option("haas", "Haas Effect", {"off", "on"}, 1) params:set_action("haas", function(x) engine.haas(x - 1) end)
  params:add_taper("rspeed", "Rotation", 0, 1, 0, 1, "Hz") params:set_action("rspeed", function(v) engine.rspeed(v) end)

  params:add_group("grains_tape", "TAPE", 8)
  params:add_option("tape_mix", "Analog", {"off", "on"}, 1) params:set_action("tape_mix", function(x) engine.tape_mix(x - 1) end)
  params:add_control("shaper_mix", "Shaper drive", controlspec.new(0, 100, "lin", 1, 0, "%")) params:set_action("shaper_mix", function(v) engine.shaper_mix(v * 0.01) end)
  params:add_control("wobble_mix", "Wobble", controlspec.new(0, 100, "lin", 1, 0, "%")) params:set_action("wobble_mix", function(v) engine.wobble_mix(v * 0.01) end)
  params:add_control("wobble_amp", "Wow Depth", controlspec.new(0, 100, "lin", 1, 20, "%")) params:set_action("wobble_amp", function(v) engine.wobble_amp(v * 0.01) end)
  params:add_control("wobble_rpm", "Wow Speed", controlspec.new(30, 90, "lin", 1, 33, "rpm")) params:set_action("wobble_rpm", function(v) engine.wobble_rpm(v) end)
  params:add_control("flutter_amp", "Flutter Depth", controlspec.new(0, 100, "lin", 1, 35, "%")) params:set_action("flutter_amp", function(v) engine.flutter_amp(v * 0.01) end)
  params:add_control("flutter_freq", "Flutter Speed", controlspec.new(3, 30, "lin", 0.01, 6, "Hz")) params:set_action("flutter_freq", function(v) engine.flutter_freq(v) end)
  params:add_control("flutter_var", "Flutter Var", controlspec.new(0.1, 10, "lin", 0.01, 2, "Hz")) params:set_action("flutter_var", function(v) engine.flutter_var(v) end)

  params:add_group("grains_eq", "EQ", 4)
  params:add_control("eq_low", "Bass", controlspec.new(-20, 20, "lin", 0.5, 0, "dB")) params:set_action("eq_low", function(v) engine.eq_low(v) end)
  params:add_control("eq_mid", "Mid", controlspec.new(-20, 20, "lin", 0.5, 0, "dB")) params:set_action("eq_mid", function(v) engine.eq_mid(v) end)
  params:add_control("eq_high", "Treble", controlspec.new(-20, 20, "lin", 0.5, 0, "dB")) params:set_action("eq_high", function(v) engine.eq_high(v) end)
  params:add_control("tilt", "Tilt", controlspec.new(-1, 1, "lin", 0.01, 0, "")) params:set_action("tilt", function(x) engine.tilt(x * 12) end)

  params:add_group("grains_tone", "FILTER", 3)
  params:add_control("cutoff", "LPF", controlspec.new(20, 20000, "exp", 1, 20000, "Hz"))
  params:add_control("res", "Resonance", controlspec.new(0, 100, "lin", 1, 20, "%"))
  params:add_control("vhpf", "HPF", controlspec.new(20, 800, "exp", 1, 20, "hz"))

  params:add_group("grains_bitcrush", "BITCRUSH", 4)
  params:add_control("bc_mix", "Mix", controlspec.new(0, 100, "lin", 1, 0, "%")) params:set_action("bc_mix", function(v) engine.bc_mix(v * 0.01) end)
  params:add_option("bc_mod", "Mix Mod", {"off", "on"}, 1) params:set_action("bc_mod", function(x) engine.bc_mod(x - 1) end)
  params:add_taper("bc_rate", "Rate", 1, 48000, 4500, 3, "Hz") params:set_action("bc_rate", function(v) engine.bc_rate(v) end)
  params:add_taper("bc_bits", "Bits", 1, 24, 14, 1, "") params:set_action("bc_bits", function(v) engine.bc_bits(v) end)

  params:add_group("grains_wavefold", "WAVEFOLD", 3)
  params:add_control("wf_mix", "Mix", controlspec.new(0, 100, "lin", 1, 0, "%")) params:set_action("wf_mix", function(v) engine.wf_mix(v * 0.01) end)
  params:add_control("wf_drive", "Drive", controlspec.new(0, 100, "lin", 1, 75, "%")) params:set_action("wf_drive", function(v) engine.wf_drive(v * 0.01) end)
  params:add_control("wf_sym", "Symmetry", controlspec.new(0, 100, "lin", 1, 0, "%")) params:set_action("wf_sym", function(v) engine.wf_sym(v * 0.01) end)

  params:add_group("grains_reso", "RESONATE", 4)
  params:add_control("reso_mix", "Mix", controlspec.new(0, 100, "lin", 1, 0, "%")) params:set_action("reso_mix", function(v) engine.reso_mix(v * 0.01) reso_update() end)
  params:add_control("reso_decay", "Decay", controlspec.new(0.01, 5, "exp", 0, 2, "s")) params:set_action("reso_decay", function(v) engine.reso_decay(v) end)
  params:add_number("reso_root", "Root", 24, 128, 48, function(p) return MusicUtil.note_num_to_name(p:get(), true) end) params:set_action("reso_root", function() reso_update() end)
  params:add_option("reso_voicing", "Voicing", RESO_NAMES, 2) params:set_action("reso_voicing", function(v) reso_voicing(v) reso_update() end)

  params:add_group("grains_glitch", "GLITCH", 8)
  params:add_control("gl_ratio", "Glitch", controlspec.new(0, 100, "lin", 1, 0, "%")) params:set_action("gl_ratio", function(v) engine.gl_ratio(v * 0.01) end)
  params:add_control("gl_mix", "Mix", controlspec.new(0, 100, "lin", 1, 100, "%")) params:set_action("gl_mix", function(v) engine.gl_mix(v * 0.01) end)
  params:add_taper("gl_prob", "Frequency", 0.1, 20, 5, 1, "Hz") params:set_action("gl_prob", function(v) engine.gl_prob(v) end)
  params:add_control("gl_min", "Min Length", controlspec.new(10, 500, "lin", 1, 75, "ms")) params:set_action("gl_min", function(v) engine.gl_min(v * 0.001) end)
  params:add_control("gl_max", "Max Length", controlspec.new(20, 500, "lin", 1, 200, "ms")) params:set_action("gl_max", function(v) engine.gl_max(v * 0.001) end)
  params:add_number("gl_stutters", "Max Stutters", 2, 20, 5) params:set_action("gl_stutters", function(v) engine.gl_stutters(v) end)
  params:add_control("gl_rev", "Reverse Chance", controlspec.new(0, 100, "lin", 1, 0, "%")) params:set_action("gl_rev", function(v) engine.gl_rev(v * 0.01) end)
  params:add_control("gl_pitch", "Pitch Chance", controlspec.new(0, 100, "lin", 1, 0, "%")) params:set_action("gl_pitch", function(v) engine.gl_pitch(v * 0.01) end)

  params:add_group("grains_morph", "MORPH", 3)
  params:add_control("morph", "Morph", controlspec.new(0, 100, "lin", 0.5, 0, "%")) params:set_action("morph", function(v) Morph.set(v * 0.01) dirty = true end)
  params:add_binary("do_store_a", "Store A", "trigger", 0) params:set_action("do_store_a", function(v) if v == 1 then Morph.store(1) params:set("morph", 0) end end)
  params:add_binary("do_store_b", "Store B", "trigger", 0) params:set_action("do_store_b", function(v) if v == 1 then Morph.store(2) params:set("morph", 100) end end)

  params:add_group("grains_gen", "RANDOMIZE", 8)
  params:add_binary("do_dice", "Randomize!", "trigger", 0) params:set_action("do_dice", function(v) if v == 1 then dice() end end)
  params:add_binary("do_reseed", "Reseed Voices", "trigger", 0) params:set_action("do_reseed", function(v) if v == 1 then reseed_voices() end end)
  params:add_number("lseed", "layer order", 1, 9999, 1) params:set_action("lseed", function() push_population() dirty = true end)
  for _, k in ipairs({"tune", "motion", "space", "shape", "voice"}) do
    params:add_option("lock_" .. k, k, {"roll", "hold"}, 1)
  end

  params:add_group("grains_bounce", "RECORD", 3)
  params:add_control("bounce_len", "Loop Length", controlspec.new(1, 60, "lin", 0.5, 8, "s"))
  params:add_control("bounce_xf", "Crossfade", controlspec.new(0.1, 5, "lin", 0.1, 1, "s"))
  params:add_binary("do_bounce", "Record Loop", "trigger", 0) params:set_action("do_bounce", function(v) if v == 1 then start_bounce() end end)

  params:add_group("grains_hold", "FREEZE / LOCK", NV * 2 + 1)
  params:add_binary("freeze_all", "Freeze All", "toggle", 0) params:set_action("freeze_all", freeze_refresh)
  for i = 1, NV do
    params:add_binary("freeze" .. i, i .. " freeze", "toggle", 0) params:set_action("freeze" .. i, freeze_refresh)
    params:add_binary("lock_v" .. i, i .. " lock", "toggle", 0) params:set_action("lock_v" .. i, lock_refresh)
  end  
  
  params:add_group("grains_src", "SOURCE", NV + 2)
  for n = 1, NV do
    params:add_binary("do_load" .. n, "Load " .. n .. " Random", "trigger", 0) params:set_action("do_load" .. n, function(v) if v == 1 then load_n(n) end end)
  end
  params:add_file("source", "Folder", _path.tape) params:set_action("source", function() scanned_dir = nil end)
  params:add_control("chunk", "Slice Length", controlspec.new(2, 60, "lin", 0.5, 15, "s"))

  for _, p in ipairs(VOICE_PARAMS) do
    params:set_action(p[2], function()
      if not dicing then ovr_clear(p[2]) end
      push_one(p)
    end)
  end

  for _, id in ipairs({"level", "tuning", "spread", "chord", "variance", "cutoff", "motionrate", "ampfloor"}) do
    params:set_action(id, function()
      if not dicing then ovr_clear(id) end
      push_voices()
    end)
  end

  morph_last = #params.params
  for _, id in ipairs(HIDDEN) do params:hide(id) end
end

local function setup_osc()
  osc.event = function(path, args)
    if path == "/grains/state" then
      for i = 1, nva do
        local pos, pc = S.pos[i], poscol[i]
        local live = S.on[i]
        local base = (i - 1) * NL
        for L = 1, (S.nl[i] or 0) do
          local p = args[base + L] or 0
          pos[L] = p
          if live then
            local k = floor(p * CW)
            if pc[L] ~= k then pc[L] = k dirty = true end
          end
        end
      end
      return
    end
    dirty = true
    if path == "/grains/waveform" then
      local v = (args[1] or 0) + 1
      if v < 1 or v > NV then return end
      local raw, mx = {}, 0
      for c = 0, RAW - 1 do
        local x = args[c + 2] or 0
        raw[c] = x
        if x > mx then mx = x end
      end
      if mx > 0 then
        for c = 0, RAW - 1 do raw[c] = sqrt(raw[c] / mx) end
      else
        for c = 0, RAW - 1 do raw[c] = 0 end
      end
      S.raw[v] = raw
      S.wf[v] = matrix.wave(raw)
      S.loaded[v] = true
      xf_in(v, S.wf[v])
    elseif path == "/grains/fail" then
      local v = (args[1] or 0) + 1
      if v >= 1 and v <= NV then retry_voice(v) end
    elseif path == "/grains/bounce" then
      bounce_until = 0
    end
  end
end

function redraw()
  if installer_screen() then installer:redraw() return end
  screen.clear()
  S.sel = sel
  matrix.draw(S)
  local now = util.time()
  if volbar.frac and (now - volbar.t) < POP_DUR then
    matrix.volbar(volbar.frac)
  elseif morph_on then
    matrix.morphbar(Morph.pos)
  end
  if pop.kind and (now - pop.t) < POP_DUR then
    if pop.kind == "fx" then
      matrix.fxpopup(pop.txt)
    elseif pop.kind == "tilt" then
      matrix.tilteq(params:get("tilt"))
    elseif pop.kind == "hpf" then
      matrix.hpf(params:get("vhpf"))
    else
      matrix.filter(params:get("cutoff"), params:get("res") * 0.01)
    end
  end
  if bounce_until > 0 then matrix.fxpopup("recording...") end
  screen.update()
end

local function edit(suffix, d)
  if sel < 1 then return end
  params:delta(PID[sel][suffix], d)
end

local COARSE = {density = 5, layers = 8}
local coarse_acc = {}
local function coarse(id, d)
  local step = COARSE[id] or 4
  local t = floor((coarse_acc[id] or 0) + d)
  local n = floor(abs(t) / step)
  if t < 0 then n = -n end
  coarse_acc[id] = t - n * step
  return n
end

local function pop_show(kind, txt)
  pop.kind, pop.txt, pop.t = kind, txt, util.time()
  dirty = true
end

local function level_delta(d)
  params:set("level", clamp(params:get("level") + d * LEVEL_STEP_DB, DB_FLOOR, LEVEL_MAX_DB))
  volbar.frac, volbar.t = vol_frac(params:get("level"), LEVEL_MAX_DB), util.time()
  dirty = true
end

local FX_MAP    = {"reverb_mix", "d_mix", "sh_mix"}
local FX_LABELS = {"reverb", "delay", "shimmer"}

local function morph_toggle()
  morph_on = not morph_on
  dirty = true
end

local function toggle_param(id)
  params:set(id, params:get(id) == 0 and 1 or 0)
  dirty = true
end

local function freeze_voice_toggle()
  if sel < 1 then return end
  toggle_param("freeze" .. sel)
end

local function freeze_all_toggle()
  toggle_param("freeze_all")
end

local function lock_voice_toggle()
  if sel < 1 then return end
  toggle_param("lock_v" .. sel)
end

local function gesture_id()
  return (key_state[1] and "1" or "") .. (key_state[2] and "2" or "") .. (key_state[3] and "3" or "")
end

local hold_due, hold_act

local function mark_key_interaction()
  if key_gesture then key_gesture.fired = true end
  hold_due = nil
end

local function step_sel(d)
  dirty = true
  if nva < 1 then sel = 0 return end
  if sel < 1 then sel = 1 return end
  sel = ((sel - 1 + d) % nva) + 1
end

local KEY_COMBOS = {
  ["1"]   = {long = function() morph_toggle() end},
  ["2"]   = {short = function() step_sel(-1) end},
  ["3"]   = {short = function() step_sel(1) end},
  ["12"]  = {short = function() load_n(nva < 1 and DEFAULT_NV or nva) end,
             long  = function() freeze_voice_toggle() end},
  ["13"]  = {short = function() dice() end,
             long  = function() freeze_all_toggle() end},
  ["23"]  = {short = function() lock_voice_toggle() end},
  ["123"] = {short = function() reseed_voices() end}
}

local function handle_key_press()
  for id in pairs(COARSE) do coarse_acc[id] = 0 end
  local t = util.time()
  key_gesture = {id = gesture_id(), press_time = t, fired = false}
  local combo = KEY_COMBOS[key_gesture.id]
  hold_act = combo and combo.long
  hold_due = hold_act and (t + LONGPRESS) or nil
end

local function hold_tick()
  if hold_due and util.time() >= hold_due then
    hold_due = nil
    local g = key_gesture
    if g and not g.fired then
      g.fired = true
      hold_act()
    end
  end
end

local function handle_key_release()
  hold_due = nil
  local g = key_gesture
  if g and not g.fired then
    g.fired = true
    local combo = KEY_COMBOS[g.id]
    if combo and combo.short then combo.short() end
  end
  local id = gesture_id()
  if id == "" then
    key_gesture = nil
  else
    key_gesture = {id = id, press_time = g and g.press_time or util.time(), fired = true}
  end
end

function enc(n, d)
  if installer_screen() then return end
  local k1, k2, k3 = key_state[1], key_state[2], key_state[3]
  dirty = true

  if k1 or k2 or k3 then
    mark_key_interaction()
  end

  if k2 and k3 and not k1 then
    local fx = FX_MAP[n]
    if fx then
      params:delta(fx, d)
      local v = params:get(fx)
      pop_show("fx", FX_LABELS[n] .. ": " ..
        ((n == 1) and fast_db(v) or string.format("%d%%", floor(v + 0.5))))
    end

  elseif k1 and k2 and not k3 then
    if n == 1 then
      params:delta("tilt", d)
      pop_show("tilt")
    elseif n == 2 then
      params:delta("vhpf", d)
      pop_show("hpf")
    else
      params:delta("cutoff", d)
      pop_show("filt")
    end

  elseif not k1 and k2 and not k3 and n == 1 then
    Shuffle.vol:kick(d)

  elseif not k1 and not k2 and k3 and n == 1 then
    Shuffle.pitch:kick(d)

  elseif not k1 and (k2 or k3) then
    if sel < 1 then return end
    local sh = k2 and Shuffle.vol or Shuffle.pitch
    if n == 2 then
      sh:nudge(sel, d)
    elseif n == 3 then
      for i = 1, nva do
        if i ~= sel then sh:nudge(i, d) end
      end
    end

  elseif k1 then
    if n == 1 then
      local step = coarse("density", d)
      if step ~= 0 then params:delta("density", step) end
    elseif n == 2 then
      local step = coarse("layers", d)
      if step ~= 0 and sel >= 1 then nudge_voice_layers(sel, step) end
    else
      params:delta("motionrate", d)
      pop_show("fx", string.format("motion: %.2fx", params:get("motionrate")))
    end

  else
    if n == 1 then
      if morph_on then
        params:delta("morph", d * 3)
      else
        level_delta(d)
      end
    elseif n == 2 then
      edit("bstart", d)
    else
      edit("bwidth", d)
    end
  end
end

function key(n, z)
  dirty = true
  if installer_screen() then
    if boot_screen and n == 2 and z == 1 and not installer.installing and not installer.ready_to_restart then
      boot_screen = false
    else
      installer:key(n, z)
    end
    return
  end
  if n == 2 and z == 1 and not key_state[2] then Shuffle.vol:reset() end
  if n == 3 and z == 1 and not key_state[3] then Shuffle.pitch:reset() end
  key_state[n] = (z == 1)
  if z == 1 then handle_key_press() else handle_key_release() end
end

function init()
  math.randomseed(floor(util.time() * 1000) % 1000000)
  for i = 1, NV do
    pits[i] = Pit.new(LCAPS[1] * 2)
    S.loaded[i] = false
    S.on[i] = nil
    S.pos[i] = {}
    S.ls[i], S.le[i] = {}, {}
    S.b0[i], S.b1[i] = 0, 1
    S.nl[i] = 0
    last_win[i] = {}
    cls[i], cle[i] = {}, {}
    lastcol[i], poscol[i] = {}, {}
    for L = 1, NL do
      S.pos[i][L] = 0
      S.ls[i][L], S.le[i][L] = 0, 1
    end
  end
  if pcall(function() return params:lookup_param("reverb") end) then
    initial_reverb = params:get("reverb")
    params:set("reverb", 1)
  end
  if pcall(function() return params:lookup_param("rev_eng_input") end) then
    initial_rev_send = params:get("rev_eng_input")
  end
  reroll_seeds()
  setup_params()
  setup_osc()
  params:set("lseed", math.random(9999))
  params:bang()
  refresh_layout()
  Morph.init(morph_first, morph_last, morph_skip)
  params.action_write = function(filename) pset_write(filename .. ".gstate") end
  params.action_read = pset_read
  params.action_delete = function(filename)
    for _, ext in ipairs(PSET_EXT) do os.remove(filename .. ext) end
  end
  push_voice_params()
  push_per_voice()
  push_population()
  engine.report_rate(REPORT_RATE)
  load_random(DEFAULT_NV)
  ui_metro = metro.init()
  ui_metro.time = 1 / FPS
  ui_metro.event = function()
    physics_tick()
    hold_tick()
    if frz_any then
      blink_n = blink_n + 1
      if blink_n >= BLINK_FRAMES then
        blink_n = 0
        S.blink = not S.blink
        dirty = true
      end
    end
    if pop.kind or volbar.frac then
      local now = util.time()
      if pop.kind and (now - pop.t) >= POP_DUR then
        pop.kind = nil
        dirty = true
      end
      if volbar.frac and (now - volbar.t) >= POP_DUR then
        volbar.frac = nil
        dirty = true
      end
    end
    if bounce_until > 0 and util.time() >= bounce_until then
      bounce_until = 0
      dirty = true
    end
    if installer_screen() then dirty = true end
    if dirty then
      dirty = false
      redraw()
    end
  end
  ui_metro:start()
  clock.run(function()
    clock.sleep(3)
    installer:check()
  end)
end

function cleanup()
  if ui_metro then ui_metro:stop() end
  if initial_rev_send then params:set("rev_eng_input", initial_rev_send) end
  if initial_reverb then params:set("reverb", initial_reverb) end
  osc.event = nil
end