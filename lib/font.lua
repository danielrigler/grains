local F = {n = 0, ver = 0, runs = {}}

local floor, max, abs, log = math.floor, math.max, math.abs, math.log

local GLYPH = {
  K = {"010", "101", "010"}, F = {"111", "110", "100"}, E = {"111", "110", "111"}, B = {"110", "011", "001"},
  O = {"111", "101", "111"}, W = {"101", "111", "111"}, M = {"101", "010", "101"}, U = {"101", "101", "111"},
  c = {"11", "10", "11"}, S = {"011", "010", "110"}, G = {"110", "101", "111"}, T = {"111", "010", "010"},
  X = {"011101", "010111", "110101"}, D = {"110", "101", "110"}, R = {"111", "110", "101"},
  Z = {"01111", "01010", "11010"}, C = {"111", "100", "111"}
}

local IDS = {"reverb_mix", "d_mix", "sh_mix", "sh_mod", "bc_mix", "bc_mod", "wf_mix", "reso_mix", "gl_ratio", "gl_mix",
  "tape_mix", "shaper_mix", "wobble_mix", "reel_mix", "genloss_mix", "ringmod_mix", "spiral_mix", "sub_mix", "ott_mix",
  "stchorus_mix", "m_width", "dimension_mix", "vibe_mix", "haas", "binaural", "rspeed", "eq_low", "eq_mid", "eq_high",
  "tilt", "cutoff", "vhpf", "d_sync", "morph_auto", "morph_sync", "vlfo", "vlfo_sync"}

local fx, objs = {}, {}
local function poll() for i, id in ipairs(IDS) do fx[id] = objs[i]:get() end end

local get_beats = rawget(_G, "clock") and clock.get_beats
if get_beats and not pcall(get_beats) then get_beats = nil end
local function clock_pos()
  local b = get_beats and get_beats()
  return type(b) == "number" and floor(b) % 4 or 0
end

local function mixmod()
  local cur, nxt, t0 = math.random(), math.random(), util.time()
  return function(now)
    while now - t0 >= 4 do cur, nxt, t0 = nxt, math.random(), t0 + 4 end
    return cur + (nxt - cur) * (now - t0) * 0.25
  end
end
local bc_lfo, sh_lfo, now_t = mixmod(), mixmod(), 0

local LPF, HPF = 1 / log(1000), 1 / log(40)
local function eqdev(c) return max(max(abs(c.eq_low), abs(c.eq_mid), abs(c.eq_high)) / 20, abs(c.tilt)) end
local function mix(id) return {function(c) return c[id] > 0 end, function(c) return c[id] end} end
local function clock_on(c)
  return (c.d_sync == 2 and c.d_mix > 0) or (c.morph_auto == 2 and c.morph_sync == 2) or (c.vlfo == 2 and c.vlfo_sync == 2)
end

local SPECS = {
  {"K", nil, clock_on},
  {"F", "grains_tone", function(c) return c.cutoff < 19999 or c.vhpf > 20.1 end,
    function(c) return max(1 - log(math.min(max(c.cutoff, 20), 20000) / 20) * LPF, log(math.min(max(c.vhpf, 20), 800) / 20) * HPF) * 100 end},
  {"E", "grains_eq", function(c) return eqdev(c) > 0.01 end, function(c) return eqdev(c) * 100 end},
  {"B", "grains_bitcrush", mix("bc_mix")[1], function(c) return c.bc_mod == 2 and c.bc_mix * bc_lfo(now_t) or c.bc_mix end},
  {"O", "grains_reso", table.unpack(mix("reso_mix"))},
  {"W", "grains_wavefold", table.unpack(mix("wf_mix"))},
  {"M", "grains_ringmod", table.unpack(mix("ringmod_mix"))},
  {"U", "grains_sub", table.unpack(mix("sub_mix"))},
  {"c", "grains_ott", table.unpack(mix("ott_mix"))},
  {"S", "grains_spiral", table.unpack(mix("spiral_mix"))},
  {"G", "grains_glitch", function(c) return c.gl_ratio > 0 and c.gl_mix > 0 end, function(c) return c.gl_ratio end},
  {"T", "grains_tape", function(c) return c.tape_mix == 2 or c.shaper_mix > 0 or c.wobble_mix > 0 or c.reel_mix > 0 or c.genloss_mix > 0 end,
    function(c) return max(c.tape_mix == 2 and 25 or 0, c.shaper_mix, c.wobble_mix, c.reel_mix, c.genloss_mix) end},
  {"X", "grains_shimmer", mix("sh_mix")[1], function(c) return c.sh_mod == 2 and c.sh_mix * sh_lfo(now_t) or c.sh_mix end},
  {"D", "grains_delay", table.unpack(mix("d_mix"))},
  {"R", "grains_reverb", function(c) return c.reverb_mix > -40 end, function(c) return (c.reverb_mix + 40) / 58 * 100 end},
  {"Z", "grains_dimension", function(c) return c.m_width ~= 100 or c.haas == 2 or c.binaural == 2 or c.rspeed > 0 end,
    function(c) return max(abs(c.m_width - 100) / 100, (c.haas == 2 or c.binaural == 2) and 0.25 or 0, c.rspeed) * 100 end},
  {"C", "grains_chorus", function(c) return c.dimension_mix > 0 or c.stchorus_mix > 0 or c.vibe_mix > 0 end,
    function(c) return max(c.dimension_mix, c.stchorus_mix, c.vibe_mix) end}
}

