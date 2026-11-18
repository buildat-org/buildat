-- Buildat: extensions/jam/songs.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- [MUSIC_SYNTH] jam's example songs, as jam.songs: Brimstone Speedway's
-- race (Scrap Heat) and menu (Yard Vamp) music, from the prototype
-- (local/music_proto, kit_plan 4z37d), each levelled to -14 LUFS by its
-- master gain. The template's kit/music entities hold the same texts
-- (util/jam_check.sh compares them); its race's tempo is the user's pick.
return {
scrap_heat = [==[
# Scrap Heat: gritty rock for Brimstone Speedway (E, 163 bpm).
# Two palm-muted power-chord guitars panned hard left and right, a picked
# bass with grit, a rock kit, a lead guitar in the break. A 4-bar intro
# (one guitar, then the band), then verse, chorus, break, verse, chorus
# and a turnaround that loops back into the verse.
title Scrap Heat
tempo 163
steps 16
beat 4
swing 0

reverb size=0.8 decay=1.3 damp=0.5 predelay=0.015 lowcut=200
delay time=3 feedback=0.3 tone=2500
master comp=-12 ratio=2 ceiling=-1.8 gain=-2.1

# Instruments ---------------------------------------------------------
# A power chord: root, fifth and octave, each a Karplus-Strong string a
# few cents apart; the track's amp distorts the three together.
inst gtr pluck bright=0.85 decay=6 pick=0.13 mdecay=0.2 mbright=0.35 rdecay=0.05 chord=0,7,12 spread=5 gate=0.95 vels=0.35 a=0.001 s=1 r=0.06
inst lead pluck bright=0.9 decay=9 pick=0.22 rdecay=0.12 vib=28 vibrate=5.6 vibdelay=0.18 glide=0.07 gate=0.98 vels=0.3 s=1 r=0.1
inst bass osc wave=saw wave2=square mix2=0.4 detune2=0 ftype=lp poles=4 cut=380 res=0.2 fenv=2.8 fa=0.001 fd=0.22 fs=0.25 ktrack=0.7 a=0.001 d=1.5 s=0.65 r=0.05 gate=0.9 vels=0.5
inst kick kick tone=50 pdrop=3.4 pdecay=0.03 d=0.5 s=0 click=0.6 drive=4 vels=0.5
inst snare snare tone=185 pdrop=1.5 pdecay=0.02 d=0.4 s=0 ndecay=0.24 nfreq=2600 snappy=0.75 drive=5 vels=0.6
inst hat hat tone=50 nfreq=9000 metal=1 noise=0.55 d=0.08 s=0 odecay=0.5 vels=0.65
inst crash cymbal tone=68 nfreq=6500 metal=1 noise=0.9 a=0.002 d=2.4 s=0 vels=0.5
inst ride cymbal tone=58 nfreq=7000 metal=0.8 noise=0.35 d=1.6 s=0 bell=0.15 vels=0.6
inst tom tom pdrop=1.6 pdecay=0.05 d=0.7 s=0 ndecay=0.07 nfreq=1500 snappy=0.25 drive=4 vels=0.6

# Tracks: amp = the guitar amp's drive in dB; hum = up to this many ms
# late (deterministic); velr = velocity +-
track gtl   inst=gtr  gain=-4 pan=-0.85 amp=34 bias=0.25 tight=100 hump=7 cab=4600 ampout=-10 rev=0.06 hum=7 velr=0.06 mono=1 seed=11
track gtr   inst=gtr  gain=-4 pan=0.85 amp=33 bias=0.2 tight=95 hump=6 mid=1000 cab=4300 ampout=-10 rev=0.06 hum=7 velr=0.06 mono=1 tune=-6 seed=23
track lead  inst=lead gain=-8 pan=0.1 amp=40 hump=8 mid=1000 cab=5000 presence=4 ampout=-10 rev=0.18 dly=0.25 mono=1
track bass  inst=bass gain=6 amp=18 blend=0.55 tight=250 hump=5 mid=900 cab=3000 fizz=4000 ampout=-4 comp=-20 ratio=4 mono=1 hum=3
track kick  inst=kick gain=-1 hum=2
track snare inst=snare gain=1 pan=0.05 rev=0.22 hum=3 velr=0.05
track hat   inst=hat gain=2 pan=0.3 choke=1 hum=4 velr=0.12 hp=400
track ride  inst=ride gain=-8 pan=0.35 hum=4 velr=0.1 hp=400
track crash inst=crash gain=-8 pan=-0.4 rev=0.1 hp=300
track tom   inst=tom gain=-4 pan=-0.1 rev=0.15

# Moods: track gains (dB or off) that a game switches between, on a bar
mood lobby gtl=off gtr=off lead=off crash=-6
mood calm gtl=-9 gtr=-9 lead=off kick=-3

# Patterns: one line a bar per track; tokens a step (a 16th).
# . rest  - hold  E2 a note  ! accent  ? soft  m palm mute  ~ slide on
# drums: X accent  x hit  g ghost  o open hat  f flam
pattern vA bars=2
gtl:  E2m . E2m . E2m . E2m E2m E2m . G2! - . A2! - .
gtl:  E2m . E2m . E2m . E2m E2m E2m . D3! - - - C3! -
gtr:  = gtl
bass: E1 . E1 . E1 . E1 E1 E1 . G1! - . A1! - .
bass: E1 . E1 . E1 . E1 E1 E1 . D2! - - - C2! -

pattern vB bars=2
gtl:  E2m . E2m . E2m . E2m E2m E2m . G2! - . A2! - .
gtl:  E2m . E2m . E2m . E2m E2m Bb2! - - . A2! - G2! -
gtr:  = gtl
bass: E1 . E1 . E1 . E1 E1 E1 . G1! - . A1! - .
bass: E1 . E1 . E1 . E1 E1 Bb1! - - . A1! - G1! -

pattern chA bars=2
gtl:  C3! - C3 - C3 - C3 - D3! - D3 - D3 - D3 -
gtl:  E2! - E2 - E2 - E2 - E2 - E2 - G2! - A2! -
gtr:  = gtl
bass: C2! . C2 . C2 . C2 . D2! . D2 . D2 . D2 .
bass: E1! . E1 . E1 . E1 . E1 . E1 . G1! . A1! .

pattern chB bars=2
gtl:  C3! - C3 - C3 - C3 - D3! - D3 - D3 - B2! -
gtl:  E2! - - - - - - - E2m . E2m . E2m E2m E2m E2m
gtr:  = gtl
bass: C2! . C2 . C2 . C2 . D2! . D2 . D2 . B1! .
bass: E1! - - - - - - - E1 . E1 . E1 E1 E1 E1

pattern brk
gtl:  E2m . E2m E2m E2m . E2m E2m E2m . E2m E2m E2m . G2m A2m
gtr:  = gtl
bass: E1 . E1 E1 E1 . E1 E1 E1 . E1 E1 E1 . G1 A1

pattern ld1 bars=2
lead: B4! - - - - - - - A4~ - B4 - - - G4 -
lead: E4! - - - - - - - - - - - D4 - E4 -
pattern ld2 bars=2
lead: G4! - A4 - B4 - D5! - - - B4 - A4 - G4 -
lead: A4~ - B4 - - - - - - - - - . . . .
pattern ld3 bars=2
lead: E5! - - - D5 - B4 - D5~ - E5 - - - D5 B4
lead: A4 - - - G4 - E4 - G4~ - A4 - - - - -
pattern ld4 bars=2
lead: B4! - A4 G4 E4 - G4 - A4~ - Bb4~ - B4 - - -
lead: E4! - - - - - - - - - - - - - . .

# Drums
pattern beat
kick:  X . . . . . x . X . x . . . . .
snare: . . . . X . . . . . . . X . . g
hat:   X . x . X . x . X . x . X . x .

pattern beatx
kick:  X . . . . . x . X . x . . . . .
snare: . . . . X . . . . . . . X . . g
hat:   . . x . X . x . X . x . X . x .
crash: X . . . . . . . . . . . . . . .

pattern beatf bars=2
kick:  X . . . . . x . X . x . . . . .
kick:  X . . . . . x . X . . . X . . .
snare: . . . . X . . . . . . . X . . g
snare: . . . . X . . . X x . . . . . .
hat:   X . x . X . x . X . x . X . x .
hat:   X . x . X . x . . . . . . . . .
tom:   . . . . . . . . . . . . . . . .
tom:   . . . . . . . . . . A3! A3 E3! E3 B2! B2

pattern beatc bars=2
kick:  X . . . . . x . X . x . . . x .
snare: . . . . X . . . . . . . X . . .
ride:  X . x . X . x . X . x . X . x .
crash: X . . . . . . . . . . . . . . .
crash: . . . . . . . . . . . . . . . .

pattern beatcf bars=2
kick:  X . . . . . x . X . x . . . x .
kick:  X . . . . . x . X . . . X . . .
snare: . . . . X . . . . . . . X . . .
snare: . . . . X . . . . . . . X x X x
ride:  X . x . X . x . X . x . X . x .
ride:  X . x . X . x . . . . . . . . .
crash: X . . . . . . . . . . . . . . .
crash: . . . . . . . . . . . . . . . .
tom:   . . . . . . . . . . . . . . . .
tom:   . . . . . . . . E3! E3 B2! B2 . . . .

# The turnaround: a ringing stop, a snare build, a gallop with toms
pattern stop bars=2
gtl:   E2! - - - - - - - - - - - - - - -
gtl:   - - - - - - - - - - - - . . . .
gtr:   = gtl
bass:  E1! - - - - - - - - - - - - - - -
bass:  - - - - - - - - - - - - . . . .
kick:  X . . . . . . . . . . . . . . .
kick:  . . . . . . . . . . . . X . . .
crash: X . . . . . . . . . . . . . . .
crash: . . . . . . . . . . . . . . . .
snare: . . . . . . . . . . . . . . . .
snare: . . . . . . . . g g g x x X X X

pattern go bars=2
gtl:   E2m . E2m E2m E2m . E2m E2m E2m . E2m E2m E2m . G2m A2m
gtr:   = gtl
bass:  E1 . E1 E1 E1 . E1 E1 E1 . E1 E1 E1 . G1 A1
kick:  X . x . X . x . X . x . X . x .
kick:  X . . . X . . . X . . . X . . .
snare: . . . . X . . . . . . . X . . .
snare: . . . . . . . . . . . . X X X X
hat:   X . x . X . x . X . x . X . x .
hat:   . . . . . . . . . . . . . . . .
tom:   . . . . . . . . . . . . . . . .
tom:   A3! A3 A3 A3 E3! E3 E3 E3 B2! B2 B2 B2 . . . .

# The intro: the left guitar alone over a hat count, then the band
pattern in1 bars=2
gtl:   E2m . E2m . E2m . E2m E2m E2m . G2! - . A2! - .
gtl:   E2m . E2m . E2m . E2m E2m E2m . D3! - - - C3! -
hat:   x . . . x . . . x . . . x . . .

pattern in2 bars=2
gtl:   E2m . E2m . E2m . E2m E2m E2m . G2! - . A2! - .
gtl:   E2m . E2m . E2m . E2m E2m Bb2! - - . A2! - G2! -
gtr:   = gtl
bass:  E1 . E1 . E1 . E1 E1 E1 . G1! - . A1! - .
bass:  E1 . E1 . E1 . E1 E1 Bb1! - - . A1! - G1! -
kick:  X . . . X . . . X . . . X . . .
kick:  X . . . X . . . X . . . . . . .
hat:   x . x . x . x . x . x . x . x .
hat:   x . x . x . x . . . . . . . . .
tom:   . . . . . . . . . . . . . . . .
tom:   . . . . . . . . A3! A3 E3! E3 B2! B2 B2 B2
snare: . . . . . . . . . . . . . . . .
snare: . . . . . . . . . . . . X . X X

# Arrangement: an entry is a pattern, patterns layered with +, *N repeats
section intro:  in1 in2
section verse:  vA+beatx vB+beat vA+beat vB+beatf
section chorus: chA+beatc chB+beatc chA+beatc chB+beatcf
section break:  brk+beat+ld1 brk+beat+ld2 brk+beat+ld3 brk+beatf+ld4
section verse2: vA+beatx vB+beatf
section turn:   stop go
play intro verse chorus break verse2 chorus turn
loop verse
]==],
yard_vamp = [==[
# Yard Vamp: a riff-led menu track (E, 82 bpm, shuffled 16ths). A lounge
# band vamping in a garage: a 2-bar riff on the bass with a lightly driven
# tremolo guitar an octave up, round a 12-bar blues (E, A, B); then an
# 8-bar Em7-A13 vamp of guitar stabs and electric piano. Brushes, a shaker,
# a ride in the vamp; a few short guitar fills. Same instruments as
# menu.song. A 1-bar intro, then 20 bars that loop.
title Yard Vamp
tempo 82
steps 16
beat 4
swing 0.2

reverb size=1.1 decay=2.6 damp=0.55 predelay=0.02 lowcut=250
delay time=6 feedback=0.38 tone=2200
master comp=-16 ratio=1.6 ceiling=-2.2 gain=5.1

inst ep fm ratio=1 index=1.6 idecay=0.9 ifloor=0.15 tine=0.18 tratio=14 tdecay=0.05 a=0.003 d=4 s=0 r=0.5 gate=0.95 vels=0.6
inst gtr pluck bright=0.45 decay=3.5 pick=0.2 rdecay=0.4 vib=12 vibrate=5 vibdelay=0.3 glide=0.08 gate=1 vels=0.5 s=1 r=0.3
inst bass pluck bright=0.3 decay=1.6 pick=0.28 rdecay=0.12 gate=0.85 vels=0.4 s=1 r=0.08
inst kick kick tone=54 pdrop=2.2 pdecay=0.03 d=0.45 s=0 click=0.08 vels=0.6
inst brush snare tone=300 pdrop=1.2 pdecay=0.01 d=0.15 s=0 ndecay=0.16 nfreq=4200 snappy=0.92 a=0.006 vels=0.7
inst shaker hat metal=0 noise=1 nfreq=6500 a=0.012 d=0.07 s=0 vels=0.8
inst ride cymbal tone=60 nfreq=7500 metal=0.7 noise=0.25 d=2 s=0 bell=0.2 vels=0.7

# gtr doubles the bass riff an octave up (transpose); gtc plays the stabs
# and fills as written
track gtr   inst=gtr  gain=2 pan=-0.3 transpose=12 amp=11 bias=0.1 tight=120 hump=2 cab=4600 lp=3500 ampout=-7 trem=0.3 tremsteps=2 rev=0.22 dly=0.15 mono=1 hum=8 velr=0.08 seed=5
track gtc   inst=gtr  gain=-1 pan=0.35 amp=10 bias=0.1 tight=120 hump=2 cab=5200 ampout=-6 trem=0.55 tremsteps=2 rev=0.3 dly=0.3 mono=1 hum=10 velr=0.08 seed=17
track ep    inst=ep   gain=-13 pan=0.2 rev=0.25 hum=12 velr=0.06 trem=0.15 tremsteps=8
track bass  inst=bass gain=5 pan=0 lp=1800 lo=3 comp=-26 ratio=5 catk=0.0004 crel=0.15 hum=6 mono=1
track kick  inst=kick gain=-4 hum=5
track brush inst=brush gain=-3 pan=0.15 rev=0.3 hum=8 velr=0.1
track shk   inst=shaker gain=-7 pan=-0.3 hum=6 velr=0.15 hp=2000
track ride  inst=ride gain=-14 pan=0.4 rev=0.15 hum=6 velr=0.1 hp=500

mood quiet kick=off brush=off shk=off ride=off

def em7  E3+B3+D4+G4
def a13  G3+C#4+F#4
def em9  G3+B3+D4+F#4
def a9   G3+B3+C#4+E4

# The riff, a bar a pattern: a call, its answer, a climb; on A and on B
pattern rE1
bass: E2! - . E2' . . G2 . A2 - . . . . E2? .
gtr:  = bass
pattern rE2
bass: E2! - . E2' . . G2 . A2 - . G2' . E2 . D2
gtr:  = bass
pattern rE3
bass: E2! - . E2' . . G2 . A2 . Bb2 . B2 - D3 .
gtr:  = bass
pattern rA1
bass: A1! - . A1' . . C2 . D2 - . . . . A1? .
gtr:  = bass
pattern rA2
bass: A1! - . A1' . . C2 . D2 - . C2' . A1 . B1
gtr:  = bass
pattern rB1
bass: B1! - . B1' . . D2 . E2 - . . . . B1? .
gtr:  = bass
# The turnaround: the riff stops on B, a short fill above it
pattern turn
bass: E2! - . E2' . . G2 . B1! - - - - - . .
gtr:  E2! - . E2' . . G2 . B1! - - - - - . .
gtc:  . . . . . . . . . . . . F#4' A4' B4 -

# The vamp: Em7 and A13 stabs locked with the bass
pattern vamp bars=2
bass: E2! - - . . . E2' . B1 . D2 . E2 . . .
bass: A1! - - . . . A1' . E2 . G2 . A2 . . .
gtc:  . . em7' . . . . . . . em7? . em7' . . .
gtc:  . . a13' . . . . . . . a13? . a13' . . .
ep:   em9? - - - - - - - - - - - - - - -
ep:   a9? - - - - - - - - - - - - - - -
pattern vampend bars=2
bass: E2! - - . . . E2' . B1 . D2 . E2 . . .
bass: A1! - - . . . A1' . E2 . G2 . A2 . B1 .
gtc:  . . em7' . . . . . . . em7? . em7' . . .
gtc:  . . a13' . . . . . . . . . G4' E4' D4 B3
ep:   em9? - - - - - - - - - - - - - - -
ep:   a9? - - - - - - - - - - - - - - -

# Drums
pattern drA
kick:  X . . . . . . . . . x . . . . .
brush: . . . . x . . . . . . . x . . g
shk:   x . g . x . g . x . g . x . g .
pattern drF
kick:  X . . . . . . . X . . . . . . .
brush: . . . . x . . . . . . . x g x g
shk:   x . g . x . g . x . . . . . . .
pattern drB
kick:  X . . . . . . . . . x . . . . .
brush: . . . . x . . . . . . . x . . g
ride:  X . . . x . . x X . . . x . . x
shk:   x . g . x . g . x . g . x . g .

pattern intro
gtr:   . . . . . . . . A2 - . G2' . E2 . D2
shk:   . . . . . . . . x . g . x . g .

section intro: intro
section blues: rE1+drA rE2+drA rE1+drA rE3+drA rA1+drA rA2+drA rE1+drA rE2+drA rB1+drA rA1+drA rE1+drA turn+drF
section vamp:  vamp+drB vamp+drB vamp+drB vampend+drB
play intro blues vamp
loop blues
]==],
}
