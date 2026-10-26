local K = {state = {false, false, false}}

local IDS = {[0] = "", "1", "2", "12", "3", "13", "23", "123"}
local combos, longpress, steps, acc = {}, 1, {}, {}
local gesture, fired, due = nil, false, nil
local floor, abs = math.floor, math.abs

local function gid()
  local s = K.state
  return IDS[(s[1] and 1 or 0) + (s[2] and 2 or 0) + (s[3] and 4 or 0)]
end

function K.init(cfg)
  combos, longpress, steps, acc = cfg.combos or {}, cfg.longpress or 1, cfg.coarse or {}, {}
  gesture, fired, due = nil, false, nil
  K.state[1], K.state[2], K.state[3] = false, false, false
end

function K.coarse(id, d)
  local step = steps[id] or 3
  local t = floor((acc[id] or 0) + d)
  local n = floor(abs(t) / step)
  if t < 0 then n = -n end
  acc[id] = t - n * step
  return n
end

function K.mark() fired, due = true, nil end

function K.press(n)
  K.state[n] = true
  for id in pairs(steps) do acc[id] = 0 end
  gesture, fired = gid(), false
  local c = combos[gesture]
  due = c and c.long and (util.time() + longpress) or nil
end

function K.release(n)
  K.state[n], due = false, nil
  if gesture and not fired then
    local c = combos[gesture]
    if c and c.short then c.short() end
  end
  gesture = gid()
  fired = true
  if gesture == "" then gesture = nil end
end

function K.tick(now)
  if due and now >= due then
    due = nil
    if gesture and not fired then
      fired = true
      combos[gesture].long()
    end
  end
end

return K
