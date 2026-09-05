local P = {}
P.__index = P
P.SPAN = 127
local SPAN = P.SPAN
local INV_SPAN = 1 / SPAN
local MASS_SCALE = 10
local CONTACT = 2

local max, random, floor = math.max, math.random, math.floor

local clamp = include("grains/lib/util").clamp

local function set_bead(b, lo, hi)
  local r = random(3, 12)
  b.pos = clamp(lo + random() * max(hi - lo, 1), lo, hi)
  b.vel = random(-100, 100) / 200
  b.r = r
  b.m = r * r * MASS_SCALE
  return b
end

local function new_bead(lo, hi) return set_bead({}, lo, hi) end

local function elastic(mA, mB, vA1, vB1)
  local vC1 = vA1 - vB1
  local vD2 = (2 * vC1) / (mB / mA + 1)
  local vB2 = vD2 + vB1
  local vC2 = vC1 - (mB * vD2) / mA
  return vC2 + vB1, vB2
end

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
  m.energy = 0
  return m
end

function P:reroll(lo, hi)
  local b = self.beads
  for i = 1, self.n do set_bead(b[i], lo or 8, hi or 120) end
  reindex(self)
  self.energy = 0
end

function P:resize(n, lo, hi)
  if n == self.n then return end
  local b = self.beads
  for i = self.n + 1, n do b[i] = new_bead(lo or 8, hi or 120) end
  for i = n + 1, self.n do b[i] = nil end
  self.n = n
  reindex(self)
  self.energy = 0
end

local function thermostat(b, energy, setpoint)
  local t = random() * 0.2
  if energy < setpoint then t = t + 1 else t = 1 - t end
  b.vel = b.vel * t
end

function P:update(lo, hi, setpoint, maxv)
  maxv = maxv or 3
  if hi - lo < 4 then
    hi = lo + 4
    if hi > SPAN then hi = SPAN; lo = SPAN - 4 end
  end
  local beads = self.beads
  local ord = self.ord
  local n = self.n
  local moving = setpoint > 0
  local contact = CONTACT * (hi - lo) / SPAN
  if maxv > contact then contact = maxv end
  if moving then
    local nmaxv = -maxv
    for i = 1, n do
      local b = beads[i]
      local v = b.vel
      if v > maxv then v = maxv elseif v < nmaxv then v = nmaxv end
      local p = b.pos + v
      if p < lo then
        p = lo
        v = -v
      elseif p > hi then
        p = hi
        v = -v
      end
      b.pos, b.vel = p, v
    end
    sort_ord(ord, beads, n)
    local push = contact * 0.5
    local en = self.energy
    for k = 1, n - 1 do
      local a, b = beads[ord[k]], beads[ord[k + 1]]
      if b.pos - a.pos < contact then
        a.vel, b.vel = elastic(a.m, b.m, a.vel, b.vel)
        a.pos = a.pos - push
        b.pos = b.pos + push
        thermostat(a, en, setpoint)
        thermostat(b, en, setpoint)
      end
    end
  end
  local e = 0
  for i = 1, n do
    local b = beads[i]
    local v = b.vel
    e = e + 0.5 * v * v * b.m
    local p = b.pos
    if p < lo then b.pos = lo elseif p > hi then b.pos = hi end
  end
  self.energy = e
  if moving and (e < setpoint * 0.6 or e > setpoint * 1.6) then
    for i = 1, n do thermostat(beads[i], e, setpoint) end
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
    b.pos, b.vel, b.r, b.m = t[k + 1], t[k + 2], r, r * r * MASS_SCALE
  end
  for i = n + 1, self.n do beads[i] = nil end
  self.n = n
  reindex(self)
  self.energy = 0
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
