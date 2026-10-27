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

// [CLIENT_WASM] step 2: the imports, from memory the module owns

// A quad, 12 floats a vertex (position, normal, colour, texture
// coordinate), and its two triangles
static const float quad[4 * 12] = {
	0, 0, 0,  0, 0, -1,  1, 1, 1, 1,  0, 1,
	1, 0, 0,  0, 0, -1,  1, 1, 1, 1,  1, 1,
	1, 1, 0,  0, 0, -1,  1, 1, 1, 1,  1, 0,
	0, 1, 0,  0, 0, -1,  1, 1, 1, 1,  0, 0,
};
static const unsigned quad_indices[6] = {0, 2, 1, 0, 3, 2};
// 2x2 RGBA: red, green, blue, white
static const unsigned char pixels[16] = {
	255, 0, 0, 255,  0, 255, 0, 255,  0, 0, 255, 255,  255, 255, 255, 255,
};

// The quad as the node's geometry, the pixels as the texture's
BUILDAT_WASM_EXPORT void draw(int node, int texture)
{
	buildat_geometry_set(node, 0, quad, 4, quad_indices, 6);
	buildat_texture_set(texture, 2, 2, pixels, sizeof pixels);
}

// The node moved by dx along x and turned to face -x; returns its new x
// times 1000
BUILDAT_WASM_EXPORT int move(int node, float dx)
{
	float t[10];
	buildat_node_get(node, t);
	t[0] += dx;
	t[3] = 0; t[4] = 0; t[5] = 1; t[6] = 0; // 180 degrees about y
	buildat_node_set(node, t);
	buildat_node_get(node, t);
	return (int)(t[0] * 1000.0f + (t[0] < 0 ? -0.5f : 0.5f));
}

// The volume's voxels: the sum of their ids (the low 16 bits) weighted by
// position, and how many are not empty, as count * 1000000 + sum
static unsigned voxels_buf[16 * 16 * 16];
BUILDAT_WASM_EXPORT int voxels(int volume)
{
	int size[6];
	buildat_voxels_size(volume, size);
	if(size[3] * size[4] * size[5] > 16 * 16 * 16)
		return -1;
	const int n = buildat_voxels_read(volume, size, voxels_buf,
			sizeof voxels_buf);
	int count = 0, sum = 0;
	for(int i = 0; i < n; i++){
		if(voxels_buf[i] & 0xffff){
			count++;
			sum += (int)(voxels_buf[i] & 0xffff) * (i + 1);
		}
	}
	return count * 1000000 + sum;
}

// A packet to the server, "main:ping"; it answers "main:pong"
BUILDAT_WASM_EXPORT void ping(void)
{
	static const char name[] = "ping", data[] = "hello from wasm";
	buildat_send_packet(name, sizeof name - 1, data, sizeof data - 1);
}

// The next event Lua queued, logged: its length, or -1 with none
static char event_buf[256];
BUILDAT_WASM_EXPORT int poll(void)
{
	const int n = buildat_event_take(event_buf, sizeof event_buf);
	if(n >= 0 && n <= (int)sizeof event_buf){
		static const char got[] = "event: ";
		static char line[sizeof got - 1 + sizeof event_buf];
		for(unsigned i = 0; i < sizeof got - 1; i++)
			line[i] = got[i];
		for(int i = 0; i < n; i++)
			line[sizeof got - 1 + i] = event_buf[i];
		buildat_log(line, sizeof got - 1 + n);
	}
	return n;
}

BUILDAT_WASM_EXPORT unsigned now(void)
{
	return buildat_time_ms();
}

// The boundary's checks: each of these traps in the import
BUILDAT_WASM_EXPORT void use_node(int node)
{
	float t[10];
	buildat_node_get(node, t);
}

// A pointer past the memory
BUILDAT_WASM_EXPORT void bad_pointer(int node)
{
	buildat_node_get(node, (float*)0xfffffff0u);
}

// A pointer and length whose sum wraps in 32 bits
BUILDAT_WASM_EXPORT void len_overflow(void)
{
	buildat_log((const char*)0xffffff00u, 0x200);
}

// An index past the vertices
BUILDAT_WASM_EXPORT void bad_index(int node)
{
	static const unsigned idx[3] = {0, 1, 4};
	buildat_geometry_set(node, 0, quad, 4, idx, 3);
}

// A texture past the cap
BUILDAT_WASM_EXPORT void big_texture(int texture)
{
	buildat_texture_set(texture, 8192, 8192, pixels, 8192u * 8192u * 4u);
}

// [CLIENT_WASM] step 3: calls that never end, each stopped by the meter:
// a loop, a loop of memory.fill (charged by its size), and a recursion
// through a function pointer (call_indirect) with no loop in it
BUILDAT_WASM_EXPORT void spin(void)
{
	volatile unsigned x = 0;
	for(;;)
		x++;
}

// (stop is never set: it keeps the fills from being dropped)
static unsigned char wide[8 << 20];
static volatile int stop;
BUILDAT_WASM_EXPORT int spin_fill(void)
{
	for(unsigned i = 0; !stop; i++)
		__builtin_memset(wide, (int)i, sizeof wide);
	return wide[0];
}

static int (*volatile branch)(int);
static int tree(int depth)
{
	return depth == 0 ? 1 : branch(depth - 1) + branch(depth - 1);
}
BUILDAT_WASM_EXPORT int spin_tree(int depth)
{
	branch = tree;
	return tree(depth);
}

// The hot loop the meter's cost is measured on: the buffer reversed rounds
// times; returns the milliseconds it took
BUILDAT_WASM_EXPORT unsigned bench(unsigned rounds)
{
	const unsigned start = buildat_time_ms(), n = sizeof buf;
	unsigned sum = 0;
	for(unsigned r = 0; r < rounds; r++){
		for(unsigned i = 0; i < n / 2; i++){
			unsigned char t = buf[i];
			buf[i] = buf[n - 1 - i];
			buf[n - 1 - i] = t;
		}
		sum = sum * 31 + buf[r % n];
	}
	buf[0] ^= (unsigned char)sum;
	return buildat_time_ms() - start;
}

