local M = {}

M.VOL_MIN_DB, M.VOL_MAX_DB = -60, 16
M.VOL_LO, M.VOL_HI = -60, 6
M.PITCH_LO, M.PITCH_HI = -24, 24

M.VOL_RATE = 3
M.PITCH_RATE = 2.5
M.GLIDE = 0.92

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
  local id = self.ids[i]
  params:set(id, max(self.emin, min(self.emax, params:get(id) + d)))
  mark()
end

function M.init(cfg)
  nvoices, mark = cfg.count, cfg.dirty
  M.vol = setmetatable({
    ids = cfg.vol_ids, rate = M.VOL_RATE, level = true,
    lo = M.VOL_LO, hi = M.VOL_HI, quant = 0.5,
    emin = M.VOL_MIN_DB, emax = M.VOL_MAX_DB,
    pos = {}, vel = {}
  }, E)
  M.pitch = setmetatable({
    ids = cfg.tune_ids, rate = M.PITCH_RATE,
    lo = M.PITCH_LO, hi = M.PITCH_HI, quant = 1,
    emin = M.PITCH_LO, emax = M.PITCH_HI,
    pos = {}, vel = {}
  }, E)
end

return M