local G = {}

local floor = math.floor

local NVR, UP, DN = 6, 7, 8
local BG, LO, HI, IDLE, BLINK = 2, 6, 15, 4, 4
local FX_LO, FX_HI = 1, 12
local STEP, REP, REP_WAIT = 0.05, 0.02, 0.3
local NBIG, NSMALL, BIG, HYST = 24, 16, 2, 0.75
local EQ, VQ, VHYST, FAST = 3, 4, 0.75, 0.5

G.FX = {
  {"reverb_mix", "reverb"}, {"d_mix", "delay"}, {"sh_mix", "shimmer"},
  {"dimension_mix", "dimension"}, {"stchorus_mix", "chorus"}, {"vibe_mix", "vibe"},
  {"wobble_mix", "wobble"}, {"bc_mix", "crush"}, {"spiral_mix", "spiral"},
  {"sub_mix", "sub"}, {"gl_ratio", "glitch"}
}
local FX = G.FX

local g, cfg, S
local W = 16
local led, sent = {}, {}
local scan, sweep, resend, sweep_on = 0, 0, nil, false
local rq, pa, pb = {}, {}, {}
local anchor, held, used = {}, {}, {}
local modv
local rep_d, rep_t, rep_k, rep_v
local kl, kh, ka, kb, ke, bprev = {}, {}, {}, {}, {}, {}
local backlog = true

local tn = 0

local function toga_path()
  local d = norns and norns.state and norns.state.data
  return d and (d .. "toga_clients") or nil
end

local function toga_save()
  local p = toga_path()
  if not p then return end
  local f = io.open(p, "w")
  if not f then return end
  local n = #g.dest
  for k = n > 4 and n - 3 or 1, n do
    local d = g.dest[k]
    f:write(tostring(d[1]), " ", tostring(d[2]), "\n")
  end
  f:close()
end

