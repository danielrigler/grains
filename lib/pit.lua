local P = {SPAN = 127}
P.__index = P

local SPAN, INV = 127, 1 / 127
local CONTACT, CONTACT_MIN, SEP, REST = 3, 0.5, 0.25, 0.55
local SPEED, GAMMA, GMIN, GMAX, WMIN, VCAP = 1.15, 0.055, 0.03, 0.22, 0.12, 3.5
local KREF, NZ2 = 2.4495, 1.2247449
local random, sqrt = math.random, math.sqrt

local function bead(m, i, lo, hi)
  local r = random(3, 12)
  m.r[i], m.mass[i], m.k[i] = r, r * r * 10, KREF / sqrt(r)
  m.pos[i] = lo + random() * math.max(hi - lo, 1)
  if m.pos[i] > hi then m.pos[i] = hi end
  m.vel[i] = (random() - 0.5) * m.k[i]
end

local function trim(m, n)
  for i = n + 1, m.n do m.pos[i], m.vel[i], m.r[i], m.mass[i], m.k[i], m.ord[i] = nil, nil, nil, nil, nil, nil end
  m.n = n
  for i = 1, n do m.ord[i] = i end
end

function P.new(n)
  local m = setmetatable({n = n or 2, pos = {}, vel = {}, r = {}, mass = {}, k = {}, ord = {}}, P)
  for i = 1, m.n do bead(m, i, 8, 120) end
  trim(m, m.n)
  return m
end

function P:reroll(lo, hi)
  for i = 1, self.n do bead(self, i, lo or 8, hi or 120) end
  trim(self, self.n)
end

function P:resize(n, lo, hi)
  if n == self.n then return end
  for i = self.n + 1, n do bead(self, i, lo or 8, hi or 120) end
  trim(self, n)
end

function P:update(lo, hi, rate)
  local pos, vel, mass, kk, ord, n = self.pos, self.vel, self.mass, self.k, self.ord, self.n
  local span = hi - lo
  if span < 4 then
    hi = lo + 4
    if hi > SPAN then hi, lo = SPAN, SPAN - 4 end
    span = 4
  end
  if not rate or rate <= 0 then
    for i = 1, n do
      local p = pos[i]
      if p < lo then pos[i] = lo elseif p > hi then pos[i] = hi end
    end
    return
  end
  local w = span * INV
  if w < WMIN then w = WMIN end
  local g = GAMMA * sqrt(rate)
  if g < GMIN then g = GMIN elseif g > GMAX then g = GMAX end
  local decay, vt = 1 - g, SPEED * rate * w
  local nz, cap = 2 * vt * sqrt(g * (2 - g)) * NZ2, VCAP * vt
  if cap > span * 0.5 then cap = span * 0.5 end
  for i = 1, n do
    local k = kk[i]
    local v, c = vel[i] * decay + (random() + random() - 1) * nz * k, cap * k
    if v > c then v = c elseif v < -c then v = -c end
    local p = pos[i] + v
    if p < lo then
      p, v = lo + lo - p, -v
      if p > hi then p = hi end
    elseif p > hi then
      p, v = hi + hi - p, -v
      if p < lo then p = lo end
    end
    pos[i], vel[i] = p, v
  end
  for i = 2, n do
    local a = ord[i]
    local p, j = pos[a], i - 1
    while j >= 1 and pos[ord[j]] > p do ord[j + 1] = ord[j] j = j - 1 end
    ord[j + 1] = a
  end
  local cw = CONTACT * span * INV
  if cw < CONTACT_MIN then cw = CONTACT_MIN end
  for i = 1, n - 1 do
    local a, b = ord[i], ord[i + 1]
    local pa, pb = pos[a], pos[b]
    local d = pb - pa
    if d < cw then
      local o = (cw - d) * SEP
      pa, pb = pa - o, pb + o
      pos[a], pos[b] = pa < lo and lo or pa, pb > hi and hi or pb
      local va, vb = vel[a], vel[b]
      local rel = vb - va
      if rel < 0 then
        local ma, mb = mass[a], mass[b]
        local j = (1 + REST) * rel / (ma + mb)
        vel[a], vel[b] = va + j * mb, vb - j * ma
      end
    end
  end
end

function P:dump()
  local t, pos, vel, r = {}, self.pos, self.vel, self.r
  for i = 1, self.n do t[i * 3 - 2], t[i * 3 - 1], t[i * 3] = pos[i], vel[i], r[i] end
  return t
end

function P:load(t)
  local n, pos, vel = #t // 3, self.pos, self.vel
  for i = 1, n do
    local r = t[i * 3]
    self.r[i], self.mass[i], self.k[i] = r, r * r * 10, KREF / sqrt(r)
    pos[i], vel[i] = t[i * 3 - 2], t[i * 3 - 1]
  end
  trim(self, n)
end

function P:window(k)
  local i = k * 2 - 1
  local x, y = self.pos[i], self.pos[i + 1]
  if not x or not y then return 0, 1 end
  if x > y then x, y = y, x end
  return x * INV, y * INV
end

return P
