#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Reads every runner and says which of them cannot fail -- the contract
# in check_lib.sh, checked statically ([CI_RUNS] (1)).
#
# It is a reading, not a check of behaviour: what it catches is a runner
# that prints FAIL: and still leaves the shell at 0, which is a green
# light with the fault written inside it. Exit 1 if any runner is like
# that, so CI can hold the line once they are all fixed.
#
# **Every runner run_all.sh runs**: every script git knows with a
# "# tier:" line, wherever it is ([RUN_ALL_TO_UTIL]).
#
#   util/check_contract.sh
set -u
cd "$(dirname "$0")/.."
python3 - <<'PY'
import os, re, sys, subprocess
bad = []
quiet = []
# **A runner is a .sh that names a tier**: netsim_table.sh says in its
# own header that it is a tool and takes arguments, and counting it as a
# silent runner was this check asking a table generator for a verdict
# (2026-09-25). Found as run_all.sh finds them.
paths = sorted(subprocess.run(["git", "grep", "-l", "^# tier:", "--", "*.sh"],
		capture_output=True, text=True, check=True).stdout.split())
skipped = 0
for name in paths:
	# verdict.sh is sourced by fuzz.sh and drive.sh and sets their status;
	# it is a fragment and not a runner of its own
	if os.path.basename(name) in ("check_contract.sh", "fullscreen_gate.sh",
			"run_all.sh", "verdict.sh"):
		skipped += 1
		continue
	src = open(name, errors="ignore").read()
	# **A runner's verdict may live in the python beside it** -- new_world.sh
	# calls new_world.py, which says PASS:/FAIL: and exits on it, and
	# reading only the shell called that silent (2026-09-25). The sibling
	# is read for *whether there is a verdict* and nowhere else: the rules
	# below are about the shell's own shape, and a python's last line is
	# not the runner's exit status.
	spoken = src
	# ...and in a sibling shell it sources: fuzz.sh and drive.sh both
	# take their verdict from verdict.sh (2026-09-25)
	for sib in set(re.findall(r"([\w./]+\.(?:py|sh))", src)):
		cand = os.path.join(os.path.dirname(name) or ".",
				os.path.basename(sib))
		if os.path.exists(cand) and os.path.abspath(cand) != os.path.abspath(name):
			spoken += "\n" + open(cand, errors="ignore").read()
	if "FAIL:" not in spoken and "echo FAIL" not in spoken:
		quiet.append(name)
		continue
	why = []
	# A python block that says FAIL: and never leaves a status behind
	for m in re.finditer(r"python3[^\n]*<<'?(\w+)'?\n(.*?)\n\1\n", src, re.S):
		body = m.group(2)
		# raise SystemExit(1) is the same thing said the other way, and
		# a python block that ends on it leaves the same status
		if ("FAIL:" in body and "sys.exit" not in body
				and "SystemExit" not in body):
			why.append("a python block prints FAIL: and does not sys.exit")
	# The shell's own verdict, with no exit anywhere after it
	for m in re.finditer(r'echo\s+"?FAIL[:\s]', src):
		rest = src[m.end():m.end() + 200]
		# exit 1 straight away, a precondition's exit 2, a function's
		# return 1 for its caller to act on, or a status the runner
		# carries to its own exit at the end: a flag set (fail=1, ok=)
		# that an exit or a return 1 reads later
		# (on the echo's line or the next)
		flag = re.search(r'\b(\w+)=1?\s*[;}\n]',
				"\n".join(rest.split("\n")[:2]) + "\n")
		carried = flag and re.search(
				r'exit "?\$\{?%s\b|\$\{?%s\b\}?"?\s*\]\s*\|\|\s*(exit|return) 1'
				% (flag.group(1), flag.group(1)), src)
		if not carried and not any(t in rest for t in ("exit 1", "exit $",
				"exit 2", "return 1", "status=1", "sys.exit", "SystemExit")):
			why.append("a shell FAIL: is not followed by exit 1")
			break
	# And whatever the runner ends with is what its status will be.
	# **Comments are not commands**: most files in this tree end with a
	# vim modeline, and reading that as the exit status flagged three
	# runners that exit properly one line above it (2026-09-25).
	lines = [l for l in src.splitlines()
			if l.strip() and not l.strip().startswith("#")]
	last = lines[-1].strip() if lines else ""
	# A runner may end on the line that says it passed, as long as every
	# way of failing before it left through exit 1 -- or through
	# check_lib.sh's fail, which is echo FAIL: and exit 1
	# exec replaces this process with another runner's, so that runner's
	# status is this one's (first_run.sh is drive.sh with a MENU_RUN)
	ends_on_verdict = (re.fullmatch(r"\w+", last) or last.startswith("exit ")
			or last.startswith("exec ")
			or "verdict_exit" in last or last == "fi"
			or last.endswith("|| exit 1") or last.endswith("exit 1; }")
			or (("PASS" in last) and ("exit 1" in src
				or re.search(r"(^|[\s;&|{(])fail ", src, re.M))))
	if not ends_on_verdict:
		why.append("the last command is %r, so that is the exit status" % last)
	if why:
		bad.append((name, why))
for name, why in bad:
	print("%s:" % name)
	for w in why:
		print("    %s" % w)
print("%d runners with a verdict, %d that cannot fail, %d with no verdict "
		"at all" % (len(paths) - skipped - len(quiet), len(bad), len(quiet)))
print("PASS: every runner's verdict decides its exit status" if not bad
		else "FAIL: %d runners print a verdict their exit status does not carry"
		% len(bad))
sys.exit(1 if bad else 0)
PY