local function toga_restore()
  local p = toga_path()
  local f = p and io.open(p, "r")
  if not f then return end
  local dest = g.dest
  for line in f:lines() do
    local ip, port = line:match("^(%S+)%s+(%d+)$")
    if ip then
      local seen = false
      for _, d in ipairs(dest) do
        if d[1] == ip then d[2] = port seen = true end
      end
      if not seen then dest[#dest + 1] = {ip, port} end
    end
  end
  f:close()
  tn = #dest
  if tn > 0 then
    g:send_connected(nil, true)
    g:refresh(true)
  end
end

local function resize()
  W = (g and g.cols and g.cols > 0) and g.cols or 16
  for k = 1, W * DN do sent[k] = -99 end
  kl, kh, ka, kb, ke, bprev = {}, {}, {}, {}, {}, {}
  backlog = true
end

local function lvl(x)
  if x <= 0 then return FX_LO end
  if x >= 1 then return FX_HI end
  return floor(FX_LO + (FX_HI - FX_LO) * x + 0.5)
end

local function meter(u, d, v, bip)
  if bip then
    led[u], led[d] = lvl(v * 2 - 1), lvl(1 - v * 2)
  else
    led[u], led[d] = lvl(v * 2 - 1), lvl(v * 2)
  end
end

function G.redraw()
  if g == nil or g.device == nil then return end
  local n, blink = cfg.count(), S.blink
  local k = 0
  local dirty = backlog
  for i = 1, NVR do
    local live = (i <= n and S.files[i]) and true or false
    local hi = IDLE
    if S.on[i] then
      local x, q = (S.volf[i] or 0) * VQ, rq[i]
      if not q or x - q > VHYST or q - x > VHYST then q = floor(x + 0.5) rq[i] = q end
      hi = LO + (HI - LO) * q / VQ
    end
    if blink and S.frz[i] then hi = hi >= LO + BLINK and hi - BLINK or hi + BLINK end
    local a, b = (S.b0[i] or 0) * W, (S.b1[i] or 1) * W
    local ma, mb = a - (pa[i] or a), b - (pb[i] or b)
    pa[i], pb[i] = a, b
    local eq = (ma > FAST or ma < -FAST or mb > FAST or mb < -FAST) and b - a >= 1 and 1 or EQ
    if live ~= kl[i] or hi ~= kh[i] or a ~= ka[i] or b ~= kb[i] or eq ~= ke[i] then
      kl[i], kh[i], ka[i], kb[i], ke[i] = live, hi, a, b, eq
      dirty = true
      for c = 0, W - 1 do
        k = k + 1
        local l = 0
        if live then
          local lo = a > c and a or c
          local up = b < c + 1 and b or c + 1
          local cov = up - lo
          l = BG
          if cov > 0 then
            cov = floor(cov * eq + 0.5)
            if cov > 0 or eq == EQ then l = BG + (hi - BG) * (cov < 1 and 1 or cov) / eq end
          end
        end
        led[k] = l
      end
    else
      k = k + W
    end
  end
  for c = 1, W do led[k + c], led[k + W + c] = 0, 0 end
  for c = 1, #FX do
    if c > W - 5 then break end
    local f = FX[c]
    meter(k + c, k + W + c, params:get_raw(f[1]), f[3])
  end
  meter(k + W - 4, k + W + W - 4, cfg.lfofrac("rlfo"))
  meter(k + W - 3, k + W + W - 3, cfg.lfofrac("vlfo"))
  meter(k + W, k + W + W, cfg.densfrac())
  for c = W - 2, W - 1 do
    led[k + c] = held[UP * 32 + c] and FX_HI or FX_LO
    led[k + W + c] = held[DN * 32 + c] and FX_HI or FX_LO
  end
  if modv then
    led[k + W] = S.lck[modv] and FX_HI or FX_LO
    led[k + W + W] = S.frz[modv] and FX_HI or FX_LO
  end
  for j = k + 1, k + W + W do
    local l = led[j]
    if bprev[j] ~= l then bprev[j] = l dirty = true end
  end
  if not dirty then return end
  local N, nb, ns, last = W * DN, NBIG, NSMALL, nil
  for n = 0, N - 1 do
    local j = (scan + n) % N + 1
    local d = led[j] - sent[j]
    if d < 0 then d = -d end
    local big = d >= BIG
    if (big and nb > 0) or (not big and d >= HYST and ns > 0) then
      if big then nb = nb - 1 else ns = ns - 1 last = j end
      local l = floor(led[j] + 0.5)
      sent[j] = l
      g:led((j - 1) % W + 1, floor((j - 1) / W) + 1, l)
    end
  end
  if ns == 0 then scan = last % N end
  backlog = nb == 0 or ns == 0
  if nb < NBIG or ns < NSMALL then g:refresh() end
end

local function nudge(id, d)
  local v = params:get_raw(id) + d
  params:set_raw(id, v < 0 and 0 or (v > 1 and 1 or v))
end

local function row_key(x, i, z)
  if z == 0 then
    if anchor[i] == x then
      if not used[i] and i <= cfg.count() and S.files[i] then cfg.bounds(i, (x - 1) / W) end
      anchor[i] = nil
      if modv == i then modv = nil end
    end
    return
  end
  if i > cfg.count() or not S.files[i] then return end
  local a = anchor[i]
  if a and a ~= x then
    used[i] = true
    local lo, hi = a < x and a or x, a < x and x or a
    cfg.bounds(i, (lo - 1) / W, (hi - lo + 1) / W)
  elseif not a then
    anchor[i], used[i], modv = x, false, i
    cfg.grab(i)
  end
end

local function act(x, d, tap, v)
  if x == W - 1 then return cfg.vol(d, tap, v) end
  if x == W then return cfg.density(d, tap) end
  if x == W - 3 then return cfg.lfo(d, tap, "vlfo") end
  if x == W - 4 then return cfg.lfo(d, tap, "rlfo") end
  local f = FX[x]
  if d == 0 then
    params:set_raw(f[1], f[3] and 0.5 or 0)
  else
    nudge(f[1], d * (tap and STEP or REP))
  end
  cfg.pop(f[2], f[1])
end

local function fx_key(x, y, z)
  local k = y * 32 + x
  if z == 0 then
    held[k] = nil
    if rep_k == k then rep_k = nil end
    return
  end
  if x < W - 4 and FX[x] == nil then return end
  held[k] = true
  local v = x == W - 1 and modv or nil
  if v then used[v] = true end
  if held[(y == UP and DN or UP) * 32 + x] then
    rep_k = nil
    act(x, 0, nil, v)
  else
    rep_d, rep_t, rep_k, rep_v = y == UP and 1 or -1, util.time() + REP_WAIT, k, v
    act(x, rep_d, true, v)
  end
end

local function key(x, y, z)
  if y <= NVR then
    row_key(x, y, z)
  elseif y <= DN then
    if x == W - 2 or (x == W and modv) then
      held[y * 32 + x] = z == 1 or nil
      if z == 1 then
        if x == W - 2 then
          cfg.trig(y == UP)
        else
          used[modv] = true
          cfg.hold(modv, y == UP)
        end
      end
    else
      fx_key(x, y, z)
    end
  end
  G.redraw()
end

function G.held(i) return anchor[i] ~= nil end

function G.tick(now)
  if g.dest and #g.dest ~= tn then
    tn = #g.dest
    toga_save()
  end
  if rep_k and now >= rep_t then act(rep_k % 32, rep_d, nil, rep_v) end
  G.redraw()
  sweep_on = not sweep_on
  if sweep_on and resend and g.device then
    sweep = sweep % (W * DN) + 1
    resend(g, (sweep - 1) % W + 1, floor((sweep - 1) / W) + 1)
  end
end

function G.init(c)
  cfg, S = c, c.S
  local grid = util.file_exists(_path.code.."toga") and include "toga/lib/togagrid" or grid
  g = grid.connect()
  g.key = key
  resend = g.update_led
  grid.add = resize
  resize()
  if g.dest then
    if util.make_dir and norns and norns.state and norns.state.data then util.make_dir(norns.state.data) end
    toga_restore()
  end
end

function G.cleanup()
  if g and g.device then
    g:all(0)
    g:refresh()
  end
end

return G
