local M = {pos = 0, dirty = false}

local mp, ma, mb, mc, mlo, msp, mnum, mid, act, byid = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
local n, nact, relist, applying, linked = 0, 0, true, false, true
local cpos, target = nil, nil
local EPS, ARRIVED, floor = 1e-3, 0.99, math.floor

local function c01(x) return x < 0 and 0 or x > 1 and 1 or x end

local function span(k)
  local p = mp[k]
  if mnum[k] then return p.min, p.max - p.min end
  return mlo[k], msp[k]
end

local function raw_of(k)
  local lo, sp = span(k)
  if sp then return sp <= 0 and 0 or (mp[k]:get() - lo) / sp end
  return mp[k]:get_raw()
end

local function write(k, v, exact)
  local p = mp[k]
  local lo, sp = span(k)
  if sp then
    if sp <= 0 then return 0 end
    local at, want = p:get(), floor(lo + v * sp + 0.5)
    if at ~= want then p:set(want) at = want end
    return (at - lo) / sp
  end
  local at = p:get_raw()
  if (exact and at ~= v) or (not exact and (v < at - EPS or v > at + EPS)) then p:set_raw(v) return v end
  return at
end

local function hold_here()
  for k = 1, n do mc[k] = raw_of(k) end
  cpos, relist = M.pos, true
end

local function dest()
  if target then return target end
  if M.pos <= 0 then return 1 end
  if M.pos >= 1 then return 2 end
end

local function record(k)
  local raw = c01(raw_of(k))
  relist = true
  if linked then
    ma[k], mb[k] = raw, raw
    if cpos then mc[k] = raw end
    return
  end
  local d = dest()
  if d then
    if d == 1 then ma[k] = raw else mb[k] = raw end
    if cpos == M.pos then mc[k] = raw end
    return
  end
  mc[k] = raw
  if cpos ~= M.pos then hold_here() end
end

function M.hold(f)
  local prev = applying
  applying = true
  local ok, err = pcall(f)
  applying = prev
  if not ok then error(err, 0) end
end

function M.set(pos)
  pos = c01(pos)
  if pos >= 1 then linked = false end
  if target and pos ~= M.pos then target = nil end
  M.pos, M.dirty = pos, true
end

function M.init(first, last, skip)
  n, target, cpos = 0, nil, nil
  local P = params
  for i = first, last do
    local p = P.params[i]
    if p and p.id and p.t and not skip(p.id) then
      local lo, sp
      if p.t == P.tNUMBER then lo, sp = p.min, p.max - p.min elseif p.t == P.tOPTION then lo, sp = 1, p.count - 1 end
      if p.t == P.tCONTROL or p.t == P.tTAPER or (sp and sp > 0) then
        n = n + 1
        local k = n
        mp[k], mid[k], byid[p.id], mlo[k], msp[k], mnum[k] = p, p.id, k, lo, sp, p.t == P.tNUMBER
        ma[k] = raw_of(k)
        mb[k] = ma[k]
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
    local c = cpos and mc[k] or ma[k]
    if c ~= ma[k] or c ~= mb[k] then nact = nact + 1 act[nact] = k end
  end
  relist = false
end

function M.apply()
  M.dirty = false
  if relist then rebuild() end
  if nact == 0 then cpos = nil return end
  local pos, e, f = M.pos, nil, 0
  if cpos then
    if pos > cpos then e, f = mb, cpos >= 1 and 0 or math.min((pos - cpos) / (1 - cpos), 1)
    elseif pos < cpos then e, f = ma, cpos <= 0 and 0 or math.min((cpos - pos) / cpos, 1)
    else e = mb end
    if f >= ARRIVED then f = 1 end
  end
  local into = pos <= 0 and ma or pos >= 1 and mb or nil
  local X, Y, t = ma, mb, pos
  if e then X, Y, t = mc, e, f end
  local g, changed = 1 - t, false
  applying = true
  for j = 1, nact do
    local k = act[j]
    local r = write(k, c01(X[k] * g + Y[k] * t), into ~= nil)
    if into and r ~= into[k] then into[k], changed = r, true end
  end
  applying = false
  if changed then relist = true end
  if e and f >= ARRIVED then cpos, relist, M.dirty = nil, true, true end
end

function M.store(which)
  for k = 1, n do if which == 1 then ma[k] = raw_of(k) else mb[k] = raw_of(k) end end
  linked, relist, target = false, true, which
  hold_here()
end

function M.gesture(f)
  M.hold(f)
  local d = linked and 0 or dest()
  if not d then return hold_here() end
  for k = 1, n do
    local r = raw_of(k)
    if d ~= 2 then ma[k] = r end
    if d ~= 1 then mb[k] = r end
  end
  cpos, relist = nil, true
end

function M.clear()
  for k = 1, n do ma[k] = raw_of(k) mb[k] = ma[k] end
  linked, target, relist, cpos = true, nil, true, nil
end

function M.save()
  local a, b, c = {}, {}, cpos and {}
  for k = 1, n do
    local id = mid[k]
    a[id], b[id] = ma[k], mb[k]
    if c then c[id] = mc[k] end
  end
  return {pos = M.pos, linked = linked, target = target, cpos = cpos, a = a, b = b, c = c}
end

function M.load(t)
  local a, b, c = t.a, t.b, t.c
  for k = 1, n do
    local id, r = mid[k], raw_of(k)
    ma[k], mb[k], mc[k] = a[id] or r, b[id] or r, c and c[id] or r
  end
  M.pos, linked, target, cpos = t.pos, t.linked, t.target, c and t.cpos
  relist, M.dirty = true, false
end

function M.move(from_id, to_id)
  local a, b = byid[from_id], byid[to_id]
  if not a or not b then return false end
  ma[b], mb[b], mc[b] = ma[a], mb[a], mc[a]
  local r = c01(raw_of(a))
  ma[a], mb[a], mc[a], relist = r, r, r, true
  return true
end

return M
