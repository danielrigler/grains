local Scale = include("grains/lib/scale")

local R = {}

R.VOICINGS = {
  {0, 7, 12, 19, 24}, {0, 7, 14, 21, 28}, {0, 4, 7, 12, 16}, {0, 3, 7, 12, 15},
  {0, 4, 7, 11, 14}, {0, 3, 7, 10, 14}, {0, 12, 19.0196, 24, 27.8631}, {0, 12, 24, 36, 48}
}

R.NAMES = {"5th+oct", "fifths", "major", "minor", "maj7", "min7", "harmonic", "octaves", "scale"}
R.SCALE = #R.NAMES

local vidx, tones, sent = 1, {}, {}

function R.voicing(idx) vidx = idx end

function R.root()
  local r = params:get("reso_root") + params:get("tuning")
  return r < 24 and 24 or r > 128 and 128 or r
end

function R.update()
  if params:get("reso_mix") <= 0 then return end
  local d = R.VOICINGS[vidx] or Scale.chord(params:get("scale"), tones)
  local base, diff = R.root() - 69, false
  for i = 1, 5 do
    local f = 440 * 2 ^ ((base + d[i]) / 12)
    if sent[i] ~= f then sent[i], diff = f, true end
  end
  if diff then engine.reso_freqs(sent[1], sent[2], sent[3], sent[4], sent[5]) end
end

return R
