// voxelworld's client half in wasm ([CLIENT_WASM] step 6): a chunk's column
// tops for the horizon map, which was the engine's buildat.column_heights.
// client_lua/module.lua calls it, and runs column_heights_lua() -- the
// same steps in Lua -- where the module is not there or not ready.
#include "interface/wasm_api.h"

#define HORIZON_NONE (-32768)
#define MAX_SIDE 256
#define MAX_TABLE (1 << 20)

// Per voxel type id, 1 where the type blocks the sky (solid and not a
// cutout: edge_material_id set and not alpha_masked); Lua writes it
static unsigned char g_table[MAX_TABLE];
// One z slice of the chunk's inside, x fastest, then y
static unsigned int g_slice[MAX_SIDE * MAX_SIDE];
static short g_raw[MAX_SIDE * MAX_SIDE];
static short g_out[MAX_SIDE * MAX_SIDE];

BUILDAT_WASM_EXPORT unsigned char *vw_table(void){ return g_table; }
BUILDAT_WASM_EXPORT short *vw_out(void){ return g_out; }

// The local y of each column's highest voxel that blocks the sky, w*d int16
// in [z][x] order over the inside of the volume (its region less one voxel
// of padding a side), HORIZON_NONE for none; then each the lowest of its
// 3x3 columns. The id is bits shift...shift+width-1 of the voxel's first
// plane (width 0: a format with no id, every voxel type 1); id 0 is
// undefined (open), an id at or past table_len open too. Into vw_out();
// returns its bytes, or -1 for a volume past MAX_SIDE or a table past
// MAX_TABLE.
BUILDAT_WASM_EXPORT int vw_column_heights(int vol, int shift, int width,
		int table_len)
{
	if(shift < 0 || width < 0 || width > 32 || shift + width > 32 ||
			table_len < 0 || table_len > MAX_TABLE)
		return -1;
	int r[6];
	buildat_voxels_size(vol, r);
	const int w = r[3] - 2, h = r[4] - 2, d = r[5] - 2;
	if(w <= 0 || d <= 0)
		return 0;
	if(w > MAX_SIDE || h > MAX_SIDE || d > MAX_SIDE)
		return -1;
	const unsigned int mask = width == 32 ? 0xffffffffu :
			(1u << width) - 1u;
	for(int i = 0; i < w * d; i++)
		g_raw[i] = HORIZON_NONE;
	for(int z = 0; h > 0 && z < d; z++){
		const int box[6] = {r[0] + 1, r[1] + 1, r[2] + 1 + z, w, h, 1};
		buildat_voxels_read(vol, box, g_slice, sizeof g_slice);
		for(int x = 0; x < w; x++){
			for(int y = h - 1; y >= 0; y--){
				const unsigned int word = g_slice[y * w + x];
				const unsigned int id = width ? (word >> shift) & mask : 1;
				if(id != 0 && id < (unsigned int)table_len && g_table[id]){
					g_raw[z * w + x] = (short)y;
					break;
				}
			}
		}
	}
	// Eroded by a 3x3 minimum: a tree trunk or a bush is gone from the map
	// and terrain stays (simplified: a one-wide ridge goes with it)
	for(int z = 0; z < d; z++){
		for(int x = 0; x < w; x++){
			short m = 32767;
			for(int dz = -1; dz <= 1; dz++){
				for(int dx = -1; dx <= 1; dx++){
					const int xx = x + dx, zz = z + dz;
					if(xx < 0 || zz < 0 || xx >= w || zz >= d)
						continue;
					const short v = g_raw[zz * w + xx];
					if(v < m)
						m = v;
				}
			}
			g_out[z * w + x] = m;
		}
	}
	return w * d * 2;
}
