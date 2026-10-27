/* buildat's, not WAMR's: wasm_runtime_common.c calls this for natives
 * registered through WAMR's C API (wasm_c_api.c), which buildat leaves out
 * and never registers any with; so it is never reached. */
#include <stdlib.h>
struct wasm_trap_t;
void wasm_trap_delete(struct wasm_trap_t *trap)
{
	(void)trap;
	abort();
}

/* And on Windows, what platform_init.c calls from win_socket.c, which
 * buildat leaves out with WASI: no sockets, so no winsock to start. */
#ifdef _WIN32
int init_winsock(void)
{
	return 0;
}
void deinit_winsock(void)
{
}
#endif
