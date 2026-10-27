local G = {}

local floor = math.floor
local NVR, UP, DN = 6, 7, 8
local BG, BG_LCK, LO, HI, IDLE, FX_LO, FX_HI = 2, 4, 6, 15, 4, 1, 12
local PULSE, DEPTH, dim = 2.4, 3, 0
local STEP, REP, REP_WAIT = 0.05, 0.02, 0.3
local NBIG, NSMALL, BIG, HYST, EQ, VQ, VHYST, FAST = 24, 16, 2, 0.75, 3, 4, 0.75, 0.5

G.FX = {
  {"reverb_mix", "reverb"}, {"d_mix", "delay"}, {"sh_mix", "shimmer"}, {"dimension_mix", "dimension"},
  {"stchorus_mix", "chorus"}, {"vibe_mix", "vibe"}, {"wobble_mix", "wobble"}, {"bc_mix", "crush"},
  {"spiral_mix", "spiral"}, {"sub_mix", "sub"}, {"gl_ratio", "glitch"}
}
local FX = G.FX

local g, cfg, V
local W = 16
local led, sent, rq, pa, pb, anchor, held, used = {}, {}, {}, {}, {}, {}, {}, {}
local kl, kh, ka, kb, ke, bprev = {}, {}, {}, {}, {}, {}
local scan, sweep, sweep_on, backlog, resend, modv = 0, 0, false, true, nil, nil
local rep_d, rep_t, rep_k, rep_v
local tn = 0

local function toga_path()
  local d = norns and norns.state and norns.state.data
  return d and d .. "toga_clients"
end

local function toga_save()
  local f = toga_path() and io.open(toga_path(), "w")
  if not f then return end
  local n = #g.dest
  for k = math.max(n - 3, 1), n do f:write(tostring(g.dest[k][1]), " ", tostring(g.dest[k][2]), "\n") end
  f:close()
end

