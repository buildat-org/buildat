#!/bin/bash
# tier: quick
# ci
# cost: ~2s (2026-10-08)
# covers: src/interface/address.h builtin/network/api.h
# [REWORK_FIXES]: host:port and URL parsing, the one copy every caller uses.
#   util/address_check.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
cat > "$t/c.cpp" <<'CPP'
#include "interface/address.h"
#include <cassert>
#include <cstdio>
using namespace interface;
static ss_ hp(const ss_ &a, const ss_ &def = "29500")
{
	ss_ h, p;
	return split_host_port(a, &h, &p, def) ? h+"|"+p : "bad";
}
int main()
{
	assert(hp("example.org") == "example.org|29500");
	assert(hp("example.org:30000") == "example.org|30000");
	assert(hp("example.org:") == "example.org|29500");
	assert(hp("[::1]") == "::1|29500");
	assert(hp("[::1]:30000") == "::1|30000");
	assert(hp("::1") == "::1|29500");
	assert(hp("2001:db8::1") == "2001:db8::1|29500");
	assert(hp("host", "") == "host|");
	assert(hp("") == "bad");
	assert(hp(":30000") == "bad");
	assert(hp("[::1") == "bad");
	assert(hp("[::1]x") == "bad");
	assert(hp("host:0") == "bad");
	assert(hp("host:65536") == "bad");
	assert(hp("host:12a") == "bad");
	assert(hp("host:123456") == "bad");
	assert(join_host_port("::1", "80") == "[::1]:80");
	assert(join_host_port("a.b", "80") == "a.b:80");
	assert(join_host_port("a.b", "") == "a.b");
	Url u;
	assert(parse_url("https://Example.org/x/y", &u) && u.scheme == "https" &&
			u.host == "Example.org" && u.port == "443" && !u.port_given &&
			u.path == "/x/y");
	assert(parse_url("HTTP://[::1]:8080", &u) && u.scheme == "http" &&
			u.host == "::1" && u.port == "8080" && u.port_given && u.path == "");
	assert(parse_url("wss://h", &u) && u.port == "443");
	assert(parse_url("tcp://h", &u, "29500") && u.port == "29500");
	// A colon in the path is not a port
	assert(parse_url("http://h/a:b", &u) && u.port == "80" && u.path == "/a:b");
	assert(!parse_url("h:80", &u));
	assert(!parse_url("http://", &u));
	assert(!parse_url("http://h:x/", &u));
	return 0;
}
CPP
c++ -std=c++11 -I"$here/src" -I"$here" "$t/c.cpp" -o "$t/c" && "$t/c"
# [SECURITY_RUN_7] network::address_bin: a block however the address is
# written, a /48 given three groups (Starport's report buckets)
cat > "$t/b.cpp" <<'CPP'
#include "network/api.h"
#include <cassert>
int main()
{
	using network::address_bin;
	assert(address_bin("1.2.3.4") == "1.2.3.0/24");
	assert(address_bin("::ffff:1.2.3.4") == "1.2.3.0/24");
	assert(address_bin("2001:db8:0:1::5") == "2001:db8:0:1::/64");
	assert(address_bin("2001:db8::1", 3) == address_bin("2001:db8:0:1::5", 3));
	assert(address_bin("2001:DB8:0000:1::5", 3) == "2001:db8:0::/48");
	assert(address_bin("1.2.3.4", 3) == "1.2.3.0/24");
	return 0;
}
CPP
c++ -std=c++11 -I"$here/src" -I"$here/builtin" -I"$here" \
	-I"$here/3rdparty/cereal/include" "$t/b.cpp" -o "$t/b" && "$t/b"
echo "PASS: host:port and URLs parsed as one; an address's block however it is written"
