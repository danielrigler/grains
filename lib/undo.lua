local U = {}

local MAX, HOLD = 10, 0.7

local ustack, rstack = {}, {}
local nu, nr = 0, 0
local capture, restore
local last_t, last_kind = 0, nil
local busy = false

function U.init(cfg)
  capture, restore = cfg.capture, cfg.restore
  MAX = cfg.depth or MAX
  HOLD = cfg.hold or HOLD
  ustack, rstack, nu, nr = {}, {}, 0, 0
  last_t, last_kind = 0, nil
  busy = false
end

local function push(st, n, snap)
  if n >= MAX then
    for k = 1, n - 1 do st[k] = st[k + 1] end
    st[n] = snap
    return n
  end
  n = n + 1
  st[n] = snap
  return n
end

local function drop_redo()
  for k = 1, nr do rstack[k] = nil end
  nr = 0
end

function U.mark(kind)
  if busy or capture == nil then return end
  local now = util.time()
  if kind ~= nil and kind == last_kind and now - last_t < HOLD then
    last_t = now
    return
  end
  last_kind, last_t = kind, now
  local ok, snap = pcall(capture)
  if not ok or snap == nil then
    if not ok then print("grains: undo capture failed -- " .. tostring(snap)) end
    return
  end
  nu = push(ustack, nu, snap)
  drop_redo()
end

function U.wrap(kind, f)
  return function(...)
    U.mark(kind)
    return f(...)
  end
end

local function step(from, nfrom, to, nto)
  local snap = from[nfrom]
  from[nfrom] = nil
  busy = true
  local ok_c, cur = pcall(capture)
  local ok_r, err = pcall(restore, snap)
  busy = false
  last_kind, last_t = nil, 0
  if not ok_r then
    print("grains: undo restore failed -- " .. tostring(err))
    return nfrom - 1, nto
  end
  if ok_c and cur ~= nil then nto = push(to, nto, cur) end
  return nfrom - 1, nto
end

function U.undo()
  if nu < 1 or restore == nil then return false end
  nu, nr = step(ustack, nu, rstack, nr)
  return true
end

function U.redo()
  if nr < 1 or restore == nil then return false end
  nr, nu = step(rstack, nr, ustack, nu)
  return true
end

function U.clear()
  for k = 1, nu do ustack[k] = nil end
  nu = 0
  drop_redo()
  last_kind, last_t = nil, 0
end

function U.depth() return nu, nr end

return U
