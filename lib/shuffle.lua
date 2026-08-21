local M = {}

M.SPAN = 20
M.VOL_MIN_DB, M.VOL_MAX_DB = -60, 16
M.VOL_LO, M.VOL_HI = -60, 3
M.VOL_QUANT, M.VOL_STEP = 0.5, 1
M.PITCH_LO, M.PITCH_HI = -24, 24

local MOD = 2147483648
local floor, max, min = math.floor, math.max, math.min

local nvoices = function() return 0 end
local mark = function() end

local function lcg(s) return (s * 1664525 + 1013904223) % MOD end

local function knot(fid, v, k, seed)
  if k == 0 then return 0 end
  local z = k >= 0 and (2 * k) or (-2 * k - 1)
  return (lcg(lcg(seed + fid * 9973 + v * 8191 + z * 104729)) / MOD) * 2 - 1
end

local function seed_now()
  local ok, v = pcall(params.get, params, "lseed")
  return (ok and v) and floor(v) or 1
end

local E = {}
E.__index = E

function E:reset()
  self.depth = 0
  for i = 1, self.nv do self.base[i], self.off[i] = nil, 0 end
end

function E:apply()
  local k = floor(self.depth / M.SPAN)
  local f = self.depth / M.SPAN - k
  local s = f * f * (3 - 2 * f)
  local seed = seed_now()
  local lo, hi, q, fid = self.lo, self.hi, self.quant, self.fid
  for i = 1, nvoices() do
    local b = self.base[i]
    if b then
      local v0 = knot(fid, i, k, seed)
      local mod = v0 + (knot(fid, i, k + 1, seed) - v0) * s
      local v = max(lo, min(hi, b + mod * (mod > 0 and (hi - b) or (b - lo))))
      if q then v = floor(v / q + 0.5) * q end
      self.off[i] = v - b
      self.applying = true
      params:set(self.ids[i], v)
      self.applying = false
    end
  end
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

function E:release(i)
  if self.base[i] then
    self.base[i] = params:get(self.ids[i]) - (self.off[i] or 0)
  end
end

function E:touched(i)
  if not self.applying then self:release(i) end
end

function E:nudge(i, d)
  self:release(i)
  local id = self.ids[i]
  params:set(id, max(self.emin, min(self.emax, params:get(id) + d * self.step)))
  mark()
end

local function new(ids, fid, lo, hi, quant, step, emin, emax)
  return setmetatable({
    ids = ids, nv = #ids, fid = fid, lo = lo, hi = hi, quant = quant,
    step = step, emin = emin, emax = emax,
    base = {}, off = {}, depth = 0, applying = false
  }, E)
end

function M.init(cfg)
  nvoices, mark = cfg.count, cfg.dirty
  M.vol = new(cfg.vol_ids, 1, M.VOL_LO, M.VOL_HI, M.VOL_QUANT,
    M.VOL_STEP, M.VOL_MIN_DB, M.VOL_MAX_DB)
  M.pitch = new(cfg.tune_ids, 2, M.PITCH_LO, M.PITCH_HI, 1,
    1, M.PITCH_LO, M.PITCH_HI)
end

return M