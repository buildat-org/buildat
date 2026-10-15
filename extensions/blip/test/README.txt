blip's import fixtures ([BLIP]), each written by the program it comes from:

sfxr_v100.sfs, sfxr_v101.sfs, sfxr_v102.sfs
  sfxr's SaveSettings() (github.com/grimfang4/sfxr, source/main.cpp, MIT),
  compiled with its version a variable and the fields a version before
  102 lacks left out as its LoadSettings() reads them; the parameters
  are SFXR in gen_test.lua.

jsfxr.txt
  jsfxr's Params().toB58() and JSON.stringify(Params) in node
  (github.com/chr15m/jsfxr, sfxr.js), for the parameters JSFXR in
  gen_test.lua and sound_vol 0.3: the link string, then the JSON.

gen_test.lua checks that each decodes to those values and maps to the
blip1 string committed with it.