local OFF = {
  F = {cutoff = 20000, vhpf = 20}, E = {eq_low = 0, eq_mid = 0, eq_high = 0, tilt = 0}, B = {bc_mix = 0},
  O = {reso_mix = 0}, W = {wf_mix = 0}, M = {ringmod_mix = 0}, U = {sub_mix = 0}, c = {ott_mix = 0},
  S = {spiral_mix = 0}, G = {gl_ratio = 0}, X = {sh_mix = 0}, D = {d_mix = 0}, R = {reverb_mix = -40},
  T = {tape_mix = 1, shaper_mix = 0, wobble_mix = 0, reel_mix = 0, genloss_mix = 0},
  Z = {m_width = 100, haas = 1, binaural = 1, rspeed = 0}, C = {dimension_mix = 0, stchorus_mix = 0, vibe_mix = 0}
}

local CLOCK_AT = {{1, 2}, {2, 3}, {3, 2}, {2, 1}}
local last, clk, clk_pos = -1, false, -1
local buf, shown = {}, {}

function F.init()
  for i, id in ipairs(IDS) do objs[i] = params:lookup_param(id) end
  poll()
end

local function emit(n, l, x, y, w)
  buf[n + 1], buf[n + 2], buf[n + 3], buf[n + 4] = l, x, y, w
  return n + 4
end

function F.tick(now)
  if now - last >= 0.2 then
    last, now_t = now, now
    poll()
    clk = clock_on(fx)
  elseif not clk or clock_pos() == clk_pos then
    return false
  end
  clk_pos = clk and clock_pos() or -1
  local ns, width, at = 0, -1, CLOCK_AT[clk_pos + 1] or CLOCK_AT[1]
  for _, s in ipairs(SPECS) do
    if s[3](fx) then
      ns = ns + 1
      shown[ns] = s
      width = width + #GLYPH[s[1]][1] + 1
    end
  end
  local x, n = math.max(128 - width, 0), 0
  for k = 1, ns do
    local s = shown[k]
    local g = GLYPH[s[1]]
    local lv = s[4] and 1 + floor(math.min(max(s[4](fx), 0), 100) * 0.14)
    local cr, cc = at[1], at[2]
    for row = 1, 3 do
      local r, col = g[row], 1
      while col <= #r do
        if r:byte(col) == 49 then
          local l = lv or ((row == cr and col == cc) and 15 or 3)
          local e = col
          while lv and r:byte(e + 1) == 49 do e = e + 1 end
          n = emit(n, l, x + col - 1, 60 + row, e - col + 1)
          col = e
        end
        col = col + 1
      end
    end
    x = x + #g[1] + 1
  end
  local changed = n ~= F.n
  if not changed then
    local r = F.runs
    for k = 1, n do if r[k] ~= buf[k] then changed = true break end end
  end
  if changed then
    F.runs, buf, F.n, F.ver = buf, F.runs, n, F.ver + 1
  end
  return changed
end

function F.groups(on)
  poll()
  for _, s in ipairs(SPECS) do if s[2] then on[s[2]] = s[3](fx) end end
end

function F.clear()
  poll()
  for _, s in ipairs(SPECS) do
    local off = OFF[s[1]]
    if off and s[3](fx) then for id, v in pairs(off) do params:set(id, v) end end
  end
end

return F
