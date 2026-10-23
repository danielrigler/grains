local M = {}

M.LIST = {
  {"octaves",    {0}},
  {"fifths",     {0, 7}},
  {"sus",        {0, 5, 7}},
  {"major",      {0, 4, 7}},
  {"minor",      {0, 3, 7}},
  {"maj7",       {0, 4, 7, 11}},
  {"min7",       {0, 3, 7, 10}},
  {"maj pent",   {0, 2, 4, 7, 9}},
  {"min pent",   {0, 3, 5, 7, 10}},
  {"ionian",     {0, 2, 4, 5, 7, 9, 11}},
  {"dorian",     {0, 2, 3, 5, 7, 9, 10}},
  {"mixolydian", {0, 2, 4, 5, 7, 9, 10}},
  {"lydian",     {0, 2, 4, 6, 7, 9, 11}},
  {"aeolian",    {0, 2, 3, 5, 7, 8, 10}},
  {"phrygian",   {0, 1, 3, 5, 7, 8, 10}},
  {"whole tone", {0, 2, 4, 6, 8, 10}},
  {"chromatic",  {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}}
}
M.DEFAULT = 7
M.CHROMATIC = #M.LIST
M.NAMES = {}

local floor, abs = math.floor, math.abs
local T, N, NEAR, FIFTH = {}, {}, {}, {}

for k, s in ipairs(M.LIST) do
  local t, n = s[2], #s[2]
  M.NAMES[k], T[k], N[k] = s[1], t, n
  local near = {}
  for r = 0, 11 do
    local best, bd = 0, 99
    for j = 0, n do
      local dd = abs(r - (j < n and t[j + 1] or 12))
      if dd < bd then best, bd = j, dd end
    end
    near[r] = best
  end
  NEAR[k] = near
  for j = 1, n do if t[j] == 7 then FIFTH[k] = true end end
end

local function ok(k) return N[k] and k or M.DEFAULT end

function M.round(x) return x < 0 and -floor(0.5 - x) or floor(x + 0.5) end

function M.size(k) return N[ok(k)] end

function M.pitch(d, k)
  k = ok(k)
  local n = N[k]
  local o = d // n
  return T[k][d - o * n + 1] + 12 * o
end

function M.near(st, k)
  k = ok(k)
  st = floor(st + 0.5)
  local o = st // 12
  return o * N[k] + NEAR[k][st - o * 12]
end

function M.steps(st, k)
  local d = M.near(st, k)
  if d == 0 and st ~= 0 then return st > 0 and 1 or -1 end
  return d
end

function M.snap(st, k) return M.pitch(M.near(st, k), k) end

function M.move(st, d, k) return M.pitch(M.near(st, k) + d, k) end

function M.fifth(k) return FIFTH[ok(k)] == true end

local OPEN = {0, 7, 12, 19, 24}

function M.chord(k, out)
  k = ok(k)
  local s = N[k] // 3
  if s < 1 then s = 1 end
  for i = 1, 5 do out[i] = k == M.CHROMATIC and OPEN[i] or M.pitch((i - 1) * s, k) end
  return out
end

return M
