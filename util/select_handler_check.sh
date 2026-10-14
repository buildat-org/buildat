#!/bin/bash
# tier: quick
# ci
# cost: ~2s (2026-10-04)
# covers: src/interface/select_handler.h
# [SELECT_BAD_FD]: a socket closed under select() is left out while it stays
# closed, said once, and taken back when its number is open again -- the
# number is reused, and the listener was once set aside for good.
#   util/select_handler_check.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
cat > "$t/c.cpp" <<'CPP'
#include "core/types.h"
#include <cassert>
#include <cstdio>
static int warnings = 0;
#define log_w(m, ...) (warnings++, fprintf(stderr, __VA_ARGS__), fputc('\n', stderr))
#define log_d(...) ((void)0)
#include "interface/select_handler.h"
#include <sys/socket.h>
int main()
{
	interface::SelectHandler h;
	int a[2], b[2];
	assert(socketpair(AF_UNIX, SOCK_STREAM, 0, a) == 0);
	assert(socketpair(AF_UNIX, SOCK_STREAM, 0, b) == 0);
	const int gone = b[0];
	sv_<int> active;
	assert(h.check(1000, {a[0], gone}, active) && active.empty());
	close(gone);
	// The select fails on it, and it is found by asking, not by guessing
	assert(!h.check(1000, {a[0], gone}, active));
	assert(h.closed_fds == set_<int>({gone}) && warnings == 1);
	// Left out from then on, the others still waited on, and not said again
	assert(write(a[1], "x", 1) == 1);
	assert(h.check(1000, {a[0], gone}, active));
	assert(active == sv_<int>({a[0]}) && warnings == 1);
	char c;
	assert(read(a[0], &c, 1) == 1);
	// The number open again: taken back
	int d[2];
	assert(socketpair(AF_UNIX, SOCK_STREAM, 0, d) == 0);
	assert(d[0] == gone || d[1] == gone);
	const int other = d[0] == gone ? d[1] : d[0];
	assert(write(other, "y", 1) == 1);
	active.clear();
	assert(h.check(1000, {a[0], gone}, active));
	assert(active == sv_<int>({gone}) && h.closed_fds.empty());
	printf("PASS: a closed fd left out once said, and taken back when reused\n");
	return 0;
}
CPP
c++ -std=c++11 -I"$here/src" "$t/c.cpp" -o "$t/c" 2> "$t/build.log" ||
	{ echo "FAIL: did not build: $(head -5 "$t/build.log")"; exit 1; }
"$t/c" 2> "$t/run.log" || { echo "FAIL: $(tail -3 "$t/run.log")"; exit 1; }
