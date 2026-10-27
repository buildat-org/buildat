// apps/sample_wasm: a recursion whose every frame holds 4000 values across
// its call: 4000 wasm locals, and a native frame of some 32 KiB in
// wasm2c's C, so that a native stack overflows long before a call-depth
// count stops it. Both clients must trap, not crash ([WASM_FRAME_SIZE],
// check.sh)
#include "interface/wasm_api.h"

static long long g[5000];
static long long (*volatile again)(int);

// Each value loaded before the call, which may change g, so the compiler
// keeps it until after
#define V(i) long long v##i = g[i] * n;
#define S(i) s = (s ^ v##i) * 3 + 1;
#define T(M, p) M(p##0) M(p##1) M(p##2) M(p##3) M(p##4) \
		M(p##5) M(p##6) M(p##7) M(p##8) M(p##9)
#define H(M, p) T(M, p##0) T(M, p##1) T(M, p##2) T(M, p##3) T(M, p##4) \
		T(M, p##5) T(M, p##6) T(M, p##7) T(M, p##8) T(M, p##9)
#define K(M, p) H(M, p##0) H(M, p##1) H(M, p##2) H(M, p##3) H(M, p##4) \
		H(M, p##5) H(M, p##6) H(M, p##7) H(M, p##8) H(M, p##9)
#define Q(M) K(M, 1) K(M, 2) K(M, 3) K(M, 4)

BUILDAT_WASM_EXPORT long long deep(int n)
{
	Q(V)
	again = deep;
	g[n % 5000] = n;
	long long s = n > 0 ? again(n - 1) : 0;
	Q(S)
	return s;
}
