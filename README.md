# grains

A six-voice granular looper for [monome norns](https://monome.org/docs/norns/).

Point it at a folder of samples and it loads up-to six voices, each running several independently drifting playback heads. The heads are in a little physics simulation, colliding inside the boundaries you set, so a patch keeps moving on its own without ever repeating exactly. Usually the result tends to land somewhere between a drone, a tape loop and a chord that never quite settles. 
Apply all kinds of effects including: reverb, delay, shimmer, chorus, tape simulation, glitch, waveforder, bitcrusher, resonator, etc. It is possible to morph between two states. And there is a seamless loop recorder. The control layout lets you perform without any additional hardware.  

It is under development, so things might change. 

Based on [Graintopia](https://github.com/schollz/graintopia) by @infinitedigits.


<table>
  <tr>
    <td><img src="docs/1.png" width="278"></td>
    <td><img src="docs/2.png" width="278"></td>
  </tr>
  <tr>
    <td><img src="docs/4.png" width="278"></td>
    <td><img src="docs/6.png" width="278"></td>
  </tr>
</table>

## requires

- norns (or norns shield)

## install

From maiden:

```
;install https://github.com/danielrigler/grains
```

Do not forget to restart. 

## controls

**start here:** `K1+E1` sets density - how many layers are spread across the loaded voices. At zero you hear nothing.
`K1+K2` fills the voices with random files from your tape folder. Or you can set a specific folder under `PARAMS > SOURCE`.

**encoders**

| | |
| --- | --- |
| `E1` | master volume |
| `E2` / `E3` | boundary start / width, on the selected voice |
| `K1+E1` | density |
| `K1+E2` | layers on the selected voice |
| `K1+E3` | movement |
| `K2+E1` | shuffle volumes |
| `K2+E2` / `K2+E3` | selected voice volume / all the others |
| `K3+E1` | shuffle pitches |
| `K3+E2` / `K3+E3` | selected voice pitch / all the others |
| `K1+K2+E1` | tilt EQ |
| `K1+K2+E2` / `K1+K2+E3` | high pass / low pass |
| `K2+K3+E1/E2/E3` | reverb / delay / shimmer mix |

**keys**

| | |
| --- | --- |
| `K2` / `K3` | select voice |
| `K1+K2` | load random files |
| `K2+K3` | lock the selected voice |
| `K1+K2+K3` | reseed voices |
| `K1` hold | morph toggle |
| `K1+K2` hold | freeze the selected voice |
| `K1+K3` hold | freeze all voices |


## notes

Voices take fewer layers each as you load more files (8 for one or two voices, 4 for three or four, 3 for five or six).  
Long files are sliced: *Slice Length* under SOURCE decides how much is taken, from a random position in the file.  
Loop recording saves the file to  `dust/audio/grains/`.  

## credits

- grains by @dddstudio
- based on [Graintopia](https://github.com/schollz/graintopia) by @infinitedigits
