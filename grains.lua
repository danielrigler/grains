--
--
--
--          grains v0.10
--           @dddstudio
--
--
--
-- K1+E1 Density - Start Here
-- E1 Master Volume
-- K2/K3 Navigate Voices
-- E2/E3 Set Boundaries
-- K1+K2 Randomize
-- K1+K3 Load Random
-- K2+K3 Lock Selected Voice
-- K2+E1 Shuffle Volumes
-- K2+E2 Selected Volume
-- K2+E3 Other Volumes
-- K3+E1 Shuffle Pitches
-- K3+E2 Selected Pitch
-- K3+E3 Other Pitches
-- K1+E2 Add/Remove Layers
-- K1+E3 Add/Remove Voices
-- K1+K3+E1 Tuning
-- K1+K3+E2 Energy
-- K1+K3+E3 Pitch Change
-- K1+K2+K3 Reseed Voices
-- K2+K3+E1/E2/E3 Effect Mix
-- K1+K2+E1 Tilt EQ
-- K1+K2+E2 HPF
-- K1+K2+E3 LPF
-- K1 hold: Morph Toggle
-- K2 hold: Record to Voice
-- K3 hold: Record to New Voice
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

local MusicUtil = require("musicutil")
local Installer = include("grains/lib/installer/installer")
local installer = Installer:new{requirements = {"AnalogTape"}, zip = "https://github.com/schollz/portedplugins/releases/download/v0.4.6/PortedPlugins-RaspberryPi.zip"}
local boot_screen = not installer:ready()
local function installer_screen() return boot_screen or installer:pending() end
engine.name = installer:ready() and "grains" or nil
local tape    = include("grains/lib/tape")
local AUDIO_DIR = "/home/we/dust/audio/"
local Pit     = include("grains/lib/pit")
local Dice    = include("grains/lib/dice")
local matrix  = include("grains/lib/matrix")
local font    = include("grains/lib/font")
local Morph   = include("grains/lib/morph")
local Sync    = include("grains/lib/sync")
local Shuffle = include("grains/lib/shuffle")
local Reso    = include("grains/lib/reso")
local Keys    = include("grains/lib/keys")
local clamp   = include("grains/lib/util").clamp
local NV = 6
local NL = 14
local DEFAULT_NV = 4
local LCAPS = {14, 10, 6, 5, 4, 4}
local RAW = matrix.RAW
local CW = matrix.CW
local SPAN = Pit.SPAN
local FPS = 60
local TSTEP = 15 / FPS
local phys_acc = 0
local ENERGY_BASE = 200
local RATE_OFF = 0.05
local REPORT_RATE = 30
local sel = 0
local key_state = Keys.state
local LONGPRESS = 1
local POP_DUR = 0.5
local pop = {kind = nil, txt = nil, t = 0}
local volbar = {frac = nil, t = 0}
local REC = {
  dir = AUDIO_DIR .. "grains/",
  min = 0.3, msg_dur = 1.0, save_wait = 10,
  norm_db = -6, quiet = 0.0005, meter_floor = -48, whole = 3600,
  confirm_dur = 10, kinds = {loop = "grains_", input = "in_"},
  state = nil, t0 = 0, level = 0, peak = 0,
  path = nil, target = 1, tick = -1, txt = nil, wait = 0,
  bars = {0, 0}, sub = "", shown = -1
}
local DB_FLOOR = -60
local LEVEL_MAX_DB = 6
local LEVEL_STEP_DB = 1
local VOL_DEFAULT_DB = -6
local LPF_OFF, HPF_OFF = 20000, 20
local NOFILTER_CHANCE = 50
local initial_reverb, initial_rev_send, initial_monitor_level
local ui_metro
local pits = {}
local morph_on = false
local MORPH_SKIP = {morph = true, source = true, chunk = true, lseed = true, level = true}

local function morph_skip(id)
  return (MORPH_SKIP[id]
      or id:find("^morph") or id:find("^do_")
      or id:find("^lock_") or id:find("^freeze") or id:find("^rec_")) ~= nil
end
local morph_first, morph_last

local nva, lcap = -1, -1

