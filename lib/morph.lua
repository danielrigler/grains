local M = {}

M.pos = 0
M.dirty = false

local mp, ma, mb, msp, mlo, mid, mnum = {}, {}, {}, {}, {}, {}, {}
local mact, nact = {}, 0
local relist = true
local n = 0
local applying = false
local linked = true
local EPS = 1e-3

local mc = {}
local cpos = nil
local ARRIVED = 0.99

local target = nil

function M.hold(f)
  local prev = applying
  applying = true
  local ok, err = pcall(f)
  applying = prev
  if not ok then error(err, 0) end
end

function M.set(pos)
  if pos < 0 then pos = 0 elseif pos > 1 then pos = 1 end
  if pos >= 1 then linked = false end
  if target and pos ~= M.pos then target = nil end
  M.pos = pos
  M.dirty = true
end

local floor = math.floor

local byid = {}

local function raw_of(k)
  local p = mp[k]
  local lo, sp
  if mnum[k] then
    lo = p.min
    sp = p.max - lo
  else
    lo, sp = mlo[k], msp[k]
  end
  if sp then
    if sp <= 0 then return 0 end
    return (p:get() - lo) / sp
  end
  return p:get_raw()
end

local function write(k, v, exact)
  local p = mp[k]
  local lo, sp
  if mnum[k] then
    lo = p.min
    sp = p.max - lo
  else
    lo, sp = mlo[k], msp[k]
  end
  if sp then
    if sp <= 0 then return 0 end
    local at = p:get()
    local want = floor(lo + v * sp + 0.5)
    if at ~= want then p:set(want) at = want end
    return (at - lo) / sp
  end
  local at = p:get_raw()
  if exact then
    if at ~= v then p:set_raw(v) return v end
    return at
  end
  if v < at - EPS or v > at + EPS then
    p:set_raw(v)
    return v
  end
  return at
end

local function leg(pos)
  if cpos == nil then return nil end
  local f
  if pos > cpos then
    local den = 1 - cpos
    if den <= 0 then return mb, 0 end
    f = (pos - cpos) / den
    if f > 1 then f = 1 end
    return mb, f
  elseif pos < cpos then
    if cpos <= 0 then return ma, 0 end
    f = (cpos - pos) / cpos
    if f > 1 then f = 1 end
    return ma, f
  end
  return mb, 0
end

local function hold_here()
  local C = mc
  for k = 1, n do C[k] = raw_of(k) end
  cpos = M.pos
  relist = true
end

local function record(k)
  local raw = raw_of(k)
  local pos = M.pos
  relist = true
  if raw < 0 then raw = 0 elseif raw > 1 then raw = 1 end

  if linked then
    ma[k], mb[k] = raw, raw
    if cpos then mc[k] = raw end
    return
  end

  local dest
  if target == 1 or target == 2 then dest = target
  elseif pos <= 0 then dest = 1
  elseif pos >= 1 then dest = 2 end
  if dest then
    if dest == 1 then ma[k] = raw else mb[k] = raw end
    if cpos == pos then mc[k] = raw end
    return
  end

  mc[k] = raw
  if cpos ~= pos then hold_here() end
end

function M.init(first, last, skip)
  n = 0
  target = nil
  cpos = nil
  local tN, tO = params.tNUMBER, params.tOPTION
  local tC, tT = params.tCONTROL, params.tTAPER
  for i = first, last do
    local p = params.params[i]
    if p and p.id and p.t and not skip(p.id) then
      local lo, span
      if p.t == tN then
        lo, span = p.min, p.max - p.min
      elseif p.t == tO then
        lo, span = 1, p.count - 1
      end
      local ok = (p.t == tC or p.t == tT) or (span ~= nil and span > 0)
      if ok then
        n = n + 1
        local k = n
        mp[k], mid[k] = p, p.id
        byid[p.id] = k
        mlo[k], msp[k] = lo, span
        mnum[k] = (p.t == tN) or nil
        local r = raw_of(k)
        ma[k], mb[k] = r, r
        local prev = p.action
        p.action = function(v)
          if prev then prev(v) end
          if not applying then record(k) end
        end
      end
    end
  end
  relist = true
  return n
end

local function rebuild()
  local cnt, act, A, B = 0, mact, ma, mb
  if cpos == nil then
    for k = 1, n do
      if A[k] ~= B[k] then cnt = cnt + 1 act[cnt] = k end
    end
  else
    local C = mc
    for k = 1, n do
      local c = C[k]
      if c ~= A[k] or c ~= B[k] then cnt = cnt + 1 act[cnt] = k end
    end
  end
  nact = cnt
  relist = false
end

function M.apply()
  M.dirty = false
  if relist then rebuild() end
  local count = nact
  if count == 0 then cpos = nil return end
  local pos = M.pos
  local e, f = leg(pos)
  if e and f >= ARRIVED then f = 1 end
  local into = (pos <= 0) and ma or ((pos >= 1) and mb or nil)
  local act, dirty_list, exact = mact, false, into ~= nil

  local X, Y, t
  if e then X, Y, t = mc, e, f else X, Y, t = ma, mb, pos end
  local g = 1 - t
  applying = true
  for j = 1, count do
    local k = act[j]
    local v = X[k] * g + Y[k] * t
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    local r = write(k, v, exact)
    if into and r ~= into[k] then into[k] = r dirty_list = true end
  end
  applying = false
  if dirty_list then relist = true end
  if e and f >= ARRIVED then
    cpos = nil
    relist = true
    M.dirty = true
  end
end

local function file_gesture()
  local pos = M.pos
  local dest
  if linked then dest = 0
  elseif target == 1 or target == 2 then dest = target
  elseif pos <= 0 then dest = 1
  elseif pos >= 1 then dest = 2
  end
  if dest == nil then hold_here() return end
  for k = 1, n do
    local r = raw_of(k)
    if dest ~= 2 then ma[k] = r end
    if dest ~= 1 then mb[k] = r end
  end
  cpos = nil
  relist = true
end

function M.store(which)
  for k = 1, n do
    local r = raw_of(k)
    if which == 1 then ma[k] = r else mb[k] = r end
  end
  linked = false
  relist = true
  target = which
  hold_here()
end

function M.gesture(f)
  M.hold(f)
  file_gesture()
end

function M.clear()
  for k = 1, n do
    local r = raw_of(k)
    ma[k], mb[k] = r, r
  end
  linked = true
  target = nil
  relist = true
  cpos = nil
end

function M.slots() return n end

function M.slot(k) return mid[k], ma[k], mb[k] end

function M.move(from_id, to_id)
  local a, b = byid[from_id], byid[to_id]
  if a == nil or b == nil then return false end
  ma[b], mb[b], mc[b] = ma[a], mb[a], mc[a]
  local r = raw_of(a)
  if r < 0 then r = 0 elseif r > 1 then r = 1 end
  ma[a], mb[a], mc[a] = r, r, r
  relist = true
  return true
end

function M.put(id, a, b)
  local k = byid[id]
  if k == nil then return false end
  if a then ma[k] = (a < 0) and 0 or (a > 1) and 1 or a end
  if b then mb[k] = (b < 0) and 0 or (b > 1) and 1 or b end
  relist = true
  return true
end

function M.settled(pos)
  linked = false
  relist = true
  target = nil
  cpos = nil
  if pos then
    M.pos = (pos < 0 and 0) or (pos > 1 and 1) or pos
  end
end

return M
