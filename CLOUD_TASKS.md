# Work for the cloud session, round 2 (2026-10-31)

Two dev items from the master plan, both skeldat check sections that fail
now and then. The rules are round 1's (claude/cloud-tasks): commit on
this branch only, as `git -c user.name=Claude -c user.email=claude@buildat.org
commit`, no Co-Authored-By, the item's tag in the subject, no PROBE
lines; the three BUILDAT_*_DEFAULTs at https://127.0.0.1:9; no check delay
over 2 s; results below. Run a section alone with
`SECTIONS=10 apps/skeldat/check.sh` (`SECTIONS=list` lists them).

## 1. skeldat section 10, the dig's crack, fails half the time [SKELDAT_DIG_CRACK_FLAKY]

5 of 10 runs failed on one machine, 8 of 14 on another branch: the client
restarts the dig mid-way and the server refuses it as too short. **Do**:
why the client restarts the dig (a held button read as released, a
target change, a frame gap -- see doc/client_commands.txt on held keys);
fix the cause, not the check, unless the check drives it wrongly; 10
runs of the section pass.

## 2. skeldat section 54, boats, fails now and then [SKELDAT_BOATS_FLAKY]

"no landing" / "burnt by its skull": 2 of 4 runs, 1 of 3 on another
branch. **Do**: the cause; fix it; 10 runs of the section pass.

## Results

### [SKELDAT_DIG_CRACK_FLAKY]

- Commit f0745c18 (skeldat: a dig's time from the frame after its start).
- Cause: step_dig added the frame's dt in the frame a new dig started,
  time from before the dig_start the server measures from. After a dig,
  the dug voxel's going made a long frame (0.3-0.7 s under llvmpipe), and
  the held button's next voxel counted it: its crack started at frame 3,
  the 0.7 s dig was done 0.41 s after its dig_start, and the server
  (which wants 0.75 of the time) refused it. The dig's time now starts
  at the frame after its start.
- Tally: section 10 failed 2 of 3 runs before; 10 of 10 pass after
  (`SECTIONS=10 apps/skeldat/check.sh`).

### [SKELDAT_BOATS_FLAKY]

- Commit fb938fb7 (skeldat check: boats run 2 ends after the landing,
  burns judged by the way back). Only apps/skeldat/check.sh changed.
- Cause, two parts:
  1. Run 2 had a fixed 170 s (2.8 game days). The boat's way to a shore
     is its random aims, and now and then it saw no landing in that
     time. Run 2 now ends 50 game seconds after the server's "lands at"
     line (the landing's sunrise and day), with 400 s as its limit.
  2. Any burn after the landing counted as "it burnt by its skull". But
     a landed skeleton walks off by night (to a footprint, building) like
     any other, and the sun can catch it on its way back. A burn now fails
     only where no shelter search with a way of more than 2 steps came
     before it. Beside its skull it is not exposed and searches none.
- Tally: 10 of 10 pass (`SECTIONS=54 apps/skeldat/check.sh`).

### Checks run

`util/run_all.sh --changed 6db51d55..HEAD`:
- lua_syntax passed; web_lock_check skipped (no Chrome).
- apps/skeldat/check.sh failed once in section 26 (the bow), which
  neither commit touches: `AssertionError: [1.0, 0.95, 0.29]`. The
  drive's 450 ms half-draw was held 0.95 s on a slow frame, and the
  assert wants under 0.95 (`0.4 <= held[1] < 0.95`, a [CHECK_TIMING_LIMITS]
  limit).
- Section 26 alone then passed 3 of 3.

### Open

- Section 26's half-draw limit (`held[1] < 0.95`) is close to what a
  slow frame stretches the 450 ms hold to. It flaked once in a full
  skeldat run here. Not changed: it is another item.
