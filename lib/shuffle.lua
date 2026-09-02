local M = {}

M.VOL_MIN_DB, M.VOL_MAX_DB = -60, 16
M.VOL_LO, M.VOL_HI = -60, 6
M.PITCH_LO, M.PITCH_HI = -24, 24

M.VOL_RATE = 3
M.PITCH_RATE = 2.5
M.GLIDE = 0.92
M.VOL_SLACK = 76

local floor, max, min, abs, sqrt, random =
  math.floor, math.max, math.min, math.abs, math.sqrt, math.random
local nvoices, mark = function() return 0 end, function() end

local E = {}
E.__index = E

function E:kick(d)
  local n = nvoices()
  if n < 1 then return end
  local pos, vel, ids = self.pos, self.vel, self.ids
  local lo, hi, q, rate = self.lo, self.hi, self.quant, self.rate
  local g = max(0, min(0.99, M.GLIDE))
  local k = sqrt(1 - g * g)
  local sum = 0
  for i = 1, n do
    local cur = params:get(ids[i])
    local p = pos[i]
    if p == nil or abs(floor(p / q + 0.5) * q - cur) > 1e-6 then p = cur end
    pos[i] = p
    vel[i] = (vel[i] or random() * 2 - 1) * g + (random() * 2 - 1) * k
    sum = sum + vel[i]
  end
  local mean = self.level and sum / n or 0
  for i = 1, n do
    local p = pos[i] + (vel[i] - mean) * rate * d
    if p < lo then p, vel[i] = lo, -vel[i]
    elseif p > hi then p, vel[i] = hi, -vel[i] end
    pos[i] = p
    params:set(ids[i], floor(p / q + 0.5) * q)
  end
  mark()
end

function E:nudge(i, d)
  local ids, sh, at = self.ids, self.shadow, self.at
  local lo, hi, k = self.emin, self.emax, self.slack
  local n = nvoices()
  if i > n then n = i end
  local mx, mn = -1e30, 1e30
  for j = 1, n do
    local cur = params:get(ids[j])
    local v = sh[j]
    if at[j] ~= cur then v = cur sh[j] = cur at[j] = cur end
    if j == i then
      v = v + d * (self.step or 1)
      if v < lo - k then v = lo - k elseif v > hi + k then v = hi + k end
      sh[j] = v
    end
    if v > mx then mx = v end
    if v < mn then mn = v end
  end
  local off = (mx < lo and lo - mx) or (mn > hi and hi - mn) or 0
  if off ~= 0 then
    for j = 1, n do sh[j] = sh[j] + off end
  end
  local v = sh[i]
  params:set(ids[i], max(lo, min(hi, v)))
  at[i] = params:get(ids[i])
  mark()
end

function M.init(cfg)
  nvoices, mark = cfg.count, cfg.dirty
  M.vol = setmetatable({
    ids = cfg.vol_ids, rate = M.VOL_RATE, level = true,
    lo = M.VOL_LO, hi = M.VOL_HI, quant = 0.5,
    emin = M.VOL_MIN_DB, emax = M.VOL_MAX_DB, slack = M.VOL_SLACK,
    pos = {}, vel = {}, shadow = {}, at = {}
  }, E)
  M.pitch = setmetatable({
    ids = cfg.tune_ids, rate = M.PITCH_RATE,
    lo = M.PITCH_LO, hi = M.PITCH_HI, quant = 1,
    emin = M.PITCH_LO, emax = M.PITCH_HI, slack = 0,
    pos = {}, vel = {}, shadow = {}, at = {}
  }, E)
end

return M
