local U = {}

function U.clamp(x, lo, hi)
  if x < lo then return lo elseif x > hi then return hi end
  return x
end

return U