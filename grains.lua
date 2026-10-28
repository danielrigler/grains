--
--
--
--          grains v0.22 
--           @dddstudio
--
--
--
-- K1+E1 Density
-- E1 Master Volume
-- K2/K3 Navigate Voices
-- E2/E3 Set Boundaries
-- K1+K2 Load Random
-- K1+K3 Randomize
-- K2+K3 Lock Selected Voice
-- K2+K3 hold: Undo
-- K1+K2+K3 hold: Redo
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
-- K1+K2+K3+E1 Scale
-- K1+K2+K3+E2 Voice Spread
-- K1+K2+K3+E3 Layer Spread
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
-- GRID rows 1-6: voices
-- press: move section
-- hold+press: set section
-- hold: grab moving section
-- rows 7-8: up/down
-- 1-11: reverb delay shimmer
-- dimension chorus vibe wobble
-- crush spiral sub glitch
-- 12: region lfo depth
-- 13: volume lfo depth
-- 14: reseed/randomize
-- 15: volume, 16: density
-- both keys: reset/off
-- hold row +15: vol +16: lock/frz
--
-- Based on Graintopia by
-- @infinitedigits

local MusicUtil = require "musicutil"
local installer = include("grains/lib/installer/installer").new()
engine.name = "grains"
local tape = include "grains/lib/tape"
local Pit = include "grains/lib/pit"
local Dice = include "grains/lib/dice"
local matrix = include "grains/lib/matrix"
local font = include "grains/lib/font"
local Morph = include "grains/lib/morph"
local Sync = include "grains/lib/sync"
local Shuffle = include "grains/lib/shuffle"
local Scale = include "grains/lib/scale"
local Keys = include "grains/lib/keys"
local Undo = include "grains/lib/undo"
local Grid = include "grains/lib/gridui"

local NV, NL, DEFAULT_NV, LCAPS = 6, 14, 4, {14, 10, 6, 5, 4, 4}
local AUDIO, SPAN, FPS, CTRL_HZ = "/home/we/dust/audio/", Pit.SPAN, 60, 30
local RATE_OFF, LPF_OFF, DB_FLOOR, LEVEL_MAX, LEVEL_REF, VOL_DEF = 0.05, 20000, -60, 6, -12, -6
local POP_DUR, GLIDE_N, GLIDE_K, XF_EASE, RTOUCH = 0.5, 12, 1 - 0.82 ^ 2, 0.49, 1.5
local floor, abs, random, min, max = math.floor, math.abs, math.random, math.min, math.max

local function clamp(x, lo, hi) return x < lo and lo or x > hi and hi or x end
local function amp(db) return 10 ^ (db / 20) end
local function ratio(st) return 2 ^ (st / 12) end
local function menu_rebuild() if _menu and type(_menu.rebuild_params) == "function" then _menu.rebuild_params() end end
local function menu_close() if _menu and type(_menu.set_mode) == "function" then _menu.set_mode(false) end end
local function menu_up()
  if not _menu then return false end
  if _menu.mode ~= nil then return _menu.mode == true end
  local st = norns and norns.menu and norns.menu.status
  return st ~= nil and st() == true
end

local V, PID, G = {}, {}, {}
local nva, lcap, sel, dirty = -1, -1, 0, true
local voices_dirty, pop_dirty, layout_busy, dicing, trimming = false, true, false, false, false
local blink, blink_n, frz_any, orig, morph_on = false, 0, false, false, false
local DENSP, dfrac, WIN_FN, WIN_N, wbuf = nil, 0, nil, 0, {}
local glide, sglide, xfing, shown_files = 0, 0, false, nil
local file_list, scanned_dir, scan_busy, scan_wait = {}, nil, false, nil
local fpend, PSX = {}, ".gstate"
local pop = {t = 0}
local vbar = {t = 0}
local sys = {}

local SEEDF = {"tune", "mr", "cut", "lvl", "floor"}
local LR, MD = {}, {}
for k = 1, 5 do LR[k], MD[k] = "lrate" .. k, "mididiff" .. k end
for i = 1, NV do PID[i] = {bstart = i .. "bstart", bwidth = i .. "bwidth", vol = i .. "vol", tune = i .. "tune", file = i .. "file"} end

