#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: ~1s (2026-11-04)
# covers: builtin/kit/box/libc.c
# [KIT_BOX_TRIG] The Kit box's own sin, cos, atan and atan2
# (builtin/kit/box/libc.c, the box has no libm): their section compiled
# natively and compared with the system's libm over -1000..1000 and the
# edge cases (zeros, infinities, NaN, atan2's quadrants), within 1e-15
# relative or absolute (a few ulps).
#   util/kit_box_trig_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v cc >/dev/null || skip "no cc"
check_tmp kit_box_trig; t=$CHECK_TMP
{
	cat <<'EOF'
#include <math.h>
#include <stdint.h>
#include <stdio.h>
typedef union { double d; uint64_t u; } bits;
#define sin box_sin
#define cos box_cos
#define atan box_atan
#define atan2 box_atan2
EOF
	sed -n '/^\/\* \[KIT_BOX_TRIG\]/,/^\/\* ---- locale.h/p' \
		"$here/builtin/kit/box/libc.c"
	cat <<'EOF'
#undef sin
#undef cos
#undef atan
#undef atan2
static int bad;
static void cmp(const char *f, double x, double got, double want)
{
	const double e = fabs(got - want);
	if((want != want) != (got != got) || (want == want &&
			e > 1e-15 * (fabs(want) > 1 ? fabs(want) : 1)) ||
			(want == 0 && signbit(want) != signbit(got))){
		if(bad++ < 10)
			printf("%s(%.17g): %.17g, libm %.17g\n", f, x, got, want);
	}
}
int main(void)
{
	for(double x = -1000; x <= 1000; x += 0.0137){
		cmp("sin", x, box_sin(x), sin(x));
		cmp("cos", x, box_cos(x), cos(x));
		cmp("atan", x, box_atan(x), atan(x));
		cmp("atan", x / 1000, box_atan(x / 1000), atan(x / 1000));
		cmp("atan2", x, box_atan2(x, 1.5), atan2(x, 1.5));
		cmp("atan2", x, box_atan2(-1.5, x), atan2(-1.5, x));
		cmp("atan2", x, box_atan2(x, -x * 0.3), atan2(x, -x * 0.3));
	}
	const double S[] = {0.0, -0.0, 1.0, -1.0, INFINITY, -INFINITY, NAN,
		1e-300, M_PI, M_PI / 2, M_PI / 4, 1e6};
	const int n = sizeof S / sizeof *S;
	for(int i = 0; i < n; i++){
		cmp("sin", S[i], box_sin(S[i]), sin(S[i]));
		cmp("cos", S[i], box_cos(S[i]), cos(S[i]));
		cmp("atan", S[i], box_atan(S[i]), atan(S[i]));
		for(int j = 0; j < n; j++)
			cmp("atan2", S[i] * 1000 + S[j], box_atan2(S[i], S[j]),
					atan2(S[i], S[j]));
	}
	return bad != 0;
}
EOF
} > "$t/trig.c"
cc -O2 -ffp-contract=off -o "$t/trig" "$t/trig.c" -lm ||
	fail "the trig section did not compile ($t/trig.c)"
"$t/trig" || fail "the box's trig differs from libm"
echo "PASS: the Kit box's sin, cos, atan and atan2 agree with libm"
