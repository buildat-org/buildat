// apps/sample_wasm: a module exporting the name of the client's meter
// (buildat_meter), which both clients refuse (check.sh)
#include "interface/wasm_api.h"

__attribute__((export_name("buildat_meter"))) int meter(void)
{
	return 0;
}
