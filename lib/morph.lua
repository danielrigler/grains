local M = {}

M.pos = 0
M.dirty = false

local mp, ma, mb, msp, mlo, mid, mnum = {}, {}, {}, {}, {}, {}, {}
local mact, nact = {}, 0
local relist = true
local n = 0
local applying = false
local linked = true
local EPS = 1e-4

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
  M.pos = pos
  M.dirty = true
end

local floor = math.floor

local byid = {}

local function bounds(k)
  if mnum[k] then
    local p = mp[k]
    return p.min, p.max - p.min
  end
  return mlo[k], msp[k]
end

local function raw_of(k)
  local lo, sp = bounds(k)
  if sp then
    if sp <= 0 then return 0 end
    return (mp[k]:get() - lo) / sp
  end
  return mp[k]:get_raw()
end

local function write(k, v)
  local p = mp[k]
  local lo, sp = bounds(k)
  if sp then
    if sp <= 0 then return end
    local want = floor(lo + v * sp + 0.5)
    if p:get() ~= want then p:set(want) end
  else
    local at = p:get_raw()
    if v < at - EPS or v > at + EPS then p:set_raw(v) end
  end
end

local function record(k)
  local raw = raw_of(k)
  local pos = M.pos
  relist = true
  if linked then
    ma[k], mb[k] = raw, raw
  elseif pos <= 0 then
    ma[k] = raw
  elseif pos >= 1 then
    mb[k] = raw
  else
    local a, b = ma[k], mb[k]
    local d = raw - (a + (b - a) * pos)
    ma[k], mb[k] = a + d, b + d
  end
end

function M.init(first, last, skip)
  n = 0
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
  nact = 0
  for k = 1, n do
    if ma[k] ~= mb[k] then
      nact = nact + 1
      mact[nact] = k
    end
  end
  relist = false
end

function M.apply()
  M.dirty = false
  if relist then rebuild() end
  if nact == 0 then return end
  local pos = M.pos
  local ends = (pos <= 0) and 1 or ((pos >= 1) and 2 or 0)
  applying = true
  for j = 1, nact do
    local k = mact[j]
    local a, b = ma[k], mb[k]
    local v = a + (b - a) * pos
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    write(k, v)
    if ends == 1 then
      local r = raw_of(k)
      if r ~= ma[k] then ma[k] = r relist = true end
    elseif ends == 2 then
      local r = raw_of(k)
      if r ~= mb[k] then mb[k] = r relist = true end
    end
  end
  applying = false
end

function M.store(which)
  for k = 1, n do
    local r = raw_of(k)
    if which == 1 then ma[k] = r else mb[k] = r end
  end
  linked = false
  relist = true
  M.pos = (which == 1) and 0 or 1
  M.dirty = true
end

function M.slots() return n end

function M.slot(k) return mid[k], ma[k], mb[k] end

function M.put(id, a, b)
  local k = byid[id]
  if k == nil then return false end
  if a then ma[k] = a end
  if b then mb[k] = b end
  relist = true
  return true
end

function M.settled(pos)
  linked = false
  relist = true
  if pos then
    M.pos = (pos < 0 and 0) or (pos > 1 and 1) or pos
  end
end

return M