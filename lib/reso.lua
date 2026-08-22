local R = {}

R.VOICINGS = {
  {0, 7, 12, 19, 24}, {0, 7, 14, 21, 28}, {0, 4, 7, 12, 16}, {0, 3, 7, 12, 15},
  {0, 4, 7, 11, 14}, {0, 3, 7, 10, 14}, {0, 12, 19.0196, 24, 27.8631}, {0, 12, 24, 36, 48}
}

R.NAMES = {"5th+oct", "fifths", "major", "minor", "maj7", "min7", "harmonic", "octaves"}

local ratios = {}

function R.voicing(idx)
  local d = R.VOICINGS[idx] or R.VOICINGS[1]
  for i = 1, 5 do ratios[i] = 2 ^ (d[i] / 12) end
end

function R.update()
  if params:get("reso_mix") <= 0 then return end
  local f = 440 * 2 ^ ((params:get("reso_root") - 69) / 12)
  engine.reso_freqs(f * ratios[1], f * ratios[2], f * ratios[3],
    f * ratios[4], f * ratios[5])
end

R.voicing(1)

return R