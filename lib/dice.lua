local D = {}

local random, abs, exp = math.random, math.abs, math.exp
local function rnd(lo, hi) return lo + random() * (hi - lo) end
local function rndexp(lo, hi) return lo * (hi / lo) ^ random() end
local function pick(t) return t[random(#t)] end
local function chance(pct) return pct > 0 and random() * 100 < pct end
D.rnd, D.rndexp, D.pick, D.chance = rnd, rndexp, pick, chance

D.TUNING = {
  {set = {0, 0, -12, 12, -24}, favor = 0.35, spread = 0.12},
  {set = {0, -12, 12, -24, 24}, favor = 1.00, spread = 0.55},
  {set = {0, 7, -5, 12, -12}, favor = 1.00, spread = 0.60},
  {set = {0, 3, 7, -12, 10}, favor = 0.95, spread = 0.65},
  {set = {0, 4, 7, 12, -12}, favor = 0.95, spread = 0.65},
  {set = {0, 5, 7, -7, 12}, favor = 1.05, spread = 0.70},
  {set = {0, 3, 5, 7, 10}, favor = 1.20, spread = 0.85},
  {set = {0, 12, 19, 24, 7}, favor = 1.45, spread = 0.45},
  {set = {0, -12, -24, -7, -19}, favor = 1.15, spread = 0.45},
  {set = {0, 1, -1, 2, -2}, favor = 1.30, spread = 0.90},
  {set = {0, -24, 24, -12, 12}, favor = 0.60, spread = 0.35},
  {set = {0, 2, 6, 7, 11}, favor = 1.00, spread = 0.75}
}

D.MOTION = {
  {mr = {0.05, 0.8}, slew = {1.5, 9}, rev = {0, 0.1}, floor = {45, 95}},
  {mr = {1, 2}, slew = {1.0, 4.0}, rev = {0.05, 0.2}, floor = {20, 70}},
  {mr = {2.5, 4}, slew = {0.15, 1.2}, rev = {0.1, 0.3}, floor = {5, 45}},
  {mr = {4, 8}, slew = {0.05, 0.25}, rev = {0.15, 0.4}, floor = {0, 30}}
}

D.SPACE = {
  {pan = {85, 100}, cut = {4000, 20000},
   dly = {time = {0.1, 0.5}, fb = {10, 50}, lpf = {5000, 16000}, hpf = {50, 300}, stereo = {0, 25}, duck = {10, 25}, wrate = {0.5, 4}, wdepth = {5, 25}},
   shm = {oct = {4, 5}, fb = {0, 30}, pitchv = {0, 2}, fbdelay = {0.02, 0.1}, lpf = {8000, 18000}, hpf = {1200, 3500}}},
  {pan = {85, 100}, cut = {2500, 14000},
   dly = {time = {0.1, 0.7}, fb = {20, 60}, lpf = {4000, 16000}, hpf = {50, 250}, stereo = {10, 45}, duck = {10, 30}, wrate = {0.5, 3}, wdepth = {10, 35}},
   shm = {oct = {4, 5}, fb = {10, 45}, pitchv = {0, 2}, fbdelay = {0.08, 0.25}, lpf = {6000, 15000}, hpf = {800, 2500}}},
  {pan = {85, 100}, cut = {1200, 13000},
   dly = {time = {0.2, 1.5}, fb = {35, 75}, lpf = {3500, 9000}, hpf = {30, 150}, stereo = {30, 80}, duck = {5, 20}, wrate = {0.2, 1.5}, wdepth = {20, 50}},
   shm = {oct = {4, 5}, fb = {30, 50}, pitchv = {0, 2}, fbdelay = {0.15, 0.45}, lpf = {5000, 13000}, hpf = {600, 2000}}},
  {pan = {65, 100}, cut = {350, 6000},
   dly = {time = {0.5, 2.5}, fb = {42, 75}, lpf = {700, 3000}, hpf = {20, 120}, stereo = {10, 50}, duck = {10, 35}, wrate = {0.1, 2}, wdepth = {25, 60}},
   shm = {oct = {4, 5}, fb = {25, 48}, pitchv = {0, 2}, fbdelay = {0.2, 0.5}, lpf = {1500, 6000}, hpf = {200, 900}}},
  {pan = {75, 100}, cut = {2500, 12000},
   dly = {time = {0.25, 1.2}, fb = {45, 75}, lpf = {3000, 9000}, hpf = {100, 300}, stereo = {15, 100}, duck = {15, 25}, wrate = {0.3, 2}, wdepth = {5, 30}},
   shm = {oct = {4, 5}, fb = {15, 55}, pitchv = {0, 2}, fbdelay = {0.05, 0.3}, lpf = {4000, 14000}, hpf = {700, 2200}}}
}

D.SHAPE = {
  {start = {0, 0.1}, width = {0.85, 1.0}},
  {start = {0.1, 0.55}, width = {0.22, 0.5}},
  {start = {0.05, 0.8}, width = {0.03, 0.12}},
  {start = {0.0, 0.12}, width = {0.08, 0.3}},
  {start = {0.55, 0.85}, width = {0.1, 0.4}}
}

D.FX_MAX = 4
D.FX = {
  {"reverb_mix", "reverb", 45, -24, -6, -40}, {"d_mix", "delay", 40, 10, 45, 0}, {"sh_mix", "shimmer", 20, 10, 40, 0},
  {"tape_mix", "tape", 15, 2, nil, 1}, {"reel_mix", "tape", 15, 10, 60, 0}, {"wobble_mix", "tape", 15, 10, 50, 0},
  {"dimension_mix", "chorus", 15, 20, 70, 0}, {"stchorus_mix", "chorus", 12, 20, 70, 0}, {"vibe_mix", "chorus", 12, 20, 70, 0},
  {"spiral_mix", "spiral", 12, 15, 50, 0}, {"ott_mix", "ott", 12, 10, 50, 0}, {"reso_mix", "reso", 10, 10, 45, 0},
  {"sub_mix", "sub", 10, 10, 40, 0}, {"shaper_mix", "tape", 8, 5, 40, 0}, {"genloss_mix", "tape", 8, 10, 50, 0},
  {"gl_ratio", "glitch", 8, 10, 45, 0}, {"bc_mix", "bitcrush", 6, 5, 35, 0}, {"wf_mix", "wavefold", 6, 5, 35, 0},
  {"ringmod_mix", "ringmod", 5, 5, 30, 0}
}

D.FX_SET = {
  reverb = {{"rev_decay", 2, 6, exp = true}, {"rev_damp", 20, 45}, {"rev_pre", 0, 60}, {"rev_mdepth", 10, 60},
    {"rev_mrate", 0.2, 1.5, exp = true}, {"rev_series", 0, 60}},
  delay = {{"d_ratio", pick = {4, 5, 6, 6, 6, 7, 8}}},
  shimmer = {{"sh_mod", chance = 30, on = 2, off = 1}},
  tape = {{"wobble_amp", 5, 50}, {"wobble_rpm", 30, 60}, {"flutter_amp", 10, 60}, {"flutter_freq", 3, 12, exp = true},
    {"flutter_var", 0.5, 4, exp = true}},
  chorus = {{"vibe_drift", 20, 80}},
  bitcrush = {{"bc_mod", chance = 25, on = 2, off = 1}, {"bc_rate", 2000, 24000, exp = true}, {"bc_bits", 6, 16}},
  wavefold = {{"wf_drive", 30, 90}, {"wf_sym", 0, 50}},
  reso = {{"reso_decay", 0.3, 3, exp = true}, {"reso_root", pick = {28, 35, 40, 47, 52}}, {"reso_voicing", 1, 9, int = true}},
  ringmod = {{"ringmod_rate", 5, 1500, exp = true}, {"ringmod_sweep", 0, 60}},
  spiral = {{"spiral_div", 3, 7, int = true}, {"spiral_feedback", 20, 70}, {"spiral_rise", -100, 100},
    {"spiral_glide", 0, 40}, {"spiral_span", 20, 80}, {"spiral_tone", 30, 80}},
  sub = {{"sub_detune", 30, 90}},
  glitch = {{"gl_min", 20, 100}, {"gl_max", 120, 400}, {"gl_stutters", 2, 8, int = true}, {"gl_rev", 0, 50},
    {"gl_pitch", 0, 40}, {"gl_gate", 50, 100}, {"gl_decay", 0, 40}}
}

D.FX_SET.eq = function(set)
  local on = chance(25)
  local tilt = on and chance(50)
  local band = on and not tilt
  set("tilt", tilt and rnd(-0.4, 0.4) or 0)
  set("eq_low", band and rnd(-6, 6) or 0)
  set("eq_mid", band and rnd(-3, 3) or 0)
  set("eq_high", band and rnd(-6, 6) or 0)
end

D.FX_SET.tone = function(set)
  if chance(50) then
    set("cutoff", 20000) set("vhpf", 20)
  else
    local cut = pick(D.SPACE).cut
    set("cutoff", rndexp(cut[1], cut[2])) set("vhpf", rnd(20, 400)) set("res", rnd(5, 45))
  end
end

D.FX_SET.dimension = function(set)
  local on = chance(25)
  set("m_width", on and rnd(60, 150) or 100)
  set("haas", on and chance(30) and 2 or 1)
  set("rspeed", on and chance(15) and rndexp(0.02, 0.3) or 0)
end

function D.pick_contrast(t, cur)
  local ci
  for k = 1, #t do if t[k] == cur then ci = k end end
  if not ci then return pick(t) end
  local far, any = {}, {}
  for k = 1, #t do
    if k ~= ci then
      any[#any + 1] = t[k]
      if abs(k - ci) >= 2 then far[#far + 1] = t[k] end
    end
  end
  return #far > 0 and pick(far) or #any > 0 and pick(any) or cur
end

local ROOTS = {-24, -12, -12, -7, -5, 0, 0, 0, 0, 0, 5, 7, 12, 12, 24}
function D.roll_root() return pick(ROOTS) end

function D.tuning_rows(c)
  local decay, tilt, rows = rnd(0.5, 2.4) / math.max(c.favor, 0.05), rnd(0.12, 0.55), {}
  for i = 1, 5 do
    local iv = c.set[i]
    local mag = abs(iv)
    rows[i] = {interval = iv, weight = 16 * exp(-mag / 12 * decay) + rnd(0, 2), db = -mag * tilt + rnd(-3, 3)}
  end
  if rows[1].weight < 6 then rows[1].weight = rnd(6, 14) end
  return rows
end

function D.fx_roll(set, locked)
  local fx, n, order = D.FX, 0, {}
  for k = 1, #fx do order[k] = k end
  for k = #fx, 2, -1 do
    local j = random(k)
    order[k], order[j] = order[j], order[k]
  end
  for _, k in ipairs(order) do
    local f = fx[k]
    if not locked(f[2]) then
      if n < D.FX_MAX and chance(f[3]) then
        n = n + 1
        set(f[1], f[5] and rnd(f[4], f[5]) or f[4])
      else
        set(f[1], f[6])
      end
    end
  end
end

local function value(s)
  if s.pick then return pick(s.pick) end
  if s.on then return chance(s.chance) and s.on or s.off end
  if s.int then return random(s[2], s[3]) end
  if s.exp then return rndexp(s[2], s[3]) end
  return rnd(s[2], s[3])
end

function D.fx_settings(set, locked)
  for g, specs in pairs(D.FX_SET) do
    if not locked(g) then
      if type(specs) == "function" then specs(set) else for _, s in ipairs(specs) do set(s[1], value(s)) end end
    end
  end
end

return D