local function toga_restore()
  local f = toga_path() and io.open(toga_path(), "r")
  if not f then return end
  local dest = g.dest
  for line in f:lines() do
    local ip, port = line:match("^(%S+)%s+(%d+)$")
    if ip then
      local seen = false
      for _, d in ipairs(dest) do if d[1] == ip then d[2], seen = port, true end end
      if not seen then dest[#dest + 1] = {ip, port} end
    end
  end
  f:close()
  tn = #dest
  if tn > 0 then g:send_connected(nil, true) g:refresh(true) end
end

local function resize()
  W = g and g.cols and g.cols > 0 and g.cols or 16
  for k = 1, W * DN do sent[k] = -99 end
  kl, kh, ka, kb, ke, bprev, backlog = {}, {}, {}, {}, {}, {}, true
end

local function lvl(x) return x <= 0 and FX_LO or x >= 1 and FX_HI or floor(FX_LO + (FX_HI - FX_LO) * x + 0.5) end
local function meter(u, x) led[u], led[u + W] = lvl(x * 2 - 1), lvl(x * 2) end

local function redraw()
  if not g or not g.device then return end
  local n = cfg.count()
  local k, dirty = 0, backlog
  for i = 1, NVR do
    local v = V[i]
    local live = i <= n and v.file ~= nil and (v.lck and 2 or 1)
    local hi = IDLE
    if v.on then
      local x, q = (v.volf or 0) * VQ, rq[i]
      if not q or x - q > VHYST or q - x > VHYST then q = floor(x + 0.5) rq[i] = q end
      hi = LO + (HI - LO) * q / VQ
    end
    local bg = v.lck and BG_LCK or BG
    hi = math.max(v.frz and hi - dim or hi, bg + 1)
    local a, b = v.b0 * W, v.b1 * W
    local ma, mb = a - (pa[i] or a), b - (pb[i] or b)
    pa[i], pb[i] = a, b
    local eq = (ma > FAST or ma < -FAST or mb > FAST or mb < -FAST) and b - a >= 1 and 1 or EQ
    if live ~= kl[i] or hi ~= kh[i] or a ~= ka[i] or b ~= kb[i] or eq ~= ke[i] then
      kl[i], kh[i], ka[i], kb[i], ke[i], dirty = live, hi, a, b, eq, true
      for c = 0, W - 1 do
        local l = 0
        if live then
          local cov = math.min(b, c + 1) - math.max(a, c)
          l = bg
          if cov > 0 then
            cov = floor(cov * eq + 0.5)
            if cov > 0 or eq == EQ then l = bg + (hi - bg) * math.max(cov, 1) / eq end
          end
        end
        led[k + c + 1] = l
      end
    end
    k = k + W
  end
  for c = 1, W do led[k + c], led[k + W + c] = 0, 0 end
  for c = 1, math.min(#FX, W - 5) do meter(k + c, params:get_raw(FX[c][1])) end
  meter(k + W - 4, cfg.lfofrac("rlfo"))
  meter(k + W - 3, cfg.lfofrac("vlfo"))
  meter(k + W, cfg.densfrac())
  for c = W - 2, W - 1 do
    led[k + c] = held[UP * 32 + c] and FX_HI or FX_LO
    led[k + W + c] = held[DN * 32 + c] and FX_HI or FX_LO
  end
  if modv then
    led[k + W] = V[modv].lck and FX_HI or FX_LO
    led[k + W + W] = V[modv].frz and FX_HI or FX_LO
  end
  for j = k + 1, k + W + W do
    if bprev[j] ~= led[j] then bprev[j], dirty = led[j], true end
  end
  if not dirty then return end
  local N, nb, ns, last = W * DN, NBIG, NSMALL, nil
  for q = 0, N - 1 do
    local j = (scan + q) % N + 1
    local d = math.abs(led[j] - sent[j])
    local big = d >= BIG
    if (big and nb > 0) or (not big and d >= HYST and ns > 0) then
      if big then nb = nb - 1 else ns, last = ns - 1, j end
      local l = floor(led[j] + 0.5)
      sent[j] = l
      g:led((j - 1) % W + 1, (j - 1) // W + 1, l)
    end
  end
  if ns == 0 then scan = last % N end
  backlog = nb == 0 or ns == 0
  if nb < NBIG or ns < NSMALL then g:refresh() end
end

local function act(x, d, tap, v)
  if x == W - 1 then return cfg.vol(d, tap, v) end
  if x == W then return cfg.density(d, tap) end
  if x == W - 3 then return cfg.lfo(d, tap, "vlfo") end
  if x == W - 4 then return cfg.lfo(d, tap, "rlfo") end
  local f = FX[x]
  if d == 0 then
    params:set_raw(f[1], 0)
  else
    local r = params:get_raw(f[1]) + d * (tap and STEP or REP)
    params:set_raw(f[1], r < 0 and 0 or r > 1 and 1 or r)
  end
  cfg.pop(f[2], f[1])
end

local function row_key(x, i, z)
  if z == 0 then
    if anchor[i] == x then
      if not used[i] and i <= cfg.count() and V[i].file then cfg.bounds(i, (x - 1) / W) end
      anchor[i] = nil
      if modv == i then modv = nil end
    end
    return
  end
  if i > cfg.count() or not V[i].file then return end
  local a = anchor[i]
  if a and a ~= x then
    used[i] = true
    local lo, hi = math.min(a, x), math.max(a, x)
    cfg.bounds(i, (lo - 1) / W, (hi - lo + 1) / W)
  elseif not a then
    anchor[i], used[i], modv = x, false, i
    cfg.grab(i)
  end
end

local function fx_key(x, y, z)
  local k = y * 32 + x
  if z == 0 then
    held[k] = nil
    if rep_k == k then rep_k = nil end
    return
  end
  if x < W - 4 and not FX[x] then return end
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
        if x == W - 2 then cfg.trig(y == UP) else used[modv] = true cfg.hold(modv, y == UP) end
      end
    else
      fx_key(x, y, z)
    end
  end
  redraw()
end

function G.held(i) return anchor[i] ~= nil end

function G.tick(now)
  dim = floor(DEPTH * (1 - math.abs(now / PULSE % 1 * 2 - 1)) + 0.5)
  if g.dest and #g.dest ~= tn then tn = #g.dest toga_save() end
  if rep_k and now >= rep_t then act(rep_k % 32, rep_d, nil, rep_v) end
  redraw()
  sweep_on = not sweep_on
  if sweep_on and resend and g.device then
    sweep = sweep % (W * DN) + 1
    resend(g, (sweep - 1) % W + 1, (sweep - 1) // W + 1)
  end
end

function G.init(c)
  cfg, V = c, c.V
  local tg = _path.code .. "toga/lib/togagrid.lua"
  local grid = util.file_exists(tg) and dofile(tg) or grid
  g = grid.connect()
  g.key, resend, grid.add = key, g.update_led, resize
  resize()
  if g.dest then
    if util.make_dir and norns.state.data then util.make_dir(norns.state.data) end
    toga_restore()
  end
end

function G.cleanup()
  if g and g.device then g:all(0) g:refresh() end
end

return G
