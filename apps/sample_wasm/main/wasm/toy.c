// apps/sample_wasm: the smallest module that exercises [CLIENT_WASM]'s
// pipeline, called by client_lua/init.lua
#include "interface/wasm_api.h"

static unsigned char buf[4096];

BUILDAT_WASM_EXPORT int add(int a, int b)
{
	return a + b;
}

// The floats both ways, and a 64-bit integer
BUILDAT_WASM_EXPORT double mix(float f, double d, long long i)
{
	return f * 2 + d + (double)i;
}

// Where Lua writes its bytes, and reads them back
BUILDAT_WASM_EXPORT unsigned char *buffer(void)
{
	return buf;
}

// Reverses the first n bytes of the buffer in place and returns their
// checksum
BUILDAT_WASM_EXPORT unsigned reverse(unsigned n)
{
	if(n > sizeof buf)
		n = sizeof buf;
	unsigned sum = 0;
	for(unsigned i = 0; i < n / 2; i++){
		unsigned char t = buf[i];
		buf[i] = buf[n - 1 - i];
		buf[n - 1 - i] = t;
	}
	for(unsigned i = 0; i < n; i++)
		sum = sum * 31 + buf[i];
	static const char said[] = "reversed the buffer";
	buildat_log(said, sizeof said - 1);
	return sum;
}

// Traps: a recursion with no end, and a read past the memory
static int (*volatile again)(int);
BUILDAT_WASM_EXPORT int recurse(int n)
{
	again = recurse;
	return again(n + 1) + 1;
}

BUILDAT_WASM_EXPORT int peek(unsigned address)
{
	return *(volatile int*)address;
}
