local T = {}

local EXT = {wav = true, aif = true, aiff = true, flac = true, ogg = true}

function T.scan(root, max_files, max_depth)
  max_files = max_files or 1500
  max_depth = max_depth or 4
  if root == nil or root == "" then return {}, false, false end
  if root:sub(-1) ~= "/" then root = root .. "/" end
  local out, nout = {}, 0
  local deepened = false
  local stack, ns = {{dir = root, d = 0}}, 1
  while ns > 0 and nout < max_files do
    local top = stack[ns]
    stack[ns] = nil
    ns = ns - 1
    local ok, entries = pcall(util.scandir, top.dir)
    if ok and entries then
      for _, e in ipairs(entries) do
        if e:sub(-1) == "/" then
          if e:sub(1, 1) ~= "." then
            if top.d < max_depth then
              ns = ns + 1
              stack[ns] = {dir = top.dir .. e, d = top.d + 1}
            else
              deepened = true
            end
          end
        elseif e:sub(1, 1) ~= "." then
          local ext = e:match("%.([%a]+)$")
          if ext and EXT[ext:lower()] then
            nout = nout + 1
            out[nout] = top.dir .. e
            if nout >= max_files then break end
          end
        end
      end
    end
  end
  return out, nout >= max_files, deepened
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
