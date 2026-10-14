// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/log.h"
#include "interface/voxel.h"
#include "interface/atlas.h"
#include "interface/voxel_selector.h"
#include "lua_bindings/util.h"
#include "lua_bindings/luabind_util.h"
#include "lua_bindings/sandbox_util.h"
#include <luabind/luabind.hpp>
#include <luabind/adopt_policy.hpp>
#include <luabind/object.hpp>
#include <tolua++.h>
#include <sstream>
#include <Vector2.h>
#define MODULE "lua_bindings"

using namespace interface;
using Urho3D::IntVector2;

LUABIND_ENUM_CLASS(FaceDrawType);

namespace lua_bindings {

luabind::object asd_get_total_segments(
		const AtlasSegmentDefinition &def, lua_State *L)
{
	// TODO
	return luabind::object();
}

void asd_set_total_segments(
		AtlasSegmentDefinition &def, luabind::object value_safe, lua_State *L)
{
	GET_SANDBOX_STUFF(v, 2, IntVector2);
	def.total_segments = *v;
}

luabind::object asd_get_select_segment(
		const AtlasSegmentDefinition &def, lua_State *L)
{
	// TODO
	return luabind::object();
}

void asd_set_select_segment(
		AtlasSegmentDefinition &def, luabind::object value, lua_State *L)
{
	GET_SANDBOX_STUFF(v, 2, IntVector2);
	def.select_segment = *v;
}

luabind::object vdef_get_textures(const VoxelDefinition &def, lua_State *L)
{
	luabind::object result = luabind::newtable(L);
	for(size_t i = 0; i < 6; i++){
		result[i+1] = luabind::object(L, def.textures[i]);
	}
	return result;
}

void vdef_set_textures(VoxelDefinition &def, luabind::object value, lua_State *L)
{
	for(size_t i = 0; i < 6; i++){
		def.textures[i] = luabind::object_cast<AtlasSegmentDefinition>(
				value[i+1]);
	}
}

// vdef.extra_textures = {seg, ...}: the textures a shape's quads can wear
// beyond the six faces, indexed from 1 in Lua and addressed as tile 6 and
// over in a quad. See VoxelDefinition::extra_textures.
luabind::object vdef_get_extra_textures(const VoxelDefinition &def,
		lua_State *L)
{
	luabind::object result = luabind::newtable(L);
	for(size_t i = 0; i < def.extra_textures.size(); i++)
		result[i+1] = luabind::object(L, def.extra_textures[i]);
	return result;
}

void vdef_set_extra_textures(VoxelDefinition &def, luabind::object value,
		lua_State *L)
{
	def.extra_textures.clear();
	for(size_t i = 1;; i++){
		luabind::object o = value[i];
		if(!o)
			break;
		def.extra_textures.push_back(
				luabind::object_cast<AtlasSegmentDefinition>(o));
	}
}

luabind::object vdef_get_tile_turns(const VoxelDefinition &def, lua_State *L)
{
	luabind::object result = luabind::newtable(L);
	for(size_t i = 0; i < 6; i++)
		result[i+1] = luabind::object(L, (int)def.tile_turns[i]);
	return result;
}

// vdef.tint_ramp = {0x808080, 0xffffff}: the two ends of the colour the
// tint modifier moves between. See VoxelDefinition::tint_ramp.
luabind::object vdef_get_tint_ramp(const VoxelDefinition &def, lua_State *L)
{
	luabind::object result = luabind::newtable(L);
	for(size_t i = 0; i < 2; i++)
		result[i+1] = luabind::object(L, (double)def.tint_ramp[i]);
	return result;
}

void vdef_set_tint_ramp(VoxelDefinition &def, luabind::object value,
		lua_State *L)
{
	for(size_t i = 0; i < 2; i++){
		luabind::object v = value ? value[i+1] : luabind::object();
		def.tint_ramp[i] = v && luabind::type(v) == LUA_TNUMBER ?
				((uint32_t)luabind::object_cast<double>(v) & 0xffffffUL) :
				0xffffffUL;
	}
}

void vdef_set_tile_turns(VoxelDefinition &def, luabind::object value,
		lua_State *L)
{
	for(size_t i = 0; i < 6; i++){
		luabind::object v = value[i+1];
		def.tile_turns[i] = v && luabind::type(v) == LUA_TNUMBER ?
				(uint8_t)(luabind::object_cast<int>(v) & 3) : 0;
	}
}

// vdef.shape: an array of quads, each
//   {tile = 1...6,
//    p = {x0,y0,z0, x1,y1,z1, x2,y2,z2, x3,y3,z3},
//    uv = {u0,v0, u1,v1, u2,v2, u3,v3}}
// The corners are in the voxel's own cube of -0.5...0.5 and the texture
// coordinates in the tile's own 0...1; see interface/voxel.h.
static luabind::object quad_to_lua(const interface::VoxelQuad &q,
		lua_State *L)
{
	luabind::object quad = luabind::newtable(L);
	quad["tile"] = (int)q.tile + 1;
	quad["connect_dir"] = (int)q.connect_dir;
	luabind::object p = luabind::newtable(L);
	luabind::object uv = luabind::newtable(L);
	for(int c = 0; c < 4; c++){
		for(int a = 0; a < 3; a++)
			p[c * 3 + a + 1] = q.p[c][a];
		for(int a = 0; a < 2; a++)
			uv[c * 2 + a + 1] = q.uv[c][a];
	}
	quad["p"] = p;
	quad["uv"] = uv;
	return quad;
}

static luabind::object vdef_get_shape(const VoxelDefinition &def,
		lua_State *L)
{
	luabind::object result = luabind::newtable(L);
	for(size_t i = 0; i < def.shape.size(); i++)
		result[i + 1] = quad_to_lua(def.shape[i], L);
	return result;
}

static double quad_number(const luabind::object &t, int index)
{
	luabind::object v = t[index];
	if(!v || luabind::type(v) != LUA_TNUMBER)
		throw Exception(ss_()+"VoxelDefinition.shape: entry "+itos(index)+
				" is not a number");
	return luabind::object_cast<double>(v);
}

static interface::VoxelQuad quad_from_lua(const luabind::object &quad)
{
	luabind::object p = quad["p"];
	luabind::object uv = quad["uv"];
	if(!p || luabind::type(p) != LUA_TTABLE ||
			!uv || luabind::type(uv) != LUA_TTABLE)
		throw Exception("VoxelDefinition.shape: a quad wants p and uv");
	interface::VoxelQuad q;
	luabind::object tile = quad["tile"];
	int tile_i = (tile && luabind::type(tile) == LUA_TNUMBER) ?
			(int)luabind::object_cast<double>(tile) : 1;
	// 1...6 are the voxel's own faces and 7 and over are its extra
	// textures, which is what a shape that is more than one thing wants;
	// see VoxelDefinition::extra_textures
	if(tile_i < 1 || tile_i > 256)
		throw Exception(ss_()+"VoxelDefinition.shape: tile "+
				itos(tile_i)+" is not a face or an extra texture");
	q.tile = (uint8_t)(tile_i - 1);
	luabind::object dir = quad["connect_dir"];
	int dir_i = (dir && luabind::type(dir) == LUA_TNUMBER) ?
			(int)luabind::object_cast<double>(dir) : 0;
	if(dir_i < 0 || dir_i > 7)
		throw Exception(ss_()+"VoxelDefinition.shape: connect_dir "+
				itos(dir_i)+" is not a face, zero or seven");
	q.connect_dir = (uint8_t)dir_i;
	for(int c = 0; c < 4; c++){
		for(int a = 0; a < 3; a++)
			q.p[c][a] = (float)quad_number(p, c * 3 + a + 1);
		for(int a = 0; a < 2; a++)
			q.uv[c][a] = (float)quad_number(uv, c * 2 + a + 1);
	}
	return q;
}

static void vdef_set_shape(VoxelDefinition &def, const luabind::object &value)
{
	def.shape.clear();
	if(!value || luabind::type(value) != LUA_TTABLE)
		return;
	for(luabind::iterator it(value), end; it != end; ++it){
		luabind::object quad = *it;
		if(luabind::type(quad) != LUA_TTABLE)
			throw Exception("VoxelDefinition.shape: a quad is not a table");
		def.shape.push_back(quad_from_lua(quad));
	}
}

// vdef.shape_masked: a shape per neighbour mask, as a table of arrays of
// quads -- the same quads vdef.shape takes -- indexed 0...19. A mask with no
// shape of its own can be left out. See interface/voxel.h for what the
// indices mean.
static luabind::object vdef_get_shape_masked(const VoxelDefinition &def,
		lua_State *L)
{
	luabind::object result = luabind::newtable(L);
	for(int m = 0; m < 20; m++){
		size_t from = def.shape_masked_begin[m];
		size_t to = def.shape_masked_begin[m + 1];
		if(from >= to)
			continue;
		luabind::object list = luabind::newtable(L);
		for(size_t i = from; i < to && i < def.shape_masked.size(); i++)
			list[i - from + 1] = quad_to_lua(def.shape_masked[i], L);
		result[m] = list;
	}
	return result;
}

static void vdef_set_shape_masked(VoxelDefinition &def,
		const luabind::object &value)
{
	def.shape_masked.clear();
	for(size_t i = 0; i < 21; i++)
		def.shape_masked_begin[i] = 0;
	if(!value || luabind::type(value) != LUA_TTABLE)
		return;
	for(int m = 0; m < 20; m++){
		def.shape_masked_begin[m] = (uint16_t)def.shape_masked.size();
		luabind::object list = value[m];
		if(!list || luabind::type(list) != LUA_TTABLE)
			continue;
		for(size_t i = 1;; i++){
			luabind::object quad = list[i];
			if(!quad || luabind::type(quad) != LUA_TTABLE)
				break;
			if(def.shape_masked.size() >= 0xffff)
				throw Exception("VoxelDefinition.shape_masked: too many "
						"quads");
			def.shape_masked.push_back(quad_from_lua(quad));
		}
	}
	def.shape_masked_begin[20] = (uint16_t)def.shape_masked.size();
}

// voxel_reg:set_format{plane_bits = 32, id = {shift = 0, width = 16}, ...}
//
// The roles are id, light_sky, light_lamp, param and color, plus the
// modifiers tint, wetness, grain, gloss, speckle, emission, sag_top and
// sag_bottom; a role left out is not bound. See VoxelFormat in interface/voxel.h and doc/client_api.txt.
static interface::VoxelField field_from_lua(const luabind::object &t,
		const char *name)
{
	luabind::object f = t[name];
	if(!f || luabind::type(f) != LUA_TTABLE)
		return interface::VoxelField();
	auto number = [&](const char *key, double def){
		luabind::object v = f[key];
		if(!v || luabind::type(v) != LUA_TNUMBER)
			return def;
		return luabind::object_cast<double>(v);
	};
	return interface::VoxelField(
			(uint8_t)number("plane", 0),
			(uint8_t)number("shift", 0),
			(uint8_t)number("width", 0));
}

// voxel_reg:set_format("blocks"): a layout by its name (VoxelFormat::preset())
static void vreg_set_format(VoxelRegistry &reg, const luabind::object &t)
{
	if(t && luabind::type(t) == LUA_TSTRING){
		interface::VoxelFormat format;
		ss_ name = luabind::object_cast<ss_>(t);
		if(!interface::VoxelFormat::preset(name, &format))
			throw Exception("set_format(): no layout named \""+name+"\"");
		reg.set_format(format);
		return;
	}
	if(!t || luabind::type(t) != LUA_TTABLE)
		throw Exception("set_format(): argument is not a table or a name");
	interface::VoxelFormat format;
	{
		// plane_bits is the width of the game's own first plane
		luabind::object v = t["plane_bits"];
		if(v && luabind::type(v) == LUA_TNUMBER){
			format.planes.clear();
			format.planes.push_back(interface::VoxelPlane("",
					(uint8_t)luabind::object_cast<double>(v)));
		}
	}
	{
		// planes = {{name = "mod:heat", bits = 8}, ...}: the planes after
		// the game's own. A field of one names it by index in `plane`.
		luabind::object v = t["planes"];
		if(v && luabind::type(v) == LUA_TTABLE){
			for(size_t i = 1;; i++){
				luabind::object pt = v[i];
				if(!pt || luabind::type(pt) != LUA_TTABLE)
					break;
				luabind::object name = pt["name"];
				luabind::object bits = pt["bits"];
				if(!name || luabind::type(name) != LUA_TSTRING)
					throw Exception(ss_()+"set_format(): plane "+itos(i)+
							" has no name");
				format.planes.push_back(interface::VoxelPlane(
						luabind::object_cast<ss_>(name),
						bits && luabind::type(bits) == LUA_TNUMBER ?
						(uint8_t)luabind::object_cast<double>(bits) : 8));
			}
		}
	}
	format.id = field_from_lua(t, "id");
	format.light_sky = field_from_lua(t, "light_sky");
	format.light_lamp = field_from_lua(t, "light_lamp");
	format.param = field_from_lua(t, "param");
	format.color = field_from_lua(t, "color");
	format.tint = field_from_lua(t, "tint");
	format.wetness = field_from_lua(t, "wetness");
	format.grain = field_from_lua(t, "grain");
	format.gloss = field_from_lua(t, "gloss");
	format.speckle = field_from_lua(t, "speckle");
	format.emission = field_from_lua(t, "emission");
	format.sag_top = field_from_lua(t, "sag_top");
	format.sag_bottom = field_from_lua(t, "sag_bottom");
	reg.set_format(format);
}

// voxel_reg:set_look_rules{fallback = 1, rules = {
//     {result = 3, when = {{field = "wetness", lo = 8, hi = 15}}}, ...}}
//
// How a voxel's definition is found, for a world whose voxels have no type
// id: an ordered list of rules, first match wins. A rule with no `when`
// claims everything left. field names one of the format's roles, or is a
// table {shift = ..., width = ...} for a field of the game's own that no
// role covers. lo and hi both default to the whole range, so a clause with
// only one of them is "at least" or "at most". See VoxelSelector in
// interface/voxel_selector.h.
static interface::VoxelField clause_field_from_lua(
		const interface::VoxelFormat &format, const luabind::object &v)
{
	if(!v)
		throw Exception("set_look_rules(): a clause has no field");
	if(luabind::type(v) == LUA_TTABLE){
		auto number = [&](const char *key, double def){
			luabind::object f = v[key];
			if(!f || luabind::type(f) != LUA_TNUMBER)
				return def;
			return luabind::object_cast<double>(f);
		};
		return interface::VoxelField(
				(uint8_t)number("plane", 0),
				(uint8_t)number("shift", 0),
				(uint8_t)number("width", 0));
	}
	if(luabind::type(v) != LUA_TSTRING)
		throw Exception("set_look_rules(): a clause's field is neither a "
				"role name nor a table");
	ss_ name = luabind::object_cast<ss_>(v);
	struct Named { cc_ *name; const interface::VoxelField &f; };
	const Named fields[] = {
		{"id", format.id}, {"light_sky", format.light_sky},
		{"light_lamp", format.light_lamp}, {"param", format.param},
		{"color", format.color}, {"tint", format.tint},
		{"wetness", format.wetness}, {"grain", format.grain},
		{"gloss", format.gloss}, {"speckle", format.speckle},
		{"emission", format.emission}, {"sag_top", format.sag_top},
		{"sag_bottom", format.sag_bottom},
	};
	for(const Named &n : fields){
		if(name == n.name)
			return n.f;
	}
	throw Exception(ss_()+"set_look_rules(): \""+name+"\" is not a role");
}

static void vreg_set_look_rules(VoxelRegistry &reg, const luabind::object &t)
{
	if(!t || luabind::type(t) != LUA_TTABLE)
		throw Exception("set_look_rules(): argument is not a table");
	const interface::VoxelFormat &format = reg.get_format();
	interface::VoxelSelector selector;
	selector.kind = interface::VoxelSelector::RULES;
	{
		luabind::object v = t["fallback"];
		if(v && luabind::type(v) == LUA_TNUMBER)
			selector.fallback = (interface::VoxelTypeId)
					luabind::object_cast<double>(v);
	}
	luabind::object rules = t["rules"];
	if(!rules || luabind::type(rules) != LUA_TTABLE)
		throw Exception("set_look_rules(): there are no rules");
	for(size_t i = 1;; i++){
		luabind::object rt = rules[i];
		if(!rt || luabind::type(rt) != LUA_TTABLE)
			break;
		interface::VoxelRule rule;
		luabind::object result = rt["result"];
		if(!result || luabind::type(result) != LUA_TNUMBER)
			throw Exception(ss_()+"set_look_rules(): rule "+itos(i)+
					" has no result");
		rule.result = (interface::VoxelTypeId)
				luabind::object_cast<double>(result);
		luabind::object when = rt["when"];
		if(when && luabind::type(when) == LUA_TTABLE){
			for(size_t j = 1;; j++){
				luabind::object ct = when[j];
				if(!ct || luabind::type(ct) != LUA_TTABLE)
					break;
				auto number = [&](const char *key, double def){
					luabind::object f = ct[key];
					if(!f || luabind::type(f) != LUA_TNUMBER)
						return def;
					return luabind::object_cast<double>(f);
				};
				interface::VoxelField field =
						clause_field_from_lua(format, ct["field"]);
				rule.clauses.push_back(interface::VoxelRuleClause(field,
						(uint32_t)number("lo", 0),
						(uint32_t)number("hi", (double)field.mask())));
			}
		}
		selector.rules.push_back(rule);
	}
	reg.set_look_selector(selector);
}

static ss_ vreg_dump_format(VoxelRegistry &reg)
{
	return reg.get_format().dump();
}

// Which type a voxel is under this registry's format, which is the only
// thing that knows where the id is in the word. VoxelInstance's own id is
// the legacy layout and is wrong for every world that says otherwise -- a
// client asking what it is pointing at has to ask here.
static uint32_t vreg_id_of(VoxelRegistry &reg, const interface::VoxelInstance &v)
{
	return reg.get_format().id_of(v.data);
}

// The same voxel with another type id and everything else -- its light, its
// param -- as it was: what a client writes where it predicts a dig or a
// place ([PREDICTION]), so the hole is lit the way the server will light it
static interface::VoxelInstance vreg_with_id(VoxelRegistry &reg,
		const interface::VoxelInstance &v, uint32_t id)
{
	interface::VoxelInstance out = v;
	const interface::VoxelFormat &f = reg.get_format();
	if(f.id.bound())
		f.id.set(out.data, id);
	return out;
}

// The two light nibbles of a voxel, 0..15 each, under the format: what the
// held item is lit by is the light where the player stands ([WIELD_MESH])
static uint32_t vreg_light_sky_of(VoxelRegistry &reg, const interface::VoxelInstance &v)
{
	const interface::VoxelFormat &f = reg.get_format();
	return f.light_sky.bound() ? f.light_sky.get(v.data) : 15;
}
static uint32_t vreg_light_lamp_of(VoxelRegistry &reg, const interface::VoxelInstance &v)
{
	const interface::VoxelFormat &f = reg.get_format();
	return f.light_lamp.bound() ? f.light_lamp.get(v.data) : 0;
}

// The boxes of a voxel, {{x0, y0, z0, x1, y1, z1}, ...}, the variant's own
// when its param picks one that has them; nil for the cube.
// collision_boxes_of is what stops a player as the client's physics takes it
// (nil for a voxel that stops nothing too -- physically_solid is the question
// for that); selection_boxes_of what is pointed at ([VL_RAIL_BOXES]).
static luabind::object vreg_boxes_of(VoxelRegistry &reg,
		const interface::VoxelInstance &v, lua_State *L,
		sv_<float> interface::VoxelDefinition::*def_boxes,
		sv_<float> interface::VoxelVariant::*var_boxes)
{
	const interface::VoxelFormat &f = reg.get_format();
	const interface::VoxelDefinition *def =
			reg.get((interface::VoxelTypeId)f.id_of(v.data));
	if(!def)
		return luabind::object();
	const sv_<float> *boxes = &(def->*def_boxes);
	if(!def->variants.empty() && f.param.bound()){
		const size_t i = def->variant_of_param[f.param.get(v.data) & 0xff];
		if(i < def->variants.size() && !(def->variants[i].*var_boxes).empty())
			boxes = &(def->variants[i].*var_boxes);
	}
	if(boxes->empty())
		return luabind::object();
	luabind::object t = luabind::newtable(L);
	for(size_t b = 0; b + 6 <= boxes->size(); b += 6){
		luabind::object box = luabind::newtable(L);
		for(size_t k = 0; k < 6; k++)
			box[k + 1] = (*boxes)[b + k];
		t[b / 6 + 1] = box;
	}
	return t;
}

static luabind::object vreg_collision_boxes_of(VoxelRegistry &reg,
		const interface::VoxelInstance &v, lua_State *L)
{
	const interface::VoxelFormat &f = reg.get_format();
	const interface::VoxelDefinition *def =
			reg.get((interface::VoxelTypeId)f.id_of(v.data));
	if(!def || def->collision_boxes.empty())
		return luabind::object();
	return vreg_boxes_of(reg, v, L, &interface::VoxelDefinition::collision_boxes,
			&interface::VoxelVariant::collision_boxes);
}

static luabind::object vreg_selection_boxes_of(VoxelRegistry &reg,
		const interface::VoxelInstance &v, lua_State *L)
{
	return vreg_boxes_of(reg, v, L, &interface::VoxelDefinition::selection_boxes,
			&interface::VoxelVariant::selection_boxes);
}

// By value rather than through VoxelRegistry::get()'s const reference, which
// luabind will not bind a Lua number to: a number is a temporary and there
// is nothing for the reference to point at
static const interface::VoxelDefinition* vreg_get_by_id(VoxelRegistry &reg,
		uint32_t id)
{
	return reg.get((interface::VoxelTypeId)id);
}

// describe_lights(atlas_reg) -> JSON: every atlas segment a light-emitting
// voxel's faces draw, with the voxel's light_source (1..15), for a mesh
// dump's reader -- the path trace gives those tiles an emission
// ([LAMP_REF]). Main thread only, since the cache is built with the atlas.
static ss_ vreg_describe_lights(VoxelRegistry &reg, sp_<AtlasRegistry> atlas_reg)
{
	std::ostringstream os;
	os<<"[";
	bool first = true;
	const size_t n = reg.get_count();
	for(size_t id = 1; id <= n; id++){
		const interface::VoxelDefinition *def =
				reg.get((interface::VoxelTypeId)id);
		if(!def || def->light_source == 0)
			continue;
		const interface::CachedVoxelDefinition *c = reg.get_cached(
				(interface::VoxelTypeId)id, atlas_reg.get());
		if(!c)
			continue;
		for(size_t face = 0; face < 6; face++){
			const interface::AtlasSegmentReference &ref = c->textures[face];
			if(ref.atlas_id == interface::ATLAS_UNDEFINED)
				continue;
			os<<(first ? "\n" : ",\n")<<"{\"atlas\":"<<ref.atlas_id
					<<",\"segment\":"<<ref.segment_id<<",\"light\":"
					<<(int)def->light_source<<",\"node\":\""
					<<def->name.block_name<<"\"}";
			first = false;
		}
	}
	os<<"\n]\n";
	return os.str();
}

// vdef.variants: what the voxel's param does to how it is drawn, as an array
// of variants. One is
//
//   {shape = {<quads>}, tile_order = {0,1,2,3,4,5}, tile_turns = {0,...},
//    color = 0xffffff, liquid_top = 0.5, params = {0, 4, 8}}
//
// where params is which param values pick this variant. Everything is
// optional: a variant with no shape wears the definition's own, and a param
// value no variant claims is drawn as if the param changed nothing. See
// VoxelVariant in interface/voxel.h.
static void vdef_set_variants(VoxelDefinition &def,
		const luabind::object &value)
{
	def.variants.clear();
	for(size_t i = 0; i < 256; i++)
		def.variant_of_param[i] = 0;
	if(!value || luabind::type(value) != LUA_TTABLE)
		return;
	// Index 0 is what an unclaimed param gets, so it has to mean "nothing
	// special": a variant of the definition's own shape and no tint
	def.variants.push_back(interface::VoxelVariant());
	for(luabind::iterator it(value), end; it != end; ++it){
		luabind::object t = *it;
		if(luabind::type(t) != LUA_TTABLE)
			throw Exception("VoxelDefinition.variants: a variant is not a "
					"table");
		if(def.variants.size() >= 256)
			throw Exception("VoxelDefinition.variants: too many variants");
		interface::VoxelVariant var;
		{
			luabind::object shape = t["shape"];
			if(shape && luabind::type(shape) == LUA_TTABLE){
				for(luabind::iterator qi(shape), qend; qi != qend; ++qi){
					luabind::object quad = *qi;
					if(luabind::type(quad) != LUA_TTABLE)
						throw Exception("VoxelDefinition.variants: a quad is "
								"not a table");
					var.shape.push_back(quad_from_lua(quad));
				}
			}
		}
		for(const char *key : {"tile_order", "tile_turns"}){
			luabind::object list = t[key];
			if(!list || luabind::type(list) != LUA_TTABLE)
				continue;
			for(size_t i = 0; i < 6; i++){
				luabind::object v = list[i + 1];
				if(!v || luabind::type(v) != LUA_TNUMBER)
					continue;
				uint8_t n = (uint8_t)luabind::object_cast<double>(v);
				if(key[5] == 'o'){
					if(n > 5)
						throw Exception("VoxelDefinition.variants: "
								"tile_order is not a face");
					var.tile_order[i] = n;
				} else {
					var.tile_turns[i] = n;
				}
			}
		}
		{
			luabind::object v = t["color"];
			if(v && luabind::type(v) == LUA_TNUMBER)
				var.color = (uint32_t)luabind::object_cast<double>(v)
						& 0xffffffUL;
		}
		{
			luabind::object v = t["liquid_top"];
			if(v && luabind::type(v) == LUA_TNUMBER)
				var.liquid_top = (float)luabind::object_cast<double>(v);
		}
		uint8_t index = (uint8_t)def.variants.size();
		def.variants.push_back(var);
		luabind::object params = t["params"];
		if(!params || luabind::type(params) != LUA_TTABLE)
			throw Exception("VoxelDefinition.variants: a variant has no "
					"params");
		for(luabind::iterator pi(params), pend; pi != pend; ++pi){
			luabind::object v = *pi;
			if(luabind::type(v) != LUA_TNUMBER)
				throw Exception("VoxelDefinition.variants: a param is not a "
						"number");
			int param = (int)luabind::object_cast<double>(v);
			if(param < 0 || param > 255)
				throw Exception("VoxelDefinition.variants: param "+
						itos(param)+" is out of range");
			def.variant_of_param[param] = index;
		}
	}
}

static luabind::object vdef_get_variants(const VoxelDefinition &def,
		lua_State *L)
{
	luabind::object result = luabind::newtable(L);
	// Variant 0 is the engine's own "nothing special" entry and is not one
	// the caller wrote
	for(size_t i = 1; i < def.variants.size(); i++){
		const interface::VoxelVariant &var = def.variants[i];
		luabind::object t = luabind::newtable(L);
		luabind::object shape = luabind::newtable(L);
		for(size_t q = 0; q < var.shape.size(); q++)
			shape[q + 1] = quad_to_lua(var.shape[q], L);
		t["shape"] = shape;
		luabind::object order = luabind::newtable(L);
		luabind::object turns = luabind::newtable(L);
		for(size_t f = 0; f < 6; f++){
			order[f + 1] = (int)var.tile_order[f];
			turns[f + 1] = (int)var.tile_turns[f];
		}
		t["tile_order"] = order;
		t["tile_turns"] = turns;
		t["color"] = (double)var.color;
		t["liquid_top"] = var.liquid_top;
		luabind::object params = luabind::newtable(L);
		size_t n = 0;
		for(size_t p = 0; p < 256; p++){
			if(def.variant_of_param[p] == i)
				params[++n] = (int)p;
		}
		t["params"] = params;
		result[i] = t;
	}
	return result;
}

sp_<VoxelRegistry> createVoxelRegistry(lua_State *L)
{
	return sp_<VoxelRegistry>(
			interface::createVoxelRegistry());
}

void init_voxel(lua_State *L)
{
	using namespace luabind;

	module(L)[
		class_<VoxelName, bases<>, sp_<VoxelName>>("__buildat_VoxelName")
			.def(constructor<>())
			.def_readwrite("block_name", &VoxelName::block_name)
			.def_readwrite("segment_x", &VoxelName::segment_x)
			.def_readwrite("segment_y", &VoxelName::segment_y)
			.def_readwrite("segment_z", &VoxelName::segment_z)
			.def_readwrite("rotation_primary", &VoxelName::rotation_primary)
			.def_readwrite("rotation_secondary", &VoxelName::rotation_secondary)
		,
		class_<AtlasSegmentDefinition, bases<>, sp_<AtlasSegmentDefinition>>(
				"__buildat_AtlasSegmentDefinition")
			.def(constructor<>())
			.def_readwrite("resource_name",
					&AtlasSegmentDefinition::resource_name)
			.property("total_segments",
					&asd_get_total_segments, &asd_set_total_segments)
			.property("select_segment",
					&asd_get_select_segment, &asd_set_select_segment)
			.def_readwrite("lod_simulation",
					&AtlasSegmentDefinition::lod_simulation)
			.def_readwrite("roughness", &AtlasSegmentDefinition::roughness)
			.def_readwrite("spec_strength",
					&AtlasSegmentDefinition::spec_strength)
			.def_readwrite("bumpiness", &AtlasSegmentDefinition::bumpiness)
			.def_readwrite("translucency",
					&AtlasSegmentDefinition::translucency)
			.def_readwrite("spots", &AtlasSegmentDefinition::spots)
.def_readwrite("static_spots", &AtlasSegmentDefinition::static_spots)
		,
		class_<VoxelDefinition, bases<>, sp_<VoxelDefinition>>(
				"__buildat_VoxelDefinition")
			.def(constructor<>())
			.def_readwrite("name", &VoxelDefinition::name)
			.def_readwrite("id", &VoxelDefinition::id)
			.property("textures", &vdef_get_textures, &vdef_set_textures)
			.property("extra_textures", &vdef_get_extra_textures,
					&vdef_set_extra_textures)
			.property("tile_turns", &vdef_get_tile_turns,
					&vdef_set_tile_turns)
			.def_readwrite("face_draw_type", &VoxelDefinition::face_draw_type)
			.def_readwrite("edge_material_id", &VoxelDefinition::edge_material_id)
			.def_readwrite("physically_solid", &VoxelDefinition::physically_solid)
			.def_readwrite("fully_empty", &VoxelDefinition::fully_empty)
			.def_readwrite("uv_scale", &VoxelDefinition::uv_scale)
			// Across and up ([SIGIL_ROUND]); nought is "the same as
			// uv_scale", which is every definition that does not say
			.def_readwrite("uv_scale_v", &VoxelDefinition::uv_scale_v)
			.property("shape", &vdef_get_shape, &vdef_set_shape)
			.property("shape_masked", &vdef_get_shape_masked,
					&vdef_set_shape_masked)
			.property("variants", &vdef_get_variants, &vdef_set_variants)
			.property("tint_ramp", &vdef_get_tint_ramp, &vdef_set_tint_ramp)
			.def_readwrite("sag_extent", &VoxelDefinition::sag_extent)
			.def_readwrite("shape_double_sided",
					&VoxelDefinition::shape_double_sided)
			.def_readwrite("shape_lit_from_above",
					&VoxelDefinition::shape_lit_from_above)
			.def_readwrite("translucent", &VoxelDefinition::translucent)
			.def_readwrite("alpha_masked", &VoxelDefinition::alpha_masked)
			.def_readwrite("shape_group", &VoxelDefinition::shape_group)
			.def_readwrite("is_liquid", &VoxelDefinition::is_liquid)
			.def_readwrite("climbable", &VoxelDefinition::climbable)
			.def_readwrite("move_resistance",
					&VoxelDefinition::move_resistance)
			.def_readwrite("bouncy", &VoxelDefinition::bouncy)
			.def_readwrite("slippery", &VoxelDefinition::slippery)
			.def_readwrite("disable_jump", &VoxelDefinition::disable_jump)
			.def_readwrite("disable_descend",
					&VoxelDefinition::disable_descend)
			.def_readwrite("swimmable", &VoxelDefinition::swimmable)
			.def_readwrite("pointable", &VoxelDefinition::pointable)
			.def_readwrite("liquid_top", &VoxelDefinition::liquid_top)
			.def_readwrite("connect_group", &VoxelDefinition::connect_group)
			.def_readwrite("connect_mask", &VoxelDefinition::connect_mask)
			.def_readwrite("connect_to_solid",
					&VoxelDefinition::connect_to_solid)
			.enum_("FaceDrawType")[
				value("FACEDRAWTYPE_NEVER", (int)FaceDrawType::NEVER),
				value("FACEDRAWTYPE_ALWAYS", (int)FaceDrawType::ALWAYS),
				value("FACEDRAWTYPE_ON_EDGE", (int)FaceDrawType::ON_EDGE)
			]
			.enum_("EdgeMaterialId")[
				value("EDGEMATERIALID_EMPTY", EDGEMATERIALID_EMPTY),
				value("EDGEMATERIALID_GROUND", EDGEMATERIALID_GROUND)
			]
		,
		class_<VoxelRegistry, bases<>, sp_<VoxelRegistry>>("VoxelRegistry")
			.def("add_voxel", &VoxelRegistry::add_voxel)
			.def("get_count", &VoxelRegistry::get_count)
			.def("get_by_id", &vreg_get_by_id)
			.def("describe_lights", &vreg_describe_lights)
			.def("get_by_name", (const VoxelDefinition*(VoxelRegistry::*)
					(const VoxelName&)) &VoxelRegistry::get)
			.def("serialize", (ss_(VoxelRegistry::*) ())
					&VoxelRegistry::serialize)
			.def("deserialize", (void(VoxelRegistry::*) (const ss_ &))
					&VoxelRegistry::deserialize)
			.def("set_format", &vreg_set_format)
			.def("set_look_rules", &vreg_set_look_rules)
			.def("dump_format", &vreg_dump_format)
			.def("id_of", &vreg_id_of)
			.def("with_id", &vreg_with_id)
			.def("light_sky_of", &vreg_light_sky_of)
			.def("light_lamp_of", &vreg_light_lamp_of)
			.def("collision_boxes_of", &vreg_collision_boxes_of)
			.def("selection_boxes_of", &vreg_selection_boxes_of)
		,
		def("__buildat_createVoxelRegistry", &createVoxelRegistry)
	];
}

} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
