local P = {}
P.__index = P
P.SPAN = 127
local SPAN = P.SPAN
local INV_SPAN = 1 / SPAN
local MASS_SCALE = 10

local CONTACT   = 3
local CONTACT_MIN = 0.5
local SEP       = 0.25
local REST      = 0.55
local SPEED     = 1.15
local GAMMA     = 0.055
local GMIN      = 0.03
local GMAX      = 0.22
local WMIN      = 0.12
local VCAP      = 3.5
local KREF      = 2.4495

local max, random, floor, sqrt = math.max, math.random, math.floor, math.sqrt

local clamp = include("grains/lib/util").clamp

local function set_bead(b, lo, hi)
  local r = random(3, 12)
  local k = KREF / sqrt(r)
  b.pos = clamp(lo + random() * max(hi - lo, 1), lo, hi)
  b.r = r
  b.m = r * r * MASS_SCALE
  b.k = k
  b.vel = (random() - 0.5) * k
  return b
end

local function new_bead(lo, hi) return set_bead({}, lo, hi) end

local function reindex(self)
  local ord = self.ord
  for i = 1, self.n do ord[i] = i end
end

local function sort_ord(ord, beads, n)
  for i = 2, n do
    local v = ord[i]
    local p = beads[v].pos
    local j = i - 1
    while j >= 1 and beads[ord[j]].pos > p do
      ord[j + 1] = ord[j]
      j = j - 1
    end
    ord[j + 1] = v
  end
end

function P.new(n)
  local m = setmetatable({}, P)
  m.n = n or 2
  m.beads = {}
  m.ord = {}
  for i = 1, m.n do m.beads[i] = new_bead(8, 120) end
  reindex(m)
  return m
end

function P:reroll(lo, hi)
  local b = self.beads
  for i = 1, self.n do set_bead(b[i], lo or 8, hi or 120) end
  reindex(self)
end

function P:resize(n, lo, hi)
  if n == self.n then return end
  local b = self.beads
  for i = self.n + 1, n do b[i] = new_bead(lo or 8, hi or 120) end
  for i = n + 1, self.n do b[i] = nil end
  self.n = n
  reindex(self)
end

function P:update(lo, hi, rate)
  local span = hi - lo
  if span < 4 then
    hi = lo + 4
    if hi > SPAN then hi = SPAN lo = SPAN - 4 end
    span = 4
  end
  local beads, ord, n = self.beads, self.ord, self.n

  if rate == nil or rate <= 0 then
    for i = 1, n do
      local b = beads[i]
      local p = b.pos
      if p < lo then b.pos = lo elseif p > hi then b.pos = hi end
    end
    return
  end

  local w = span * INV_SPAN
  if w < WMIN then w = WMIN end
  local g = GAMMA * sqrt(rate)
  if g < GMIN then g = GMIN elseif g > GMAX then g = GMAX end
  local decay = 1 - g
  local vt = SPEED * rate * w
  local nz = 2 * vt * sqrt(g * (2 - g))
  local cap = VCAP * vt
  local half = span * 0.5
  if cap > half then cap = half end

  for i = 1, n do
    local b = beads[i]
    local k = b.k
    local v = b.vel * decay + (random() + random() + random() - 1.5) * nz * k
    local c = cap * k
    if v > c then v = c elseif v < -c then v = -c end
    local p = b.pos + v
    if p < lo then
      p = lo + lo - p
      v = -v
      if p > hi then p = hi end
    elseif p > hi then
      p = hi + hi - p
      v = -v
      if p < lo then p = lo end
    end
    b.pos, b.vel = p, v
  end

  sort_ord(ord, beads, n)

  local cw = CONTACT * span * INV_SPAN
  if cw < CONTACT_MIN then cw = CONTACT_MIN end
  for i = 1, n - 1 do
    local a, b = beads[ord[i]], beads[ord[i + 1]]
    local d = b.pos - a.pos
    if d < cw then
      local o = (cw - d) * SEP
      local pa, pb = a.pos - o, b.pos + o
      if pa < lo then pa = lo end
      if pb > hi then pb = hi end
      a.pos, b.pos = pa, pb
      local rel = b.vel - a.vel
      if rel < 0 then
        local j = (1 + REST) * rel / (a.m + b.m)
        a.vel = a.vel + j * b.m
        b.vel = b.vel - j * a.m
      end
    end
  end
end

function P:load(t, n)
  if n == nil or n < 1 then return false end
  for i = 1, n * 3 do
    if t[i] == nil then return false end
  end
  local beads = self.beads
  for i = 1, n do
    local k = (i - 1) * 3
    local b = beads[i]
    if b == nil then b = {} beads[i] = b end
    local r = clamp(floor(t[k + 3]), 1, 64)
    b.pos, b.vel, b.r, b.m, b.k = t[k + 1], t[k + 2], r, r * r * MASS_SCALE, KREF / sqrt(r)
  end
  for i = n + 1, self.n do beads[i] = nil end
  self.n = n
  reindex(self)
  return true
end

function P:window(k)
  k = k or 1
  local i = (k - 1) * 2 + 1
  local a, b = self.beads[i], self.beads[i + 1]
  if a == nil or b == nil then return 0, 1 end
  local x, y = a.pos, b.pos
  if x > y then x, y = y, x end
  return x * INV_SPAN, y * INV_SPAN
end

return P
