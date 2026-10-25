local M = {}

M.VOL_MIN_DB, M.VOL_MAX_DB = -60, 16
M.VOL_LO, M.VOL_HI = -60, 6
M.PITCH_LO, M.PITCH_HI = -24, 24

M.VOL_RATE = 3
M.PITCH_RATE = 2.5
M.VOL_SLACK = 76

local floor, max, min, abs, sqrt, random =
  math.floor, math.max, math.min, math.abs, math.sqrt, math.random
local GLIDE = 0.92
local GK = sqrt(1 - GLIDE * GLIDE)
local nvoices, mark = function() return 0 end, function() end
local snapfn = nil

function M.snap(x)
  local v = snapfn and snapfn(x) or floor(x + 0.5)
  while v > M.PITCH_HI do v = v - 12 end
  while v < M.PITCH_LO do v = v + 12 end
  return v
end

local E = {}
E.__index = E

function E:kick(d)
  local n = nvoices()
  if n < 1 then return end
  local pos, vel, ids = self.pos, self.vel, self.ids
  local lo, hi, q, rate, sn = self.lo, self.hi, self.quant, self.rate, self.snap
  local sum = 0
  for i = 1, n do
    local cur = params:get(ids[i])
    local p = pos[i]
    if p == nil or abs((sn and sn(p) or floor(p / q + 0.5) * q) - cur) > 1e-6 then p = cur end
    pos[i] = p
    vel[i] = (vel[i] or random() * 2 - 1) * GLIDE + (random() * 2 - 1) * GK
    sum = sum + vel[i]
  end
  local mean = self.level and sum / n or 0
  for i = 1, n do
    local p = pos[i] + (vel[i] - mean) * rate * d
    if p < lo then p, vel[i] = lo, -vel[i]
    elseif p > hi then p, vel[i] = hi, -vel[i] end
    pos[i] = p
    params:set(ids[i], sn and sn(p) or floor(p / q + 0.5) * q)
  end
  mark()
end

function E:nudge(i, d, others)
  local a, b, skip = i, i, 0
  if others then a, b, skip = 1, nvoices(), i end
  local ids = self.ids
  if self.move then
    for j = a, b do
      if j ~= skip then
        local id = ids[j]
        params:set(id, max(self.lo, min(self.hi, self.move(params:get(id), d))))
      end
    end
    mark()
    return
  end
  local sh, at = self.shadow, self.at
  local lo, hi, k = self.emin, self.emax, self.slack
  local mx, mn = -1e30, 1e30
  for j = a, b do
    if j ~= skip then
      local cur = params:get(ids[j])
      if at[j] ~= cur then sh[j], at[j] = cur, cur end
      local v = sh[j]
      if v > mx then mx = v end
      if v < mn then mn = v end
    end
  end
  if mx < mn then return end
  local off = ((mx < lo and lo - mx) or (mn > hi and hi - mn) or 0) + d * (self.step or 1)
  mx, mn = mx + off, mn + off
  off = off + ((mx < lo and lo - mx) or (mn > hi and hi - mn) or 0)
  for j = a, b do
    if j ~= skip then
      local v = sh[j] + off
      if v < lo - k then v = lo - k elseif v > hi + k then v = hi + k end
      sh[j] = v
      params:set(ids[j], max(lo, min(hi, v)))
      at[j] = params:get(ids[j])
    end
  end
  mark()
end

function M.init(cfg)
  nvoices, mark = cfg.count, cfg.dirty
  snapfn = cfg.snap
  M.vol = setmetatable({
    ids = cfg.vol_ids, rate = M.VOL_RATE, level = true,
    lo = M.VOL_LO, hi = M.VOL_HI, quant = 0.5,
    emin = M.VOL_MIN_DB, emax = M.VOL_MAX_DB, slack = M.VOL_SLACK,
    pos = {}, vel = {}, shadow = {}, at = {}
  }, E)
  M.pitch = setmetatable({
    ids = cfg.tune_ids, rate = M.PITCH_RATE,
    lo = M.PITCH_LO, hi = M.PITCH_HI, quant = 1, snap = M.snap, move = cfg.move,
    emin = M.PITCH_LO, emax = M.PITCH_HI, slack = 0,
    pos = {}, vel = {}, shadow = {}, at = {}
  }, E)
end

return M
