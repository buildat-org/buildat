#!/bin/bash
# tier: quick
# cost: ~10 s (2026-10-12)
# covers: src/interface/record.h src/interface/protocol.h src/lua_bindings/cereal.cpp
# [COMPAT_BREAK_07] 8b: a record with a field added at its end read by the
# reader before it; another major refused; a file hashed by an algorithm
# this does not know refused. With a display, the Lua cereal binding's
# "record" in a serverless app: the same bytes as C++ writes, a newer
# minor's tail skipped, another major refused.
#   util/record_check.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
cat > "$t/c.cpp" <<'CPP'
#include "interface/protocol.h"
#include <cassert>
#include <cstdio>
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
	// For the Lua part: the bytes of a New and a 42 after it
	std::ostringstream hx(std::ios::binary);
	{ cereal::PortableBinaryOutputArchive ar(hx); ar(n, (uint32_t)42); }
	for(unsigned char ch : hx.str())
		printf("%02x", ch);
	printf("\n");
	return 0;
}
CPP
c++ -std=c++11 -I"$here/src" -I"$here" -I"$here/3rdparty/cereal/include" \
	"$t/c.cpp" -o "$t/c"
want=$("$t/c")

lua_part=""
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ -x "$here/Build/bin/buildat" ]; then
	app=$t/u/dev_apps/lr
	mkdir -p "$app/main/client_lua"
	echo '{"kind": "app", "client_main": "init.lua"}' > "$app/main/meta.json"
	printf '{"author": "tester", "name": "lr", "version": "1.0.0", "engine_api": 1,
		"audience": "everyone", "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "record_check", "serverless": true}\n' > "$app/meta.json"
	cat > "$app/main/client_lua/init.lua" <<'L'
local log = buildat.Logger("lr")
local cereal = require("buildat/extension/cereal")
local function hex(s)
	return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local function t(major, minor, fields)
	return {"object", {"r", {"record", major, minor, {"object", unpack(fields)}}},
			{"after", "int32_t"}}
end
local d = cereal.binary_output({r = {a = 7, b = "x", c = 9}, after = 42},
		t(1, 1, {{"a", "int32_t"}, {"b", "string"}, {"c", "int32_t"}}))
local o = cereal.binary_input(d, t(1, 0, {{"a", "int32_t"}, {"b", "string"}}))
local ok = pcall(cereal.binary_input, d, t(2, 0, {{"a", "int32_t"}}))
log:info("lr: " .. hex(d) .. " " .. o.r.a .. o.r.b .. tostring(o.r.c) ..
		o.after .. " " .. tostring(ok))
L
	printf 'delay 3000\nquit\n' > "$t/cmds"
	(cd "$here/Build" && BUILDAT_RUN=dev:lr timeout 60 bin/buildat \
		-o launch_ui=launch_menu -D "$t/u" -w 640x480 -l 3 -o sound_mute=1 \
		-c @"$t/cmds" > "$t/lua.log" 2>&1)
	got=$(grep -aoP 'lr: \K.*' "$t/lua.log" | head -1)
	[ "$got" = "$want 7xnil42 false" ] ||
		{ echo "FAIL: Lua's record: \"$got\", not \"$want 7xnil42 false\""; exit 1; }
	lua_part="; Lua's the same"
fi
echo "PASS: a record's added tail skipped by an older reader; another major refused; an unknown file hash refused$lua_part"
