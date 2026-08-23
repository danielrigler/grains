local P = {}
P.__index = P
P.SPAN = 127
local SPAN = P.SPAN
local INV_SPAN = 1 / SPAN
local MASS_SCALE = 10
local CONTACT = 2

local max, random, floor = math.max, math.random, math.floor

local clamp = include("grains/lib/util").clamp

local function new_bead(lo, hi)
  local r = random(3, 12)
  return {
    pos = clamp(lo + random() * max(hi - lo, 1), lo, hi),
    vel = random(-100, 100) / 200,
    r = r,
    m = r * r * MASS_SCALE
  }
end

local function elastic(mA, mB, vA1, vB1)
  local vC1 = vA1 - vB1
  local vD2 = (2 * vC1) / (mB / mA + 1)
  local vB2 = vD2 + vB1
  local vC2 = vC1 - (mB * vD2) / mA
  return vC2 + vB1, vB2
end

function P.new(n)
  local m = setmetatable({}, P)
  m.n = n or 2
  m.beads = {}
  for i = 1, m.n do m.beads[i] = new_bead(8, 120) end
  m.energy = 0
  return m
end

function P:reroll(lo, hi)
  for i = 1, self.n do self.beads[i] = new_bead(lo or 8, hi or 120) end
  self.energy = 0
end

function P:resize(n, lo, hi)
  if n == self.n then return end
  local b = self.beads
  for i = self.n + 1, n do b[i] = new_bead(lo or 8, hi or 120) end
  for i = n + 1, self.n do b[i] = nil end
  self.n = n
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
  local n = self.n
  local moving = setpoint > 0
  local contact = CONTACT
  if maxv > CONTACT then contact = maxv end
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
    local push = contact * 0.5
    local ncontact = -contact
    local en = self.energy
    for i = 1, n do
      local a = beads[i]
      local ap = a.pos
      for j = i + 1, n do
        local b = beads[j]
        local d = b.pos - ap
        if d < contact and d > ncontact then
          a.vel, b.vel = elastic(a.m, b.m, a.vel, b.vel)
          if d > 0 then
            ap = ap - push
            b.pos = b.pos + push
          else
            ap = ap + push
            b.pos = b.pos - push
          end
          a.pos = ap
          thermostat(a, en, setpoint)
          thermostat(b, en, setpoint)
        end
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
  local beads = {}
  for i = 1, n do
    local k = (i - 1) * 3
    local pos, vel, r = t[k + 1], t[k + 2], t[k + 3]
    if pos == nil or vel == nil or r == nil then return false end
    r = clamp(floor(r), 1, 64)
    beads[i] = {pos = pos, vel = vel, r = r, m = r * r * MASS_SCALE}
  end
  self.beads = beads
  self.n = n
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