local S = {
  wf = {}, raw = {}, pos = {}, on = {}, loaded = {},
  ls = {}, le = {}, files = {},
  b0 = {}, b1 = {}, sel = 0, nl = {},
  volf = {},
  pitchf = {},

  pin = {}
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
local SCAN_MAX_FILES, SCAN_MAX_DEPTH = 2000, 6
local scanned_dir = nil
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

local VSEED_FIELDS = {"tune", "mr", "cut", "lvl", "floor"}
local function reroll_seeds()
  for i = 1, NV do vseed[i] = vseed[i] or {} end
  for _, f in ipairs(VSEED_FIELDS) do
    local vals = stratified(NV, -1, 1)
    for i = 1, NV do
      if not vlocked[i] then vseed[i][f] = vals[i] end
    end
  end
end

local bounce_until = 0

local function start_bounce()
  if bounce_until > 0 then return end
  local d, xf = params:get("bounce_len"), params:get("bounce_xf")
  bounce_until = util.time() + d + xf + 0.5
  engine.bounce(d, "grains_" .. os.date("%y%m%d_%H%M%S"), xf)
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
  local was = sent[key]
  if was and abs(was - val) < 1e-6 then return end
  sent[key] = val
  engine.set_all(key, val)
end

local sent_one = {}
local function eset_one(i, key, val)
  local t = sent_one[key]
  if not t then t = {} sent_one[key] = t end
  local was = t[i]
  if was and abs(was - val) < 1e-6 then return end
  t[i] = val
  engine.set_one(i - 1, key, val)
end

local TUNE = {spread_st = 24, lspread = 1, lrates = {}}

function TUNE.ratio(st) return 2 ^ (st / 12) end
function TUNE.amp(db) return 10 ^ (db / 20) end
function TUNE.layer(st) return TUNE.ratio(floor(st * TUNE.lspread + 0.5)) end

local VOICE_PARAMS = {
  {"revprob",  "reverse",  function(v) return v * 0.01 end},
  {"rateSlew", "rateslew"},
  {"panwidth", "panwidth", function(v) return v * 0.01 end},
  {"res",      "res",      function(v) return (100 - v) * 0.007 end},
  {"hpf",      "vhpf"}
}
for i = 1, 5 do
  VOICE_PARAMS[#VOICE_PARAMS + 1] = {"weight" .. i, "weight" .. i}
  VOICE_PARAMS[#VOICE_PARAMS + 1] = {"lrate" .. i,  "mididiff" .. i, TUNE.layer}
  VOICE_PARAMS[#VOICE_PARAMS + 1] = {"lamp" .. i,   "vdb" .. i,      TUNE.amp}
end

for _, p in ipairs(VOICE_PARAMS) do
  if p[1]:find("^lrate") then TUNE.lrates[#TUNE.lrates + 1] = p end
end

local SCALARS = {"tuning", "chord", "spread", "variance", "motionrate", "pitchrate", "cutoff", "ampfloor"}
local DICE_GLOBALS = {}
for _, id in ipairs(SCALARS) do DICE_GLOBALS[#DICE_GLOBALS + 1] = id end
for _, p in ipairs(VOICE_PARAMS) do
  if p[2] ~= "res" then DICE_GLOBALS[#DICE_GLOBALS + 1] = p[2] end
end

local DICE_SET = {}
for _, id in ipairs(DICE_GLOBALS) do DICE_SET[id] = true end

local dicing = false
local ovr_n = 0

local function push_one(p)
  local key, id, xf = p[1], p[2], p[3]
  local g = params:get(id)
  local gval = xf and xf(g) or g
  if ovr_n == 0 then
    eset(key, gval)
    return
  end
  for i = 1, NV do
    local t = ovr[i]
    local hv = t and t[id]
    if hv == nil then
      eset_one(i, key, gval)
    else
      eset_one(i, key, xf and xf(hv) or hv)
    end
  end
end

local function push_voice_params()
  for _, p in ipairs(VOICE_PARAMS) do push_one(p) end
end

function TUNE.set_layer_spread(pct)
  TUNE.lspread = pct * 0.01
  for _, p in ipairs(TUNE.lrates) do push_one(p) end
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
  if n == 0 then drop_shadows() end
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
  local now = {}
  for k, id in ipairs(DICE_GLOBALS) do now[k] = params:get(id) end
  for i = 1, NV do
    if vlocked[i] then
      local t = ovr[i]
      if t == nil then t = {} ovr[i] = t end
      for k, id in ipairs(DICE_GLOBALS) do
        if t[id] == nil then t[id] = now[k] end
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
  local gspread = params:get("spread") * TUNE.spread_st / 100
  local gchord  = params:get("chord")
  local gmr     = params:get("motionrate")
  local gpr     = params:get("pitchrate")
  local gcut    = params:get("cutoff")
  local gflr    = params:get("ampfloor") / 100
  local lvl     = params:get("level")
  for i = 1, nva do
    local s = vseed[i]
    local pid = PID[i]
    local trim = LAYER_TRIM[act_nl[i]] or 0
    local ivol, itune = params:get(pid.vol), params:get(pid.tune)
    S.volf[i] = vol_frac(ivol, Shuffle.VOL_MAX_DB)
    S.pitchf[i] = clamp(itune / Shuffle.PITCH_HI, -1, 1)
    if s then
      local frz = vfrozen[i]

      local var, root, spread, chord, mr, pr, cut, flr =
            gvar, groot, gspread, gchord, gmr, gpr, gcut, gflr
      local h = ovr[i]
      if h then
        if h.variance   then var    = h.variance / 100 end
        if h.tuning     then root   = h.tuning         end
        if h.spread     then spread = h.spread * TUNE.spread_st / 100 end
        if h.chord      then chord  = h.chord          end
        if h.motionrate then mr     = h.motionrate     end
        if h.pitchrate  then pr     = h.pitchrate      end
        if h.cutoff     then cut    = h.cutoff         end
        if h.ampfloor   then flr    = h.ampfloor / 100 end
      end

      eset_one(i, "vrate", TUNE.ratio(root + Dice.snap(s.tune * spread, chord) + itune))

      local emod = 2 ^ (s.mr * var * 1.3)
      local m = (frz or mr <= RATE_OFF) and 0 or clamp(mr * emod, 0.02, 12)
      vmr[i] = m
      eset_one(i, "mrate", m)
      eset_one(i, "prate", (frz or pr <= RATE_OFF) and 0 or clamp(pr * emod, 0.02, 12))
      eset_one(i, "cutoff",   clamp(cut * 2 ^ (s.cut * var * 2.6), 90, LPF_OFF))
      local db = clamp(lvl + ivol + trim + s.lvl * var * 7, -100, 6)
      if lvl <= -59.5 or ivol <= -59.5 then db = -100 end
      eset_one(i, "vamp", TUNE.amp(db))
      eset_one(i, "ampfloor", clamp(flr + s.floor * var * 0.35, 0, 1))
    end
  end
end

local pop_dirty = true
local function push_population() pop_dirty = true end

local lord, lord_n, lord_key = {}, 0, nil
local lord_pend = nil
local prev_ord, ord_buf = {}, {}

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
  local d0 = floor(params:get("density"))
  local d = d0
  if d > lord_n then d = lord_n end

  local need, pin, free = nil, 0, 0
  for i = 1, nva do

    if vlocked[i] and S.files[i] then
      local p = S.pin[i]
      if p == nil then

        p = 0
        for k = 1, d do if lord[k] == i then p = p + 1 end end
        S.pin[i] = p
      end
      if p > lcap then p = lcap end
      need = need or {}
      need[i] = p
      pin = pin + p
    else
      free = free + lcap
    end
  end

  if need then
    local hi = pin + free
    if hi > lord_n then hi = lord_n end
    if d < pin then d = pin end
    if d > hi then d = hi end
    if d ~= d0 then

      params:set("density", d, true)
    end

    local room, nf, nb = d - pin, 0, 0
    for k = 1, lord_n do
      local v = lord[k]
      local take
      if need[v] then
        take = need[v] > 0
        if take then need[v] = need[v] - 1 end
      else
        take = room > 0
        if take then room = room - 1 end
      end
      if take then nf = nf + 1 ord_buf[nf] = v else nb = nb + 1 prev_ord[nb] = v end
    end
    for k = 1, nf do lord[k] = ord_buf[k] end
    for k = 1, nb do lord[nf + k] = prev_ord[k] end
  end

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

  if vlocked[i] and S.files[i] then
    local p0 = S.pin[i] or act_nl[i] or 0
    if p0 > lcap then p0 = lcap end
    local p = p0 + step
    if p < 0 then p = 0 elseif p > lcap then p = lcap end
    if p ~= p0 then
      S.pin[i] = p
      params:set("density", d + p - p0)
    end
    return
  end

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
      if on then
        local lw = last_win[i]
        for k = 1, lcap * 2 do lw[k] = nil end
      end
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
    if ovr[i] then
      for id, v in pairs(ovr[i]) do
        f:write(string.format("ovr %d %s %.9g\n", i, id, v))
      end
    end

    if S.files[i] and vlocked[i] and S.pin[i] then
      f:write(string.format("pin %d %d\n", i, S.pin[i]))
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

  elseif tag == "pin" and voice then
    local v = tonumber(tok[3])
    if v and v == v and v >= 0 and v <= NL then
      r.pin[voice] = floor(v)
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
  local r = {seed = {}, pit = {}, hold = {}, pin = {}}
  if not (pset_scan(fn .. ".gstate", r) or pset_scan_old(fn, r)) then return end
  for i = 1, NV do
    if r.seed[i] then vseed[i] = r.seed[i] end
    ovr[i] = (vlocked[i] and r.hold[i]) or nil

    S.pin[i] = vlocked[i] and (r.pin[i] or S.pin[i]) or nil
  end
  ovr_sync()
  push_voice_params()
  push_voices()
  if r.morph or r.mpos then
    Morph.settled(r.mpos)
    params:set("morph", Morph.pos * 100, true)
  end
  pset_pend = (r.geom or r.ord or next(r.pit)) and
    {geom = r.geom, ord = r.ord, pit = r.pit, pin = r.pin, t = util.time()} or nil
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
    if vlocked[i] then S.pin[i] = pd.pin and pd.pin[i] or nil end
  end
  push_population()
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
  local shown = (n >= NV) and NV or n + 1
  if S.shown ~= shown then
    S.shown = shown
    for i = 1, NV do
      if i <= shown then params:show(PID[i].file) else params:hide(PID[i].file) end
    end
    if _menu and type(_menu.rebuild_params) == "function" then
      _menu.rebuild_params()
    end
  end
  local cap = LCAPS[n] or (lcap > 0 and lcap) or LCAPS[1]
  if n == nva and cap == lcap then return end
  layout_busy = true
  local cap_changed = cap ~= lcap
  nva, lcap = n, cap

  if sel > nva then sel = (nva < 1) and 0 or nva end
  local nm = (n < 1 and 1 or n) * cap
  Morph.hold(function()
    params:lookup_param("density").max = nm
    params:set("density", clamp(floor(dfrac * nm + 0.5), 0, nm))
  end)
  for k = cap * 2 + 1, NL * 2, 2 do wbuf[k], wbuf[k + 1] = 0, 1 end
  for i = 1, NV do
    pits[i]:resize(cap * 2, (blo[i] or 0) * SPAN, (bhi[i] or 1) * SPAN)

    if cap_changed then last_win[i] = {} end
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
  engine.report_geom(n, cap)
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
    local b0, b1 = S.b0, S.b1
    if glide == 0 then
      for i = 1, NV do b0[i], b1[i] = blo[i], bhi[i] end
      gliding = false
    else
      for i = 1, NV do
        local x, y = b0[i], b1[i]
        b0[i] = x + (blo[i] - x) * GLIDE_K
        b1[i] = y + (bhi[i] - y) * GLIDE_K
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
        local window = pit.window
        local a, b = blo[i] * SPAN, bhi[i] * SPAN
        local m = vmr[i] or 1
        local w = bhi[i] - blo[i]
        if w < 0.05 then w = 0.05 elseif w > 1 then w = 1 end
        local energy = 0
        if m > 0 then
          energy = ENERGY_BASE * m * m
          if energy < 10 then energy = 10 end
          energy = energy * w
        end
        local vmax   = clamp(2.5 * m, 0.15, 10) * sqrt(w)
        for _ = 1, steps do pit:update(a, b, energy, vmax) end

        local lw = last_win[i]
        local changed = false
        for L = 1, nl do
          local st, en = window(pit, L)
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
            local st, en = window(pit, L)
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

local function load_voice(i, path, whole)
  S.files[i] = path
  dirty = true
  for L = 1, NL do S.pos[i][L] = 0 end
  xf_clear(i)
  S.loaded[i] = false
  S.wf[i], S.raw[i] = nil, nil
  params:set(PID[i].file, path, true)
  refresh_layout()
  engine.read(i - 1, path,
    whole and REC.whole or params:get("chunk"),
    whole and 0 or 1)
end

local function clear_voice(i)
  S.files[i] = nil
  S.pin[i] = nil
  xf_clear(i)
  S.loaded[i] = false
  S.wf[i], S.raw[i] = nil, nil
  tries[i] = 0
  for L = 1, NL do S.pos[i][L] = 0 end
  params:set(PID[i].file, AUDIO_DIR, true)
  engine.clear(i - 1)
end

function REC.finish(txt)
  REC.state = txt and "msg" or nil
  REC.txt = txt
  REC.wait = txt and (util.time() + REC.msg_dur) or 0
  dirty = true
end

function REC.free_slot()
  for i = 1, NV do
    if S.files[i] == nil then return i end
  end
  return nil
end

function REC.start(fresh)
  if REC.state then return end
  local name = "in_" .. os.date("%y%m%d_%H%M%S")
  if fresh then
    REC.target = REC.free_slot()
    if REC.target == nil then
      REC.finish("no free voices")
      return
    end
  else
    REC.target = sel >= 1 and sel or 1
  end
  REC.fresh = fresh or nil
  REC.path = REC.dir .. name .. ".wav"
  REC.t0, REC.level, REC.level_r, REC.peak, REC.tick = util.time(), 0, 0, 0, -1
  REC.shown = -2
  REC.metered = false
  REC.state = "rec"
  engine.rec_start(name,
    params:get("rec_max"),
    TUNE.amp(params:get("rec_gain")),
    params:get("rec_norm") == 2 and TUNE.amp(REC.norm_db) or 0,
    params:get("rec_src") - 1,
    params:get("rec_mon") <= DB_FLOOR and 0 or TUNE.amp(params:get("rec_mon")))
  dirty = true
end

function REC.stop()
  if REC.state ~= "rec" then return end
  local quiet = REC.metered and REC.peak < REC.quiet
  local bad = quiet or (util.time() - REC.t0) < REC.min
  engine.rec_stop(bad and 0 or 1)
  if bad then
    REC.finish(quiet and "no input" or "too short")
  else
    REC.state, REC.wait = "save", util.time() + REC.save_wait
    dirty = true
  end
end

function REC.frac(v)
  if v == nil or v <= 0 then return 0 end
  local db = 20 * math.log(v > 1e-5 and v or 1e-5) / math.log(10)
  return (db - REC.meter_floor) / -REC.meter_floor
end

function REC.list(prefix)
  local out = {}
  local ok, entries = pcall(util.scandir, REC.dir)
  if ok and entries then
    for _, e in ipairs(entries) do
      if e:sub(1, #prefix) == prefix and e:sub(-4):lower() == ".wav" then
        out[#out + 1] = e
      end
    end
  end
  return out
end

function REC.keep()
  local used = {}
  for i = 1, NV do
    local f = S.files[i]
    if f then used[f:match("[^/]+$") or f] = true end
  end
  if REC.path then used[REC.path:match("[^/]+$")] = true end
  local dir = norns and norns.state and norns.state.data
  if dir then
    local ok, entries = pcall(util.scandir, dir)
    if ok and entries then
      for _, e in ipairs(entries) do
        if e:sub(-5):lower() == ".pset" then
          local f = io.open(dir .. e, "r")
          if f then
            for line in f:lines() do
              for name in line:gmatch("([^/\"%s]+%.[Ww][Aa][Vv])") do used[name] = true end
            end
            f:close()
          end
        end
      end
    end
  end
  return used
end

function REC.sweep(kind, doit)
  local used = REC.keep()
  local gone, n = {}, 0
  for _, name in ipairs(REC.list(REC.kinds[kind])) do
    if not used[name] then
      n = n + 1
      gone[n] = name
    end
  end
  if not doit then return n end
  local k = 0
  for _, name in ipairs(gone) do
    if os.remove(REC.dir .. name) then
      k = k + 1
      print("grains: deleted " .. name)
    end
  end
  scanned_dir = nil
  return k
end

function REC.clean(kind)
  if REC.state or bounce_until > 0 then return end
  if _menu and type(_menu.set_mode) == "function" then _menu.set_mode(false) end
  local n = REC.sweep(kind, false)
  REC.kind = kind
  if n < 1 then
    REC.finish("nothing unused")
    return
  end
  REC.txt = string.format("delete %d?", n)
  REC.state, REC.wait = "confirm", util.time() + REC.confirm_dur
  dirty = true
end

function REC.confirm(yes)
  if REC.state ~= "confirm" then return end
  if not yes then REC.finish(nil) return end
  REC.state = nil
  REC.finish(REC.sweep(REC.kind, true) .. " deleted")
end

function REC.done(ok)
  if REC.state ~= "save" then return end
  if not ok then REC.finish("write failed") return end
  local i = REC.target
  if i < 1 or i > NV then i = 1 end
  if REC.fresh then
    params:set(PID[i].vol, VOL_DEFAULT_DB)
    params:set(PID[i].tune, 0)
    params:set(PID[i].bstart, 0)
    params:set(PID[i].bwidth, 100)
  end
  tries[i] = 0
  load_voice(i, REC.path, true)
  sel = i
  REC.finish(nil)
end

local function reset_volumes(slots)
  Shuffle.vol:reset()
  if slots then
    for _, i in ipairs(slots) do params:set(PID[i].vol, VOL_DEFAULT_DB) end
    return
  end
  for i = 1, NV do params:set(PID[i].vol, VOL_DEFAULT_DB) end
end

local MOVE = {params = {"file", "bstart", "bwidth", "vol", "tune"}, tables = nil}

local function slot_defaults(i)
  S.loaded[i] = false
  S.on[i] = nil
  S.wf[i], S.raw[i] = nil, nil
  S.files[i] = nil
  S.nl[i] = 0
  S.b0[i], S.b1[i] = 0, 1
  S.volf[i], S.pitchf[i] = nil, nil
  local pos, ls, le, tls, tle = {}, {}, {}, {}, {}
  S.pos[i], S.ls[i], S.le[i] = pos, ls, le
  cls[i], cle[i] = tls, tle
  lastcol[i], poscol[i] = {}, {}
  last_win[i] = {}
  for L = 1, NL do
    pos[L] = 0
    ls[L], le[L] = 0, 1
    tls[L], tle[L] = 0, 1
  end
  pits[i] = Pit.new((lcap > 0 and lcap or LCAPS[1]) * 2)
  xfp[i], xfw[i], xfx[i], xfy[i] = nil, nil, nil, nil
  ovr[i], vmr[i] = nil, nil
  S.pin[i] = nil
  blo[i], bhi[i] = 0, 1
  tries[i] = 0
  act_nl[i] = 0
  vseed[i] = {}
  for _, f in ipairs(VSEED_FIELDS) do
    vseed[i][f] = math.random() * 2 - 1
  end
end

local function move_slot(src, dst)
  if src == dst then return end

  if MOVE.tables == nil then
    MOVE.tables = {
      S.wf, S.raw, S.pos, S.on, S.loaded, S.ls, S.le, S.files,
      S.b0, S.b1, S.nl, S.volf, S.pitchf, S.pin,
      pits, xfp, xfw, xfx, xfy,
      cls, cle, lastcol, poscol, last_win,
      ovr, vseed, vmr, blo, bhi, tries, act_nl
    }
  end

  local pv = {}
  for _, k in ipairs(MOVE.params) do pv[k] = params:get(PID[src][k]) end
  local frz = params:get("freeze" .. src)
  local lck = params:get("lock_v" .. src)

  for _, t in ipairs(MOVE.tables) do t[dst] = t[src] end
  Shuffle.relocate(src, dst)
  slot_defaults(src)

  for _, k in ipairs(MOVE.params) do params:set(PID[dst][k], pv[k], true) end
  params:set(PID[src].file, AUDIO_DIR, true)
  params:set(PID[src].bstart, 0, true)
  params:set(PID[src].bwidth, 100, true)
  params:set(PID[src].vol, VOL_DEFAULT_DB, true)
  params:set(PID[src].tune, 0, true)

  params:set("freeze" .. dst, frz, true)
  params:set("lock_v" .. dst, lck, true)
  params:set("freeze" .. src, 0, true)
  params:set("lock_v" .. src, 0, true)
  freeze_refresh()
  lock_refresh()

  for _, k in ipairs(MOVE.params) do
    if k ~= "file" then Morph.move(PID[src][k], PID[dst][k]) end
  end

  for _, t in pairs(sent_one) do t[dst], t[src] = t[src], nil end

  engine.move(src - 1, dst - 1)

  for k = 1, lord_n do
    if lord[k] == src then lord[k] = dst elseif lord[k] == dst then lord[k] = src end
  end
  lord_pend = nil

  if sel == src then sel = dst end
  if S.wf[dst] then xf_in(dst, S.wf[dst]) end
  push_population()
  push_voices()
  dirty = true
end

local function locked_voice(i)
  return S.files[i] ~= nil and vlocked[i] ~= nil
end

local function locked_count()
  local n = 0
  for i = 1, NV do
    if locked_voice(i) then n = n + 1 end
  end
  return n
end

local function keep_for(n)
  local take, nlk = {}, 0
  for i = 1, NV do
    if locked_voice(i) then take[i] = true nlk = nlk + 1 end
  end
  if n < nlk then n = nlk end
  local room = n - nlk
  for i = 1, NV do
    if S.files[i] and not take[i] and room > 0 then
      take[i] = true
      room = room - 1
    end
  end
  local keep, k = {}, 0
  for i = 1, NV do
    if take[i] then k = k + 1 keep[k] = i end
  end
  return keep, k, n
end

local function compact_to(keep, nk)
  local survive = {}
  for k = 1, nk do survive[keep[k]] = true end
  for i = 1, NV do
    if S.files[i] and not survive[i] then clear_voice(i) end
  end
  for k = 1, nk do
    if keep[k] ~= k then move_slot(keep[k], k) end
  end
end

local function clear_all()
  for i = 1, NV do clear_voice(i) end
  reset_volumes()

  for i = 1, NV do
    params:set("lock_v" .. i, 0, true)
    params:set("freeze" .. i, 0, true)
  end
  lock_refresh()
  freeze_refresh()

  refresh_layout()
  dirty = true
end

local function fresh_pool(roll)
  local used = {}
  for i = 1, NV do
    local f = S.files[i]
    if f and not (roll and roll[i]) then used[f] = true end
  end
  local pool = {}
  for _, f in ipairs(file_list) do
    if not used[f] then pool[#pool + 1] = f end
  end
  if #pool == 0 then return file_list end
  return pool
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
  if dir == nil or dir == "" or dir == "-" then dir = AUDIO_DIR end
  if dir:sub(-1) ~= "/" then dir = dir:match("^(.*/)") or AUDIO_DIR end
  if dir ~= scanned_dir then
    local capped, deepened
    file_list, capped, deepened = tape.scan(dir, SCAN_MAX_FILES, SCAN_MAX_DEPTH)
    local note = ""
    if capped then
      note = string.format(" (capped at %d -- point SOURCE at a subfolder to reach the rest)",
        SCAN_MAX_FILES)
    elseif deepened then
      note = string.format(" (stopped at %d folders deep)", SCAN_MAX_DEPTH)
    end
    print(string.format("grains: %d sample%s in %s%s",
      #file_list, #file_list == 1 and "" or "s", dir, note))
    scanned_dir = #file_list > 0 and dir or nil
  end
  return #file_list > 0
end

local function load_random_into(slots, scanned)
  local ns = #slots
  if ns < 1 then return end
  if not (scanned or scan_source()) then return end
  local target = {}
  for _, i in ipairs(slots) do target[i] = true end
  local chosen = tape.pick(fresh_pool(target), ns)
  layout_busy = true
  for k, i in ipairs(slots) do
    tries[i] = 0
    if chosen[k] then load_voice(i, chosen[k]) end
  end
  layout_busy = false
  refresh_layout()
end

local function load_random(n, scanned)
  n = clamp(floor(n or (nva < 1 and DEFAULT_NV or nva)), 1, NV)
  local slots = {}
  for i = 1, n do slots[i] = i end
  load_random_into(slots, scanned)
end

local function load_n(n, keep_vol)
  n = clamp(floor(n), 1, NV)

  local keep, nk, want = keep_for(n)
  n = want
  layout_busy = true
  compact_to(keep, nk)
  layout_busy = false

  local slots = {}
  for i = 1, n do
    if not locked_voice(i) then slots[#slots + 1] = i end
  end

  if not keep_vol then reset_volumes(slots) end

  if #slots < 1 then
    refresh_layout()
    dirty = true
    return
  end

  for _, i in ipairs(slots) do
    xf_clear(i)
    S.loaded[i] = false
    S.wf[i], S.raw[i] = nil, nil
  end
  dirty = true
  redraw()
  if not scan_source() then
    for _, i in ipairs(slots) do clear_voice(i) end
    refresh_layout()
    return
  end
  load_random_into(slots, true)
end

local src = {}

function src.reslice()
  if count_files() < 1 then return end
  layout_busy = true
  for i = 1, NV do

    local path = not locked_voice(i) and S.files[i] or nil
    if path then
      tries[i] = 0
      load_voice(i, path)
    end
  end
  layout_busy = false
  refresh_layout()
  dirty = true
end

function src.set_count(n)
  n = clamp(floor(n), 1, NV)
  local cur = count_files()
  local nlk = locked_count()
  if n < nlk then n = nlk end
  if n == cur then return end
  layout_busy = true
  if n < cur then

    local keep, nk = keep_for(n)
    compact_to(keep, nk)
  else
    local need = 0
    for i = 1, n do
      if S.files[i] == nil then need = need + 1 end
    end
    if need > 0 then
      if not scan_source() then
        layout_busy = false
        return false
      end
      local chosen, k = tape.pick(fresh_pool(), need), 0
      for i = 1, n do
        if S.files[i] == nil then
          k = k + 1
          local f = chosen[k]
          if f then
            tries[i] = 0
            params:set(PID[i].vol, VOL_DEFAULT_DB)
            params:set(PID[i].tune, 0)
            load_voice(i, f)
          end
        end
      end
    end
  end
  layout_busy = false
  refresh_layout()
  dirty = true
  return true
end

local held = {}

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
  if any then
    for i = 1, nva do
      if not held[i] then engine.reseed_one(i - 1) end
    end
    return
  end
  engine.reseed()
end

local function reseed_voices(reorder)
  glide = GLIDE_FRAMES
  lord_pend = nil
  local anyheld = false
  for i = 1, NV do
    held[i] = (vfrozen[i] or vlocked[i]) or nil
    if held[i] then anyheld = true end
  end
  if reorder then
    local prevn = 0
    if anyheld then
      build_order()
      prevn = lord_n
      for k = 1, lord_n do prev_ord[k] = lord[k] end
    end
    params:set("lseed", math.random(9999))
    if anyheld then order_keep_held(prevn) end
  end
  flush_population()
  for i = 1, nva do
    if not held[i] then
      local pit, tls, tle, lw = pits[i], cls[i], cle[i], last_win[i]
      pit:reroll(blo[i] * SPAN, bhi[i] * SPAN)
      for L = 1, lcap do
        local s, e = pit:window(L)
        local k = (L - 1) * 2
        tls[L], tle[L] = s, e
        wbuf[k + 1], wbuf[k + 2] = s, e
        lw[k + 1], lw[k + 2] = s, e
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
    params:set("pitchrate", Dice.rndexp(c.mr[1], c.mr[2]))
    params:set("rateslew", Dice.rndexp(c.slew[1], c.slew[2]))
    params:set("reverse", Dice.rnd(c.rev[1], c.rev[2]) * 100)
    params:set("ampfloor", Dice.rnd(c.floor[1], c.floor[2]))
  end,
  space = function()
    local c = Dice.pick(Dice.SPACE)
    params:set("panwidth", Dice.rnd(c.pan[1], c.pan[2]))
    if Dice.chance(NOFILTER_CHANCE) then
      params:set("cutoff", LPF_OFF)
      params:set("vhpf", HPF_OFF)
    else
      params:set("cutoff", Dice.rndexp(c.cut[1], c.cut[2]))
      params:set("vhpf", Dice.rnd(HPF_OFF, 400))
    end
    params:set("variance", Dice.rnd(0, 100))

    local d = c.dly
    if Sync.dly_synced() then
      params:set("d_div", math.random(3, 14))
    end
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
  Morph.gesture(function()
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
    reseed_voices(true)
  end)
end

local function setup_params()

  local HIDDEN = {"grains_tune", "grains_bounds", "grains_reverb", "reverb_mix", "level", "chord", "lseed", "morph_seed", "grains_hold"}
  local SLOT_CHARS = 24

  local function eng(id, k)
    params:set_action(id, k and function(v) engine[id](v * k) end
                            or function(v) engine[id](v) end)
  end
  local function engopt(id)
    params:set_action(id, function(x) engine[id](x - 1) end)
  end

  local function pct(id, label, default)
    params:add_control(id, label, controlspec.new(0, 100, "lin", 1, default, "%"))
    eng(id, 0.01)
  end
  morph_first = #params.params + 1

  params:add_separator("  ")

  for i = 1, NV do
    local sid = PID[i].file
    params:add_file(sid, "S" ..i, AUDIO_DIR) params:set_action(sid, function(path)
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
    local slot = params:lookup_param(sid)
    if slot then
      slot.string = function()
        local v = params:get(sid)
        if type(v) ~= "string" or v == "" or v == "-" or v:sub(-1) == "/" then return "-" end
        local base = v:match("[^/]+$") or v
        local stem, ext = base:match("^(.+)%.(%w+)$")
        if stem and #ext <= 4 then base = stem end
        if #base > SLOT_CHARS then base = base:sub(1, SLOT_CHARS - 2) .. ".." end
        return base
      end
    end
  end

  params:add_separator(" ")

  params:add_group("grains_main", "VOICES", 14)
  params:add_control("level", "Level", controlspec.new(DB_FLOOR, LEVEL_MAX_DB, "lin", 0.5, -20, "dB"))
  params:add_number("density", "Density", 0, NV * NL, 0) params:set_action("density", function(v) if not layout_busy then local m = params:lookup_param("density").max dfrac = m > 0 and clamp(v / m, 0, 1) or 0 end push_population() end)
  params:add_control("tuning", "Tuning", controlspec.new(-36, 24, "lin", 1, 0, "st"))
  params:add_control("spread", "Voice Spread", controlspec.new(0, 100, "lin", 1, 75, "%"))
  params:add_option("chord", "Chord", Dice.CHORD_NAMES, 6)
  params:add_control("lspread", "Layer Spread", controlspec.new(0, 200, "lin", 1, 100, "%"))
  params:set_action("lspread", TUNE.set_layer_spread)
  params:add_control("variance", "Voice Variance", controlspec.new(0, 100, "lin", 1, 50, "%"))
  params:add_control("motionrate", "Energy", controlspec.new(0.05, 8, "exp", 0, 1, "x"))
  params:add_control("pitchrate", "Pitch Change", controlspec.new(0.05, 8, "exp", 0, 1, "x"))
  for _, id in ipairs({"motionrate", "pitchrate"}) do
    local rp = params:lookup_param(id)
    if rp then
      rp.string = function()
        local v = params:get(id)
        return v <= RATE_OFF and "off" or string.format("%.2f x", v)
      end
    end
  end
  params:add_control("reverse", "Reverse Chance", controlspec.new(0, 100, "lin", 1, 40, "%"))
  params:add_control("rateslew", "Rate Slew", controlspec.new(0.005, 10, "exp", 0, 1.5, "s"))
  params:add_control("panwidth", "Pan Width", controlspec.new(0, 100, "lin", 1, 90, "%"))
  params:add_control("ampfloor", "Level Floor", controlspec.new(0, 100, "lin", 1, 25, "%"))
  params:add_binary("freeze_all", "Freeze All", "toggle", 0) params:set_action("freeze_all", freeze_refresh)

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
    local p = PID[i]
    params:add_control(p.bstart, i .. " start", controlspec.new(0, 100, "lin", 0.2, 0, "%"))
    params:add_control(p.bwidth, i .. " width", controlspec.new(0, 100, "lin", 0.2, 100, "%"))
    params:set_action(p.bstart, function() trim_width(i) end)
    params:set_action(p.bwidth, function() trim_width(i) end)
    params:add_control(p.vol, i .. " volume", controlspec.new(Shuffle.VOL_MIN_DB, Shuffle.VOL_MAX_DB, "lin", 0.5, VOL_DEFAULT_DB, "dB")) params:set_action(p.vol, function() Shuffle.vol:touched(i) push_voices() end)
    params:add_number(p.tune, i .. " pitch", Shuffle.PITCH_LO, Shuffle.PITCH_HI, 0) params:set_action(p.tune, function() Shuffle.pitch:touched(i) push_voices() end)
    HIDDEN[#HIDDEN + 1] = p.bstart
    HIDDEN[#HIDDEN + 1] = p.bwidth
    HIDDEN[#HIDDEN + 1] = p.vol
    HIDDEN[#HIDDEN + 1] = p.tune
  end

  params:add_group("grains_reverb", "R3VERB", 1)
  params:add_taper("reverb_mix", "Mix", -40, 18, -40, 0, "dB") params:set_action("reverb_mix", nrev_set_mix)

  params:add_group("grains_delay", "DELAY", 11)
  pct("d_mix", "Mix", 0)
  params:add_control("d_time", "Time", controlspec.new(0.02, 5, "exp", 0, 0.5, "s")) params:set_action("d_time", function() Sync.dly_refresh() end)
  params:add_option("d_sync", "Time Base", {"free", "clock"}, 1) params:set_action("d_sync", function() Sync.dly_refresh() Sync.vis() end)
  params:add_number("d_div", "Division", 1, Sync.NDIV, Sync.DIV_QUART, function() return Sync.dly_fmt() end) params:set_action("d_div", function() Sync.dly_refresh() end)
  params:add_control("d_fb", "Feedback", controlspec.new(0, 120, "lin", 1, 40, "%")) eng("d_fb", 0.01)
  params:add_control("d_lpf", "LPF", controlspec.new(20, 20000, "exp", 1, 7500, "Hz")) eng("d_lpf")
  params:add_control("d_hpf", "HPF", controlspec.new(20, 20000, "exp", 1, 200, "Hz")) eng("d_hpf")
  pct("d_wdepth", "Mod Depth", 25)
  params:add_control("d_wrate", "Mod Freq", controlspec.new(0, 20, "lin", 0.1, 2, "Hz")) eng("d_wrate")
  pct("d_stereo", "Ping-Pong", 20)
  pct("d_duck", "Ducking", 17)

  params:add_group("grains_shimmer", "SHIMMER", 8)
  pct("sh_mix", "Mix", 0)
  params:add_option("sh_mod", "Mix Mod", {"off", "on"}, 1) engopt("sh_mod")
  params:add_option("sh_oct", "Pitch Shift", {"-2 oct", "-1 oct", "0", "+1 oct", "+2 oct"}, 4) params:set_action("sh_oct", function(x) engine.sh_oct(({0.25, 0.5, 1, 2, 4})[x]) end)
  pct("sh_pitchv", "Variance", 2)
  params:add_control("sh_lowpass", "LPF", controlspec.new(20, 20000, "lin", 1, 13000, "Hz")) eng("sh_lowpass")
  params:add_control("sh_hipass", "HPF", controlspec.new(20, 20000, "exp", 1, 1400, "Hz")) eng("sh_hipass")
  params:add_control("sh_fbdelay", "Delay", controlspec.new(0.01, 0.5, "lin", 0.01, 0.2, "s")) eng("sh_fbdelay")
  pct("sh_fb", "Feedback", 20)

  params:add_group("grains_tape", "TAPE", 8)
  params:add_option("tape_mix", "Analog", {"off", "on"}, 1) engopt("tape_mix")
  pct("shaper_mix", "Shaper drive", 0)
  pct("wobble_mix", "Wobble", 0)
  pct("wobble_amp", "Wow Depth", 20)
  params:add_control("wobble_rpm", "Wow Speed", controlspec.new(30, 90, "lin", 1, 33, "rpm")) eng("wobble_rpm")
  pct("flutter_amp", "Flutter Depth", 35)
  params:add_control("flutter_freq", "Flutter Speed", controlspec.new(3, 30, "lin", 0.01, 6, "Hz")) eng("flutter_freq")
  params:add_control("flutter_var", "Flutter Var", controlspec.new(0.1, 10, "lin", 0.01, 2, "Hz")) eng("flutter_var")

  params:add_group("grains_dimension", "STEREO", 4)
  params:add_control("m_width", "Width", controlspec.new(0, 200, "lin", 1, 100, "%")) params:set_action("m_width", function(v) engine.m_width(v / 100) end)
  pct("dimension_mix", "Dimension", 0)
  params:add_option("haas", "Haas Effect", {"off", "on"}, 1) engopt("haas")
  params:add_taper("rspeed", "Rotation", 0, 1, 0, 1, "Hz") eng("rspeed")

  params:add_group("grains_eq", "EQ", 4)
  params:add_control("eq_low", "Bass", controlspec.new(-20, 20, "lin", 0.5, 0, "dB")) eng("eq_low")
  params:add_control("eq_mid", "Mid", controlspec.new(-20, 20, "lin", 0.5, 0, "dB")) eng("eq_mid")
  params:add_control("eq_high", "Treble", controlspec.new(-20, 20, "lin", 0.5, 0, "dB")) eng("eq_high")
  params:add_control("tilt", "Tilt", controlspec.new(-1, 1, "lin", 0.01, 0, "")) eng("tilt", 12)

  params:add_group("grains_tone", "FILTER", 3)
  params:add_control("cutoff", "LPF", controlspec.new(20, 20000, "exp", 1, 20000, "Hz"))
  params:add_control("res", "Resonance", controlspec.new(0, 100, "lin", 1, 20, "%"))
  params:add_control("vhpf", "HPF", controlspec.new(20, 800, "exp", 1, 20, "hz"))

  params:add_group("grains_bitcrush", "BITCRUSH", 4)
  pct("bc_mix", "Mix", 0)
  params:add_option("bc_mod", "Mix Mod", {"off", "on"}, 1) engopt("bc_mod")
  params:add_taper("bc_rate", "Rate", 1, 48000, 4500, 3, "Hz") eng("bc_rate")
  params:add_taper("bc_bits", "Bits", 1, 24, 14, 1, "") eng("bc_bits")

  params:add_group("grains_wavefold", "WAVEFOLD", 3)
  pct("wf_mix", "Mix", 0)
  pct("wf_drive", "Drive", 75)
  pct("wf_sym", "Symmetry", 0)

  params:add_group("grains_reso", "RESONATE", 4)
  params:add_control("reso_mix", "Mix", controlspec.new(0, 100, "lin", 1, 0, "%")) params:set_action("reso_mix", function(v) engine.reso_mix(v * 0.01) Reso.update() end)
  params:add_control("reso_decay", "Decay", controlspec.new(0.01, 5, "exp", 0, 2, "s")) eng("reso_decay")
  params:add_number("reso_root", "Root", 24, 128, 48, function(p) return MusicUtil.note_num_to_name(p:get(), true) end) params:set_action("reso_root", function() Reso.update() end)
  params:add_option("reso_voicing", "Voicing", Reso.NAMES, 2) params:set_action("reso_voicing", function(v) Reso.voicing(v) Reso.update() end)

  params:add_group("grains_glitch", "GLITCH", 8)
  pct("gl_ratio", "Glitch", 0)
  pct("gl_mix", "Mix", 100)
  params:add_taper("gl_prob", "Frequency", 0.1, 20, 5, 1, "Hz") eng("gl_prob")
  params:add_control("gl_min", "Min Length", controlspec.new(10, 500, "lin", 1, 75, "ms")) eng("gl_min", 0.001)
  params:add_control("gl_max", "Max Length", controlspec.new(20, 500, "lin", 1, 200, "ms")) eng("gl_max", 0.001)
  params:add_number("gl_stutters", "Max Stutters", 2, 20, 5) eng("gl_stutters")
  pct("gl_rev", "Reverse Chance", 0)
  pct("gl_pitch", "Pitch Chance", 0)

  params:add_group("grains_gen", "RANDOMIZE", 8)
  params:add_binary("do_dice", "Randomize!", "trigger", 0) params:set_action("do_dice", function(v) if v == 1 then dice() end end)
  params:add_binary("do_reseed", "Reseed Voices", "trigger", 0) params:set_action("do_reseed", function(v) if v == 1 then reseed_voices() end end)
  params:add_number("lseed", "layer order", 1, 9999, 1) params:set_action("lseed", function() push_population() dirty = true end)
  for _, k in ipairs({"tune", "motion", "space", "shape", "voice"}) do
    params:add_option("lock_" .. k, k, {"roll", "hold"}, 1)
  end

  params:add_group("grains_morph", "MORPH", 12)
  params:add_control("morph", "Morph", controlspec.new(0, 100, "lin", 0.5, 0, "%")) params:set_action("morph", function(v)
    if not Sync.driving and Sync.mo_on() then params:set("morph_auto", 1) end
    Morph.set(v * 0.01)
    dirty = true
  end)
  params:add_binary("do_store_a", "Store A", "trigger", 0) params:set_action("do_store_a", function(v) if v == 1 then params:set("morph_auto", 1) Morph.store(1) dirty = true end end)
  params:add_binary("do_store_b", "Store B", "trigger", 0) params:set_action("do_store_b", function(v) if v == 1 then params:set("morph_auto", 1) Morph.store(2) dirty = true end end)
  params:add_binary("do_store_clear", "Clear Morph", "trigger", 0) params:set_action("do_store_clear", function(v) if v == 1 then Morph.clear() dirty = true end end)
  params:add_option("morph_auto", "LFO", {"off", "on"}, 1) params:set_action("morph_auto", function(v) if v == 2 and params:get("morph_depth") <= 0 then params:set("morph_depth", 100) end Sync.vis() dirty = true end)
  params:add_control("morph_depth", "Depth", controlspec.new(0, 100, "lin", 1, 100, "%"))
  params:add_option("morph_shape", "Shape", Sync.SHAPES, 2)
  params:add_option("morph_sync", "Time Base", {"free", "clock"}, 2) params:set_action("morph_sync", function() Sync.vis() end)
  params:add_number("morph_div", "Division", 1, Sync.NDIV, Sync.DIV_4BAR, function() return Sync.mo_fmt() end)
  params:add_control("morph_rate", "Free Cycle", controlspec.new(0.25, 600, "exp", 0, 20, "s"))
  params:add_control("morph_slew", "Smoothing", controlspec.new(0, 8, "lin", 0.01, 0.1, "s"))
  params:add_number("morph_seed", "Motion Seed", 1, 9999, 1)

  params:add_group("grains_bounce", "RECORD", 12)
  params:add_separator("Record Input")
  params:add_control("rec_gain", "Gain", controlspec.new(-24, 24, "lin", 0.5, 0, "dB"))
  params:add_control("rec_max", "Max Time", controlspec.new(2, 60, "lin", 1, 30, "s"))
  params:add_option("rec_norm", "Normalize", {"off", "-6 dB"}, 2)
  params:add_option("rec_src", "Source", {"stereo", "mono sum", "left", "right"}, 2)
  params:add_control("rec_mon", "Monitor", controlspec.new(DB_FLOOR, 12, "lin", 0.5, 0, "dB"))
  local mp = params:lookup_param("rec_mon")
  if mp then
    mp.string = function()
      local v = params:get("rec_mon")
      return v <= DB_FLOOR and "off" or string.format("%.1f dB", v)
    end
  end
  params:add_binary("do_clean_in", "Clean Input Recordings!", "trigger", 0) params:set_action("do_clean_in", function(v) if v == 1 then REC.clean("input") end end)  
  params:add_separator("Record Loop")
  params:add_control("bounce_len", "Loop Length", controlspec.new(1, 60, "lin", 0.5, 8, "s"))
  params:add_control("bounce_xf", "Crossfade", controlspec.new(0.1, 5, "lin", 0.1, 1, "s"))
  params:add_binary("do_bounce", "RECORD LOOP!", "trigger", 0) params:set_action("do_bounce", function(v) if v == 1 then start_bounce() end if _menu and type(_menu.set_mode) == "function" then _menu.set_mode(false) end end)
  params:add_binary("do_clean_loop", "Clean Loops!", "trigger", 0) params:set_action("do_clean_loop", function(v) if v == 1 then REC.clean("loop") end end)

  params:add_group("grains_hold", "FREEZE / LOCK", NV * 2)
  for i = 1, NV do
    params:add_binary("freeze" .. i, i .. " freeze", "toggle", 0) params:set_action("freeze" .. i, freeze_refresh)
    params:add_binary("lock_v" .. i, i .. " lock", "toggle", 0)
    params:set_action("lock_v" .. i, function(v)

      if v ~= 1 then S.pin[i] = nil end
      lock_refresh()

      local m = params:lookup_param("density").max
      params:set("density", clamp(floor(dfrac * m + 0.5), 0, m), true)
      push_population()
    end)
  end

  params:add_group("grains_src", "SOURCE", NV + 5)
  params:add_binary("do_clear", "Unload All", "trigger", 0) params:set_action("do_clear", function(v) if v == 1 then clear_all() end end)
  for n = 1, NV do
    params:add_binary("do_load" .. n, "Load " .. n .. " Random", "trigger", 0) params:set_action("do_load" .. n, function(v) if v == 1 then load_n(n) end end)
  end
  params:add_file("source", "Folder", AUDIO_DIR)
  params:set_action("source", function()
    scanned_dir = nil
  end)
  local src_p = params:lookup_param("source")
  if src_p then
    local SRC_CHARS = 24
    src_p.string = function()
      local v = params:get("source")
      if type(v) ~= "string" or v == "" or v == "-" then return "-" end
      local dir = v:sub(-1) == "/" and v or v:match("^(.*/)")
      if dir == nil or dir == "" then dir = AUDIO_DIR end
      local name = dir:match("([^/]+)/$") or "/"
      if #name > SRC_CHARS then name = name:sub(1, SRC_CHARS - 2) .. ".." end
      return name
    end
  end

  params:add_binary("do_rescan", "Re-scan Folder", "trigger", 0)
  params:set_action("do_rescan", function(v)
    if v == 1 then
      scanned_dir = nil
      scan_source()
    end
  end)
  params:add_control("chunk", "Slice Length", controlspec.new(2, 60, "lin", 0.5, 15, "s"))
  params:add_binary("do_reslice", "Re-slice", "trigger", 0) params:set_action("do_reslice", function(v) if v == 1 then src.reslice() end end)

  for _, p in ipairs(VOICE_PARAMS) do
    params:set_action(p[2], function()
      if not dicing then ovr_clear(p[2]) end
      push_one(p)
    end)
  end

  local function scalar_action(id)
    params:set_action(id, function()
      if not dicing then ovr_clear(id) end
      push_voices()
    end)
  end
  scalar_action("level")
  for _, id in ipairs(SCALARS) do scalar_action(id) end

  morph_last = #params.params
  for _, id in ipairs(HIDDEN) do params:hide(id) end
end

local function setup_osc()
  osc.event = function(path, args)
    if path == "/grains/state" then
      for i = 1, nva do
        local pos, pc = S.pos[i], poscol[i]
        local live = S.on[i]
        local base = (i - 1) * lcap
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

      if S.files[v] then xf_in(v, S.wf[v]) end
    elseif path == "/grains/fail" then
      local v = (args[1] or 0) + 1
      if v >= 1 and v <= NV then retry_voice(v) end
    elseif path == "/grains/bounce" then
      bounce_until = 0
    elseif path == "/grains/rec_level" then
      local l, r = args[1] or 0, args[2] or 0
      REC.level, REC.level_r, REC.metered = l, r, true
      local m = l > r and l or r
      if m > REC.peak then REC.peak = m end
    elseif path == "/grains/rec_done" then
      REC.done((args[1] or 0) > 0)
    end
  end
end

function redraw()
  if installer_screen() then installer:redraw() return end
  screen.clear()
  S.sel = sel
  matrix.draw(S)
  if nva < 1 then matrix.notice("no audio loaded", "K1+K2 or load from the MENU") end
  local now = util.time()
  local vol_on = volbar.frac and (now - volbar.t) < POP_DUR
  if vol_on then
    matrix.volbar(volbar.frac)
  elseif morph_on then
    matrix.morphbar(Morph.pos)
  end
  if vol_on or not morph_on then matrix.icons(font.draw) end
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
  if REC.state then
    if REC.state == "rec" then
      local clip = REC.level >= 0.99 or REC.level_r >= 0.99
      if REC.shown ~= REC.tick then
        REC.shown = REC.tick
        REC.sub = string.format("S%d  %.1fs", REC.target,
          REC.tick > 0 and REC.tick * 0.1 or 0)
      end
      REC.bars[1], REC.bars[2] = REC.frac(REC.level), REC.frac(REC.level_r)
      matrix.recpopup(clip and "REC  clip" or "REC", REC.sub, REC.bars)
    elseif REC.state == "confirm" then
      matrix.recpopup(REC.txt, REC.kind == "loop" and "loops" or "recs",
        nil, "K3 ok    K2 no")
    elseif REC.state == "save" then
      matrix.recpopup("saving...")
    else
      matrix.recpopup(REC.txt or "")
    end
  end
  screen.update()
end

local function edit(suffix, d)
  if sel < 1 then return end
  params:delta(PID[sel][suffix], d)
end

local coarse = Keys.coarse

local function pop_show(kind, txt)
  pop.kind, pop.txt, pop.t = kind, txt, util.time()
  dirty = true
end

function src.nudge_count(step)
  local cur = count_files()
  if cur < 1 and step < 0 then return end
  local want = clamp(cur + step, 1, NV)
  if want == cur then return end
  src.set_count(want)
end

local function level_delta(d)
  params:set("level", clamp(params:get("level") + d * LEVEL_STEP_DB, DB_FLOOR, LEVEL_MAX_DB))
  volbar.frac, volbar.t = vol_frac(params:get("level"), LEVEL_MAX_DB), util.time()
  dirty = true
end

local FX = {{"reverb_mix", "reverb"}, {"d_mix", "delay"}, {"sh_mix", "shimmer"}}

local function morph_toggle()
  morph_on = not morph_on
  dirty = true
end

local function toggle_param(id)
  params:set(id, params:get(id) == 0 and 1 or 0)
  dirty = true
end

local function toggle_voice(prefix)
  if sel < 1 then return end
  toggle_param(prefix .. sel)
end

local function step_sel(d)
  dirty = true
  if nva < 1 then sel = 0 return end
  if sel < 1 then sel = 1 return end
  sel = ((sel - 1 + d) % nva) + 1
end

local KEY_COMBOS = {
  ["1"]   = {long = morph_toggle},
  ["2"]   = {short = function() step_sel(-1) end,
             long  = REC.start},
  ["3"]   = {short = function() step_sel(1) end,
             long  = function() REC.start(true) end},
  ["12"]  = {short = function() load_n(nva < 1 and DEFAULT_NV or nva, true) end,
             long  = function() toggle_voice("freeze") end},
  ["13"]  = {short = dice,
             long  = function() toggle_param("freeze_all") end},
  ["23"]  = {short = function() toggle_voice("lock_v") end},
  ["123"] = {short = reseed_voices}
}

function enc(n, d)
  if installer_screen() or REC.state then return end
  local k1, k2, k3 = key_state[1], key_state[2], key_state[3]
  dirty = true

  if k1 or k2 or k3 then
    Keys.mark()
  end

  if k2 and k3 and not k1 then
    local fx = FX[n]
    if fx then
      params:delta(fx[1], d)
      local v = params:get(fx[1])
      pop_show("fx", fx[2] .. ": " ..
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
    if n == 1 and k3 then
      params:set("tuning", params:get("tuning") + d)
      pop_show("fx", string.format("tuning: %+.0f st", params:get("tuning")))
    elseif n == 1 then
      local step = coarse("density", d)
      if step ~= 0 then params:delta("density", step) end
    elseif n == 2 and k3 then
      params:delta("motionrate", d)
      local v = params:get("motionrate")
      pop_show("fx", v <= RATE_OFF and "energy: off" or string.format("energy: %.2fx", v))
    elseif n == 2 then
      local step = coarse("layers", d)
      if step ~= 0 and sel >= 1 then nudge_voice_layers(sel, step) end
    elseif k3 then
      params:delta("pitchrate", d)
      local v = params:get("pitchrate")
      pop_show("fx", v <= RATE_OFF and "pitch: off" or string.format("pitch: %.2fx", v))
    else
      local step = coarse("voices", d)
      if step ~= 0 then src.nudge_count(step) end
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
  if installer_screen() then installer:key(n, z) return end
  if REC.state then
    if z == 1 then
      if REC.state == "rec" then REC.stop()
      elseif REC.state == "confirm" then REC.confirm(n == 3)
      elseif REC.state == "msg" then REC.finish(nil) end
    else
      Keys.release(n)
    end
    return
  end
  if n == 2 and z == 1 and not key_state[2] then Shuffle.vol:reset() end
  if n == 3 and z == 1 and not key_state[3] then Shuffle.pitch:reset() end
  if z == 1 then Keys.press(n) else Keys.release(n) end
end

function init()
  if not installer:ready() then
    clock.run(function()
      while true do
        redraw()
        clock.sleep(1 / 15)
      end
    end)
    return
  end
  initial_monitor_level = params:get('monitor_level')
  params:set('monitor_level', -math.huge)
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
  Keys.init{combos = KEY_COMBOS, longpress = LONGPRESS,
            coarse = {density = 5, layers = 5, voices = 5, mofreq = 3}}
  params:set("lseed", math.random(9999))
  params:set("morph_seed", math.random(9999))
  params:bang()
  font.init()
  refresh_layout()
  Morph.init(morph_first, morph_last, morph_skip)
  params.action_write = function(filename) pset_write(filename .. ".gstate") end
  params.action_read = pset_read
  params.action_delete = function(filename)
    for _, ext in ipairs({".gstate", ".lorder", ".morph"}) do os.remove(filename .. ext) end
  end
  push_voice_params()
  push_per_voice()
  push_population()
  engine.report_rate(REPORT_RATE)
  load_random(DEFAULT_NV)
  ui_metro = metro.init()
  ui_metro.time = 1 / FPS
  ui_metro.event = function()
    Sync.tick()
    physics_tick()
    Keys.tick()
    if font.tick() then dirty = true end
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
    if REC.state then
      local now = util.time()
      if REC.state == "rec" then
        if now - REC.t0 >= params:get("rec_max") then
          REC.stop()
        else
          local t = floor((now - REC.t0) * 10)
          if t ~= REC.tick then
            REC.tick = t
            dirty = true
          end
        end
      elseif now >= REC.wait then
        REC.finish(REC.state == "save" and "failed" or nil)
      end
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
  if initial_monitor_level then params:set('monitor_level', initial_monitor_level) end
  osc.event = nil
end