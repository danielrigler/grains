local K = {}

K.state = {false, false, false}

local combos, longpress = {}, 1
local coarse_step, coarse_acc = {}, {}
local gesture = nil
local hold_due, hold_act = nil, nil

local floor, abs = math.floor, math.abs

function K.init(cfg)
  combos = cfg.combos or {}
  longpress = cfg.longpress or 1
  coarse_step = cfg.coarse or {}
  coarse_acc = {}
  gesture, hold_due, hold_act = nil, nil, nil
  K.state[1], K.state[2], K.state[3] = false, false, false
end

local function gesture_id()
  return (K.state[1] and "1" or "") ..
         (K.state[2] and "2" or "") ..
         (K.state[3] and "3" or "")
end

function K.coarse(id, d)
  local step = coarse_step[id] or 3
  local t = floor((coarse_acc[id] or 0) + d)
  local n = floor(abs(t) / step)
  if t < 0 then n = -n end
  coarse_acc[id] = t - n * step
  return n
end

function K.mark()
  if gesture then gesture.fired = true end
  hold_due = nil
end

function K.press(n)
  K.state[n] = true
  for id in pairs(coarse_step) do coarse_acc[id] = 0 end
  local t = util.time()
  gesture = {id = gesture_id(), press_time = t, fired = false}
  local c = combos[gesture.id]
  hold_act = c and c.long
  hold_due = hold_act and (t + longpress) or nil
end

function K.release(n)
  K.state[n] = false
  hold_due = nil
  local g = gesture
  if g and not g.fired then
    g.fired = true
    local c = combos[g.id]
    if c and c.short then c.short() end
  end
  local id = gesture_id()
  if id == "" then
    gesture = nil
  else
    gesture = {id = id, press_time = g and g.press_time or util.time(), fired = true}
  end
end

function K.tick()
  if hold_due and util.time() >= hold_due then
    hold_due = nil
    local g = gesture
    if g and not g.fired then
      g.fired = true
      hold_act()
    end
  end
end

return K