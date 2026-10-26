local U = {}

local MAX, HOLD = 10, 0.7
local us, rs = {}, {}
local capture, restore
local last_t, last_kind, busy = 0, nil, false

function U.init(cfg)
  capture, restore = cfg.capture, cfg.restore
  MAX, HOLD = cfg.depth or MAX, cfg.hold or HOLD
  us, rs, last_t, last_kind, busy = {}, {}, 0, nil, false
end

local function push(st, snap)
  if #st >= MAX then table.remove(st, 1) end
  st[#st + 1] = snap
end

local function snap()
  local ok, s = pcall(capture)
  if not ok then print("grains: undo capture failed -- " .. tostring(s)) return nil end
  return s
end

function U.mark(kind)
  if busy or not capture then return end
  local now = util.time()
  if kind and kind == last_kind and now - last_t < HOLD then last_t = now return end
  last_kind, last_t = kind, now
  local s = snap()
  if not s then return end
  push(us, s)
  rs = {}
end

local function step(from, to)
  if #from < 1 or not restore then return false end
  local s = table.remove(from)
  busy = true
  local cur = snap()
  local ok, err = pcall(restore, s)
  busy, last_kind, last_t = false, nil, 0
  if not ok then print("grains: undo restore failed -- " .. tostring(err)) return true end
  if cur then push(to, cur) end
  return true
end

function U.undo() return step(us, rs) end
function U.redo() return step(rs, us) end
function U.clear() us, rs, last_kind, last_t = {}, {}, nil, 0 end

return U
