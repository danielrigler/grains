local T = {}

local LIST = "/tmp/grains_files.txt"

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

function T.scan(root, max_files, max_depth, done)
  if not root or root == "" then return done({}, false, false) end
  if root:sub(-1) ~= "/" then root = root .. "/" end
  local d, deep = q(root), max_depth + 1
  norns.system_cmd("nice -n 10 find " .. d .. " -mindepth 1 -maxdepth " .. deep
    .. " -name '.*' -prune -o -type f \\( -iname '*.wav' -o -iname '*.aif' -o -iname '*.aiff' -o -iname '*.flac' -o -iname '*.ogg' \\) -print 2>/dev/null | head -n "
    .. max_files .. " > " .. LIST .. "; find " .. d .. " -mindepth " .. deep .. " -maxdepth " .. deep
    .. " -type d -not -path '*/.*' -print -quit 2>/dev/null | wc -l; echo _done_", function(out)
    local list, f = {}, io.open(LIST, "r")
    if f then for line in f:lines() do list[#list + 1] = line end f:close() end
    done(list, #list >= max_files, (tonumber((out or ""):match("^%s*(%d+)")) or 0) > 0)
  end)
end

function T.pick(list, n)
  local total, res, pool, m = #list, {}, {}, 0
  for i = 1, n do
    if m == 0 then
      if total == 0 then break end
      for j = 1, total do pool[j] = list[j] end
      m = total
    end
    local k = math.random(m)
    res[i], pool[k], pool[m], m = pool[k], pool[m], nil, m - 1
  end
  return res
end

return T
