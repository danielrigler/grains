local font = {}

font.micro_font = {
  D = {{1,1,0},{1,0,1},{1,1,0}},
  B = {{1,1,0},{0,1,1},{0,0,1}},
  L = {{1,0},{1,0},{1,1}},
  C = {{1,1,1},{1,0,0},{1,1,1}},
  G = {{1,1,0},{1,0,1},{1,1,1}},
  E = {{1,1,1},{1,1,0},{1,1,1}},
  I = {{1},{1},{1}},
  R = {{1,1,1},{1,1,0},{1,0,1}},
  T = {{1,1,1},{0,1,0},{0,1,0}},
  S = {{0,1,1},{0,1,0},{1,1,0}},
  X = {{0,1,1,1,0,1},{0,1,0,1,1,1},{1,1,0,1,0,1}},
  V = {{0,0,1},{1,1,1},{1,1,1}},
  H = {{1,0,1},{1,1,1},{1,0,1}},
  Z = {{0,1,1,1,1},{0,1,0,1,0},{1,1,0,1,0}},
  F = {{1,1,1},{1,1,0},{1,0,0}},
  P = {{1,1,1},{1,1,1},{1,0,0}},
  O = {{1,1,1},{1,0,1},{1,1,1}},
  W = {{1,0,1},{1,1,1},{1,1,1}},
  M = {{1,0,1},{0,1,0},{1,0,1}},
  K = {{0,1,0},{1,0,1},{0,1,0}},
  A = {{0,0,1},{0,1,1},{1,1,1}},
  N = {{1,1,1},{1,0,1},{1,0,1}},
  U = {{1,0,1},{1,0,1},{1,1,1}}
}

local micro_font_by_byte = {}
for ch, glyph in pairs(font.micro_font) do micro_font_by_byte[ch:byte()] = glyph end

local floor, min, max, abs, log = math.floor, math.min, math.max, math.abs, math.log

