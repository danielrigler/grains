local T = {}

local EXT = {wav = true, aif = true, aiff = true, flac = true, ogg = true}

function T.scan(root, max_files, max_depth)
  max_files = max_files or 1500
  max_depth = max_depth or 4
  if root == nil or root == "" then return {}, false, false end
  if root:sub(-1) ~= "/" then root = root .. "/" end
  local out = {}
  local deepened = false
  local stack = {{dir = root, d = 0}}
  while #stack > 0 and #out < max_files do
    local top = table.remove(stack)
    local ok, entries = pcall(util.scandir, top.dir)
    if ok and entries then
      for _, e in ipairs(entries) do
        if e:sub(-1) == "/" then
          if e:sub(1, 1) ~= "." then
            if top.d < max_depth then
              stack[#stack + 1] = {dir = top.dir .. e, d = top.d + 1}
            else
              deepened = true
            end
          end
        elseif e:sub(1, 1) ~= "." then
          local ext = e:match("%.([%a]+)$")
          if ext and EXT[ext:lower()] then
            out[#out + 1] = top.dir .. e
            if #out >= max_files then break end
          end
        end
      end
    end
  end
  return out, #out >= max_files, deepened
end

function T.pick(list, n)
  local m = #list
  local res = {}
  if m == 0 then return res end
  local pool = {}
  for i = 1, m do pool[i] = list[i] end
  for i = 1, n do
    if m == 0 then
      for j = 1, #list do pool[j] = list[j] end
      m = #list
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