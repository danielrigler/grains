local T = {}

local LIST = "/tmp/grains_files.txt"

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

function T.scan(root, max_files, max_depth, done)
  max_files = max_files or 1500
  max_depth = max_depth or 4
  if root == nil or root == "" then return done({}, false, false) end
  if root:sub(-1) ~= "/" then root = root .. "/" end
  local d = q(root)
  local cmd = "nice -n 10 find " .. d .. " -mindepth 1 -maxdepth " .. (max_depth + 1)
    .. " -name '.*' -prune -o -type f \\( -iname '*.wav' -o -iname '*.aif' -o -iname '*.aiff' -o -iname '*.flac' -o -iname '*.ogg' \\) -print 2>/dev/null | head -n " .. max_files .. " > " .. LIST
    .. "; find " .. d .. " -mindepth " .. (max_depth + 1) .. " -maxdepth " .. (max_depth + 1) .. " -type d -not -path '*/.*' -print -quit 2>/dev/null | wc -l; echo _done_"
  norns.system_cmd(cmd, function(out)
    local list, n, f = {}, 0, io.open(LIST, "r")
    if f then for line in f:lines() do n = n + 1 list[n] = line end f:close() end
    done(list, n >= max_files, (tonumber((out or ""):match("^%s*(%d+)")) or 0) > 0)
  end)
end

function T.pick(list, n)
  local total = #list
  local m = total
  local res = {}
  if m == 0 then return res end
  local pool = {}
  for i = 1, m do pool[i] = list[i] end
  for i = 1, n do
    if m == 0 then
      for j = 1, total do pool[j] = list[j] end
      m = total
    end
    local k = math.random(m)
    res[i] = pool[k]
    pool[k] = pool[m]
    pool[m] = nil
    m = m - 1
  end
  return res
end

return T
