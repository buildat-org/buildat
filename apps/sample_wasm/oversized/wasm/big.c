// apps/sample_wasm: a module past the client's 8 MiB cap on a .wasm, which
// both clients refuse before reading further (check.sh)
#include "interface/wasm_api.h"

static const unsigned char big[9 << 20] = {[(9 << 20) - 1] = 1};

BUILDAT_WASM_EXPORT int at(unsigned i)
{
	return big[i % sizeof big];
}