local function plot_text(plot, x, y, text, level)
  local cursor_x = x
  local level_is_fn = type(level) == "function"
  local col_levels = (not level_is_fn) and type(level) == "table" and level or nil
  local col_last = col_levels and col_levels[#col_levels] or nil
  for i = 1, #text do
    local glyph = micro_font_by_byte[text:byte(i)]
    if glyph then
      local w = #glyph[1]
      for row = 1, 3 do
        for col = 1, w do
          if glyph[row][col] == 1 then
            local lvl
            if level_is_fn then
              lvl = level(row, col)
            else
              lvl = col_levels and (col_levels[col] or col_last) or level
            end
            plot(lvl or 1, cursor_x + col - 1, y + row - 1)
          end
        end
      end
      cursor_x = cursor_x + w + 1
    else
      cursor_x = cursor_x + 3
    end
  end
  return cursor_x
end
font.plot_text = plot_text

local _text_cache = {}
function font.plot_text_cached(plot, x, y, text, level)
  local c = _text_cache[text]
  if not c then
    local xs, ys, n = {}, {}, 0
    local w = plot_text(function(_, px, py) n = n + 1 xs[n] = px ys[n] = py end, 0, 0, text, 1) - 1
    c = {xs = xs, ys = ys, n = n, w = w}
    _text_cache[text] = c
  end
  local xs, ys = c.xs, c.ys
  for i = 1, c.n do plot(level, x + xs[i], y + ys[i]) end
  return x + c.w + 1
end

local fx = {
  reverb_mix    = -40,
  d_mix         = 0,
  sh_mix        = 0,
  sh_mod        = 1,
  bc_mix        = 0,
  bc_mod        = 1,
  wf_mix        = 0,
  reso_mix      = 0,
  gl_ratio      = 0,
  gl_mix        = 100,
  tape_mix      = 1,
  shaper_mix    = 0,
  wobble_mix    = 0,
  m_width       = 100,
  dimension_mix = 0,
  haas          = 1,
  rspeed        = 0,
  eq_low        = 0,
  eq_mid        = 0,
  eq_high       = 0,
  tilt          = 0,
  cutoff        = 20000,
  vhpf          = 20
}

local watched = {}

function font.init()
  local n = 0
  for id in pairs(fx) do
    if params.lookup[id] then n = n + 1 watched[n] = id end
  end
  for k = n + 1, #watched do watched[k] = nil end
  font.poll()
end

function font.poll()
  for i = 1, #watched do
    local id = watched[i]
    fx[id] = params:get(id)
  end
end

local BINARY_ON = 25

local function value_to_level(val)
  if val < 0 then val = 0 elseif val > 100 then val = 100 end
  return 1 + floor((val / 100) * 14)
end

local _LPF_INV = 1 / log(20000 / 20)
local _HPF_INV = 1 / log(800 / 20)

local function lpf_norm(freq)
  local f = freq < 20 and 20 or (freq > 20000 and 20000 or freq)
  return log(f / 20) * _LPF_INV
end

local function hpf_norm(freq)
  local f = freq < 20 and 20 or (freq > 800 and 800 or freq)
  return log(f / 20) * _HPF_INV
end

local function filter_active(c)
  return c.cutoff < 19999 or c.vhpf > 20.1
end

local function filter_intensity(c)
  return max(1 - lpf_norm(c.cutoff), hpf_norm(c.vhpf)) * 100
end

local function eq_dev(c)
  local d = max(abs(c.eq_low), abs(c.eq_mid), abs(c.eq_high)) / 20
  local t = abs(c.tilt)
  return max(d, t)
end

local function eq_active(c)
  return eq_dev(c) > 0.01
end

local function eq_intensity(c)
  return eq_dev(c) * 100
end

local function tape_active(c)
  return c.tape_mix == 2 or c.shaper_mix > 0 or c.wobble_mix > 0
end

local function tape_intensity(c)
  local v = c.tape_mix == 2 and BINARY_ON or 0
  if c.shaper_mix > v then v = c.shaper_mix end
  if c.wobble_mix > v then v = c.wobble_mix end
  return v
end

local function stereo_active(c)
  return c.m_width ~= 100 or c.dimension_mix > 0 or c.haas == 2 or c.rspeed > 0
end

local function stereo_intensity(c)
  local w = abs(c.m_width - 100) / 100
  local h = c.haas == 2 and (BINARY_ON / 100) or 0
  return max(w, c.dimension_mix / 100, h, c.rspeed) * 100
end

local MOD_FREQ = 0.25
local MOD_PERIOD = 1 / MOD_FREQ
local _draw_now = 0

local function make_mix_mod()
  local cur, nxt = math.random(), math.random()
  local seg_start = util.time()
  return function(now)
    local t = now - seg_start
    if t >= MOD_PERIOD then
      repeat
        cur, nxt = nxt, math.random()
        seg_start = seg_start + MOD_PERIOD
        t = now - seg_start
      until t < MOD_PERIOD
    end
    return cur + (nxt - cur) * (t * MOD_FREQ)
  end
end

local _bc_lfo = make_mix_mod()
local _sh_lfo = make_mix_mod()

local FX_SPECS = {
  {glyph = "F", show = filter_active,                              val = filter_intensity},
  {glyph = "E", show = eq_active,                                  val = eq_intensity},
  {glyph = "B", show = function(c) return c.bc_mix > 0 end,         val = function(c) return c.bc_mod == 2 and c.bc_mix * _bc_lfo(_draw_now) or c.bc_mix end},
  {glyph = "O", show = function(c) return c.reso_mix > 0 end,       val = function(c) return c.reso_mix end},
  {glyph = "W", show = function(c) return c.wf_mix > 0 end,         val = function(c) return c.wf_mix end},
  {glyph = "G", show = function(c) return c.gl_ratio > 0 and c.gl_mix > 0 end, val = function(c) return c.gl_ratio end},
  {glyph = "T", show = tape_active,                                val = tape_intensity},
  {glyph = "X", show = function(c) return c.sh_mix > 0 end,        val = function(c) return c.sh_mod == 2 and c.sh_mix * _sh_lfo(_draw_now) or c.sh_mix end},
  {glyph = "D", show = function(c) return c.d_mix > 0 end,         val = function(c) return c.d_mix end},
  {glyph = "R", show = function(c) return c.reverb_mix > -40 end,  val = function(c) return util.linlin(-40, 18, 0, 100, c.reverb_mix) end},
  {glyph = "Z", show = stereo_active,                              val = stereo_intensity}
}

local RIGHT_EDGE, Y0 = 127, 61
local UPDATE_INTERVAL = 1 / 5

local _pl, _px, _py, _pn = {}, {}, {}, 0
local _n, _changed = 0, false
local _last_update = -1
local _shown, _level = {}, {}

local function collect(level, x, y)
  local n = _n + 1
  _n = n
  if _pl[n] ~= level or _px[n] ~= x or _py[n] ~= y then
    _pl[n], _px[n], _py[n] = level, x, y
    _changed = true
  end
end

local function glyph_width(ch)
  local g = micro_font_by_byte[ch:byte()]
  return g and #g[1] or 3
end

function font.tick()
  local now = util.time()
  if now - _last_update < UPDATE_INTERVAL then return false end
  _last_update = now
  _draw_now = now
  font.poll()
  local shown, width = 0, 0
  for i = 1, #FX_SPECS do
    local spec = FX_SPECS[i]
    if spec.show(fx) then
      shown = shown + 1
      _shown[shown] = spec.glyph
      _level[shown] = value_to_level(spec.val(fx))
      width = width + glyph_width(spec.glyph) + 1
    end
  end
  if width > 0 then width = width - 1 end
  _n, _changed = 0, false
  local x = RIGHT_EDGE + 1 - width
  if x < 0 then x = 0 end
  for i = 1, shown do
    x = plot_text(collect, x, Y0, _shown[i], _level[i])
  end
  if _n ~= _pn then
    _pn = _n
    _changed = true
  end
  return _changed
end

function font.draw(plot)
  local l, x, y = _pl, _px, _py
  for i = 1, _pn do plot(l[i], x[i], y[i]) end
end

return font