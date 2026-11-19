-- Buildat: extensions/jam/songs.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- [MUSIC_SYNTH] jam's example songs, as jam.songs: Brimstone Speedway's
-- race (Scrap Heat) and menu (Yard Vamp) music, from the prototype
-- (local/music_proto, kit_plan 4z37d), each levelled to -17 LUFS by its
-- master gain and ceiling (-14 at first, then 3 dB down to sit under the
-- game: kit_plan 4z37h). The template's kit/music entities hold the same texts
-- (util/jam_check.sh compares them); its race's tempo is the user's pick.
-- [JAM_APP] And the jam app's other starters: Slow Tide (an ambient pad)
-- and Launch Room (extensions/launch_world's room music as a song, its
-- layers' loudness and bands within 2 dB of synth.lua's m116_broken's,
-- measured offline), both at -17 LUFS.
return {
scrap_heat = [==[
# Scrap Heat: gritty rock for Brimstone Speedway (E, 156 bpm).
# Two palm-muted power-chord guitars panned hard left and right, a picked
# bass with grit, a rock kit, a lead guitar in the break. A 4-bar intro
# (one guitar, then the band), then verse, chorus, break, verse, chorus,
# each played twice, and a turnaround that loops back into the verse.
title Scrap Heat
tempo 156
steps 16
beat 4
swing 0

reverb size=0.8 decay=1.3 damp=0.5 predelay=0.015 lowcut=200
delay time=3 feedback=0.3 tone=2500
master comp=-12 ratio=2 ceiling=-4.8 gain=-5.1

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
play intro verse verse chorus chorus break break verse2 verse2 chorus chorus turn
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
master comp=-16 ratio=1.6 ceiling=-5.2 gain=2.1

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
slow_tide = [==[
# Slow Tide: a slow ambient pad (D minor, 60 bpm, no drums). Warm
# detuned saws whose filter breathes on a slow LFO, a glassy upper
# voicing, a sine sub and sparse bells drawn at random each pass. Two
# bars a chord: Dm9, Bbmaj9, Fadd9, C6/9; the bells come in on the
# second pass of the chords and the whole loops.
title Slow Tide
tempo 60
steps 16
beat 4
swing 0

reverb size=1.3 decay=6 damp=0.6 predelay=0.04 lowcut=200
delay time=6 feedback=0.5 tone=1800
master comp=-20 ratio=1.5 ceiling=-5 gain=-4.4

inst warm osc wave=saw wave2=saw detune2=12 mix2=0.5 ftype=lp poles=4 cut=520 res=0.12 ktrack=0.3 flfo=1 flforate=0.023 a=3.5 d=1 s=1 r=4 gate=1 vels=0
inst glass osc gain=-14 wave=tri wave2=sine oct2=1 mix2=0.3 detune2=4 ftype=lp cut=2400 ktrack=0 flfo=0.7 flforate=0.013 a=4 d=1 s=1 r=5 gate=1 vels=0
inst sub osc wave=sine a=1.5 d=1 s=1 r=2.5 gate=1 vels=0
inst bell fm gain=-8 ratio=3.5 index=1.4 idecay=1.2 ifloor=0.05 tine=0.2 tratio=7 tdecay=0.1 a=0.004 d=7 s=0 r=3 vels=0.6

track warm  inst=warm  gain=-6 rev=0.5 trem=0.15 tremsteps=96
track glass inst=glass gain=-15 pan=0.25 rev=0.9 trem=0.3 tremsteps=56
track sub   inst=sub   gain=-8
track bell  inst=bell  gain=-16 pan=-0.3 rev=1 dly=0.5 seed=3

mood deep glass=off bell=off
mood bare glass=off bell=off warm=-4

def dm9  D3+F3+A3+C4+E4
def bb9  Bb2+D3+F3+A3+C4
def f9   F2+C3+G3+A3+C4
def c69  C3+E3+A3+D4

# A chord a pattern, two bars each
pattern d bars=2
warm:  dm9 - - - - - - - - - - - - - - -
warm:  - - - - - - - - - - - - - - - -
glass: A4+E5 - - - - - - - - - - - - - - -
glass: - - - - - - - - - - - - - - - -
sub:   D2 - - - - - - - - - - - - - - -
sub:   - - - - - - - - - - - - - - - -
pattern bb bars=2
warm:  bb9 - - - - - - - - - - - - - - -
warm:  - - - - - - - - - - - - - - - -
glass: F4+D5 - - - - - - - - - - - - - - -
glass: - - - - - - - - - - - - - - - -
sub:   Bb1 - - - - - - - - - - - - - - -
sub:   - - - - - - - - - - - - - - - -
pattern f bars=2
warm:  f9 - - - - - - - - - - - - - - -
warm:  - - - - - - - - - - - - - - - -
glass: C5+G5 - - - - - - - - - - - - - - -
glass: - - - - - - - - - - - - - - - -
sub:   F1 - - - - - - - - - - - - - - -
sub:   - - - - - - - - - - - - - - - -
pattern c bars=2
warm:  c69 - - - - - - - - - - - - - - -
warm:  - - - - - - - - - - - - - - - -
glass: E4+D5 - - - - - - - - - - - - - - -
glass: - - - - - - - - - - - - - - - -
sub:   C2 - - - - - - - - - - - - - - -
sub:   - - - - - - - - - - - - - - - -

# Bells on D minor's pentatonic, each on a quarter of the passes
pattern bells bars=2
bell: . . . . A5%25 . . . . . . . D6%25 . . .
bell: . . F5%25 . . . . . C6%25 . . . . . G5%25 .

section drift: d bb f c
section tide:  d+bells bb+bells f+bells c+bells
play drift tide
loop drift
]==],
launch_room = [==[
# Launch Room: the launcher's room music (extensions/launch_world's
# synth.lua, m116_broken) as a song: downtempo, a broken beat with swung
# hats, two pads over Cmaj7 Am7 Fmaj7 G, a sub bass, a dotted riff into
# the delay, wind and chimes. Six sections of 16 bars, looping. What keeps
# it moving as the room's does: the pads' and the wind's filters swept by
# slow LFOs on the song's clock (flfo, flforate), so no pass sounds like
# the last, and chimes drawn at random each pass (%N).
title Launch Room
tempo 116
steps 16
beat 4
swing 0.16

reverb size=1 decay=2.4 damp=0.5 predelay=0.02 lowcut=220
delay time=3 feedback=0.42 tone=2400
master comp=-18 ratio=1.6 ceiling=-4 gain=-2

# padA: sines with a little of the second harmonic, its brightness swept;
# padB: two detuned saws through four poles, the cutoff swept slower
inst padA osc gain=-1.6 wave=sine wave2=tri oct2=1 mix2=0.3 detune2=0 ftype=lp cut=900 res=0.1 ktrack=0 flfo=1.2 flforate=0.011 a=1.6 d=1 s=1 r=1.6 gate=1 vels=0
inst padB osc gain=-1.9 wave=saw wave2=saw detune2=14 mix2=0.5 ftype=lp poles=4 cut=300 res=0.15 ktrack=0 flfo=1.3 flforate=0.0072 a=2 d=1 s=1 r=2 gate=1 vels=0
inst sub osc wave=sine a=0.05 d=1 s=1 r=0.4 gate=1 vels=0
inst riff osc wave=saw ftype=lp cut=300 res=0.25 fenv=3.2 fa=0.001 fd=0.25 fs=0 fr=0.3 ktrack=0.5 a=0.002 d=2 s=0 r=0.3 gate=1 vels=0.4
inst wind osc gain=11 wave=none noise=1 ftype=lp poles=2 cut=70 res=0 ktrack=0 flfo=0.8 flforate=0.005 a=3 d=1 s=1 r=3 gate=1 vels=0
inst chime osc gain=-11 wave=sine wave2=sine oct2=1 detune2=558 mix2=0.2 a=0.003 d=9 s=0 r=4 vels=0.5
inst kick kick tone=50 pdrop=3 pdecay=0.05 click=0.05 d=1 s=0 vels=0.7
inst snare snare tone=185 pdrop=1.3 pdecay=0.02 snappy=0.55 ndecay=0.2 nfreq=3200 d=0.3 s=0 vels=0.7
inst hat hat tone=50 metal=0.3 noise=0.9 nfreq=8500 d=0.07 s=0 odecay=0.45 vels=0.8
inst rim snare tone=820 pdrop=1 pdecay=0.01 snappy=0.8 ndecay=0.04 nfreq=5000 d=0.05 s=0 vels=0.6

# trem: the pads' slow swell (256 steps, 33 s); the wind's
track padA  inst=padA  gain=-11 pan=-0.2 trem=0.25 tremsteps=256 rev=0.4
track padB  inst=padB  gain=-13 pan=0.2 trem=0.2 tremsteps=200 rev=0.4
track sub   inst=sub   gain=-14 mono=1
track riff  inst=riff  gain=-12 pan=0.15 dly=0.8 rev=0.2 mono=1
track wind  inst=wind  gain=-4 pan=-0.1 trem=0.4 tremsteps=256 rev=0.3
track chime inst=chime gain=-16 pan=0.3 rev=0.7 dly=0.3 seed=7
track kick  inst=kick  gain=0
track snare inst=snare gain=-11 rev=0.25 hum=4
track hat   inst=hat   gain=0 pan=0.25 choke=1 hum=5 velr=0.1 hp=500
track rim   inst=rim   gain=-1 pan=-0.25 rev=0.2

# Moods for a game to move between, as the room's engagement does
mood calm kick=off snare=off hat=off rim=off riff=-6
mood still kick=off snare=off hat=off rim=off riff=off sub=-6

def cmaj C3+E3+G3+B3
def am7  A2+C3+E3+G3
def fmaj F2+A2+C3+E3
def g6   G2+B2+D3+G3

# The chords, four bars each: padA, padB and the sub as separate layers
pattern aC bars=4
padA: cmaj - - - - - - - - - - - - - - -
padA: - - - - - - - - - - - - - - - -
padA: - - - - - - - - - - - - - - - -
padA: - - - - - - - - - - - - - - - -
pattern bC bars=4
padB: cmaj - - - - - - - - - - - - - - -
padB: - - - - - - - - - - - - - - - -
padB: - - - - - - - - - - - - - - - -
padB: - - - - - - - - - - - - - - - -
pattern sC bars=4
sub: C2 - - - - - - - - - - - - - - -
sub: - - - - - - - - - - - - - - - -
sub: - - - - - - - - - - - - - - - -
sub: - - - - - - - - - - - - - - - -
pattern aA bars=4
padA: am7 - - - - - - - - - - - - - - -
padA: - - - - - - - - - - - - - - - -
padA: - - - - - - - - - - - - - - - -
padA: - - - - - - - - - - - - - - - -
pattern bA bars=4
padB: am7 - - - - - - - - - - - - - - -
padB: - - - - - - - - - - - - - - - -
padB: - - - - - - - - - - - - - - - -
padB: - - - - - - - - - - - - - - - -
pattern sA bars=4
sub: A1 - - - - - - - - - - - - - - -
sub: - - - - - - - - - - - - - - - -
sub: - - - - - - - - - - - - - - - -
sub: - - - - - - - - - - - - - - - -
pattern aF bars=4
padA: fmaj - - - - - - - - - - - - - - -
padA: - - - - - - - - - - - - - - - -
padA: - - - - - - - - - - - - - - - -
padA: - - - - - - - - - - - - - - - -
pattern bF bars=4
padB: fmaj - - - - - - - - - - - - - - -
padB: - - - - - - - - - - - - - - - -
padB: - - - - - - - - - - - - - - - -
padB: - - - - - - - - - - - - - - - -
pattern sF bars=4
sub: F1 - - - - - - - - - - - - - - -
sub: - - - - - - - - - - - - - - - -
sub: - - - - - - - - - - - - - - - -
sub: - - - - - - - - - - - - - - - -
pattern aG bars=4
padA: g6 - - - - - - - - - - - - - - -
padA: - - - - - - - - - - - - - - - -
padA: - - - - - - - - - - - - - - - -
padA: - - - - - - - - - - - - - - - -
pattern bG bars=4
padB: g6 - - - - - - - - - - - - - - -
padB: - - - - - - - - - - - - - - - -
padB: - - - - - - - - - - - - - - - -
padB: - - - - - - - - - - - - - - - -
pattern sG bars=4
sub: G1 - - - - - - - - - - - - - - -
sub: - - - - - - - - - - - - - - - -
sub: - - - - - - - - - - - - - - - -
sub: - - - - - - - - - - - - - - - -

# The riff: dotted eighths through the chord an octave up, against the beat
pattern rC bars=2
riff: C4 . . G4 . . E4 . . B4 . . G4 . E4 .
riff: C4 . . G4 . . E4 . B4 . G4 . . E4 . .
pattern rA bars=2
riff: A3 . . E4 . . C4 . . G4 . . E4 . C4 .
riff: A3 . . E4 . . C4 . G4 . E4 . . C4 . .
pattern rF bars=2
riff: F3 . . C4 . . A3 . . E4 . . C4 . A3 .
riff: F3 . . C4 . . A3 . E4 . C4 . . A3 . .
pattern rG bars=2
riff: G3 . . D4 . . B3 . . G4 . . D4 . B3 .
riff: G3 . . D4 . . B3 . G4 . D4 . . B3 . .

# The broken beat; beatin fades it in over a bar (per-step gains)
pattern beat
kick:  X . . . . . x . . . X . . . . g
snare: . . . . x . . . . . . . x . . g
hat:   x g x g x g x g x g x g x g o g
rim:   . . . . . . . . . . . g . . . .
pattern beatin
kick:  X . . . . . x . . . X . . . . g
kick~gain: -12 . . . . . -8 . . . -4 . . . . 0
hat:   x g x g x g x g x g x g x g o g
hat~gain: -12 -11 -10 -9 -8 -7 -6 -5 -4 -3 -2 -1 0 . . .
pattern hats
hat:   g . g . g . g . g . g . g . o .

# Wind, four bars a breath; chimes on C major's pentatonic, each on 10 %
# of the passes: one every 5 s or so, never the same run twice
pattern air bars=4
wind: C4 - - - - - - - - - - - - - - -
wind: - - - - - - - - - - - - - - - -
wind: - - - - - - - - - - - - - - - -
wind: - - - - - - - - - - - - - - - -
pattern bells bars=4
chime: C5%10 . . . A5%10 . . . E5%10 . . . D6%10 . . .
chime: G5%10 . . . C6%10 . . . D5%10 . . . E6%10 . . .
chime: A5%10 . . . E5%10 . . . G5%10 . . . C5%10 . . .
chime: D6%10 . . . G5%10 . . . C6%10 . . . A5%10 . . .

# The room's six sections, as synth.lua's SECTIONS
section intro:  aC+air aA+air aF+air aG+air
section groove: aC+sC+beatin aA+sA+beat aF+sF+beat aG+sG+beat
section riff:   aC+sC+beat+rC aA+sA+beat+rA aF+sF+beat+rF aG+sG+beat+rG
section lift:   bC+sC+beat+rC+bells bA+sA+beat+rA+bells bF+sF+beat+rF+bells bG+sG+beat+rG+bells
section break:  bC+air+bells+hats bA+air+bells+hats bF+air+bells+hats bG+air+bells+hats
section back:   aC+bC+sC+beatin aA+bA+sA+beat aF+bF+sF+beat aG+bG+sG+beat
play intro groove riff lift break back
loop intro
]==],
}
