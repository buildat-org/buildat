#!/bin/bash
# tier: quick
# cost: ~5s (2026-10-12)
# covers: src/interface/record.h src/interface/protocol.h
# [COMPAT_BREAK_07] 8b: a record with a field added at its end read by the
# reader before it; another major refused; a file hashed by an algorithm
# this does not know refused.
#   util/record_check.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
cat > "$t/c.cpp" <<'CPP'
#include "interface/protocol.h"
#include <cassert>
using namespace interface;
struct Old { uint32_t a = 0; ss_ b; };
struct New { uint32_t a = 0; ss_ b; uint32_t c = 0; };
template<class Archive> void serialize(Archive &archive, Old &v)
{
	Record<Archive> r(archive, "Thing", 1, 0);
	r.ar(v.a, v.b);
	r.end();
}
template<class Archive> void serialize(Archive &archive, New &v)
{
	Record<Archive> r(archive, "Thing", 1, 1);
	r.ar(v.a, v.b);
	if(r.minor >= 1)
		r.ar(v.c);
	r.end();
}
struct Next { uint32_t a = 0; };
template<class Archive> void serialize(Archive &archive, Next &v)
{
	Record<Archive> r(archive, "Thing", 2, 0);
	r.ar(v.a);
	r.end();
}
template<class W, class R> R through(W w, uint32_t after = 0)
{
	std::ostringstream os(std::ios::binary);
	{ cereal::PortableBinaryOutputArchive ar(os); ar(w, after); }
	std::istringstream is(os.str(), std::ios::binary);
	R r;
	uint32_t got = 0;
	{ cereal::PortableBinaryInputArchive ar(is); ar(r, got); }
	assert(got == after);
	return r;
}
int main()
{
	New n; n.a = 7; n.b = "x"; n.c = 9;
	// The tail skipped, and what follows the record read where it is
	Old o = through<New, Old>(n, 42);
	assert(o.a == 7 && o.b == "x");
	// An older one read by the newer reader, the added field left as it is
	Old o2; o2.a = 3; o2.b = "y";
	New n2 = through<Old, New>(o2, 5);
	assert(n2.a == 3 && n2.b == "y" && n2.c == 0);
	Next x; x.a = 1;
	bool refused = false;
	try { through<Next, Old>(x); } catch(RecordError &e){ refused = true; }
	assert(refused);
	// A file hashed by an algorithm this does not know: the byte after
	// the name
	FileHash f; f.name = "zz.png"; f.hash = "h";
	std::ostringstream os(std::ios::binary);
	{ cereal::PortableBinaryOutputArchive ar(os); ar(f); }
	ss_ d = os.str();
	size_t at = d.find("zz.png") + 6;
	assert(d[at] == HASH_SHA1);
	d[at] = 2;
	refused = false;
	try {
		std::istringstream is(d, std::ios::binary);
		cereal::PortableBinaryInputArchive ar(is);
		ar(f);
	} catch(RecordError &e){ refused = true; }
	assert(refused);
	return 0;
}
CPP
c++ -std=c++11 -I"$here/src" -I"$here" -I"$here/3rdparty/cereal/include" \
	"$t/c.cpp" -o "$t/c" && "$t/c"
echo "PASS: a record's added tail skipped by an older reader; another major refused; an unknown file hash refused"
