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

(Per item: commits, cause, the 10-run tally, checks run, anything open.)
