local M = {}

M.VOL_MIN_DB, M.VOL_MAX_DB = -60, 16
M.VOL_LO, M.VOL_HI = -60, 10
M.PITCH_LO, M.PITCH_HI = -24, 24
M.SPAN = 10
M.VOL_UP = 20
M.VOL_DOWN = 30
M.PITCH_SWING = 18
M.VOL_HOLD = 0.5

local DEAD = 0.45
local STEEP = 1.8
local floor, max, min, abs, log = math.floor, math.max, math.min, math.abs, math.log
local LOG10 = 10 / log(10)
local nvoices, mark = function() return 0 end, function() end

local function hash(a)
  local x = floor(a) & 0xffffffff
  x = ((x ~ (x >> 16)) * 0x7feb352d) & 0xffffffff
  x = ((x ~ (x >> 15)) * 0x846ca68b) & 0xffffffff
  return (x ~ (x >> 16)) / 0x100000000
end

local perm, ka, kb = {}, {}, {}
local function deal(fid, k, seed, n, out)
  if k == 0 then
    for v = 1, n do out[v] = 0 end
    return
  end
  local b = seed + fid * 9973 + (k > 0 and 2 * k or -2 * k - 1) * 104729
  for v = 1, n do perm[v] = v end
  for i = n, 2, -1 do
    local j = floor(hash(b + i * 6151) * i) + 1
    perm[i], perm[j] = perm[j], perm[i]
  end
  for v = 1, n do
    local u = (perm[v] - 1 + hash(b + v * 8191)) / n * 2 - 1
    local m = DEAD + (1 - DEAD) * abs(u)
    out[v] = u < 0 and -m or m
  end
end

local function seed_now()
  local ok, v = pcall(params.get, params, "lseed")
  return (ok and v) and floor(v) or 1
end

local E = {}
E.__index = E

function E:reset()
  self.depth, self.base, self.off = 0, {}, {}
end

function E:apply()
  local base, off, n = self.base, self.off, nvoices()
  local up, down, q = self.up, self.down, self.quant
  local d = self.depth / M.SPAN
  local k = floor(d)
  local f = max(0, min(1, (d - k - 0.5) * STEEP + 0.5))
  local s = f * f * (3 - 2 * f)
  local seed = seed_now()
  deal(self.fid, k, seed, n, ka)
  deal(self.fid, k + 1, seed, n, kb)

  local sum, cnt, p0, p1 = 0, 0, 0, 0
  for i = 1, n do
    local b = base[i]
    if b then
      local mod = ka[i] + (kb[i] - ka[i]) * s
      off[i] = mod * (mod > 0 and up or down)
      sum, cnt = sum + off[i], cnt + 1
      if self.hold then
        p0 = p0 + 10 ^ (b * 0.1)
        p1 = p1 + 10 ^ ((b + off[i]) * 0.1)
      end
    end
  end

  local shift = 0
  if self.hold and cnt > 1 then
    local h = M.VOL_HOLD
    shift = (1 - h) * (-sum / cnt) + h * LOG10 * log(p0 / p1)
  end

  self.applying = true
  for i = 1, n do
    local b = base[i]
    if b then
      local v = max(self.lo, min(self.hi, b + off[i] + shift))
      if q then v = floor(v / q + 0.5) * q end
      off[i] = v - b
      params:set(self.ids[i], v)
    end
  end
  self.applying = false
end

function E:kick(d)
  local n = nvoices()
  if n < 1 then return end
  for i = 1, n do
    if self.base[i] == nil then
      self.base[i], self.off[i] = params:get(self.ids[i]), 0
    end
  end
  self.depth = self.depth + d
  self:apply()
  mark()
end

function E:touched(i)
  if not self.applying and self.base[i] then
    self.base[i] = params:get(self.ids[i]) - (self.off[i] or 0)
  end
end

function E:relocate(src, dst)
  if src == dst then return end
  self.base[dst], self.off[dst] = self.base[src], self.off[src] or 0
  self.base[src], self.off[src] = nil, 0
end

function E:nudge(i, d)
  self:touched(i)
  local id = self.ids[i]
  params:set(id, max(self.emin, min(self.emax, params:get(id) + d)))
  mark()
end

function M.relocate(src, dst)
  M.vol:relocate(src, dst)
  M.pitch:relocate(src, dst)
end

function M.init(cfg)
  nvoices, mark = cfg.count, cfg.dirty
  M.vol = setmetatable({
    ids = cfg.vol_ids, fid = 1, hold = true,
    lo = M.VOL_LO, hi = M.VOL_HI, quant = 0.5,
    up = M.VOL_UP, down = M.VOL_DOWN,
    emin = M.VOL_MIN_DB, emax = M.VOL_MAX_DB,
    base = {}, off = {}, depth = 0, applying = false
  }, E)
  M.pitch = setmetatable({
    ids = cfg.tune_ids, fid = 2,
    lo = M.PITCH_LO, hi = M.PITCH_HI, quant = 1,
    up = M.PITCH_SWING, down = M.PITCH_SWING,
    emin = M.PITCH_LO, emax = M.PITCH_HI,
    base = {}, off = {}, depth = 0, applying = false
  }, E)
end

return M