local M = {VOL_MIN_DB = -60, VOL_MAX_DB = 16, PITCH_LO = -24, PITCH_HI = 24}

local floor, max, min, abs, sqrt, random = math.floor, math.max, math.min, math.abs, math.sqrt, math.random
local GLIDE = 0.92
local GK = sqrt(1 - GLIDE * GLIDE)
local count, mark, snapfn = function() return 0 end, function() end, nil

function M.snap(x)
  local v = snapfn and snapfn(x) or floor(x + 0.5)
  while v > M.PITCH_HI do v = v - 12 end
  while v < M.PITCH_LO do v = v + 12 end
  return v
end

local E = {}
E.__index = E

function E:q(p) return self.snap and self.snap(p) or floor(p / self.quant + 0.5) * self.quant end

function E:kick(d)
  local n = count()
  if n < 1 then return end
  local pos, vel, ids, sum = self.pos, self.vel, self.ids, 0
  for i = 1, n do
    local cur, p = params:get(ids[i]), pos[i]
    if not p or abs(self:q(p) - cur) > 1e-6 then p = cur end
    pos[i] = p
    vel[i] = (vel[i] or random() * 2 - 1) * GLIDE + (random() * 2 - 1) * GK
    sum = sum + vel[i]
  end
  local mean = self.level and sum / n or 0
  for i = 1, n do
    local p = pos[i] + (vel[i] - mean) * self.rate * d
    if p < self.lo then p, vel[i] = self.lo, -vel[i] elseif p > self.hi then p, vel[i] = self.hi, -vel[i] end
    pos[i] = p
    params:set(ids[i], self:q(p))
  end
  mark()
end

function E:nudge(i, d, others)
  local a, b, skip = i, i, 0
  if others then a, b, skip = 1, count(), i end
  local ids = self.ids
  if self.move then
    for j = a, b do
      if j ~= skip then params:set(ids[j], max(self.lo, min(self.hi, self.move(params:get(ids[j]), d)))) end
    end
    return mark()
  end
  local sh, at, lo, hi, k = self.shadow, self.at, self.emin, self.emax, self.slack
  local mx, mn = -1e30, 1e30
  for j = a, b do
    if j ~= skip then
      local cur = params:get(ids[j])
      if at[j] ~= cur then sh[j], at[j] = cur, cur end
      mx, mn = max(mx, sh[j]), min(mn, sh[j])
    end
  end
  if mx < mn then return end
  local function fit(x, y) return (x < lo and lo - x) or (y > hi and hi - y) or 0 end
  local off = fit(mx, mn) + d * (self.step or 1)
  off = off + fit(mx + off, mn + off)
  for j = a, b do
    if j ~= skip then
      sh[j] = max(lo - k, min(hi + k, sh[j] + off))
      params:set(ids[j], max(lo, min(hi, sh[j])))
      at[j] = params:get(ids[j])
    end
  end
  mark()
end

function M.init(cfg)
  count, mark, snapfn = cfg.count, cfg.dirty, cfg.snap
  M.vol = setmetatable({ids = cfg.vol_ids, rate = 3, level = true, lo = -60, hi = 6, quant = 0.5,
    emin = M.VOL_MIN_DB, emax = M.VOL_MAX_DB, slack = 76, pos = {}, vel = {}, shadow = {}, at = {}}, E)
  M.pitch = setmetatable({ids = cfg.tune_ids, rate = 2.5, lo = M.PITCH_LO, hi = M.PITCH_HI, quant = 1,
    snap = M.snap, move = cfg.move, emin = M.PITCH_LO, emax = M.PITCH_HI, slack = 0, pos = {}, vel = {}, shadow = {}, at = {}}, E)
end

return M