local VP = {
  {"revprob", "reverse", function(v) return orig and 0 or v * 0.01 end},
  {"rateSlew", "rateslew"},
  {"panwidth", "panwidth", function(v) return v * 0.01 end},
  {"res", "res", function(v) return (100 - v) * 0.007 end},
  {"hpf", "vhpf"}
}
local SCALARS = {"tuning", "scale", "spread", "variance", "motionrate", "pitchrate", "cutoff", "ampfloor"}
for k = 1, 5 do
  VP[#VP + 1] = {"weight" .. k, "weight" .. k}
  VP[#VP + 1] = {"lamp" .. k, "vdb" .. k, amp}
  SCALARS[#SCALARS + 1] = MD[k]
end
local DICE_IDS = {table.unpack(SCALARS)}
for _, p in ipairs(VP) do DICE_IDS[#DICE_IDS + 1] = p[2] end
local LAYER_TRIM = {}
for n = 1, NL do LAYER_TRIM[n] = -10 * math.log(n, 10) end

local function new_voice()
  local v = {at = 0, tries = 0, nl = 0, act = 0, b0 = 0, b1 = 1, lo = 0, hi = 1, rg = 1,
    pos = {}, ls = {}, le = {}, ts = {}, te = {}, lw = {}, lc = {}, pc = {}, sent = {}, seed = {}, seedT = {},
    pit = Pit.new((lcap > 0 and lcap or LCAPS[1]) * 2)}
  for L = 1, NL do v.pos[L], v.ls[L], v.le[L], v.ts[L], v.te[L] = 0, 0, 1, 0, 1 end
  for _, f in ipairs(SEEDF) do
    local x = random() * 2 - 1
    v.seed[f], v.seedT[f] = x, x
  end
  return v
end

local function vsend(i, key, val, eps)
  local s = V[i].sent
  local was = s[key]
  if was and abs(was - val) < (eps or 1e-6) then return end
  s[key] = val
  engine.set_one(i - 1, key, val)
end

local function push_vp(p, only)
  local id, f, g = p[2], p[3], params:get(p[2])
  for i = only or 1, only or NV do
    local h = V[i].ovr
    local x = h and h[id]
    if x == nil then x = g end
    vsend(i, p[1], f and f(x) or x)
  end
end

local function push_lag(only)
  local lag = Sync.vlag()
  for i = only or 1, only or NV do vsend(i, "vampLag", lag) end
end

local function push_vps(only)
  for _, p in ipairs(VP) do push_vp(p, only) end
  push_lag(only)
end

local function ovr_clear(id)
  for i = 1, NV do
    local h = V[i].ovr
    if h and h[id] ~= nil then
      h[id] = nil
      if next(h) == nil then V[i].ovr = nil end
    end
  end
end

local function ovr_capture()
  for i = 1, NV do
    local v = V[i]
    if v.lck then
      v.ovr = v.ovr or {}
      for _, id in ipairs(DICE_IDS) do if v.ovr[id] == nil then v.ovr[id] = params:get(id) end end
    end
  end
end

local function freeze_refresh()
  local all, any = params:get("freeze_all") == 1, false
  for i = 1, NV do
    local f = all or params:get("freeze" .. i) == 1
    V[i].frz, any = f, any or f
  end
  frz_any = any
  if not any then blink, blink_n = false, 0 end
  voices_dirty, dirty = true, true
end

local function lock_refresh()
  for i = 1, NV do
    local v = V[i]
    v.lck = params:get("lock_v" .. i) == 1
    if not v.lck then v.ovr = nil end
  end
  push_vps()
  voices_dirty, dirty = true, true
end

local function ov(h, id)
  local x = h and h[id]
  if x == nil then x = G[id] end
  return x
end

local function push_vol()
  if Sync.vdirty then
    Sync.vdirty = false
    local n, c = 0, 0
    for i = 1, nva do if V[i].on then n = n + 1 end end
    for i = 1, NV do
      local v = V[i]
      if i <= nva and v.on then v.vph, c = c / max(n, 1), c + 1 else v.vph = 0 end
    end
  end
  if Sync.vlagdirty then Sync.vlagdirty = false push_lag() end
  local n, sa, sg = 0, 0, 0
  for i = 1, nva do
    local v = V[i]
    local b = v.vbase
    if b and b > -99 then
      local d = v.frz and v.vd or Sync.vdb(i, v.vph or 0)
      local a = amp(b)
      v.va, v.vg, v.vd = a, amp(d), d
      if not v.frz then n, sa, sg = n + 1, sa + a, sg + a * v.vg end
    else
      v.va = nil
    end
  end
  local k = (n > 1 and sg > 1e-12) and sa / sg or 1
  local show, kdb = Sync.vshow, 0
  local rows, sc = matrix.WALL_ROWS, 1 / (Shuffle.VOL_MAX_DB - DB_FLOOR)
  if show then Sync.vshow, kdb = false, k ~= 1 and 20 * math.log(k, 10) or 0 end
  for i = 1, nva do
    local v = V[i]
    if v.va then
      local a = min(v.va * v.vg * (v.frz and 1 or k), 1.9953)
      vsend(i, "vamp", a, a * 0.004 + 1e-6)
      if show then
        local f = clamp((v.volb or 0) + (v.vd + (v.frz and 0 or kdb)) * sc, 0, 1)
        if not v.volf or floor(f * rows + 0.5) ~= floor(v.volf * rows + 0.5) then dirty = true end
        v.volf = f
      end
    end
  end
end
Sync.vpush = push_vol

local function push_per_voice()
  voices_dirty, dirty = false, true
  local lsp, vrange = G.lspread * 0.01, Shuffle.VOL_MAX_DB - DB_FLOOR
  for i = 1, nva do
    local v, pid = V[i], PID[i]
    local s, h, frz = v.seed, v.ovr, v.frz
    local ivol, itune = pid.volp:get(), pid.tunep:get()
    v.volb = clamp((ivol - DB_FLOOR) / vrange, 0, 1)
    if not Sync.von or not v.volf then v.volf = v.volb end
    v.pitchf = orig and 0 or clamp(itune / Shuffle.PITCH_HI, -1, 1)
    local var, sc = ov(h, "variance") * 0.01, ov(h, "scale")
    if orig then
      vsend(i, "vrate", 1)
      for k = 1, 5 do vsend(i, LR[k], 1) end
    else
      local deg = Scale.round(s.tune * ov(h, "spread") * 0.02 * Scale.size(sc)) + Scale.near(itune, sc)
      local vst = Scale.pitch(deg, sc)
      vsend(i, "vrate", ratio(ov(h, "tuning") + vst))
      for k = 1, 5 do vsend(i, LR[k], ratio(Scale.pitch(deg + Scale.round(Scale.steps(ov(h, MD[k]), sc) * lsp), sc) - vst)) end
    end
    local emod, mr, pr, cut = 2 ^ (s.mr * var * 1.3), ov(h, "motionrate"), ov(h, "pitchrate"), ov(h, "cutoff")
    v.mr = (frz or mr <= RATE_OFF) and 0 or clamp(mr * emod, 0.02, 12)
    vsend(i, "mrate", v.mr)
    vsend(i, "prate", (frz or pr <= RATE_OFF) and 0 or clamp(pr * emod, 0.02, 12))
    vsend(i, "cutoff", cut >= LPF_OFF - 1 and LPF_OFF or clamp(cut * 2 ^ (s.cut * var * 2.6), 90, LPF_OFF))
    v.vbase = ivol <= -59.5 and -100 or clamp(LEVEL_REF + ivol + (LAYER_TRIM[v.act] or 0) + s.lvl * var * 7, -100, LEVEL_REF + 26)
    if not Sync.von then vsend(i, "vamp", amp(v.vbase)) end
    vsend(i, "ampfloor", clamp(ov(h, "ampfloor") * 0.01 + s.floor * var * 0.35, 0, 1))
  end
  if Sync.von then push_vol() end
end

local lord, lord_n, lord_key, tmpa, tmpb = {}, 0, nil, {}, {}

local function order_key() return (floor(params:get("lseed")) * 8 + nva) * 16 + lcap end

local function build_order()
  local key = order_key()
  if lord_key == key then return end
  lord_key = key
  local s, v, n = (floor(params:get("lseed")) * 1103515245 + 12345) % 2147483648, {}, 0
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
end

local function spread_density()
  build_order()
  local d0 = floor(DENSP:get())
  local d = min(d0, lord_n)
  local need, pin, free = nil, 0, 0
  for i = 1, nva do
    local v = V[i]
    if v.lck and v.file then
      if not v.pin then
        v.pin = 0
        for k = 1, d do if lord[k] == i then v.pin = v.pin + 1 end end
      end
      need = need or {}
      need[i] = min(v.pin, lcap)
      pin = pin + need[i]
    else
      free = free + lcap
    end
  end
  if need then
    d = clamp(d, pin, min(pin + free, lord_n))
    if d ~= d0 then params:set("density", d, true) end
    local room, nf, nb = d - pin, 0, 0
    for k = 1, lord_n do
      local x = lord[k]
      local take
      if need[x] then
        take = need[x] > 0
        if take then need[x] = need[x] - 1 end
      else
        take = room > 0
        if take then room = room - 1 end
      end
      if take then nf = nf + 1 tmpa[nf] = x else nb = nb + 1 tmpb[nb] = x end
    end
    for k = 1, nf do lord[k] = tmpa[k] end
    for k = 1, nb do lord[nf + k] = tmpb[k] end
  end
  for i = 1, NV do V[i].act = 0 end
  for k = 1, d do local v = V[lord[k]] v.act = v.act + 1 end
end

local function order_move(from, to)
  local v = lord[from]
  local s = from < to and 1 or -1
  for k = from, to - s, s do lord[k] = lord[k + s] end
  lord[to] = v
end

local function nudge_layers(i, step)
  build_order()
  local d, v = min(floor(DENSP:get()), lord_n), V[i]
  if v.lck and v.file then
    local p0 = min(v.pin or v.act, lcap)
    local p = clamp(p0 + step, 0, lcap)
    if p ~= p0 then
      v.pin = p
      params:set("density", d + p - p0)
    end
    return
  end
  local n, dir = 0, step > 0 and 1 or -1
  for _ = 1, abs(step) do
    local edge, at = dir > 0 and d + n + 1 or d - n, nil
    for k = edge, dir > 0 and lord_n or 1, dir do if lord[k] == i then at = k break end end
    if not at then break end
    order_move(at, edge)
    n = n + 1
  end
  if n > 0 then params:set("density", d + n * dir) end
end

local function flush_population()
  if not pop_dirty then return end
  spread_density()
  for i = 1, NV do
    local v = V[i]
    local n = v.act
    if v.nl ~= n then
      for L = v.nl + 1, n do
        local a, b = v.pit:window(L)
        v.ts[L], v.te[L], v.ls[L], v.le[L] = a, b, a, b
      end
      v.nl = n
      if n > 0 then engine.layers(i - 1, n) end
      voices_dirty, dirty = true, true
    end
    local on = n > 0
    if v.on ~= on then
      v.on, Sync.vdirty, dirty = on, true, true
      if on and voices_dirty then push_per_voice() end
      engine.active(i - 1, on and 1 or 0)
      if on then v.lw = {} end
    end
  end
  pop_dirty = false
  sel = nva < 1 and 0 or clamp(sel, 1, nva)
end

local function trim_width(i)
  if trimming then return end
  trimming = true
  local p, v = PID[i], V[i]
  local a, w = p.startp:get(), p.widthp:get()
  if a + w > 100 then
    w = 100 - a
    params:set(p.bwidth, w)
  end
  v.lo, v.hi = a / 100, (a + w) / 100
  if glide <= 0 then v.b0, v.b1 = v.lo, v.hi end
  dirty, trimming = true, false
end

local function region_grab(i)
  local v = V[i]
  v.rt = util.time()
  if not Sync.ron or v.frz or not v.rlo or v.rg < 0.001 then return end
  v.rg = 0
  params:set(PID[i].bstart, v.rlo * 100)
  params:set(PID[i].bwidth, (v.rhi - v.rlo) * 100)
end

local function count_files()
  local n = 0
  for i = 1, NV do if V[i].file then n = i end end
  return n
end

local function refresh_layout()
  if layout_busy then return end
  local n = count_files()
  local shown = min(n + 1, NV)
  if shown_files ~= shown then
    shown_files = shown
    for i = 1, NV do if i <= shown then params:show(PID[i].file) else params:hide(PID[i].file) end end
    menu_rebuild()
  end
  local cap = LCAPS[n] or (lcap > 0 and lcap) or LCAPS[1]
  if n == nva and cap == lcap then return end
  layout_busy = true
  local cap_changed = cap ~= lcap
  nva, lcap = n, cap
  WIN_FN, WIN_N = engine["set_win" .. cap], cap * 2
  if sel > nva then sel = nva end
  local nm = max(n, 1) * cap
  Morph.hold(function()
    DENSP.max = nm
    params:set("density", clamp(floor(dfrac * nm + 0.5), 0, nm))
  end)
  for i = 1, NV do
    local v = V[i]
    v.pit:resize(cap * 2, v.lo * SPAN, v.hi * SPAN)
    if cap_changed then v.lw = {} end
    v.lc, v.pc, v.nl = {}, {}, 0
  end
  matrix.set_count(n)
  layout_busy, Sync.vdirty = false, true
  engine.report_geom(n, cap)
  pop_dirty, voices_dirty, dirty = true, true, true
end

local function xf_in(v)
  local d = random(4)
  v.xx = d == 1 and -matrix.CW or d == 2 and matrix.CW or 0
  v.xy = d == 3 and -matrix.CH or d == 4 and matrix.CH or 0
  v.xf, xfing, dirty = true, true, true
end

local function physics_tick(now, step)
  if step and Morph.dirty then Morph.apply() end
  flush_population()
  if sglide > 0 then
    sglide = sglide - 1
    for i = 1, NV do
      local c, t = V[i].seed, V[i].seedT
      for _, f in ipairs(SEEDF) do c[f] = sglide == 0 and t[f] or c[f] + (t[f] - c[f]) * GLIDE_K end
    end
    voices_dirty = true
  end
  if voices_dirty then push_per_voice() end
  if xfing then
    xfing = false
    for i = 1, NV do
      local v = V[i]
      if v.xf then
        local x, y = v.xx * XF_EASE, v.xy * XF_EASE
        dirty = true
        if abs(x) < 0.5 and abs(y) < 0.5 then v.xf = nil else v.xx, v.xy, xfing = x, y, true end
      end
    end
  end
  for i = 1, NV do
    local v = V[i]
    if not (v.frz and v.rlo) then
      local a, b, g = v.lo, v.hi, v.rg
      g = (Grid.held(i) or (v.rt and now - v.rt < RTOUCH)) and g * 0.6 or g + (1 - g) * 0.05
      v.rg = g
      if Sync.ron and g > 0.001 and i <= nva then
        local ma, mb = Sync.region(i, a, b, nva)
        a, b = a + (ma - a) * g, b + (mb - b) * g
      end
      v.rlo, v.rhi = a, b
    end
  end
  local gliding = glide > 0
  if gliding then
    glide, dirty = glide - 1, true
    for i = 1, NV do
      local v = V[i]
      if glide == 0 then v.b0, v.b1 = v.rlo, v.rhi
      else v.b0, v.b1 = v.b0 + (v.rlo - v.b0) * GLIDE_K, v.b1 + (v.rhi - v.b1) * GLIDE_K end
    end
    gliding = glide > 0
  else
    for i = 1, NV do
      local v = V[i]
      if abs(v.b0 - v.rlo) > 0.002 or abs(v.b1 - v.rhi) > 0.002 then v.b0, v.b1, dirty = v.rlo, v.rhi, true end
    end
    if not step then return end
  end
  local CW = matrix.CW
  for i = 1, nva do
    local v = V[i]
    if v.on then
      local ts, te, nl = v.ts, v.te, v.act
      if step and not v.frz then
        local pit, lw, changed = v.pit, v.lw, false
        pit:update(v.rlo * SPAN, v.rhi * SPAN, v.mr or 1)
        for L = 1, nl do
          local a, b = pit:window(L)
          local k = L * 2
          ts[L], te[L], wbuf[k - 1], wbuf[k] = a, b, a, b
          if not lw[k] or abs(a - lw[k - 1]) > 2e-4 or abs(b - lw[k]) > 2e-4 then changed = true end
        end
        if changed then
          for k = 1, nl * 2 do lw[k] = wbuf[k] end
          for L = nl + 1, lcap do wbuf[L * 2 - 1], wbuf[L * 2] = pit:window(L) end
          WIN_FN(i - 1, table.unpack(wbuf, 1, WIN_N))
        end
      end
      local ls, le, lc = v.ls, v.le, v.lc
      for L = 1, nl do
        local x0, x1 = ts[L], te[L]
        if gliding then x0, x1 = ls[L] + (x0 - ls[L]) * GLIDE_K, le[L] + (x1 - le[L]) * GLIDE_K end
        ls[L], le[L] = x0, x1
        local c0, c1 = floor(x0 * CW), floor(x1 * CW)
        if lc[L * 2 - 1] ~= c0 or lc[L * 2] ~= c1 then lc[L * 2 - 1], lc[L * 2], dirty = c0, c1, true end
      end
    end
  end
end

local function stratified(n)
  local t = {}
  for i = 1, n do t[i] = clamp(-1 + (i - 0.5) / n * 2 + (random() - 0.5) * (1.8 / n), -1, 1) end
  for i = n, 2, -1 do
    local j = random(i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

local function reroll_seeds(snap)
  for _, f in ipairs(SEEDF) do
    local vals = stratified(NV)
    for i = 1, NV do
      local v = V[i]
      if not v.lck then
        v.seedT[f] = vals[i]
        if snap then v.seed[f] = vals[i] end
      end
    end
  end
  sglide = snap and 0 or GLIDE_N
end

local function unload_view(v)
  v.xf, v.raw, dirty = nil, nil, true
  for L = 1, NL do v.pos[L] = 0 end
end

local function load_voice(i, path, len, at, retry)
  local v = V[i]
  if not retry then v.tries = 0 end
  v.file, v.len, v.at = path, len or params:get("chunk"), at or 0
  unload_view(v)
  params:set(PID[i].file, path, true)
  refresh_layout()
  push_vps(i)
  engine.read(i - 1, path, v.len, at and 0 or 1, at or 0)
end

local function clear_voice(i)
  local v = V[i]
  fpend[i], v.file, v.len, v.at, v.pin, v.tries = nil, nil, nil, 0, nil, 0
  unload_view(v)
  params:set(PID[i].file, AUDIO, true)
  engine.clear(i - 1)
end

local function src_flush()
  layout_busy = true
  for i, path in pairs(fpend) do
    fpend[i] = nil
    if path:sub(-1) == "/" then
      if V[i].file then clear_voice(i) end
    elseif path ~= V[i].file then
      load_voice(i, path)
    end
  end
  layout_busy = false
  refresh_layout()
end

local function voices_set(vs)
  layout_busy = true
  for i = 1, NV do
    local s, v = vs[i], V[i]
    fpend[i] = nil
    if not s.f then
      if v.file then clear_voice(i) end
    elseif s.f ~= v.file or s.len ~= v.len or abs(s.at - v.at) > 1e-3 then
      load_voice(i, s.f, s.len, s.at)
    end
  end
  layout_busy = false
  refresh_layout()
end

local function retry_voice(i)
  local v = V[i]
  v.tries = v.tries + 1
  if v.tries > 8 or #file_list == 0 then v.xf, v.raw = nil, nil return end
  local pool = {}
  for _, f in ipairs(file_list) do if f ~= v.file then pool[#pool + 1] = f end end
  if #pool == 0 then pool = file_list end
  load_voice(i, pool[random(#pool)], nil, nil, true)
end

local REC = {dir = AUDIO .. "grains/", kinds = {loop = "grains_", input = "in_"}, level = 0, level_r = 0, peak = 0,
  tick = -1, shown = -1, target = 1, wait = 0, bars = {0, 0}, sub = "", bq = -1, bt0 = 0, blen = 1, bend = 0}

function REC.finish(txt)
  REC.state, REC.txt, REC.wait, dirty = txt and "msg" or nil, txt, txt and util.time() + 1 or 0, true
end

function REC.free_slot() for i = 1, NV do if not V[i].file then return i end end end

function REC.start(fresh)
  if REC.state then return end
  if fresh then
    REC.target = REC.free_slot()
    if not REC.target then return REC.finish("no free voices") end
  else
    REC.target = max(sel, 1)
  end
  local name = "in_" .. os.date("%y%m%d_%H%M%S")
  REC.fresh, REC.path, REC.t0, REC.state = fresh, REC.dir .. name .. ".wav", util.time(), "rec"
  REC.level, REC.level_r, REC.peak, REC.tick, REC.shown, REC.metered = 0, 0, 0, -1, -2, false
  local mon = params:get("rec_mon")
  engine.rec_start(name, params:get("rec_max"), amp(params:get("rec_gain")), params:get("rec_norm") == 2 and amp(-6) or 0,
    params:get("rec_src") - 1, mon <= DB_FLOOR and 0 or amp(mon))
  dirty = true
end

function REC.stop()
  if REC.state ~= "rec" then return end
  local quiet = REC.metered and REC.peak < 0.0005
  local bad = quiet or util.time() - REC.t0 < 0.3
  engine.rec_stop(bad and 0 or 1)
  if bad then return REC.finish(quiet and "no input" or "too short") end
  REC.state, REC.wait, dirty = "save", util.time() + 10, true
end

function REC.frac(v)
  if not v or v <= 0 then return 0 end
  return (20 * math.log(max(v, 1e-5), 10) + 48) / 48
end

local function scan(dir, f)
  local ok, entries = pcall(util.scandir, dir)
  if ok and entries then for _, e in ipairs(entries) do f(e) end end
end

function REC.sweep(kind, doit)
  local used, gone = {}, {}
  for i = 1, NV do local f = V[i].file if f then used[f:match("[^/]+$") or f] = true end end
  if REC.path then used[REC.path:match("[^/]+$")] = true end
  local dir = norns and norns.state and norns.state.data
  if dir then
    scan(dir, function(e)
      local f = e:sub(-5):lower() == ".pset" and io.open(dir .. e, "r")
      if not f then return end
      for line in f:lines() do for name in line:gmatch("([^/\"%s]+%.[Ww][Aa][Vv])") do used[name] = true end end
      f:close()
    end)
  end
  local prefix = REC.kinds[kind]
  scan(REC.dir, function(e)
    if e:sub(1, #prefix) == prefix and e:sub(-4):lower() == ".wav" and not used[e] then gone[#gone + 1] = e end
  end)
  if not doit then return #gone end
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
  if REC.state or REC.bend > 0 then return end
  menu_close()
  local n = REC.sweep(kind, false)
  REC.kind = kind
  if n < 1 then return REC.finish("nothing unused") end
  REC.txt, REC.state, REC.wait, dirty = string.format("delete %d?", n), "confirm", util.time() + 10, true
end

function REC.confirm(yes)
  if REC.state ~= "confirm" then return end
  if not yes then return REC.finish(nil) end
  REC.state = nil
  REC.finish(REC.sweep(REC.kind, true) .. " deleted")
end

function REC.place(i, path, fresh)
  if fresh then
    local p = PID[i]
    params:set(p.vol, VOL_DEF) params:set(p.tune, 0) params:set(p.bstart, 0) params:set(p.bwidth, 100)
  end
  load_voice(i, path, 3600, 0)
  sel = i
end

function REC.done(ok)
  if REC.state ~= "save" then return end
  if not ok then return REC.finish("write failed") end
  REC.place(clamp(REC.target, 1, NV), REC.path, REC.fresh)
  REC.finish(nil)
end

function REC.bounced()
  local i = REC.bto
  REC.bend, REC.bto = 0, nil
  if not i then return end
  if REC.bnew and V[i].file then i = REC.free_slot() end
  if not i then
    if not REC.state then REC.finish("no free voices") end
    return
  end
  REC.place(i, REC.bpath, REC.bnew)
end

function REC.bounce(mode)
  if REC.bend > 0 then return end
  local to
  if mode == "new" then
    to = REC.free_slot()
    if not to then
      if not REC.state then REC.finish("no free voices") end
      return
    end
  elseif mode then
    to = max(sel, 1)
  end
  local d, xf = params:get("bounce_len"), params:get("bounce_xf")
  local name, now = "grains_" .. os.date("%y%m%d_%H%M%S"), util.time()
  REC.bend, REC.bto, REC.bnew, REC.bpath = now + d + xf + 10, to, mode == "new", REC.dir .. name .. ".wav"
  REC.bt0, REC.blen, REC.bq = now, d + xf, -1
  engine.bounce(d, name, xf, params:get("rec_lnorm") == 2 and amp(-6) or 0)
  dirty = true
end

local MOVEP = {"file", "bstart", "bwidth", "vol", "tune"}

local function move_slot(src, dst)
  if src == dst then return end
  local ps, pd, pv = PID[src], PID[dst], {}
  for _, k in ipairs(MOVEP) do pv[k] = params:get(ps[k]) end
  local frz, lck = params:get("freeze" .. src), params:get("lock_v" .. src)
  V[dst], V[src] = V[src], new_voice()
  engine.move(src - 1, dst - 1)
  for _, k in ipairs(MOVEP) do params:set(pd[k], pv[k], true) end
  params:set(ps.file, AUDIO, true) params:set(ps.bstart, 0, true) params:set(ps.bwidth, 100, true)
  params:set(ps.vol, VOL_DEF, true) params:set(ps.tune, 0, true)
  params:set("freeze" .. dst, frz, true) params:set("lock_v" .. dst, lck, true)
  params:set("freeze" .. src, 0, true) params:set("lock_v" .. src, 0, true)
  freeze_refresh()
  lock_refresh()
  for _, k in ipairs(MOVEP) do if k ~= "file" then Morph.move(ps[k], pd[k]) end end
  for k = 1, lord_n do
    if lord[k] == src then lord[k] = dst elseif lord[k] == dst then lord[k] = src end
  end
  if sel == src then sel = dst end
  if V[dst].raw then xf_in(V[dst]) end
  pop_dirty, voices_dirty, dirty = true, true, true
end

local function locked(i) return V[i].file ~= nil and V[i].lck end

local function locked_count()
  local n = 0
  for i = 1, NV do if locked(i) then n = n + 1 end end
  return n
end

local function keep_for(n)
  local take, nlk, keep = {}, locked_count(), {}
  n = max(n, nlk)
  local room = n - nlk
  for i = 1, NV do
    if locked(i) then take[i] = true
    elseif V[i].file and room > 0 then take[i], room = true, room - 1 end
  end
  for i = 1, NV do if take[i] then keep[#keep + 1] = i end end
  return keep, n
end

local function compact_to(keep)
  local survive = {}
  for _, i in ipairs(keep) do survive[i] = true end
  for i = 1, NV do if V[i].file and not survive[i] then clear_voice(i) end end
  for k, i in ipairs(keep) do if i ~= k then move_slot(i, k) end end
end

local function clear_all()
  for i = 1, NV do
    clear_voice(i)
    params:set(PID[i].vol, VOL_DEF)
    params:set("lock_v" .. i, 0, true)
    params:set("freeze" .. i, 0, true)
  end
  lock_refresh()
  freeze_refresh()
  refresh_layout()
end

local function fresh_pool(roll)
  local used, pool = {}, {}
  for i = 1, NV do
    local f = V[i].file
    if f and not (roll and roll[i]) then used[f] = true end
  end
  for _, f in ipairs(file_list) do if not used[f] then pool[#pool + 1] = f end end
  return #pool > 0 and pool or file_list
end

local function scan_source(after)
  local dir = params:get("source")
  if not dir or dir == "" or dir == "-" then dir = AUDIO end
  if dir:sub(-1) ~= "/" then dir = dir:match("^(.*/)") or AUDIO end
  if dir == scanned_dir then return #file_list > 0 end
  if after then scan_wait = after end
  if scan_busy then return nil end
  scan_busy = true
  tape.scan(dir, 2000, 6, function(list, capped, deep)
    scan_busy = false
    if sys.dead then return end
    file_list = list
    print(string.format("grains: %d sample%s in %s%s", #list, #list == 1 and "" or "s", dir,
      capped and " (capped at 2000 -- point SOURCE at a subfolder to reach the rest)" or deep and " (stopped at 6 folders deep)" or ""))
    scanned_dir = #list > 0 and dir or nil
    local f = scan_wait
    scan_wait = nil
    if f then f(#list > 0) end
  end)
end

local function load_random_into(slots, scanned)
  if #slots < 1 then return end
  if not (scanned or scan_source(function(ok) if ok then load_random_into(slots, true) end end)) then return end
  local target = {}
  for _, i in ipairs(slots) do target[i] = true end
  local chosen = tape.pick(fresh_pool(target), #slots)
  layout_busy = true
  for k, i in ipairs(slots) do if chosen[k] then load_voice(i, chosen[k]) end end
  layout_busy = false
  refresh_layout()
end

local function load_n(n, keep_vol)
  local keep, want = keep_for(clamp(floor(n), 1, NV))
  layout_busy = true
  compact_to(keep)
  layout_busy = false
  local slots = {}
  for i = 1, want do if not locked(i) then slots[#slots + 1] = i end end
  if not keep_vol then for _, i in ipairs(slots) do params:set(PID[i].vol, VOL_DEF) end end
  if #slots < 1 then return refresh_layout() end
  for _, i in ipairs(slots) do unload_view(V[i]) end
  redraw()
  local function go(ok)
    if ok then return load_random_into(slots, true) end
    for _, i in ipairs(slots) do clear_voice(i) end
    refresh_layout()
  end
  local ok = scan_source(go)
  if ok ~= nil then go(ok) end
end

local src = {}

function src.reload()
  Undo.mark()
  load_n(nva < 1 and DEFAULT_NV or nva, true)
end

function src.reslice()
  if count_files() < 1 then return end
  layout_busy = true
  for i = 1, NV do if V[i].file and not locked(i) then load_voice(i, V[i].file) end end
  layout_busy = false
  refresh_layout()
end

function src.set_count(n)
  n = max(clamp(floor(n), 1, NV), locked_count())
  local cur = count_files()
  if n == cur then return end
  layout_busy = true
  if n < cur then
    compact_to((keep_for(n)))
  else
    local need = 0
    for i = 1, n do if not V[i].file then need = need + 1 end end
    if need > 0 then
      if not scan_source(function(ok) if ok then src.set_count(n) end end) then
        layout_busy = false
        return false
      end
      local chosen, k = tape.pick(fresh_pool(), need), 0
      for i = 1, n do
        if not V[i].file then
          k = k + 1
          if chosen[k] then
            params:set(PID[i].vol, VOL_DEF)
            params:set(PID[i].tune, 0)
            load_voice(i, chosen[k])
          end
        end
      end
    end
  end
  layout_busy = false
  refresh_layout()
  return true
end

function src.nudge_count(step)
  local cur = count_files()
  if cur < 1 and step < 0 then return end
  local want = clamp(cur + step, 1, NV)
  if want == cur then return end
  Undo.mark("voices")
  src.set_count(want)
end

local function reseed_voices(reorder)
  glide = GLIDE_N
  local held, any = {}, false
  for i = 1, NV do
    held[i] = V[i].frz or V[i].lck
    any = any or held[i]
  end
  if reorder then
    local prev, prevn = {}, -1
    if any then
      build_order()
      prevn = lord_n
      for k = 1, lord_n do prev[k] = lord[k] end
    end
    params:set("lseed", random(9999))
    build_order()
    if any and prevn == lord_n and lord_n > 0 then
      local j, out = 0, {}
      for k = 1, lord_n do
        if held[prev[k]] then
          out[k] = prev[k]
        else
          repeat j = j + 1 until j > lord_n or not held[lord[j]]
          out[k] = j <= lord_n and lord[j] or prev[k]
        end
      end
      for k = 1, lord_n do lord[k] = out[k] end
    end
  end
  flush_population()
  local anyheld = false
  for i = 1, nva do
    local v = V[i]
    if held[i] then
      anyheld = true
    else
      local pit, lw = v.pit, v.lw
      pit:reroll(v.lo * SPAN, v.hi * SPAN)
      for L = 1, lcap do
        local a, b = pit:window(L)
        v.ts[L], v.te[L], wbuf[L * 2 - 1], wbuf[L * 2], lw[L * 2 - 1], lw[L * 2] = a, b, a, b, a, b
      end
      if v.on then WIN_FN(i - 1, table.unpack(wbuf, 1, WIN_N)) end
    end
  end
  reroll_seeds()
  push_per_voice()
  if anyheld then
    for i = 1, nva do if not held[i] then engine.reseed_one(i - 1) end end
  else
    engine.reseed()
  end
end

local function rolls(id) return params:get("lock_" .. id) == 1 end
local function fxlocked(g) return params:get("fxlock_" .. g) == 1 end
local function rset(id, lo, hi, e) params:set(id, (e and Dice.rndexp or Dice.rnd)(lo, hi)) end

local DICE = {
  {"tune", function()
    local c = Dice.pick(Dice.TUNING)
    for i, r in ipairs(Dice.tuning_rows(c)) do
      params:set(MD[i], r.interval) params:set("weight" .. i, r.weight) params:set("vdb" .. i, r.db)
    end
    if locked_count() == 0 then
      params:set("tuning", Dice.roll_root())
      params:set("scale", random(Scale.CHROMATIC - 1))
    end
    params:set("spread", Dice.rnd(15, 100) * c.spread)
  end},
  {"motion", function()
    local c = Dice.pick(Dice.MOTION)
    local p = Dice.chance(35) and Dice.pick_contrast(Dice.MOTION, c) or c
    rset("motionrate", c.mr[1], c.mr[2], true)
    rset("pitchrate", p.mr[1], p.mr[2], true)
    rset("rateslew", c.slew[1], c.slew[2], true)
    params:set("reverse", Dice.rnd(c.rev[1], c.rev[2]) * 100)
    rset("ampfloor", c.floor[1], c.floor[2])
  end},
  {"space", function()
    local c = Dice.pick(Dice.SPACE)
    rset("panwidth", c.pan[1], c.pan[2])
    rset("variance", 0, 100)
    if not fxlocked("delay") then
      local d = c.dly
      if Sync.dly_synced() then params:set("d_div", random(3, 14)) end
      rset("d_time", d.time[1], d.time[2], true) rset("d_fb", d.fb[1], d.fb[2]) rset("d_lpf", d.lpf[1], d.lpf[2], true)
      rset("d_hpf", d.hpf[1], d.hpf[2], true) rset("d_stereo", d.stereo[1], d.stereo[2]) rset("d_duck", d.duck[1], d.duck[2])
      rset("d_wrate", d.wrate[1], d.wrate[2]) rset("d_wdepth", d.wdepth[1], d.wdepth[2])
    end
    if not fxlocked("shimmer") then
      local h = c.shm
      params:set("sh_oct", random(h.oct[1], h.oct[2]))
      rset("sh_fb", h.fb[1], h.fb[2]) rset("sh_pitchv", h.pitchv[1], h.pitchv[2]) rset("sh_fbdelay", h.fbdelay[1], h.fbdelay[2])
      rset("sh_lowpass", h.lpf[1], h.lpf[2], true) rset("sh_hipass", h.hpf[1], h.hpf[2], true)
    end
  end},
  {"shape", function()
    local c = Dice.pick(Dice.SHAPE)
    for i = 1, NV do
      if not V[i].lck then
        local cc = random() < 0.35 and Dice.pick(Dice.SHAPE) or c
        local a, w = Dice.rnd(cc.start[1], cc.start[2]), Dice.rnd(cc.width[1], cc.width[2])
        if a + w > 1 then a = max(0, 1 - w) end
        params:set(PID[i].bstart, a * 100)
        params:set(PID[i].bwidth, w * 100)
      end
    end
  end},
  {"fx", function()
    local set = function(id, v) params:set(id, v) end
    Dice.fx_roll(set, fxlocked)
    Dice.fx_settings(set, fxlocked)
  end}
}

local function dice()
  glide = GLIDE_N
  Morph.gesture(function()
    ovr_capture()
    dicing = true
    for _, d in ipairs(DICE) do if rolls(d[1]) and not (d[1] == "tune" and orig) then d[2]() end end
    if rolls("voice") then
      for i = 1, NV do
        if not V[i].lck then
          params:set(PID[i].vol, Dice.rnd(-24, 3))
          if not orig then params:set(PID[i].tune, Shuffle.snap(random(Shuffle.PITCH_LO, Shuffle.PITCH_HI))) end
        end
      end
    end
    dicing = false
    reseed_voices(true)
  end)
end

local function state_get()
  build_order()
  local vs = {}
  for i = 1, NV do
    local v, sd, o = V[i], {}, V[i].ovr and {}
    for _, f in ipairs(SEEDF) do sd[f] = v.seedT[f] end
    if o then for id, x in pairs(v.ovr) do o[id] = x end end
    vs[i] = {f = v.file, at = v.at, len = v.len, sd = sd, p = v.pit:dump(), o = o,
      pin = v.lck and v.pin or nil, r = v.frz and {v.rlo, v.rhi, v.vd} or nil}
  end
  return {v = vs, ord = {table.unpack(lord, 1, lord_n)}, dens = floor(DENSP:get()), m = Morph.save()}
end

local function state_set(t)
  freeze_refresh()
  for i = 1, NV do
    local v, s = V[i], t.v[i]
    local p, sd = v.pit, s.sd
    v.lck = params:get("lock_v" .. i) == 1
    v.ovr, v.pin = v.lck and s.o or nil, v.lck and s.pin or nil
    for _, f in ipairs(SEEDF) do v.seed[f], v.seedT[f] = sd[f], sd[f] end
    if v.frz and s.r then v.rlo, v.rhi, v.vd = s.r[1], s.r[2], s.r[3] end
    if p.n * 3 == #s.p then
      p:load(s.p)
      local lw = v.lw
      for L = 1, lcap do
        local a, b = p:window(L)
        v.ts[L], v.te[L], lw[L * 2 - 1], lw[L * 2], wbuf[L * 2 - 1], wbuf[L * 2] = a, b, a, b, a, b
      end
      if v.file then WIN_FN(i - 1, table.unpack(wbuf, 1, WIN_N)) end
    end
  end
  local ord, n = t.ord, #t.ord
  if n == nva * lcap then
    for k = 1, n do lord[k] = ord[k] end
    lord_n, lord_key = n, order_key()
  end
  local d = min(t.dens, DENSP.max)
  params:set("density", d, true)
  dfrac = DENSP.max > 0 and d / DENSP.max or 0
  Morph.load(t.m)
  params:set("morph", Morph.pos * 100, true)
  push_vps()
  sglide, glide, pop_dirty, voices_dirty, dirty = 0, GLIDE_N, true, true, true
end

local function ser(x, o)
  local t = type(x)
  if t == "table" then
    o[#o + 1] = "{"
    for k = 1, #x do ser(x[k], o) o[#o + 1] = "," end
    for k, y in pairs(x) do
      if type(k) == "string" then o[#o + 1] = string.format("[%q]=", k) ser(y, o) o[#o + 1] = "," end
    end
    o[#o + 1] = "}"
  elseif t == "number" then
    o[#o + 1] = x ~= x and "0" or x == math.huge and "1e999" or x == -math.huge and "-1e999" or string.format("%.17g", x)
  else
    o[#o + 1] = t == "string" and string.format("%q", x) or tostring(x)
  end
end

local function pset_write(fn)
  local t, o = state_get(), {"return "}
  t.sel, t.mo = sel, morph_on
  ser(t, o)
  local f = io.open(fn .. PSX, "w")
  if f then f:write(table.concat(o)) f:close() end
end

local function pset_read(fn)
  Undo.clear()
  local ok, t = pcall(loadfile(fn .. PSX, "t", {}))
  if not ok or type(t) ~= "table" then return end
  voices_set(t.v)
  state_set(t)
  sel, morph_on = nva < 1 and 0 or clamp(t.sel, 1, nva), t.mo
end

local UN = {ids = {}}
local UN_SKIP = {source = true, morph = true, density = true, quality = true, rev_type = true, d_series = true, binaural = true}

function UN.build(first, last)
  local P = params
  for k = first, last do
    local p = P.params[k]
    local id = p and p.id
    if id and p.t ~= P.tSEPARATOR and p.t ~= P.tGROUP and p.t ~= P.tTRIGGER and p.t ~= P.tTEXT and not UN_SKIP[id]
      and not id:find("^%dfile$") and not id:find("^do_") and not id:find("^rec_") and not id:find("^bounce_")
      and not id:find("^fxlock_") then
      UN.ids[#UN.ids + 1] = id
    end
  end
end

function UN.capture()
  local t, p = state_get(), {}
  for k, id in ipairs(UN.ids) do p[k] = params:get(id) end
  t.p = p
  return t
end

function UN.restore(t)
  local p = t.p
  Morph.hold(function()
    for k, id in ipairs(UN.ids) do
      local x = p[k]
      if params:get(id) ~= x then params:set(id, x) end
    end
  end)
  voices_set(t.v)
  state_set(t)
end

local FXM = {mask = -1, t = 0, blocks = {}, mid = {}, at = {}, on = {}, seq = {}, hv = {}, list = {}}

function FXM.build(last)
  local P = params.params
  FXM.sa, FXM.clr = P[FXM.first], P[FXM.first + 1]
  for k = FXM.first + 2, FXM.split - 1 do FXM.mid[#FXM.mid + 1] = P[k] end
  local i = FXM.split
  while i <= last do
    local blk = {id = P[i].id}
    for k = 0, P[i]:get() do blk[k + 1] = P[i + k] end
    FXM.blocks[#FXM.blocks + 1] = blk
    i = i + #blk
  end
  for k = FXM.first, last do FXM.at[P[k]] = k end
end

local function fx_top(t)
  local P, H, n, i = params.params, params.hidden, 0, 1
  while i <= params.count do
    local p = P[i]
    if not H[i] then n = n + 1 t[n] = p end
    i = i + (p.t == params.tGROUP and p:get() + 1 or 1)
  end
  for k = n + 1, #t do t[k] = nil end
  return t, n
end

function FXM.order(mask)
  local P, H, L, at = params.params, params.hidden, params.lookup, FXM.at
  local M = _menu and _menu.m and _menu.m.PARAMS
  local key = M and (M.group and "oldpos" or "pos")
  local cur = M and type(M[key]) == "number" and fx_top(FXM.list)[M[key] + 1]
  local grp = M and M.group and type(M.groupid) == "number" and P[M.groupid]
  local seq, hv, n = FXM.seq, FXM.hv, 0
  local function put(p) n = n + 1 seq[n], hv[n] = p, H[at[p]] end
  put(FXM.sa)
  for pass = 1, 2 do
    for k, b in ipairs(FXM.blocks) do
      if ((mask >> (k - 1)) & 1 == 1) == (pass == 1) then for j = 1, #b do put(b[j]) end end
    end
    if pass == 1 then
      put(FXM.clr)
      for _, p in ipairs(FXM.mid) do put(p) end
    end
  end
  for k = 1, n do
    local p, i = seq[k], FXM.first + k - 1
    P[i], H[i], at[p] = p, hv[k], i
    if p.id then L[p.id] = i end
  end
  H[at[FXM.sa]], H[at[FXM.clr]] = mask == 0, mask == 0
  if grp then M.groupid = at[grp] or M.groupid end
  if cur and H[at[cur] or 0] then
    local i = at[cur]
    repeat i = i + (P[i].t == params.tGROUP and P[i]:get() + 1 or 1)
    until P[i] == nil or (not H[i] and P[i].t ~= params.tSEPARATOR)
    cur = P[i]
  end
  if M and type(M[key]) == "number" then
    local t, c = fx_top(FXM.list)
    local pos = min(c > 0 and c - 1 or 0, M[key])
    for k = 1, c do if t[k] == cur then pos = k - 1 break end end
    M[key] = pos
  end
  menu_rebuild()
end

function FXM.check(now)
  if not FXM.sa or now < FXM.t then return end
  FXM.t = now + 0.2
  local M = _menu and _menu.m and _menu.m.PARAMS
  if menu_up() and (not M or M.mode == 5) then return end
  font.groups(FXM.on)
  local mask = 0
  for k, b in ipairs(FXM.blocks) do if FXM.on[b.id] then mask = mask | (1 << (k - 1)) end end
  if mask ~= FXM.mask then
    FXM.mask = mask
    FXM.order(mask)
  end
end

local function pop_show(kind, txt) pop.kind, pop.txt, pop.t, dirty = kind, txt, util.time(), true end
local function orig_block() if orig then pop_show("fx", "original pitch") return true end end
local function undo() pop_show("fx", Undo.undo() and "undo" or "nothing to undo") end
local function redo() pop_show("fx", Undo.redo() and "redo" or "nothing to redo") end
local function toggle(id) params:set(id, params:get(id) == 0 and 1 or 0) dirty = true end
local function fast_db(v) return v <= -40 and "OFF" or string.format("%d dB", floor(v + 0.5)) end
local function fxstr(id)
  local v = params:get(id)
  if id == "reverb_mix" then return fast_db(v) end
  return v <= 0 and "OFF" or string.format("%d%%", floor(v + 0.5))
end

local function rev_route()
  local db, sysrev = params:get("reverb_mix"), params:get("rev_type") == 2
  local on = db > -40
  local w = (on and not sysrev) and amp(db) or 0
  if sys.rev_w ~= w then sys.rev_w = w engine.rev_mix(w) end
  if sys.rev == nil then return end
  if not (sysrev and on) then return params:set("reverb", 1) end
  params:set("reverb", 2)
  params:set("rev_eng_input", db)
end

local RESO_V = {{0, 7, 12, 19, 24}, {0, 7, 14, 21, 28}, {0, 4, 7, 12, 16}, {0, 3, 7, 12, 15}, {0, 4, 7, 11, 14},
  {0, 3, 7, 10, 14}, {0, 12, 19.0196, 24, 27.8631}, {0, 12, 24, 36, 48}}
local reso = {v = 1, tones = {}, sent = {}}

local function reso_root() return clamp(params:get("reso_root") + params:get("tuning"), 24, 128) end

local function reso_update()
  if params:get("reso_mix") <= 0 then return end
  local d, base, diff = RESO_V[reso.v] or Scale.chord(params:get("scale"), reso.tones), reso_root() - 69, false
  for i = 1, 5 do
    local f = 440 * 2 ^ ((base + d[i]) / 12)
    if reso.sent[i] ~= f then reso.sent[i], diff = f, true end
  end
  if diff then engine.reso_freqs(table.unpack(reso.sent, 1, 5)) end
end

local function key_fx()
  reso_update()
  local f = Scale.fifth(params:get("scale"))
  if f == reso.fifth then return end
  reso.fifth = f
  engine.gl_ratios(0.5, f and 0.7491535 or 0.5, f and 1.4983071 or 2, 2)
end

local SPIRAL = {{0.5, "oct down"}, {2 / 3, "5th down"}, {0.75, "4th down"}, {1, "unison"}, {4 / 3, "4th up"}, {1.5, "5th up"}, {2, "oct up"}}
local function spiral(v) return SPIRAL[floor((v + 100) * 0.03 + 0.5) + 1] end

local function short_name(v, dir)
  if type(v) ~= "string" or v == "" or v == "-" then return "-" end
  local s
  if dir then
    s = (v:sub(-1) == "/" and v or v:match("^(.*/)") or AUDIO):match("([^/]+)/$") or "/"
  else
    if v:sub(-1) == "/" then return "-" end
    s = v:match("[^/]+$") or v
    local stem, ext = s:match("^(.+)%.(%w+)$")
    if stem and #ext <= 4 then s = stem end
  end
  return #s > 24 and s:sub(1, 22) .. ".." or s
end

local function setup_params()
  local esent, OPT = {}, {}
  local function send(id, v) if esent[id] ~= v then esent[id] = v engine[id](v) end end
  local function act(id, a)
    if a == true then a = function(v) send(id, v) end
    elseif a == OPT then a = function(x) send(id, x - 1) end
    elseif type(a) == "number" then local k = a a = function(v) send(id, v * k) end end
    if a then params:set_action(id, a) end
  end
  local function ctl(id, name, lo, hi, warp, step, def, unit, a) params:add_control(id, name, controlspec.new(lo, hi, warp, step, def, unit)) act(id, a) end
  local function pct(id, name, def, a) ctl(id, name, 0, 100, "lin", 1, def, "%", a or 0.01) end
  local function opt(id, name, list, def, a) params:add_option(id, name, list, def or 1) act(id, a) end
  local function num(id, name, lo, hi, def, fmt, a) params:add_number(id, name, lo, hi, def, fmt) act(id, a) end
  local function tap(id, name, lo, hi, def, k, unit, a) params:add_taper(id, name, lo, hi, def, k, unit) act(id, a) end
  local function trig(id, name, f) params:add_binary(id, name, "trigger", 0) act(id, function(v) if v == 1 then f() end end) end
  local function flag(id, name, a) params:add_binary(id, name, "toggle", 0) act(id, a) end
  local function str(id, f) params:lookup_param(id).string = f end
  local function fxlock(g) params:add_binary("fxlock_" .. g, "Lock", "toggle", 0) end
  local function group(id, name, n) params:add_group("grains_" .. id, name, n) end
  local OFFON, TB, NORM = {"OFF", "ON"}, {"free", "clock"}, {"OFF", "-6 dB"}
  local HIDDEN = {"grains_tune", "level", "lseed", "morph_seed", "grains_hold"}
  local function vlfo_apply()
    Sync.vset(params:get("vlfo_shape"), params:get("vlfo_freq"), params:get("vlfo_depth"))
    Sync.vlagdirty = false
    push_lag()
    if not Sync.von then voices_dirty = true end
  end
  local function rlfo_vis() Sync.rset() Sync.vis() end
  local function series_str(p)
    local v = p:get()
    return v <= 0 and "parallel" or v >= 100 and "series" or string.format("%d%%", floor(v + 0.5))
  end
  local function rate_str(p) local v = p:get() return v <= RATE_OFF and "OFF" or string.format("%.2f x", v) end

  sys.first = #params.params + 1
  params:add_separator("  ")
  for i = 1, NV do
    params:add_file(PID[i].file, "S" .. i, AUDIO)
    act(PID[i].file, function(path) if path and path ~= "" and path ~= "-" then fpend[i] = path end end)
    str(PID[i].file, function(p) return short_name(p:get()) end)
  end

  FXM.first = #params.params + 1
  params:add_separator("fx_active", " ")
  trig("do_fx_clear", "Clear All", function() Undo.mark() Morph.gesture(font.clear) FXM.t = 0 end)
  params:add_separator(" ")

  group("main", "VOICES", 16)
  ctl("level", "Level", DB_FLOOR, LEVEL_MAX, "lin", 0.5, -20, "dB", function(v)
    local a = v <= DB_FLOOR + 0.5 and 0 or amp(v - LEVEL_REF)
    if esent.level ~= a then esent.level = a engine.master(a) end
  end)
  num("density", "Density", 0, NV * NL, 0, nil, function(v)
    if not layout_busy then dfrac = DENSP.max > 0 and clamp(v / DENSP.max, 0, 1) or 0 end
    pop_dirty = true
  end)
  flag("pitch_lock", "Original Pitch", function(v) orig, voices_dirty = v == 1, true push_vp(VP[1]) end)
  ctl("tuning", "Tuning", -48, 48, "lin", 1, 0, "st")
  opt("scale", "Scale", Scale.NAMES, Scale.DEFAULT)
  ctl("spread", "Voice Spread", 0, 100, "lin", 1, 75, "%")
  ctl("lspread", "Layer Spread", 0, 200, "lin", 1, 100, "%")
  ctl("variance", "Voice Variance", 0, 100, "lin", 1, 50, "%")
  ctl("motionrate", "Energy", 0.05, 8, "exp", 0, 1, "x")
  ctl("pitchrate", "Pitch Change", 0.05, 8, "exp", 0, 1, "x")
  str("motionrate", rate_str)
  str("pitchrate", rate_str)
  ctl("reverse", "Reverse Chance", 0, 100, "lin", 1, 10, "%")
  ctl("rateslew", "Rate Slew", 0.005, 10, "exp", 0, 1.5, "s")
  ctl("panwidth", "Pan Width", 0, 100, "lin", 1, 90, "%")
  ctl("ampfloor", "Level Floor", 0, 100, "lin", 1, 25, "%")
  flag("freeze_all", "Freeze All", freeze_refresh)
  opt("quality", "Interpolation", {"cubic", "linear (eco)"}, 1, OPT)

  group("lfo", "LFO", 14)
  opt("vlfo", "Volume LFO", OFFON, 1, function(v)
    Sync.venable(v == 2)
    Shuffle.vol.step = Sync.von and 0.5 or 1
    voices_dirty = true
    vlfo_apply()
    Sync.vis()
  end)
  opt("vlfo_shape", "Shape", Sync.SHAPES, 1, vlfo_apply)
  ctl("vlfo_depth", "Depth", 0, 36, "lin", 0.5, 16, "dB", vlfo_apply)
  ctl("vlfo_freq", "Free Cycle", 0.02, 10, "exp", 0, 0.2, "Hz", vlfo_apply)
  opt("vlfo_sync", "Time Base", TB, 1, function() vlfo_apply() Sync.vis() end)
  num("vlfo_div", "Division", 1, Sync.NDIV, Sync.DIV_BAR, Sync.vfmt, vlfo_apply)
  opt("rlfo", "Region LFO", OFFON, 1, rlfo_vis)
  opt("rlfo_mode", "Mode", {"scan", "breathe", "orbit"}, 1, Sync.rset)
  opt("rlfo_shape", "Shape", Sync.SHAPES, 1, Sync.rset)
  ctl("rlfo_depth", "Depth", 0, 100, "lin", 1, 50, "%", Sync.rset)
  ctl("rlfo_spread", "Spread", 0, 100, "lin", 1, 50, "%", Sync.rset)
  ctl("rlfo_freq", "Free Cycle", 0.01, 4, "exp", 0, 0.05, "Hz", Sync.rset)
  opt("rlfo_sync", "Time Base", TB, 1, rlfo_vis)
  num("rlfo_div", "Division", 1, Sync.NDIV, 16, Sync.rfmt, Sync.rset)

  group("tune", "TUNING", 15)
  for i, d in ipairs({{14, 0, 0}, {8, -12, 4}, {3, 24, -18}, {6, 12, -8}, {4, -24, 2}}) do
    ctl("weight" .. i, i .. ") weight", 0, 100, "lin", 1, d[1], "")
    ctl(MD[i], i .. ") tuning", -48, 48, "lin", 1, d[2], "st")
    ctl("vdb" .. i, i .. ") level", -48, 24, "lin", 0.5, d[3], "dB")
    HIDDEN[#HIDDEN + 1], HIDDEN[#HIDDEN + 2], HIDDEN[#HIDDEN + 3] = "weight" .. i, MD[i], "vdb" .. i
  end

  FXM.split = #params.params + 1

  group("reverb", "REVERB", 9)
  opt("rev_type", "Type", {"plate", "system"}, 1, function() rev_route() Sync.vis() end)
  tap("reverb_mix", "Mix", -40, 18, -40, 0, "dB", rev_route)
  str("reverb_mix", function(p) return fast_db(p:get()) end)
  ctl("rev_decay", "Decay", 0.3, 60, "exp", 0, 4, "s", function(v) send("rev_decay", 10 ^ (-0.468 / v)) end)
  ctl("rev_damp", "Damping", 0, 100, "lin", 1, 40, "%", function(v) send("rev_damp", math.exp(-2.356194 * (1 / 30) ^ (v * 0.01))) end)
  ctl("rev_pre", "Pre Delay", 0, 250, "lin", 1, 20, "ms", 0.001)
  pct("rev_mdepth", "Mod Depth", 30)
  ctl("rev_mrate", "Mod Rate", 0.05, 5, "exp", 0, 0.5, "Hz", true)
  ctl("rev_series", "Delay > Reverb", 0, 100, "lin", 1, 25, "%", function(v)
    send("rev_series", v * 0.01)
    params:set("d_series", v, true)
  end)
  str("rev_series", series_str)
  fxlock("reverb")

  group("delay", "DELAY", 14)
  pct("d_mix", "Mix", 0)
  ctl("d_time", "Time", 0.02, 5, "exp", 0, 0.5, "s", Sync.dly_refresh)
  opt("d_sync", "Time Base", TB, 1, function() Sync.dly_refresh() Sync.vis() end)
  num("d_div", "Division", 1, Sync.NDIV, Sync.DIV_QUART, Sync.dly_fmt, Sync.dly_refresh)
  local D_RATIO = {0.25, 1 / 3, 0.5, 2 / 3, 0.75, 1, 4 / 3, 1.5, 2, 3, 4}
  opt("d_ratio", "L/R Ratio", {"4:1", "3:1", "2:1", "3:2", "4:3", "1:1", "3:4", "2:3", "1:2", "1:3", "1:4"}, 6, function(x) send("d_ratio", D_RATIO[x]) end)
  ctl("d_fb", "Feedback", 0, 120, "lin", 1, 40, "%", 0.01)
  ctl("d_lpf", "LPF", 20, 20000, "exp", 1, 7500, "Hz", true)
  ctl("d_hpf", "HPF", 20, 20000, "exp", 1, 200, "Hz", true)
  pct("d_wdepth", "Mod Depth", 25)
  ctl("d_wrate", "Mod Freq", 0, 20, "lin", 0.1, 2, "Hz", true)
  pct("d_stereo", "Ping-Pong", 20)
  pct("d_duck", "Ducking", 17)
  ctl("d_series", "Delay > Reverb", 0, 100, "lin", 1, 25, "%", function(v) params:set("rev_series", v) end)
  str("d_series", series_str)
  fxlock("delay")

  group("shimmer", "SHIMMER", 9)
  pct("sh_mix", "Mix", 0)
  opt("sh_mod", "Mix Mod", OFFON, 1, OPT)
  local SH_OCT = {0.25, 0.5, 1, 2, 4}
  opt("sh_oct", "Pitch Shift", {"-2 oct", "-1 oct", "0", "+1 oct", "+2 oct"}, 4, function(x) send("sh_oct", SH_OCT[x]) end)
  pct("sh_pitchv", "Variance", 2)
  ctl("sh_lowpass", "LPF", 20, 20000, "lin", 1, 13000, "Hz", true)
  ctl("sh_hipass", "HPF", 20, 20000, "exp", 1, 1400, "Hz", true)
  ctl("sh_fbdelay", "Delay", 0.01, 0.5, "lin", 0.01, 0.2, "s", true)
  pct("sh_fb", "Feedback", 20)
  fxlock("shimmer")

  group("tape", "TAPE", 11)
  opt("tape_mix", "Tape Sim", OFFON, 1, OPT)
  pct("reel_mix", "Saturation", 0)
  pct("shaper_mix", "Shaper Drive", 0)
  pct("wobble_mix", "Wobble", 0)
  pct("wobble_amp", "Wow Depth", 20)
  ctl("wobble_rpm", "Wow Speed", 30, 90, "lin", 1, 33, "rpm", true)
  pct("flutter_amp", "Flutter Depth", 35)
  ctl("flutter_freq", "Flutter Speed", 3, 30, "lin", 0.01, 6, "Hz", true)
  ctl("flutter_var", "Flutter Var", 0.1, 10, "lin", 0.01, 2, "Hz", true)
  pct("genloss_mix", "More Tape", 0)
  fxlock("tape")

  group("dimension", "STEREO", 5)
  ctl("m_width", "Width", 0, 200, "lin", 1, 100, "%", 0.01)
  opt("haas", "Haas Effect", OFFON, 1, OPT)
  opt("binaural", "Binaural Pan", OFFON, 1, OPT)
  tap("rspeed", "Rotation", 0, 1, 0, 1, "Hz", true)
  str("rspeed", function(p) local v = p:get() return v <= 0 and "OFF" or string.format(v < 0.1 and "%.3f Hz" or "%.2f Hz", v) end)
  fxlock("dimension")

  group("chorus", "CHORUS", 5)
  pct("dimension_mix", "Dimension", 0)
  pct("stchorus_mix", "Stereo Chorus", 0)
  pct("vibe_mix", "Vibe", 0)
  pct("vibe_drift", "Vibe Drift", 50)
  fxlock("chorus")

  group("eq", "EQ", 5)
  ctl("eq_low", "Bass", -20, 20, "lin", 0.5, 0, "dB", true)
  ctl("eq_mid", "Mid", -20, 20, "lin", 0.5, 0, "dB", true)
  ctl("eq_high", "Treble", -20, 20, "lin", 0.5, 0, "dB", true)
  ctl("tilt", "Tilt", -1, 1, "lin", 0.01, 0, "", 12)
  fxlock("eq")

  group("tone", "FILTER", 4)
  ctl("cutoff", "LPF", 20, 20000, "exp", 1, 20000, "Hz")
  ctl("res", "Resonance", 0, 100, "lin", 1, 20, "%")
  ctl("vhpf", "HPF", 20, 800, "exp", 1, 20, "hz")
  fxlock("tone")

  group("bitcrush", "BITCRUSH", 5)
  pct("bc_mix", "Mix", 0)
  opt("bc_mod", "Mix Mod", OFFON, 1, OPT)
  tap("bc_rate", "Rate", 1, 48000, 4500, 3, "Hz", true)
  tap("bc_bits", "Bits", 1, 24, 14, 1, "", true)
  fxlock("bitcrush")

  group("wavefold", "WAVEFOLD", 4)
  pct("wf_mix", "Mix", 0)
  pct("wf_drive", "Drive", 75)
  pct("wf_sym", "Symmetry", 0)
  fxlock("wavefold")

  group("reso", "RESONATE", 5)
  pct("reso_mix", "Mix", 0, function(v)
    if esent.reso_mix == v * 0.01 then return end
    send("reso_mix", v * 0.01)
    reso_update()
  end)
  ctl("reso_decay", "Decay", 0.01, 5, "exp", 0, 2, "s", true)
  num("reso_root", "Root", 24, 128, 28, function() return MusicUtil.note_num_to_name(floor(reso_root()), true) end, reso_update)
  opt("reso_voicing", "Voicing", {"5th+oct", "fifths", "major", "minor", "maj7", "min7", "harmonic", "octaves", "scale"}, 9,
    function(v) reso.v = v reso_update() end)
  fxlock("reso")

  group("ringmod", "RINGMOD", 4)
  pct("ringmod_mix", "Mix", 0)
  ctl("ringmod_rate", "Freq", 0.1, 4000, "exp", 0, 800, "Hz", true)
  pct("ringmod_sweep", "Sweep", 30)
  fxlock("ringmod")

  group("spiral", "SPIRAL", 8)
  pct("spiral_mix", "Mix", 0)
  local SDIV = {0.125, 1 / 6, 0.25, 1 / 3, 0.5, 0.75, 1, 1.5}
  opt("spiral_div", "Division", {"1/32", "1/16T", "1/16", "1/8T", "1/8", "1/8.", "1/4", "1/4."}, 5,
    function(v) engine.spiral_bpm(clock.get_tempo()) engine.spiral_div(SDIV[v]) end)
  pct("spiral_feedback", "Feedback", 50)
  ctl("spiral_rise", "Rise", -100, 100, "lin", 1, 50, "%", function(v)
    local r = spiral(v)[1]
    engine.spiral_rise(r >= 1 and r * 0.5 or r - 0.5)
  end)
  str("spiral_rise", function(p) return spiral(p:get())[2] end)
  pct("spiral_glide", "Glide", 0)
  pct("spiral_span", "Span", 50)
  pct("spiral_tone", "Tone", 50)
  clock.tempo_change_handler = function(bpm) engine.spiral_bpm(bpm) end
  fxlock("spiral")

  group("sub", "SUB", 3)
  pct("sub_mix", "Mix", 0)
  pct("sub_detune", "Detune", 65)
  fxlock("sub")

  group("ott", "MULTIBAND", 2)
  pct("ott_mix", "Comp", 0)
  fxlock("ott")

  group("glitch", "GLITCH", 10)
  pct("gl_ratio", "Glitch", 0, function(v) engine.gl_ratio((v * 0.01) ^ 2) end)
  pct("gl_mix", "Mix", 100)
  ctl("gl_min", "Min Length", 10, 500, "lin", 1, 75, "ms", 0.001)
  ctl("gl_max", "Max Length", 20, 500, "lin", 1, 200, "ms", 0.001)
  num("gl_stutters", "Max Stutters", 2, 20, 5, nil, true)
  pct("gl_rev", "Reverse Chance", 0)
  pct("gl_pitch", "Pitch Chance", 0)
  ctl("gl_gate", "Gate", 5, 100, "lin", 1, 100, "%", 0.01)
  pct("gl_decay", "Decay", 0)
  fxlock("glitch")
  FXM.build(#params.params)
  for _, id in ipairs({"d_mix", "sh_mix", "reel_mix", "shaper_mix", "wobble_mix", "genloss_mix", "dimension_mix",
    "stchorus_mix", "vibe_mix", "bc_mix", "wf_mix", "reso_mix", "ringmod_mix", "spiral_mix", "sub_mix", "ott_mix", "gl_ratio", "gl_mix"}) do
    local p = params:lookup_param(id)
    local s = p.string
    p.string = function(q) return q:get() <= 0 and "OFF" or s(q) end
  end

  group("gen", "RANDOMIZE", 11)
  trig("do_dice", "Randomize!", function() Undo.mark() dice() end)
  trig("do_reseed", "Reseed Voices", function() Undo.mark() reseed_voices() end)
  trig("do_undo", "Undo", undo)
  trig("do_redo", "Redo", redo)
  num("lseed", "layer order", 1, 9999, 1, nil, function() pop_dirty, dirty = true, true end)
  for _, k in ipairs({"tune", "motion", "space", "shape", "voice"}) do opt("lock_" .. k, k, {"roll", "hold"}) end
  opt("lock_fx", "effects", {"roll", "hold"})

  group("bounds", "PER VOICE", NV * 4)
  for i = 1, NV do
    local p, trim, push = PID[i], function() trim_width(i) end, function() voices_dirty = true end
    ctl(p.bstart, i .. " start", 0, 100, "lin", 0, 0, "%", trim)
    ctl(p.bwidth, i .. " width", 0, 100, "lin", 0, 100, "%", trim)
    ctl(p.vol, i .. " volume", Shuffle.VOL_MIN_DB, Shuffle.VOL_MAX_DB, "lin", 0.5, VOL_DEF, "dB", push)
    num(p.tune, i .. " pitch", Shuffle.PITCH_LO, Shuffle.PITCH_HI, 0, nil, push)
  end

  group("morph", "MORPH", 12)
  ctl("morph", "Morph", 0, 100, "lin", 0.5, 0, "%", function(v)
    if not Sync.driving and Sync.mo_on() then params:set("morph_auto", 1) end
    Morph.set(v * 0.01)
    dirty = true
  end)
  trig("do_store_a", "Store A", function() params:set("morph_auto", 1) Morph.store(1) dirty = true end)
  trig("do_store_b", "Store B", function() params:set("morph_auto", 1) Morph.store(2) dirty = true end)
  trig("do_store_clear", "Clear Morph", function() Morph.clear() dirty = true end)
  opt("morph_auto", "LFO", OFFON, 1, function(v)
    if v == 2 and params:get("morph_depth") <= 0 then params:set("morph_depth", 100) end
    Sync.vis()
    dirty = true
  end)
  ctl("morph_depth", "Depth", 0, 100, "lin", 1, 100, "%")
  opt("morph_shape", "Shape", Sync.SHAPES, 2)
  opt("morph_sync", "Time Base", TB, 2, Sync.vis)
  num("morph_div", "Division", 1, Sync.NDIV, Sync.DIV_4BAR, Sync.mo_fmt)
  ctl("morph_rate", "Free Cycle", 0.25, 600, "exp", 0, 20, "s")
  ctl("morph_slew", "Smoothing", 0, 8, "lin", 0.01, 0.1, "s")
  num("morph_seed", "Motion Seed", 1, 9999, 1)

  group("bounce", "RECORD", 15)
  params:add_separator("Record Input")
  ctl("rec_gain", "Gain", -24, 24, "lin", 0.5, 0, "dB")
  ctl("rec_max", "Max Time", 2, 60, "lin", 1, 30, "s")
  opt("rec_norm", "Normalize", NORM, 2)
  opt("rec_src", "Source", {"stereo", "mono sum", "left", "right"}, 2)
  ctl("rec_mon", "Monitor", DB_FLOOR, 12, "lin", 0.5, 0, "dB")
  str("rec_mon", function(p) local v = p:get() return v <= DB_FLOOR and "OFF" or string.format("%.1f dB", v) end)
  trig("do_clean_in", "Clean Input Recordings!", function() REC.clean("input") end)
  params:add_separator("Record Loop")
  ctl("bounce_len", "Loop Length", 1, 60, "lin", 0.5, 8, "s")
  ctl("bounce_xf", "Crossfade", 0.1, 5, "lin", 0.1, 1, "s")
  opt("rec_lnorm", "Normalize", NORM, 2)
  trig("do_bounce", "RECORD LOOP!", function() REC.bounce() menu_close() end)
  trig("do_bounce_a", "BOUNCE to Active", function() REC.bounce("active") menu_close() end)
  trig("do_bounce_n", "BOUNCE to New", function() REC.bounce("new") menu_close() end)
  trig("do_clean_loop", "Clean Loops!", function() REC.clean("loop") end)

  group("hold", "FREEZE / LOCK", NV * 2)
  for i = 1, NV do
    flag("freeze" .. i, i .. " freeze", freeze_refresh)
    flag("lock_v" .. i, i .. " lock", function(v)
      if v ~= 1 then V[i].pin = nil end
      lock_refresh()
      params:set("density", clamp(floor(dfrac * DENSP.max + 0.5), 0, DENSP.max), true)
      pop_dirty = true
    end)
  end

  group("src", "SOURCE", NV + 6)
  trig("do_clear", "Unload All", function() Undo.mark() clear_all() end)
  trig("do_reload", "Load Random", src.reload)
  for n = 1, NV do trig("do_load" .. n, "Load " .. n .. " Random", function() Undo.mark() load_n(n) end) end
  params:add_file("source", "Folder", AUDIO)
  act("source", function() scanned_dir = nil end)
  str("source", function(p) return short_name(p:get(), true) end)
  trig("do_rescan", "Re-scan Folder", function() scanned_dir = nil scan_source() end)
  ctl("chunk", "Slice Length", 2, 60, "lin", 0.5, 15, "s")
  trig("do_reslice", "Re-slice", function() Undo.mark() src.reslice() end)

  for _, p in ipairs(VP) do
    act(p[2], function()
      if not dicing then ovr_clear(p[2]) end
      push_vp(p)
    end)
  end
  for _, id in ipairs({"lspread", table.unpack(SCALARS)}) do
    local post = id == "tuning" and reso_update or id == "scale" and key_fx
    G[id] = params:get(id)
    act(id, function(v)
      G[id] = v
      if not dicing then ovr_clear(id) end
      voices_dirty = true
      if post then post() end
    end)
  end

  DENSP = params:lookup_param("density")
  for i = 1, NV do
    local p = PID[i]
    p.volp, p.tunep = params:lookup_param(p.vol), params:lookup_param(p.tune)
    p.startp, p.widthp = params:lookup_param(p.bstart), params:lookup_param(p.bwidth)
  end
  sys.last = #params.params
  group("other", "OTHER", 2)
  trig("do_update", "Check for Updates", function() menu_close() installer:check(true) end)
  opt("auto_update", "Auto Update Check", OFFON, 1)
  params:set_save("auto_update", false)
  for _, id in ipairs(HIDDEN) do params:hide(id) end
end

do
  local vol_ids, tune_ids = {}, {}
  for i = 1, NV do vol_ids[i], tune_ids[i] = PID[i].vol, PID[i].tune end
  Shuffle.init{
    vol_ids = vol_ids, tune_ids = tune_ids,
    snap = function(x) return Scale.snap(x, params:get("scale")) end,
    move = function(x, d) return Scale.move(x, d, params:get("scale")) end,
    count = function() return nva end,
    dirty = function() dirty = true end
  }
end

local function setup_osc()
  osc.event = function(path, args)
    if path == "/grains/state" then
      local st = args[1]
      if type(st) ~= "number" or st < 1 then return end
      local CW = matrix.CW
      for i = 1, nva do
        local v = V[i]
        local pos, pc, base = v.pos, v.pc, (i - 1) * st + 1
        for L = 1, v.nl do
          local p = args[base + L] or 0
          pos[L] = p
          if v.on then
            local k = floor(p * CW)
            if pc[L] ~= k then pc[L], dirty = k, true end
          end
        end
      end
      return
    end
    dirty = true
    local i = (args[1] or 0) + 1
    if path == "/grains/waveform" then
      if i < 1 or i > NV then return end
      local raw, mx, N, v = {}, 0, matrix.RAW, V[i]
      for c = 0, N - 1 do
        raw[c] = args[c + 2] or 0
        mx = max(mx, raw[c])
      end
      for c = 0, N - 1 do raw[c] = mx > 0 and math.sqrt(raw[c] / mx) or 0 end
      local at = args[N + 2]
      v.at = type(at) == "number" and at >= 0 and at or 0
      v.raw, v.wgen = raw, nil
      if v.file then xf_in(v) end
    elseif path == "/grains/fail" then
      if i >= 1 and i <= NV then retry_voice(i) end
    elseif path == "/grains/bounce" then
      REC.bounced()
    elseif path == "/grains/rec_level" then
      local l, r = args[1] or 0, args[2] or 0
      REC.level, REC.level_r, REC.metered, REC.peak = l, r, true, max(REC.peak, l, r)
    elseif path == "/grains/rec_done" then
      REC.done((args[1] or 0) > 0)
    end
  end
end

function redraw(now)
  if installer:pending() then return installer:redraw() end
  screen.clear()
  matrix.draw(V, sel, blink)
  if nva < 1 then matrix.notice("no audio loaded", "K1+K2 or load from the MENU", "or hold K3 to record input") end
  now = now or util.time()
  local vol_on = vbar.f and now - vbar.t < POP_DUR
  if vol_on then matrix.volbar(vbar.f) elseif morph_on then matrix.morphbar(Morph.pos) end
  if vol_on or not morph_on then matrix.icons(font) end
  if nva >= 1 and DENSP:get() < 1 and not REC.state and REC.bend <= 0 then matrix.recpopup("no layers", nil, nil, "turn K1+E1 up") end
  if pop.kind and now - pop.t < POP_DUR then
    if pop.kind == "fx" then matrix.fxpopup(pop.txt)
    elseif pop.kind == "tilt" then matrix.tilteq(params:get("tilt"))
    elseif pop.kind == "hpf" then matrix.hpf(params:get("vhpf"))
    else matrix.filter(params:get("cutoff"), params:get("res") * 0.01) end
  end
  if REC.bend > 0 then
    local f = REC.bq / 64
    matrix.fxpopup(f >= 1 and "saving..." or "recording...", f)
  end
  local st = REC.state
  if st == "rec" then
    if REC.shown ~= REC.tick then
      REC.shown = REC.tick
      REC.sub = string.format("S%d  %.1fs", REC.target, max(REC.tick, 0) * 0.1)
    end
    REC.bars[1], REC.bars[2] = REC.frac(REC.level), REC.frac(REC.level_r)
    matrix.recpopup((REC.level >= 0.99 or REC.level_r >= 0.99) and "REC  clip" or "REC", REC.sub, REC.bars, nil,
      (now - REC.t0) / params:get("rec_max"))
  elseif st == "confirm" then
    matrix.recpopup(REC.txt, REC.kind == "loop" and "loops" or "recs", nil, "K3 ok    K2 no")
  elseif st == "save" then
    matrix.recpopup("saving...")
  elseif st then
    matrix.recpopup(REC.txt or "")
  end
  screen.update()
end

local function step_sel(d)
  dirty = true
  sel = nva < 1 and 0 or sel < 1 and 1 or (sel - 1 + d) % nva + 1
end

local function toggle_sel(prefix) if sel >= 1 then toggle(prefix .. sel) end end

local function pop_rate(label, id)
  local v = params:get(id)
  pop_show("fx", v <= RATE_OFF and label .. ": OFF" or string.format("%s: %.2fx", label, v))
end

local COMBOS = {
  ["1"] = {long = function() morph_on, dirty = not morph_on, true end},
  ["2"] = {short = function() step_sel(-1) end, long = function() REC.start() end},
  ["3"] = {short = function() step_sel(1) end, long = function() REC.start(true) end},
  ["12"] = {short = src.reload, long = function() toggle_sel("freeze") end},
  ["13"] = {short = function() Undo.mark() dice() end, long = function() toggle("freeze_all") end},
  ["23"] = {short = function() toggle_sel("lock_v") end, long = undo},
  ["123"] = {short = function() Undo.mark() reseed_voices() end, long = redo}
}

function enc(n, d)
  if installer:pending() or REC.state then return end
  local k1, k2, k3 = Keys.state[1], Keys.state[2], Keys.state[3]
  dirty = true
  if k1 or k2 or k3 then Keys.mark() end
  if k2 and k3 and not k1 then
    local fx = Grid.FX[n]
    params:delta(fx[1], d)
    pop_show("fx", fx[2] .. ": " .. fxstr(fx[1]))
  elseif k1 and k2 and k3 then
    if orig_block() then return end
    Undo.mark("pitch_rel")
    if n == 1 then
      local step = Keys.coarse("scale", d)
      if step ~= 0 then params:set("scale", clamp(params:get("scale") + step, 1, Scale.CHROMATIC)) end
      pop_show("fx", "scale: " .. Scale.NAMES[params:get("scale")])
    else
      local id = n == 2 and "spread" or "lspread"
      params:delta(id, d)
      pop_show("fx", string.format("%s spread: %d%%", n == 2 and "voice" or "layer", floor(params:get(id) + 0.5)))
    end
  elseif k1 and k2 then
    params:delta(({"tilt", "vhpf", "cutoff"})[n], d)
    pop_show(({"tilt", "hpf", "filt"})[n])
  elseif (k2 or k3) and not k1 and n == 1 then
    if k3 and orig_block() then return end
    local sh = k2 and Shuffle.vol or Shuffle.pitch
    Undo.mark(k2 and "shuffle_vol" or "shuffle_pitch")
    sh:kick(d)
  elseif (k2 or k3) and not k1 then
    if sel < 1 or (k3 and orig_block()) then return end
    local sh = k2 and Shuffle.vol or Shuffle.pitch
    Undo.mark(k2 and "nudge_vol" or "nudge_pitch")
    sh:nudge(sel, d, n == 3)
  elseif k1 then
    if n == 1 and k3 then
      if orig_block() then return end
      params:set("tuning", params:get("tuning") + d)
      pop_show("fx", string.format("tuning: %+d st", floor(params:get("tuning"))))
    elseif n == 1 then
      local step = Keys.coarse("density", d)
      if step ~= 0 then params:delta("density", step) end
    elseif k3 then
      local id = n == 2 and "motionrate" or "pitchrate"
      params:delta(id, d)
      pop_rate(n == 2 and "energy" or "pitch", id)
    elseif n == 2 then
      local step = Keys.coarse("layers", d)
      if step ~= 0 and sel >= 1 then nudge_layers(sel, step) end
    else
      local step = Keys.coarse("voices", d)
      if step ~= 0 then src.nudge_count(step) end
    end
  elseif n == 1 then
    if morph_on then params:delta("morph", d * 3) else
      params:set("level", clamp(params:get("level") + d, DB_FLOOR, LEVEL_MAX))
      vbar.f, vbar.t = clamp((params:get("level") - DB_FLOOR) / (LEVEL_MAX - DB_FLOOR), 0, 1), util.time()
    end
  elseif sel >= 1 then
    region_grab(sel)
    params:delta(PID[sel][n == 2 and "bstart" or "bwidth"], d)
  end
end

function key(n, z)
  dirty = true
  if installer:pending() then return installer:key(n, z) end
  if REC.state then
    if z == 0 then return Keys.release(n) end
    if REC.state == "rec" then REC.stop()
    elseif REC.state == "confirm" then REC.confirm(n == 3)
    elseif REC.state == "msg" then REC.finish(nil) end
    return
  end
  if z == 1 then Keys.press(n) else Keys.release(n) end
end

local MORPH_SKIP = {morph = true, source = true, chunk = true, lseed = true, level = true, quality = true, rev_type = true, d_series = true, binaural = true}
local function morph_skip(id)
  return MORPH_SKIP[id] or id:find("^morph") or id:find("^vlfo") or id:find("^do_") or id:find("^lock_")
    or id:find("^freeze") or id:find("^rec_") or id:find("^bounce_") or id:find("^rlfo")
end

local CFG = {path = norns.state.data .. "settings",
  ids = {"auto_update", "rec_gain", "rec_max", "rec_norm", "rec_src", "rec_mon", "bounce_len", "bounce_xf", "rec_lnorm"}}

function CFG.save()
  local t, o = {}, {"return "}
  for _, id in ipairs(CFG.ids) do t[id] = params:get(id) end
  ser(t, o)
  local f = io.open(CFG.path, "w")
  if f then f:write(table.concat(o)) f:close() end
end

function CFG.init()
  local ok, t = pcall(loadfile(CFG.path, "t", {}))
  t = ok and type(t) == "table" and t or {}
  for _, id in ipairs(CFG.ids) do
    if t[id] then params:set(id, t[id]) end
    params:set_action(id, CFG.save)
  end
end

local function frame()
  if sys.dead then return end
  local now = util.time()
  if next(fpend) then src_flush() end
  sys.n = sys.n + 1
  if sys.n == FPS * 10 and params:get("auto_update") == 2 then installer:check() end
  if sys.n % 2 == 0 then
    Sync.tick(now)
    physics_tick(now, sys.n % 4 == 0)
    Grid.tick(now)
  end
  Keys.tick(now)
  if font.tick(now) then dirty = true end
  FXM.check(now)
  if frz_any then
    blink_n = blink_n + 1
    if blink_n >= 24 then blink_n, blink, dirty = 0, not blink, true end
  end
  if pop.kind and now - pop.t >= POP_DUR then pop.kind, dirty = nil, true end
  if vbar.f and now - vbar.t >= POP_DUR then vbar.f, dirty = nil, true end
  if REC.bend > 0 then
    if now >= REC.bend then
      REC.bend, REC.bto, dirty = 0, nil, true
    else
      local q = floor(clamp((now - REC.bt0) / REC.blen, 0, 1) * 64)
      if q ~= REC.bq then REC.bq, dirty = q, true end
    end
  end
  local st = REC.state
  if st == "rec" then
    if now - REC.t0 >= params:get("rec_max") then
      REC.stop()
    else
      local t = floor((now - REC.t0) * 10)
      if t ~= REC.tick then REC.tick, dirty = t, true end
    end
  elseif st and now >= REC.wait then
    REC.finish(st == "save" and "failed" or nil)
  end
  if installer:pending() then dirty = true end
  local up = menu_up()
  if up ~= sys.menu then
    sys.menu = up
    engine.report_rate(up and 2 or 30)
  end
  if dirty and not up then
    dirty = false
    redraw(now)
  end
end

function init()
  sys.mon, sys.n, sys.menu, sys.dens_t = params:get("monitor_level"), 0, false, 0
  params:set("monitor_level", -math.huge)
  math.randomseed(floor(util.time() * 1000) % 1000000)
  for i = 1, NV do V[i] = new_voice() end
  if pcall(params.lookup_param, params, "reverb") then
    sys.rev = params:get("reverb")
    params:set("reverb", 1)
  end
  if pcall(params.lookup_param, params, "rev_eng_input") then sys.send = params:get("rev_eng_input") end
  matrix.bind()
  reroll_seeds(true)
  setup_params()
  setup_osc()
  Sync.set_rate(CTRL_HZ)
  Keys.init{combos = COMBOS, longpress = 1, coarse = {density = 5, layers = 5, voices = 5, scale = 4}}
  params:set("lseed", random(9999))
  params:set("morph_seed", random(9999))
  params:bang()
  CFG.init()
  font.init()
  FXM.check(util.time())
  refresh_layout()
  Morph.init(sys.first, sys.last, morph_skip)
  UN.build(sys.first, sys.last)
  Undo.init{capture = UN.capture, restore = UN.restore, depth = 10, hold = 0.7}
  params.action_write = pset_write
  params.action_read = pset_read
  params.action_delete = function(fn) os.remove(fn .. PSX) end
  push_vps()
  push_per_voice()
  pop_dirty = true
  Grid.init{
    V = V,
    count = function() return nva end,
    densfrac = function() return DENSP.max > 0 and DENSP:get() / DENSP.max or 0 end,
    density = function(d, tap)
      local now = util.time()
      if d == 0 or (not tap and now - sys.dens_t < 0.08) then return end
      sys.dens_t = now
      Undo.mark("density")
      params:delta("density", d)
      pop_show("fx", "density: " .. params:string("density"))
    end,
    pop = function(label, id) pop_show("fx", label .. ": " .. fxstr(id)) end,
    grab = region_grab,
    bounds = function(i, a, w)
      local p = PID[i]
      Undo.mark("grid" .. i)
      V[i].rt = util.time()
      w = w and w * 100 or p.widthp:get()
      params:set(p.bstart, min(a * 100, 100 - w))
      params:set(p.bwidth, w)
      sel, dirty = i, true
    end,
    vol = function(d, tap, v)
      local i = v or sel
      if i < 1 then return end
      Undo.mark("nudge_vol")
      if d == 0 then params:set(PID[i].vol, VOL_DEF) else Shuffle.vol:nudge(i, d * (tap and 2 or 1)) end
      pop_show("fx", "vol " .. i .. ": " .. params:string(PID[i].vol))
    end,
    hold = function(i, lk)
      local id = (lk and "lock_v" or "freeze") .. i
      toggle(id)
      pop_show("fx", (lk and "lock " or "freeze ") .. i .. (params:get(id) == 1 and ": ON" or ": OFF"))
    end,
    lfofrac = function(p) return params:get(p) == 2 and params:get_raw(p .. "_depth") or 0 end,
    lfo = function(d, tap, p)
      local on, id = params:get(p) == 2, p .. "_depth"
      local dp = params:lookup_param(id)
      local mx = dp.controlspec.maxval
      local v = d == 0 and 0 or clamp((on and dp:get() or 0) + d * mx * (tap and 0.05 or 0.01), 0, mx)
      if v <= 0 then
        if on then params:set(p, 1) end
      else
        params:set(id, v)
        if not on then params:set(p, 2) end
      end
      pop_show("fx", (p == "rlfo" and "region LFO: " or "vol LFO: ") .. (v <= 0 and "OFF"
        or p == "rlfo" and string.format("%d%%", floor(v + 0.5)) or string.format("%.1f dB", dp:get())))
    end,
    trig = function(top)
      Undo.mark()
      if top then reseed_voices() else dice() end
      pop_show("fx", top and "reseed" or "randomize")
    end
  }
  engine.report_rate(30)
  sys.metro = metro.init()
  sys.metro.time, sys.metro.event = 1 / FPS, frame
  sys.metro:start()
end

function cleanup()
  sys.dead = true
  if sys.metro then sys.metro:stop() end
  Grid.cleanup()
  clock.tempo_change_handler = nil
  if sys.send then params:set("rev_eng_input", sys.send) end
  if sys.rev then params:set("reverb", sys.rev) end
  if sys.mon then params:set("monitor_level", sys.mon) end
  osc.event = nil
end
