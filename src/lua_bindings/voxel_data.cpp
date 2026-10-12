// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// Packed samples in, a serialized volume out. One strided box copy per source,
// with a value mapping, which is enough to turn somebody else's voxel format
// into something set_voxel_geometry() and deserialize_volume() take.
//
// What wanted this is Luanti's mapblocks: a block is 4096 big-endian u16 node
// ids followed by 4096 bytes of light, and the mesher wants those plus a
// one-voxel border from the six neighbouring blocks in an 18^3 volume. That is
// seven box copies and two fields, and doing it in Lua is 100k calls a block.
// Nothing in here knows about Luanti, though: it is offsets, strides and a
// lookup table.
#include "lua_bindings/util.h"
#include "lua_bindings/luabind_util.h"
#include "core/log.h"
#include "interface/voxel.h"
#include "interface/voxel_volume.h"
#include <luabind/luabind.hpp>
#include <luabind/object.hpp>
#include <luabind/iterator_policy.hpp>
#include <cstring>
#include <unordered_map>
#define MODULE "lua_bindings"

namespace pv = PolyVox;
using interface::VoxelInstance;
using interface::VoxelVolume;

namespace lua_bindings {

// Which part of a voxel a source writes. A field names one of the roles the
// voxel format binds -- see VoxelFormat in interface/voxel.h -- and where
// that role actually is in the word is the format's business, not the
// caller's. "raw" is the whole word and belongs to no role.
static bool resolve_field(const ss_ &name, const interface::VoxelFormat &fmt,
		interface::VoxelField &dst, bool &raw)
{
	raw = false;
	if(name == "raw"){
		raw = true;
		dst = interface::VoxelField(0, 0, 32);
		return true;
	}
	if(name == "id")
		dst = fmt.id;
	else if(name == "skylight")
		dst = fmt.light_sky;
	else if(name == "lamplight")
		dst = fmt.light_lamp;
	else if(name == "param")
		dst = fmt.param;
	else if(name == "color")
		dst = fmt.color;
	else if(name == "light"){
		// Both light channels in one write, which only works when they are
		// adjacent with the sky light in the low bits
		if(!fmt.light_pair(&dst))
			throw Exception("pack_voxel_volume(): field \"light\" needs the "
					"two light channels adjacent in "+fmt.dump());
		return true;
	} else
		return false;
	if(!dst.bound())
		throw Exception("pack_voxel_volume(): field \""+name+"\" is not "
				"bound in "+fmt.dump());
	return true;
}

// A table of ids that big is already unreasonable; the point of the limit is
// that a broken map table cannot ask for an arbitrary allocation
static const size_t PACK_MAP_MAX = 1 << 26;

// Above this a map is a hash rather than an array, so that a key made of two
// samples does not ask for an allocation the size of its range
static const size_t PACK_MAP_DENSE_MAX = 1 << 22;

// A second sample array, read in lockstep with the first: the value looked up
// is first + second * scale. What wanted this is Luanti's param2, which
// decides a voxel's colour or which way it faces, so what a voxel looks like
// is a pair of samples rather than one.
struct PackSecond
{
	ss_ data;
	size_t sample_bytes = 1;
	bool big_endian = true;
	uint32_t shift = 0;
	uint32_t mask = 0xffffffff;
	int64_t scale = 1;
	bool present = false;
};

// A parsed map: what a sample value turns into. Kept behind a pointer and
// cached, because compiling one is thousands of Lua table reads and the same
// map is handed in by every source of every block; see parse_map().
struct PackMap
{
	// map[sample] -> what gets written, or -1 for a sample the map does not
	// mention
	sv_<int64_t> dense;
	// The same thing for keys that are too spread out to be an array, which
	// is what combining two samples gives
	std::unordered_map<int64_t, int64_t> sparse;
	bool is_sparse = false;
};

// map_id -> the version it was compiled from, and the compiled map. A caller
// that gives a map an id and a version gets it compiled once; see
// doc/client_api.txt.
static sm_<int64_t, std::pair<int64_t, sp_<PackMap>>> g_map_cache;
// Nothing needs many, and a caller that invents ids should not grow this
// without bound
static const size_t PACK_MAP_CACHE_MAX = 64;

struct PackSource
{
	ss_ data;
	size_t sample_bytes = 1;
	bool big_endian = true;
	int source_size[3] = {0, 0, 0};  // In samples, x y z
	int from[3] = {0, 0, 0};         // The box to copy, in samples
	int size[3] = {0, 0, 0};
	int at[3] = {0, 0, 0};           // Where it lands, in region coordinates
	int stride[3] = {0, 0, 0};       // Samples to step per x, y, z; from order
	uint32_t shift = 0;
	uint32_t mask = 0xffffffff;
	interface::VoxelField dst;      // Where in the voxel it is written
	bool dst_raw = false;           // The whole word, no role
	// No map means no mapping: the sample is the value
	sp_<PackMap> map;
	int64_t map_default = -1;  // For samples the map does not mention
	PackSecond second;
};

static double table_number(const luabind::object &t, const char *key,
		double default_value)
{
	luabind::object v = t[key];
	if(!v || luabind::type(v) != LUA_TNUMBER)
		return default_value;
	return luabind::object_cast<double>(v);
}

static double table_number_at(const luabind::object &t, int index,
		double default_value)
{
	luabind::object v = t[index];
	if(!v || luabind::type(v) != LUA_TNUMBER)
		return default_value;
	return luabind::object_cast<double>(v);
}

// {x, y, z} as an array, which is what the caller writes for a position or a
// size. Missing entries take default_value.
static void table_int3(const luabind::object &t, const char *key,
		int result[3], int default_value, const char *what)
{
	result[0] = result[1] = result[2] = default_value;
	luabind::object v = t[key];
	if(!v)
		return;
	if(luabind::type(v) != LUA_TTABLE)
		throw Exception(ss_(what) + ": " + key + " is not a table");
	for(int i = 0; i < 3; i++)
		result[i] = (int)table_number_at(v, i + 1, default_value);
}

static void parse_format(const ss_ &format, PackSource &source)
{
	if(format == "u8"){
		source.sample_bytes = 1;
		source.big_endian = true;
	} else if(format == "u16be" || format == "u16le"){
		source.sample_bytes = 2;
		source.big_endian = (format == "u16be");
	} else if(format == "u32be" || format == "u32le"){
		source.sample_bytes = 4;
		source.big_endian = (format == "u32be");
	} else {
		throw Exception("pack_voxel_volume(): unknown sample format \"" +
				format + "\"");
	}
}

// order says which axis runs fastest, first: "xyz" is x fastest, "zyx" is z
// fastest. The strides that come out are per x, y and z, in samples.
static void parse_order(const ss_ &order, const int source_size[3],
		int stride[3])
{
	if(order.size() != 3)
		throw Exception("pack_voxel_volume(): order \"" + order +
				"\" is not three axes");
	int axis[3];
	bool seen[3] = {false, false, false};
	for(int i = 0; i < 3; i++){
		char c = order[i];
		if(c < 'x' || c > 'z')
			throw Exception("pack_voxel_volume(): order \"" + order +
					"\" is not made of x, y and z");
		axis[i] = c - 'x';
		if(seen[axis[i]])
			throw Exception("pack_voxel_volume(): order \"" + order +
					"\" repeats an axis");
		seen[axis[i]] = true;
	}
	int step = 1;
	for(int i = 0; i < 3; i++){
		stride[axis[i]] = step;
		step *= source_size[axis[i]];
	}
}

static sp_<PackMap> compile_map(const luabind::object &map_o)
{
	sp_<PackMap> map(new PackMap());
	if(luabind::type(map_o) == LUA_TSTRING){
		// A byte per sample value, which is the compact way to write a mapping
		// of a few hundred small ids
		ss_ s = luabind::object_cast<ss_>(map_o);
		map->dense.assign(s.size(), -1);
		for(size_t i = 0; i < s.size(); i++)
			map->dense[i] = (uint8_t)s[i];
		return map;
	}
	if(luabind::type(map_o) != LUA_TTABLE)
		throw Exception("pack_voxel_volume(): map is neither a string nor a "
				"table");
	// Two passes: the table is sparse and unordered, so how long the lookup
	// needs to be is only known once all of the keys have been seen
	size_t highest = 0;
	for(luabind::iterator it(map_o), end; it != end; ++it){
		luabind::object key = it.key();
		if(luabind::type(key) != LUA_TNUMBER)
			continue;
		double k = luabind::object_cast<double>(key);
		if(k < 0 || k >= (double)PACK_MAP_MAX)
			throw Exception("pack_voxel_volume(): map key out of range");
		if((size_t)k > highest)
			highest = (size_t)k;
	}
	// A dense array while the keys are close together, a hash when they are
	// not: combining two samples spreads them over a range no array can hold
	map->is_sparse = highest >= PACK_MAP_DENSE_MAX;
	if(!map->is_sparse)
		map->dense.assign(highest + 1, -1);
	for(luabind::iterator it(map_o), end; it != end; ++it){
		luabind::object key = it.key();
		if(luabind::type(key) != LUA_TNUMBER)
			continue;
		luabind::object value = *it;
		if(luabind::type(value) != LUA_TNUMBER)
			continue;
		int64_t k = (int64_t)luabind::object_cast<double>(key);
		int64_t v = (int64_t)luabind::object_cast<double>(value);
		if(map->is_sparse)
			map->sparse[k] = v;
		else
			map->dense[(size_t)k] = v;
	}
	return map;
}

// source.map, compiled once per (map_id, map_version) if the source gives an
// id and every time if it does not. A map of a few thousand entries costs
// about as much to compile as the whole box copy does, and the maps of a voxel
// world outlive thousands of copies.
static void parse_map(const luabind::object &t, const luabind::object &map_o,
		PackSource &source)
{
	int64_t id = (int64_t)table_number(t, "map_id", 0);
	if(id == 0){
		source.map = compile_map(map_o);
		return;
	}
	int64_t version = (int64_t)table_number(t, "map_version", 0);
	auto it = g_map_cache.find(id);
	if(it != g_map_cache.end() && it->second.first == version){
		source.map = it->second.second;
		return;
	}
	if(g_map_cache.size() >= PACK_MAP_CACHE_MAX)
		g_map_cache.clear();
	source.map = compile_map(map_o);
	g_map_cache[id] = std::make_pair(version, source.map);
}

// The value a map holds for a key, or -1 for one it does not mention
static inline int64_t map_lookup(const PackMap &map, int64_t key)
{
	if(map.is_sparse){
		auto it = map.sparse.find(key);
		return it == map.sparse.end() ? -1 : it->second;
	}
	return (key >= 0 && (size_t)key < map.dense.size()) ?
			map.dense[(size_t)key] : -1;
}

static void parse_second(const luabind::object &t, PackSource &source)
{
	luabind::object second_o = t["second"];
	if(!second_o || luabind::type(second_o) != LUA_TTABLE)
		return;
	PackSecond &second = source.second;
	luabind::object data_o = second_o["data"];
	if(!data_o || luabind::type(data_o) != LUA_TSTRING)
		throw Exception("pack_voxel_volume(): source.second.data is not a "
				"string");
	second.data = luabind::object_cast<ss_>(data_o);
	{
		PackSource tmp;
		luabind::object format_o = second_o["format"];
		parse_format(format_o && luabind::type(format_o) == LUA_TSTRING ?
				luabind::object_cast<ss_>(format_o) : ss_("u8"), tmp);
		second.sample_bytes = tmp.sample_bytes;
		second.big_endian = tmp.big_endian;
	}
	second.shift = (uint32_t)table_number(second_o, "shift", 0);
	if(second.shift > 31)
		throw Exception("pack_voxel_volume(): source.second.shift is out of "
				"range");
	second.mask = second.sample_bytes >= 4 ? 0xffffffffUL :
			((1UL << (second.sample_bytes * 8)) - 1);
	{
		luabind::object mask_o = second_o["mask"];
		if(mask_o && luabind::type(mask_o) == LUA_TNUMBER)
			second.mask = (uint32_t)luabind::object_cast<double>(mask_o);
	}
	second.scale = (int64_t)table_number(second_o, "scale", 1);
	if(second.scale < 1)
		throw Exception("pack_voxel_volume(): source.second.scale is not "
				"positive");
	// Read in lockstep, so it has to be as long as the first array
	size_t samples = (size_t)source.source_size[0] *
			(size_t)source.source_size[1] * (size_t)source.source_size[2];
	if(second.data.size() < samples * second.sample_bytes)
		throw Exception(ss_("pack_voxel_volume(): source.second.data holds ") +
				itos(second.data.size()) + " bytes, source_size wants " +
				itos(samples * second.sample_bytes));
	second.present = true;
}

static void parse_source(const luabind::object &t, PackSource &source,
		const interface::VoxelFormat &fmt)
{
	if(luabind::type(t) != LUA_TTABLE)
		throw Exception("pack_voxel_volume(): a source is not a table");

	{
		luabind::object data_o = t["data"];
		if(!data_o || luabind::type(data_o) != LUA_TSTRING)
			throw Exception("pack_voxel_volume(): source.data is not a string");
		source.data = luabind::object_cast<ss_>(data_o);
	}
	{
		luabind::object format_o = t["format"];
		parse_format(format_o && luabind::type(format_o) == LUA_TSTRING ?
				luabind::object_cast<ss_>(format_o) : ss_("u8"), source);
	}

	table_int3(t, "source_size", source.source_size, 0,
			"pack_voxel_volume(): source");
	for(int i = 0; i < 3; i++){
		if(source.source_size[i] <= 0)
			throw Exception("pack_voxel_volume(): source_size is not positive");
	}
	table_int3(t, "from", source.from, 0, "pack_voxel_volume(): source");
	table_int3(t, "size", source.size, 0, "pack_voxel_volume(): source");
	{
		// No size means the whole of the source
		luabind::object size_o = t["size"];
		if(!size_o){
			for(int i = 0; i < 3; i++)
				source.size[i] = source.source_size[i] - source.from[i];
		}
	}
	table_int3(t, "at", source.at, 0, "pack_voxel_volume(): source");

	{
		luabind::object order_o = t["order"];
		parse_order(order_o && luabind::type(order_o) == LUA_TSTRING ?
				luabind::object_cast<ss_>(order_o) : ss_("xyz"),
				source.source_size, source.stride);
	}

	for(int i = 0; i < 3; i++){
		if(source.size[i] < 0)
			throw Exception("pack_voxel_volume(): source size is negative");
		if(source.from[i] < 0 ||
				source.from[i] + source.size[i] > source.source_size[i])
			throw Exception("pack_voxel_volume(): the box to copy is not "
					"inside source_size");
	}

	size_t samples = (size_t)source.source_size[0] *
			(size_t)source.source_size[1] * (size_t)source.source_size[2];
	if(source.data.size() < samples * source.sample_bytes)
		throw Exception(ss_("pack_voxel_volume(): source.data holds ") +
				itos(source.data.size()) + " bytes, source_size wants " +
				itos(samples * source.sample_bytes));

	source.shift = (uint32_t)table_number(t, "shift", 0);
	if(source.shift > 31)
		throw Exception("pack_voxel_volume(): shift is out of range");
	// No mask means all of the bits the format has
	source.mask = source.sample_bytes >= 4 ? 0xffffffffUL :
			((1UL << (source.sample_bytes * 8)) - 1);
	{
		luabind::object mask_o = t["mask"];
		if(mask_o && luabind::type(mask_o) == LUA_TNUMBER)
			source.mask = (uint32_t)luabind::object_cast<double>(mask_o);
	}

	{
		luabind::object field_o = t["field"];
		ss_ field = field_o && luabind::type(field_o) == LUA_TSTRING ?
				luabind::object_cast<ss_>(field_o) : ss_("id");
		if(!resolve_field(field, fmt, source.dst, source.dst_raw))
			throw Exception("pack_voxel_volume(): unknown field \"" + field +
					"\"");
	}

	{
		luabind::object map_o = t["map"];
		if(map_o && luabind::type(map_o) != LUA_TNIL)
			parse_map(t, map_o, source);
	}
	parse_second(t, source);
	{
		luabind::object default_o = t["map_default"];
		if(default_o && luabind::type(default_o) == LUA_TNUMBER)
			source.map_default =
					(int64_t)luabind::object_cast<double>(default_o);
	}
}

static uint32_t read_sample(const char *p, size_t bytes, bool big_endian)
{
	const uint8_t *b = (const uint8_t*)p;
	switch(bytes){
	case 1:
		return b[0];
	case 2:
		return big_endian ? ((uint32_t)b[0] << 8) | b[1] :
				((uint32_t)b[1] << 8) | b[0];
	default:
		return big_endian ?
				((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
				((uint32_t)b[2] << 8) | b[3] :
				((uint32_t)b[3] << 24) | ((uint32_t)b[2] << 16) |
				((uint32_t)b[1] << 8) | b[0];
	}
}

// Copies one source's box into the volume, a voxel at a time through the
// volume's own accessors -- which is where the strides on the source side
// stop mattering to anything but the source.
static void apply_source(VoxelVolume &volume,
		const pv::Region &region, const PackSource &source)
{
	const int w = region.getWidthInVoxels();
	const int h = region.getHeightInVoxels();
	const int d = region.getDepthInVoxels();
	const pv::Vector3DInt32 &lc = region.getLowerCorner();

	for(int sz = 0; sz < source.size[2]; sz++){
		const int vz = source.at[2] + sz - lc.getZ();
		if(vz < 0 || vz >= d)
			continue;
		for(int sy = 0; sy < source.size[1]; sy++){
			const int vy = source.at[1] + sy - lc.getY();
			if(vy < 0 || vy >= h)
				continue;
			for(int sx = 0; sx < source.size[0]; sx++){
				const int vx = source.at[0] + sx - lc.getX();
				if(vx < 0 || vx >= w)
					continue;
				size_t si = (size_t)(
						(source.from[0] + sx) * source.stride[0] +
						(source.from[1] + sy) * source.stride[1] +
						(source.from[2] + sz) * source.stride[2]);
				uint32_t sample = read_sample(
						&source.data[si * source.sample_bytes],
						source.sample_bytes, source.big_endian);
				sample = (sample >> source.shift) & source.mask;

				int64_t key = sample;
				if(source.second.present){
					const PackSecond &sc = source.second;
					uint32_t s2 = read_sample(
							&sc.data[si * sc.sample_bytes],
							sc.sample_bytes, sc.big_endian);
					s2 = (s2 >> sc.shift) & sc.mask;
					key += (int64_t)s2 * sc.scale;
				}

				int64_t value = key;
				if(source.map){
					value = map_lookup(*source.map, key);
					if(value < 0)
						value = source.map_default;
					if(value < 0)
						continue; // A sample nothing maps leaves the voxel be
				}

				const int ax = vx + lc.getX();
				const int ay = vy + lc.getY();
				const int az = vz + lc.getZ();
				if(source.dst_raw){
					// raw is the whole of the first plane; see
					// doc/client_api.txt
					volume.setVoxelAt(ax, ay, az,
							VoxelInstance((uint32_t)value));
				} else {
					// Into the field's own plane, which is not always the
					// first one
					uint32_t w = volume.plane_at(source.dst.plane,
							ax, ay, az);
					source.dst.set(w, (uint32_t)value);
					volume.set_plane_at(source.dst.plane, ax, ay, az, w);
				}
			}
		}
	}
}

// pack_voxel_volume(args) -> the serialized volume, as a string
//
// args.region is {x0, y0, z0, x1, y1, z1}, inclusive corners. args.fill is the
// raw voxel value the whole region starts as. args.sources is an array of box
// copies; see doc/client_api.txt for what one holds.
ss_ pack_voxel_volume(const luabind::object &args, lua_State *L)
{
	if(!args || luabind::type(args) != LUA_TTABLE)
		throw Exception("pack_voxel_volume(): args is not a table");

	// Which bits of a voxel a field name means. args.registry is the world's
	// voxel registry, which is where its format lives; without one the
	// default format applies, which is what every game had before formats
	// existed.
	interface::VoxelFormat format = interface::VoxelFormat::default_cut();
	{
		luabind::object o = args["registry"];
		if(o){
			sp_<interface::VoxelRegistry> voxel_reg =
					luabind::object_cast<sp_<interface::VoxelRegistry>>(o);
			if(voxel_reg == nullptr)
				throw Exception("pack_voxel_volume(): args.registry is not "
						"a voxel registry");
			format = voxel_reg->get_format();
		}
	}

	luabind::object region_o = args["region"];
	if(!region_o || luabind::type(region_o) != LUA_TTABLE)
		throw Exception("pack_voxel_volume(): args.region is not a table");
	int c[6];
	for(int i = 0; i < 6; i++)
		c[i] = (int)table_number_at(region_o, i + 1, 0);
	if(c[3] < c[0] || c[4] < c[1] || c[5] < c[2])
		throw Exception("pack_voxel_volume(): args.region is empty");
	pv::Region region(pv::Vector3DInt32(c[0], c[1], c[2]),
			pv::Vector3DInt32(c[3], c[4], c[5]));

	// The registry's planes, so that a source writing a field of a plane
	// other than the first has somewhere to put it
	VoxelVolume volume(region, format.planes);
	volume.fill(VoxelInstance((uint32_t)table_number(args, "fill", 0)));

	luabind::object sources_o = args["sources"];
	if(sources_o && luabind::type(sources_o) == LUA_TTABLE){
		for(luabind::iterator it(sources_o), end; it != end; ++it){
			PackSource source;
			parse_source(*it, source, format);
			apply_source(volume, region, source);
		}
	}

	return interface::serialize_volume_simple(volume);
}

#define LUABIND_FUNC(name) def("__buildat_" #name, name)

void init_voxel_data(lua_State *L)
{
	using namespace luabind;
	module(L)[
		LUABIND_FUNC(pack_voxel_volume)
	];
}

} // namespace lua_bindings

// vim: set noet ts=4 sw=4:
