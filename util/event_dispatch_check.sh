#!/bin/bash
# tier: quick
# ci
# cost: ~2s (2026-10-08)
# covers: src/interface/event.h
# [REWORK_FIXES]: EVENT_TYPEN given no parameter throws "Missing parameter",
# where it built the exception and dropped it, so the handler was skipped
# without a word.
#   util/event_dispatch_check.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
cat > "$t/c.cpp" <<'CPP'
#include "core/types.h"
#include "interface/event.h"
#include <cassert>
struct Param { virtual ~Param(){} };
static int called = 0;
static void handler(const Param &){ called++; }
interface::Event::Type interface::Event::t(const ss_ &){ return 1; }
static void dispatch(interface::Event::Type type, const Param *p)
{
	EVENT_TYPEN("x", handler, Param)
}
int main()
{
	Param x;
	dispatch(1, &x);
	assert(called == 1);
	bool threw = false;
	try { dispatch(1, nullptr); } catch(Exception &e){
		threw = ss_(e.what()).find("Missing parameter") != ss_::npos;
	}
	assert(threw && called == 1);
	return 0;
}
CPP
c++ -std=c++11 -I"$here/src" -I"$here" "$t/c.cpp" -o "$t/c" && "$t/c"
echo "PASS: a missing event parameter throws"
