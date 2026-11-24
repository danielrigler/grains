local M = {VOL_MIN_DB = -60, VOL_MAX_DB = 16, PITCH_LO = -24, PITCH_HI = 24, FLIP = 0.1}

local floor, max, min, random = math.floor, math.max, math.min, math.random
local count, mark, snapfn, S, key = function() return 0 end, function() end, nil, nil, nil
local LIM = M.FLIP * 4294967296

function M.snap(x)
  local v = snapfn and snapfn(x) or floor(x + 0.5)
  while v > M.PITCH_HI do v = v - 12 end
  while v < M.PITCH_LO do v = v + 12 end
  return v
end

local function round(x) return x < 0 and -floor(0.5 - x) or floor(x + 0.5) end

local function flip(s, t)
  local x = (s + t * 0x9E3779B1) & 0xffffffff
  x = ((x ~ (x >> 16)) * 0x45D9F3B) & 0xffffffff
  x = ((x ~ (x >> 16)) * 0x45D9F3B) & 0xffffffff
  return (x ~ (x >> 16)) < LIM
end

local function bounce(x, lo, hi)
  local r = hi - lo
  if r <= 0 then return lo end
  local y = (x - lo) % (2 * r)
  return lo + (y > r and 2 * r - y or y)
end

local function vol(e, b, u)
  if u == 0 then return b end
  local x = bounce(b + u * e.rate, min(e.lo, b), max(e.hi, b))
  return floor(x / e.quant + 0.5) * e.quant
end

local function pitch(e, b, u)
  if u == 0 then return b end
  local k = e.k
  return S.pitch(round(bounce(S.near(b, k) + u * e.step, e.dlo, e.dhi)), k)
end

local function pitch_pre(e)
  local k = key()
  e.k, e.step, e.dlo, e.dhi = k, e.rate * S.size(k), S.near(e.lo, k), S.near(e.hi, k)
end

local E = {}
E.__index = E

function E:anchor(n)
  local ids, base, last, u, c, sd = self.ids, self.base, self.last, self.u, self.c, self.sd
  for i = 1, n do
    local v = params:get(ids[i])
    base[i], last[i], u[i], c[i], sd[i] = v, v, 0, random() < 0.5 and 1 or -1, random(0, 0x7fffffff)
  end
  self.n, self.t = n, 0
end

function E:stale(n)
  if n ~= self.n then return true end
  local ids, last = self.ids, self.last
  for i = 1, n do if params:get(ids[i]) ~= last[i] then return true end end
  return false
end

function E:kick(d)
  local n = count()
  if n < 1 then return end
  if self:stale(n) then self:anchor(n) end
  local t, u, c, sd = self.t, self.u, self.c, self.sd
  if d > 0 then
    for _ = 1, d do
      for i = 1, n do
        local x = flip(sd[i], t) and -c[i] or c[i]
        c[i], u[i] = x, u[i] + x
      end
      t = t + 1
    end
  else
    for _ = 1, -d do
      t = t - 1
      for i = 1, n do
        local x = c[i]
        u[i], c[i] = u[i] - x, flip(sd[i], t) and -x or x
      end
    end
  end
  self.t = t
  if self.pre then self:pre() end
  local ids, base, last, f, hit = self.ids, self.base, self.last, self.f, false
  for i = 1, n do
    local v = f(self, base[i], u[i])
    if v ~= last[i] then
      params:set(ids[i], v)
      last[i], hit = params:get(ids[i]), true
    end
  end
  if hit then mark() end
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

local function eng(e)
  e.n, e.t, e.base, e.last, e.u, e.c, e.sd, e.shadow, e.at = 0, 0, {}, {}, {}, {}, {}, {}, {}
  return setmetatable(e, E)
end

function M.init(cfg)
  count, mark, snapfn, S, key = cfg.count, cfg.dirty, cfg.snap, cfg.scale, cfg.key
  M.vol = eng{ids = cfg.vol_ids, f = vol, rate = 2, lo = -42, hi = 6, quant = 0.5,
    emin = M.VOL_MIN_DB, emax = M.VOL_MAX_DB, slack = 76}
  M.pitch = eng{ids = cfg.tune_ids, f = pitch, pre = pitch_pre, rate = 0.1, lo = M.PITCH_LO, hi = M.PITCH_HI,
    move = cfg.move, emin = M.PITCH_LO, emax = M.PITCH_HI, slack = 0}
end

return M
