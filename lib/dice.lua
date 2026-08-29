local D = {}

D.TUNING = {
  {name = "drone",      set = {0, 0, -12, 12, -24},   favor = 0.35, spread = 0.12},
  {name = "octaves",    set = {0, -12, 12, -24, 24},  favor = 1.00, spread = 0.55},
  {name = "fifths",     set = {0, 7, -5, 12, -12},    favor = 1.00, spread = 0.60},
  {name = "minor",      set = {0, 3, 7, -12, 10},     favor = 0.95, spread = 0.65},
  {name = "major",      set = {0, 4, 7, 12, -12},     favor = 0.95, spread = 0.65},
  {name = "quartal",    set = {0, 5, 7, -7, 12},      favor = 1.05, spread = 0.70},
  {name = "pentatonic", set = {0, 3, 5, 7, 10},       favor = 1.20, spread = 0.85},
  {name = "shimmer",    set = {0, 12, 19, 24, 7},     favor = 1.45, spread = 0.45},
  {name = "subs",       set = {0, -12, -24, -7, -19}, favor = 1.15, spread = 0.45},
  {name = "cluster",    set = {0, 1, -1, 2, -2},      favor = 1.30, spread = 0.90},
  {name = "wide",       set = {0, -24, 24, -12, 12},  favor = 0.60, spread = 0.35},
  {name = "lydian",     set = {0, 2, 6, 7, 11},       favor = 1.00, spread = 0.75}
}

D.CHORDS = {
  {name = "unison", set = {0}},
  {name = "oct",    set = {0, 12}},
  {name = "5th",    set = {0, 7}},
  {name = "min",    set = {0, 3, 7}},
  {name = "maj",    set = {0, 4, 7}},
  {name = "min7",   set = {0, 3, 7, 10}},
  {name = "maj9",   set = {0, 4, 7, 11, 14}},
  {name = "sus",    set = {0, 5, 7}},
  {name = "minpent",set = {0, 3, 5, 7, 10}},
  {name = "whole",  set = {0, 2, 4, 6, 8, 10}}
}

D.CHORD_EXT = {}
D.CHORD_NAMES = {}
for ci, c in ipairs(D.CHORDS) do
  local t = {}
  for oct = -2, 2 do
    for _, s in ipairs(c.set) do t[#t + 1] = s + oct * 12 end
  end
  table.sort(t)
  D.CHORD_EXT[ci] = t
  D.CHORD_NAMES[ci] = c.name
end

function D.snap(x, ci)
  local t = D.CHORD_EXT[ci] or D.CHORD_EXT[1]
  local best, bd = t[1], math.abs(x - t[1])
  for i = 2, #t do
    local d = math.abs(x - t[i])
    if d < bd then best, bd = t[i], d end
  end
  return best
end

D.MOTION = {
  {name = "glacial",  mr = {0.05, 3},  slew = {1.5, 9},
   rev = {0, 0.2},    floor = {45, 95}},
  {name = "drifting", mr = {1, 3},   slew = {1.0, 4.0},
   rev = {0.05, 0.5}, floor = {20, 70}},
  {name = "restless", mr = {2.5, 4.5},   slew = {0.15, 1.2},
   rev = {0.2, 0.7},  floor = {5, 45}},
  {name = "skittish", mr = {4, 8},   slew = {0.05, 0.25},
   rev = {0.3, 0.85}, floor = {0, 30}}
}

D.SPACE = {
  {name = "close",  pan = {85, 100},  cut = {4000, 20000},
   dly = {time = {0.1, 0.5}, fb = {10, 50},  lpf = {5000, 16000}, hpf = {50, 300},
          stereo = {0, 25},  duck = {10, 25}, wrate = {0.5, 4},  wdepth = {5, 25}},
   shm = {oct = {4, 5},    fb = {0, 30},  pitchv = {0, 2},  fbdelay = {0.02, 0.1},
          lpf = {8000, 18000}, hpf = {1200, 3500}}},

  {name = "room",   pan = {85, 100},  cut = {2500, 14000},
   dly = {time = {0.1, 0.7},  fb = {20, 60}, lpf = {4000, 16000}, hpf = {50, 250},
          stereo = {10, 45}, duck = {10, 30}, wrate = {0.5, 3},  wdepth = {10, 35}},
   shm = {oct = {4, 5},    fb = {10, 45}, pitchv = {0, 2},  fbdelay = {0.08, 0.25},
          lpf = {6000, 15000}, hpf = {800, 2500}}},

  {name = "wash",   pan = {85, 100}, cut = {1200, 13000},
   dly = {time = {0.2, 1.5},   fb = {35, 75}, lpf = {3500, 9000},  hpf = {30, 150},
          stereo = {30, 80},  duck = {5, 20}, wrate = {0.2, 1.5}, wdepth = {20, 50}},
   shm = {oct = {4, 5},    fb = {30, 50}, pitchv = {0, 2}, fbdelay = {0.15, 0.45},
          lpf = {5000, 13000}, hpf = {600, 2000}}},

  {name = "murk",   pan = {65, 100},  cut = {350, 6000},
   dly = {time = {0.5, 2.5},   fb = {42, 75}, lpf = {700, 3000},   hpf = {20, 120},
          stereo = {10, 50},  duck = {10, 35}, wrate = {0.1, 2},  wdepth = {25, 60}},
   shm = {oct = {4, 5},    fb = {25, 48}, pitchv = {0, 2}, fbdelay = {0.2, 0.5},
          lpf = {1500, 6000},  hpf = {200, 900}}},

  {name = "echoes", pan = {75, 100},  cut = {2500, 12000},
   dly = {time = {0.25, 1.2},  fb = {45, 75}, lpf = {3000, 9000}, hpf = {100, 300},
          stereo = {15, 100}, duck = {15, 25}, wrate = {0.3, 2},  wdepth = {5, 30}},
   shm = {oct = {4, 5},    fb = {15, 55}, pitchv = {0, 2},  fbdelay = {0.05, 0.3},
          lpf = {4000, 14000}, hpf = {700, 2200}}}
}

D.SHAPE = {
  {name = "whole",   start = {0, 0.1},     width = {0.85, 1.0}},
  {name = "section", start = {0.1, 0.55},  width = {0.22, 0.5}},
  {name = "pinhole", start = {0.05, 0.8},  width = {0.03, 0.12}},
  {name = "head",    start = {0.0, 0.12},  width = {0.08, 0.3}},
  {name = "tail",    start = {0.55, 0.85}, width = {0.1, 0.4}}
}

local function rnd(lo, hi) return lo + math.random() * (hi - lo) end
local function rndexp(lo, hi) return lo * (hi / lo) ^ math.random() end
local function pick(t) return t[math.random(#t)] end
local function chance(pct) return pct > 0 and math.random() * 100 < pct end

D.rnd, D.rndexp, D.pick, D.chance = rnd, rndexp, pick, chance

local ROOTS = {-24, -12, -12, -7, -5, 0, 0, 0, 0, 0, 5, 7, 12, 12, 24}

function D.tuning_rows(c)
  local decay = rnd(0.5, 2.4) / math.max(c.favor, 0.05)
  local tilt = rnd(0.12, 0.55)
  local rows = {}
  for i = 1, 5 do
    local iv = c.set[i]
    local mag = math.abs(iv)
    rows[i] = {
      interval = iv,
      weight = 16 * math.exp(-mag / 12 * decay) + rnd(0, 2),
      db = -mag * tilt + rnd(-3, 3)
    }
  end
  if rows[1].weight < 6 then rows[1].weight = rnd(6, 14) end
  return rows
end

function D.roll_root() return pick(ROOTS) end

return D