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
local NZ2       = 1.2247449

local random, floor, sqrt = math.random, math.floor, math.sqrt

local clamp = include("grains/lib/util").clamp

local function set_bead(m, i, lo, hi)
  local r = random(3, 12)
  local k = KREF / sqrt(r)
  local w = hi - lo
  if w < 1 then w = 1 end
  m.pos[i] = clamp(lo + random() * w, lo, hi)
  m.r[i] = r
  m.mass[i] = r * r * MASS_SCALE
  m.k[i] = k
  m.vel[i] = (random() - 0.5) * k
end

local function reindex(self)
  local ord = self.ord
  for i = 1, self.n do ord[i] = i end
end

function P.new(n)
  local m = setmetatable({}, P)
  m.n = n or 2
  m.pos, m.vel, m.r, m.mass, m.k, m.ord = {}, {}, {}, {}, {}, {}
  for i = 1, m.n do set_bead(m, i, 8, 120) end
  reindex(m)
  return m
end

function P:reroll(lo, hi)
  lo, hi = lo or 8, hi or 120
  for i = 1, self.n do set_bead(self, i, lo, hi) end
  reindex(self)
end

function P:resize(n, lo, hi)
  if n == self.n then return end
  lo, hi = lo or 8, hi or 120
  for i = self.n + 1, n do set_bead(self, i, lo, hi) end
  local pos, vel, r, mass, k, ord = self.pos, self.vel, self.r, self.mass, self.k, self.ord
  for i = n + 1, self.n do
    pos[i], vel[i], r[i], mass[i], k[i], ord[i] = nil, nil, nil, nil, nil, nil
  end
  self.n = n
  reindex(self)
end

function P:update(lo, hi, rate)
  local pos, vel, mass, kk, ord, n =
    self.pos, self.vel, self.mass, self.k, self.ord, self.n
  local span = hi - lo
  if span < 4 then
    hi = lo + 4
    if hi > SPAN then hi = SPAN lo = SPAN - 4 end
    span = 4
  end

  if rate == nil or rate <= 0 then
    for i = 1, n do
      local p = pos[i]
      if p < lo then pos[i] = lo elseif p > hi then pos[i] = hi end
    end
    return
  end

  local w = span * INV_SPAN
  if w < WMIN then w = WMIN end
  local g = GAMMA * sqrt(rate)
  if g < GMIN then g = GMIN elseif g > GMAX then g = GMAX end
  local decay = 1 - g
  local vt = SPEED * rate * w
  local nz = 2 * vt * sqrt(g * (2 - g)) * NZ2
  local cap = VCAP * vt
  local half = span * 0.5
  if cap > half then cap = half end

  for i = 1, n do
    local k = kk[i]
    local v = vel[i] * decay + (random() + random() - 1) * nz * k
    local c = cap * k
    if v > c then v = c elseif v < -c then v = -c end
    local p = pos[i] + v
    if p < lo then
      p = lo + lo - p
      v = -v
      if p > hi then p = hi end
    elseif p > hi then
      p = hi + hi - p
      v = -v
      if p < lo then p = lo end
    end
    pos[i], vel[i] = p, v
  end

  for i = 2, n do
    local a = ord[i]
    local p = pos[a]
    local j = i - 1
    while j >= 1 and pos[ord[j]] > p do
      ord[j + 1] = ord[j]
      j = j - 1
    end
    ord[j + 1] = a
  end

  local cw = CONTACT * span * INV_SPAN
  if cw < CONTACT_MIN then cw = CONTACT_MIN end
  for i = 1, n - 1 do
    local a, b = ord[i], ord[i + 1]
    local pa, pb = pos[a], pos[b]
    local d = pb - pa
    if d < cw then
      local o = (cw - d) * SEP
      pa, pb = pa - o, pb + o
      if pa < lo then pa = lo end
      if pb > hi then pb = hi end
      pos[a], pos[b] = pa, pb
      local va, vb = vel[a], vel[b]
      local rel = vb - va
      if rel < 0 then
        local ma, mb = mass[a], mass[b]
        local j = (1 + REST) * rel / (ma + mb)
        vel[a] = va + j * mb
        vel[b] = vb - j * ma
      end
    end
  end
end

function P:load(t, n)
  if n == nil or n < 1 then return false end
  for i = 1, n * 3 do
    if t[i] == nil then return false end
  end
  local pos, vel, r, mass, kk = self.pos, self.vel, self.r, self.mass, self.k
  for i = 1, n do
    local b = (i - 1) * 3
    local rv = clamp(floor(t[b + 3]), 1, 64)
    pos[i], vel[i], r[i] = t[b + 1], t[b + 2], rv
    mass[i], kk[i] = rv * rv * MASS_SCALE, KREF / sqrt(rv)
  end
  local ord = self.ord
  for i = n + 1, self.n do
    pos[i], vel[i], r[i], mass[i], kk[i], ord[i] = nil, nil, nil, nil, nil, nil
  end
  self.n = n
  reindex(self)
  return true
end

function P:window(k)
  local i = (k or 1) * 2 - 1
  local pos = self.pos
  local x, y = pos[i], pos[i + 1]
  if x == nil or y == nil then return 0, 1 end
  if x > y then x, y = y, x end
  return x * INV_SPAN, y * INV_SPAN
end

return P
