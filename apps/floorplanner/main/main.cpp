// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/floorplanner: the document, its validation, its save and the
// accounts. doc/plan/floorplanner_plan.md is the spec; this is [FP_DOC].
//
// The server holds the document and is its only writer. A client sends a
// batch of operations, the server applies it whole or not at all and
// broadcasts what changed. Everything a client sends is checked here
// against the schema, whatever the sender's privileges.
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/sha256.h"
#include "interface/fs.h"
#include "interface/server_config.h"
#include "interface/os.h"
#include "client_file/api.h"
#include "network/api.h"
#include "storage/api.h"
#include "accounts/api.h"
#include "core/log.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/map.hpp>
#include <cereal/types/vector.hpp>
#include <deque>
#include <cereal/types/string.hpp>
#include <cereal/types/utility.hpp>
#include <map>
#include <random>
#include <sstream>
#include <fstream>
#include <functional>
#include <cmath>
#include <algorithm>
#include <ctime>
#define MODULE "main"

using interface::Event;
using storage::pack;
using storage::unpack;

namespace floorplanner {

// Kept in the save; bumped when a stored entity's meaning changes
static const int32_t SCHEMA_VERSION = 3;
static const size_t MAX_ENTITIES = 100000;
static const size_t MAX_OPS_PER_BATCH = 2000;
static const size_t MAX_STRING = 200;
static const size_t MAX_LIST = 1000;
// Plus or minus 100 km: far outside any building, far inside int32
static const int32_t MAX_COORD = 100000000;
// A voxel volume's cells run -128..127 on each axis, and it holds at most
// this many voxels
static const int32_t VOXEL_RANGE = 128;
static const size_t MAX_VOXELS = 200000;
// How many copies of the plan are kept, one made each time it is loaded
// **Backups by time** (user, 2026-09-30): a plan's backups/<unix time>,
// made when it opens changed since the last one and each hour it stays
// open and changes. All of the last hour are kept, then the oldest of each
// hour for a day, of each day for a week and of each week to BACKUP_KEEP_S:
// the oldest, since the state to go back to is the one before a change
// that came later in the same hour.
static const int64_t BACKUP_EVERY_S = 3600;
static const int64_t BACKUP_KEEP_S = 60 * 86400;

// Which of a plan's backups (their times, any order) thinning drops at
// `now`; the newest is always kept
static sv_<int64_t> backups_to_drop(sv_<int64_t> ids, int64_t now)
{
	std::sort(ids.begin(), ids.end());
	set_<ss_> buckets;
	sv_<int64_t> drop;
	for(size_t i = 0; i < ids.size(); i++){
		const int64_t age = now - ids[i];
		ss_ bucket;
		if(age < 3600)
			bucket = "a"+itos(ids[i]);
		else if(age < 86400)
			bucket = "h"+itos(ids[i] / 3600);
		else if(age < 7 * 86400)
			bucket = "d"+itos(ids[i] / 86400);
		else if(age < BACKUP_KEEP_S)
			bucket = "w"+itos(ids[i] / (7 * 86400));
		if(i + 1 < ids.size() && (bucket.empty() || buckets.count(bucket)))
			drop.push_back(ids[i]);
		else
			buckets.insert(bucket);
	}
	return drop;
}

static void check_backups_to_drop()
{
	const int64_t now = 100 * 86400;
	auto dropped = [&](const sv_<int64_t> &ids){
		sv_<int64_t> d = backups_to_drop(ids, now);
		std::sort(d.begin(), d.end());
		return d;
	};
	// The last hour all stays
	if(!dropped({now - 10, now - 20, now - 3000}).empty())
		throw Exception("backups_to_drop: dropped from the last hour");
	// Two in one hour of the day: the newer goes
	const int64_t h = now - 5 * 3600;
	const int64_t h0 = h - h % 3600;
	if(dropped({h0 + 10, h0 + 20, now}) != sv_<int64_t>{h0 + 20})
		throw Exception("backups_to_drop: kept two in an hour");
	if(!dropped({now - 2 * 3600, now - 4 * 3600, now}).empty())
		throw Exception("backups_to_drop: dropped hours apart");
	// Past the keep, all go but the newest
	if(dropped({now - BACKUP_KEEP_S - 10, now - BACKUP_KEEP_S - 20}) !=
			sv_<int64_t>{now - BACKUP_KEEP_S - 20})
		throw Exception("backups_to_drop: kept an old one");
	// Days in the week: the oldest of each
	const int64_t d = now - now % 86400;
	if(dropped({d - 2 * 86400 + 10, d - 2 * 86400 + 20, d - 3 * 86400 + 10,
			now}) != sv_<int64_t>{d - 2 * 86400 + 20})
		throw Exception("backups_to_drop: days");
}

// A backup's time as a person reads it: the server's clock, and how long
// ago, which is the same in every time zone
static ss_ backup_label(int64_t id, int64_t now)
{
	if(id < 0)
		return "older backup "+itos(-id)+" (time unknown)";
	char buf[32] = {};
	const time_t t = (time_t)id;
	struct tm tmv;
#ifdef _WIN32
	localtime_s(&tmv, &t);
#else
	localtime_r(&t, &tmv);
#endif
	strftime(buf, sizeof buf, "%Y-%m-%d %H:%M", &tmv);
	const int64_t age = std::max<int64_t>(0, now - id);
	ss_ ago = age < 3600 ? itos(age / 60)+" min" : age < 2 * 86400 ?
			itos(age / 3600)+" h" : itos(age / 86400)+" days";
	return ss_(buf)+" ("+ago+" ago)";
}
// A background image a client is sent at most
static const uint64_t MAX_IMAGE_BYTES = 20 * 1024 * 1024;
// A plan as a file ([FP_EXPORT]): what an import may be, at most
static const size_t MAX_IMPORT_BYTES = 64 * 1024 * 1024;
static const size_t MAX_IMPORT_IMAGES = 64;
static const char *EXPORT_MAGIC = "buildat-floorplan";
static const int32_t EXPORT_FORMAT = 1;

struct Entity
{
	int32_t id = 0;
	ss_ type;
	std::map<ss_, int32_t> ints;
	std::map<ss_, ss_> strs;
	std::map<ss_, sv_<int32_t>> lists;

	template<class Archive>
	void serialize(Archive &archive){
		archive(id, type, ints, strs, lists);
	}
};

// A plan as a file ([FP_EXPORT]): what the plan is, and nothing of who may
// use it -- no owner, roles or public setting
struct ExportImage
{
	ss_ name;
	ss_ data;

	template<class Archive>
	void serialize(Archive &archive){
		archive(name, data);
	}
};
struct PlanFile
{
	ss_ magic;
	int32_t format = 0;
	int32_t schema = 0;
	sv_<Entity> ents;
	// A voxel volume's definition id -> its voxels
	std::map<int32_t, std::map<int32_t, int32_t>> voxels;
	sv_<ExportImage> images;

	template<class Archive>
	void serialize(Archive &archive){
		archive(magic, format, schema, ents, voxels, images);
	}
};

// What an entity holding a reference does when the referenced one goes
enum class OnDelete {
	None,     // not a reference
	Cascade,  // the holder goes too
	Restrict, // the delete is refused
	Remove,   // a list drops the id; below min_len the holder goes
};

struct IntField {
	const char *name;
	int32_t min, max, def;
	const char *ref;    // entity type, or nullptr
	OnDelete on_delete;
	bool optional;      // a reference may be 0
	IntField(const char *name, int32_t min, int32_t max, int32_t def,
			const char *ref = nullptr, OnDelete on_delete = OnDelete::None,
			bool optional = false):
		name(name), min(min), max(max), def(def), ref(ref),
		on_delete(on_delete), optional(optional){}
};
struct StrField {
	const char *name;
	const char *def;
};
struct ListField {
	const char *name;
	const char *ref;
	OnDelete on_delete;
	size_t min_len;
};
struct TypeSchema {
	const char *type;
	sv_<IntField> ints;
	sv_<StrField> strs;
	sv_<ListField> lists;
	bool singleton; // exists from the start; not created or deleted
	TypeSchema(const char *type, sv_<IntField> ints, sv_<StrField> strs,
			sv_<ListField> lists, bool singleton = false):
		type(type), ints(ints), strs(strs), lists(lists),
		singleton(singleton){}
};

// What a definition is. A voxel volume comes with [FP_VOXELS].
enum DefKind { DK_BOX, DK_VOXEL, DK_OPENING, DK_DOOR, DK_WINDOW, DK_SWITCH,
	DK_STAIRS, DK_COUNT };

// Material types, as the palette's `kind` field holds them. The shader and
// the client's palette editor use the same numbers.
enum MaterialKind { MK_DRYWALL, MK_WOOD, MK_STONE, MK_WALLPAPER, MK_LAMP,
	MK_GLASS, MK_METAL, MK_TILE, MK_FABRIC, MK_PLASTER, MK_PANEL, MK_COUNT };

static const sv_<TypeSchema> SCHEMA = {
	{"settings", {
		{"ceiling", 1000, 10000, 2600},
		{"cut", 100, 10000, 1200},
		{"default_edit", 0, 1, 1},
		// The site and the moment the 3D view is lit for ([FP_DAYLIGHT]):
		// north in degrees clockwise from the plan view's up, the latitude,
		// the day of the year and the minute of the (solar) day, a
		// time-lapse's speed in minutes a second (0 still; -1 each viewer's
		// own clock for the hour, -2 their clock and calendar), and the
		// ground: 0 by the season, 1 green, 2 yellow, 3 snow; the sky: 0
		// clear, 1 overcast ([FP_OVERCAST])
		{"north", 0, 359, 0},
		{"latitude", -90, 90, 65},
		{"day", 1, 365, 172},
		{"minute", 0, 1439, 720},
		{"lapse", -2, 60, 0},
		{"ground", 0, 3, 0},
		{"sky", 0, 1, 0},
		// The treeline drawn on the horizon under PBR: a tree's height over
		// its distance, in tenths of a percent (75: 15 m at 200 m); 0 none
		{"treeline", 0, 500, 75},
		{"grid", 1, 1000, 100}, // mm, what the plan snaps to
		// Floor to floor, where "Add a floor above" puts one ([FP_LAYOUTS])
		{"floor_step", 1000, 20000, 3000},
		// The branch point drawn as a ghost in 2D ([FP_GHOST])
		{"ghost", 0, 1, 0},
	}, {}, {}, true},
	// A floor or a building placed in the world ([FP_LAYOUTS]): its own
	// coordinates turned by yaw (millidegrees) and moved to x, y, z. The
	// layouts of one group are one building.
	{"layout", {
		{"x", -MAX_COORD, MAX_COORD, 0},
		{"y", -MAX_COORD, MAX_COORD, 0},
		{"z", -MAX_COORD, MAX_COORD, 0},
		{"yaw", 0, 359999, 0},
		// The foundation under a building's lowest floor when it is above
		// the ground (user); 0 the plain grey
		{"mat_foundation", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
	}, {
		{"name", "Ground floor"},
		{"group", "Building"},
	}, {}},
	// Walls and rooms are their nodes' layout's
	// simplified: nothing checks that a wall's or a room's nodes are in one
	// layout; the client only joins nodes of the one it edits
	{"node", {
		{"layout", 1, INT32_MAX, 0, "layout", OnDelete::Restrict},
		{"x", -MAX_COORD, MAX_COORD, 0},
		{"z", -MAX_COORD, MAX_COORD, 0},
	}, {}, {}},
	{"wall", {
		{"a", 1, INT32_MAX, 0, "node", OnDelete::Cascade},
		{"b", 1, INT32_MAX, 0, "node", OnDelete::Cascade},
		{"thickness", 1, 2000, 120},
		{"justify", 0, 3, 0},     // 0 centered, 1 left, 2 right of a->b, 3 custom
		{"shift", -10000, 10000, 0}, // custom: the middle, mm left of a->b
		{"height", 0, 20000, 0},  // 0: full height
		{"hang", 0, 1, 0},        // 1: from the ceiling down
		{"mat_left", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
		{"mat_right", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
		{"mat_core", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
	}, {}, {}},
	{"room", {
		{"mat_floor", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
		{"mat_ceiling", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
		{"ceiling", 0, 10000, 0}, // 0: the plan's
	}, {
		{"name", "room"},
	}, {
		{"nodes", "node", OnDelete::Remove, 3},
	}},
	// The shape a set of instances share; see DefKind. A box is w by h by
	// d; an opening, a door and a window are w wide and h high, with trim
	// round them on both faces
	{"definition", {
		{"kind", 0, DK_COUNT - 1, DK_BOX},
		{"w", 1, 100000, 600},
		{"h", 1, 20000, 750},
		{"d", 1, 100000, 600},
		{"trim", 0, 500, 70},
		{"trim_depth", 0, 200, 15},
		{"leaf", 0, 2, 0},       // door: single, double; window: fixed, casement, double casement
		{"glazed", 0, 1, 0},     // door: a glass pane in each leaf (user)
		{"measure", 0, 1, 0},    // window: w, h and sill read as the frame's, or the glass's (user)
		{"voxel_size", 1, 1000, 50}, // a voxel volume's, mm
		// Stairs: w wide, rising h over their depth d along +Z in this
		// many equal steps
		{"steps", 1, 200, 15},
		{"mat", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
		{"mat_leaf", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
		{"mat_glass", 0, INT32_MAX, 0, "palette", OnDelete::Restrict, true},
	}, {}, {}},
	// A definition placed: yaw in millidegrees, pitch and roll in quarter
	// turns, and its height from the floor up or the ceiling down
	{"instance", {
		{"def", 1, INT32_MAX, 0, "definition", OnDelete::Cascade},
		{"layout", 1, INT32_MAX, 0, "layout", OnDelete::Restrict},
		{"x", -MAX_COORD, MAX_COORD, 0},
		{"z", -MAX_COORD, MAX_COORD, 0},
		{"yaw", 0, 359999, 0},
		{"pitch", 0, 3, 0},
		{"roll", 0, 3, 0},
		{"align", 0, 1, 0},       // 1: from the ceiling down
		{"offset", 0, 20000, 0},
		// Hosted in a wall: its centre this far along from the wall's a
		// end, its bottom sill above the floor. The position and yaw above
		// are then the wall's.
		{"host", 0, INT32_MAX, 0, "wall", OnDelete::Cascade, true},
		{"along", -MAX_COORD, MAX_COORD, 0},
		{"sill", 0, 20000, 0},
		{"flip", 0, 3, 0},        // bit 0: hinge on the other jamb; 1: swing
		// Thousandths of a right angle, to 170 degrees (user: past fully
		// open, which is 1000); the unit is kept so saved plans mean what
		// they did
		{"open", 0, 1889, 0},
		{"on", 0, 1, 1},          // a lamp's
		{"blinds", 0, 1000, 0},   // a window's blind, thousandths down
	}, {}, {
		// A switch's lamps
		{"lamps", "instance", OnDelete::Remove, 0},
	}},
	// One material: its type, its own colour, the paint over it, and the
	// knobs of its type. See Palette.glsl for what each does.
	// A picture under the plan, an existing floor plan to trace: one of the
	// save's images/, its middle at x, z, scale mm per 1000 pixels
	{"image", {
		{"layout", 1, INT32_MAX, 0, "layout", OnDelete::Restrict},
		{"x", -MAX_COORD, MAX_COORD, 0},
		{"z", -MAX_COORD, MAX_COORD, 0},
		{"yaw", 0, 359999, 0},
		{"scale", 1, 10000000, 10000},
		{"opacity", 0, 1000, 600},
		{"locked", 0, 1, 0},
		{"show3d", 0, 1, 0},
	}, {
		{"file", ""},
	}, {}},
	// **A saved viewpoint** (user, 2026-10-01): a camera fixed where it was,
	// to see the plan again from the same place -- the free 3D camera's or
	// a walker's eyes (walk 1), at x, y, z mm in its layout's frame,
	// looking yaw and pitch (millidegrees) with a vertical field of view of
	// fov degrees; and the day and minute it was saved at, which it puts
	// the light at when recall is 1
	{"viewport", {
		{"layout", 1, INT32_MAX, 0, "layout", OnDelete::Cascade},
		{"x", -MAX_COORD, MAX_COORD, 0},
		{"y", -MAX_COORD, MAX_COORD, 0},
		{"z", -MAX_COORD, MAX_COORD, 0},
		{"yaw", -1000000, 1000000, 0},
		{"pitch", -90000, 90000, 0},
		{"walk", 0, 1, 0},
		{"fov", 1, 179, 60},
		{"day", 1, 365, 172},
		{"minute", 0, 1439, 720},
		{"recall", 0, 1, 1},
	}, {
		{"name", "Viewport"},
	}, {}},
	{"palette", {
		{"kind", 0, MK_COUNT - 1, MK_DRYWALL},
		{"base", 0, 0xffffff, 0xe8e4dc},
		{"color", 0, 0xffffff, 0xffffff},
		{"finish", 0, 2, 0},       // 0 over its colour, 1 undercoat, 2 stain
		{"opacity", 0, 1000, 500}, // a stain's, and glass's
		{"color2", 0, 0xffffff, 0x404040}, // veins, pattern, grout
		{"roughness", 0, 1000, 800},
		{"specular", 0, 1000, 100},
		{"reflect", 0, 1000, 0},
		{"scale", 1, 60000, 200},  // mm
		{"seed", 0, 65535, 0},
		{"axis", 0, 2, 0},         // wood's grain: x, y, z
		{"stagger", 0, 1, 0},      // tiles
		{"grout", 0, 100, 3},      // mm
		{"temperature", 1000, 12000, 2700}, // a lamp's, in kelvin
		{"brightness", 0, 10000, 1000}, // a lamp's, 0.1 %: 100 % beside the sun
		{"speckle", 0, 1000, 300}, // plaster
		{"angle", 0, 179, 0},      // paneling's boards, 0 horizontal, 90 vertical
		{"contrast", 0, 3000, 1000}, // wood's grain, 1000 as it always was
		// Paneling's: rough sawn 0 to lacquered 1000, its seams' groove in
		// tenths of a mm, and how hand made it looks, to a log wall
		{"polish", 0, 1000, 500},
		{"gap_depth", 0, 3000, 15},
		{"gap_width", 0, 6000, 60},
		{"handmade", 0, 1000, 0},
	}, {
		{"name", "material"},
		// [FP_SAMPLE_FIT]'s samples: "rrggbb name" each, ';' between
		{"samples", ""},
	}, {}},
};

static const TypeSchema* find_schema(const ss_ &type)
{
	for(const TypeSchema &s : SCHEMA)
		if(type == s.type)
			return &s;
	return nullptr;
}

static Entity make_default(const TypeSchema &s)
{
	Entity e;
	e.type = s.type;
	for(const IntField &f : s.ints)
		e.ints[f.name] = f.def;
	for(const StrField &f : s.strs)
		e.strs[f.name] = f.def;
	for(const ListField &f : s.lists)
		e.lists[f.name] = {};
	return e;
}

static bool valid_text(const ss_ &s)
{
	for(unsigned char c : s)
		if(c < 0x20 || c == 0x7f)
			return false;
	return true;
}

// A picture's file name in a plan's images/: a PNG or JPEG by its
// extension, one name and no path, not hidden
static bool valid_image_name(const ss_ &name)
{
	if(name.empty() || name.size() > 100 || !valid_text(name) ||
			name.find('/') != ss_::npos || name.find('\\') != ss_::npos ||
			name[0] == '.')
		return false;
	ss_ lower = name;
	for(char &c : lower)
		c = tolower(c);
	namespace fs = interface::fs;
	return fs::check_file_extension(lower.c_str(), "png") ||
			fs::check_file_extension(lower.c_str(), "jpg") ||
			fs::check_file_extension(lower.c_str(), "jpeg");
}

// Whether the bytes are what the name says: a PNG's or a JPEG's signature
static bool image_matches_name(const ss_ &name, const ss_ &data)
{
	ss_ lower = name;
	for(char &c : lower)
		c = tolower(c);
	if(interface::fs::check_file_extension(lower.c_str(), "png"))
		return data.compare(0, 8, "\x89PNG\r\n\x1a\n") == 0;
	return data.size() >= 3 && (unsigned char)data[0] == 0xff &&
			(unsigned char)data[1] == 0xd8 && (unsigned char)data[2] == 0xff;
}

struct Op
{
	// 0 create, 1 set, 2 delete, 3 restore: create again under the id it
	// had, which is what an undo of a delete sends
	uint8_t op = 0;
	Entity ent;
	template<class Archive>
	void serialize(Archive &archive){
		archive(op, ent);
	}
};

// Where a user is and what they have selected, as the others are shown it
struct Presence
{
	uint8_t view = 0;         // 0 the plan, 1 the 3D camera
	int32_t cx = 0, cz = 0;   // the cursor on the floor, mm
	int32_t px = 0, py = 0, pz = 0; // the camera, mm
	int32_t yaw = 0, pitch = 0;     // millidegrees
	sv_<int32_t> sel;
	template<class Archive>
	void serialize(Archive &archive){
		archive(view, cx, cz, px, py, pz, yaw, pitch, sel);
	}
};

struct Peer
{
	ss_ name; // empty until logged in
	ss_ address;
	ss_ plan; // the plan the user is in ([FP_PLANS] 3), or ""

	Presence presence;
	bool has_presence = false;
	// Rate limit: a bucket of operations refilled per second
	double op_budget = 0;
	// And one for what is passed on to everyone in the plan or is heavy to
	// make -- presence, previews, chat, an export -- which had none
	// ([SECURITY_RUN_1]). Taken by spend_msg().
	double msg_budget = 0;
};

static const double OPS_PER_SECOND = 400;
static const double OPS_BURST = 4000;
// A presence or a preview costs 1 (a drag sends both at its frame rate), a
// chat line 20, an export 100: five lines a second, one export a second
static const double MSGS_PER_SECOND = 100;
static const double MSGS_BURST = 200;

struct VoxelEdit
{
	int32_t seq = 0;
	int32_t def = 0;
	// cell -> palette entry, 0 for none
	std::map<int32_t, int32_t> sets;
	template<class Archive>
	void serialize(Archive &archive){
		archive(seq, def, sets);
	}
};

struct LockRequest
{
	int32_t seq = 0;
	sv_<int32_t> ids;
	template<class Archive>
	void serialize(Archive &archive){
		archive(seq, ids);
	}
};

struct Preview
{
	int32_t peer = 0;
	sv_<Entity> ents;
	template<class Archive>
	void serialize(Archive &archive){
		archive(peer, ents);
	}
};

struct PresenceOut
{
	int32_t peer = 0;
	ss_ name;
	Presence p;
	template<class Archive>
	void serialize(Archive &archive){
		archive(peer, name, p);
	}
};

static bool valid_voxel_key(int32_t key)
{
	// Three bytes, each a cell coordinate + VOXEL_RANGE
	return key >= 0 && key < (1 << 24);
}


// One open plan ([FP_PLANS] 3): its save, and all of it in memory. The
// server has open as many as are in use, and closes one PLAN_IDLE_S after
// the last user has left it.
struct Plan
{
	interface::Server *m_server;
	ss_ m_name;
	// Owned by builtin/storage, which closes it when it unloads
	storage::Save *m_save = nullptr;
	storage::Store *m_store = nullptr;

	std::map<int32_t, Entity> m_ents;
	// Each voxel volume's voxels: the cell, packed as voxel_key() does, to
	// the palette entry it is made of. Kept when its definition is deleted,
	// so an undo that restores the definition gets them back.
	// simplified: a volume is one blob in the save and whole in memory; the
	// upgrade for big volumes is chunks, as voxelworld keeps them
	std::map<int32_t, std::map<int32_t, int32_t>> m_voxels;
	set_<int32_t> m_voxels_dirty;
	int32_t m_next_id = 1;
	set_<int32_t> m_dirty;
	// What is being dragged, and by whom: nobody else's batch may touch it
	std::map<int32_t, network::PeerId> m_locks;
	// The save's images/ as files for the clients: the pictures a plan can
	// be traced over. Put there by hand; a name is one file name.
	sv_<ss_> m_images;
	uint64_t m_images_bytes = 0;
	// Seconds with nobody in it
	float m_idle = 0;
	// Written to since the last backup, and when that was
	bool m_changed = false;
	int64_t m_last_backup = 0;
	// A backup opened to look at ([FP_BACKUPS]): the plan it is of, and
	// when it was made. Everyone in it is a viewer, and it goes when it
	// closes.
	ss_ m_backup_of;
	int64_t m_backup_id = 0;
	// The branch point's entities ([FP_GHOST]), read when first sent, and
	// whether its ghost was last sent on
	sv_<Entity> m_ghost;
	bool m_ghost_read = false;
	bool m_ghost_on = false;

	Plan(interface::Server *server, const ss_ &name):
		m_server(server), m_name(name)
	{}

	// The times of <save>/backups/*, newest first, and after them the
	// numbered ones from before ([FP_BACKUPS]) as -1, -2 and on: their
	// times are not known (each was copied again at every open, so their
	// files' times are all the last open's), and they are never thinned
	static sv_<int64_t> list_backups(const ss_ &path)
	{
		namespace fs = interface::fs;
		sv_<int64_t> ids, old;
		for(const fs::Node &n : fs::list_directory(path+"/backups")){
			if(!n.is_directory || n.name.empty() || n.name.size() > 18 ||
					n.name.find_first_not_of("0123456789") != ss_::npos)
				continue;
			const int64_t id = std::stoll(n.name);
			if(n.name.size() <= 2)
				old.push_back(-id);
			else
				ids.push_back(id);
		}
		std::sort(ids.begin(), ids.end(), std::greater<int64_t>());
		std::sort(old.begin(), old.end(), std::greater<int64_t>());
		ids.insert(ids.end(), old.begin(), old.end());
		return ids;
	}

	static ss_ backup_dir(const ss_ &path, int64_t id)
	{
		return path+"/backups/"+itos(id < 0 ? -id : id);
	}

	// A copy of the save into <save>/backups/<now>, then the old ones
	// thinned. The save is closed, or open and just flushed with nothing
	// written until this returns, so its write-ahead log is copied as it is.
	void backup(const ss_ &path)
	{
		namespace fs = interface::fs;
		const int64_t now = (int64_t)time(nullptr);
		const ss_ dir = path+"/backups";
		sv_<int64_t> ids;
		for(int64_t id : list_backups(path))
			if(id > 0)
				ids.push_back(id);
		if(ids.empty() || ids[0] < now){
			const ss_ to = dir+"/"+itos(now);
			fs::create_directories(to);
			bool ok = fs::copy_file(path+"/save.sqlite", to+"/save.sqlite");
			if(fs::path_exists(path+"/save.sqlite-wal"))
				ok = fs::copy_file(path+"/save.sqlite-wal",
						to+"/save.sqlite-wal") && ok;
			if(!ok){
				log_w(MODULE, "Could not back the plan up into %s", cs(to));
				fs::remove_all(to);
				return;
			}
			ids.push_back(now);
		}
		for(int64_t id : backups_to_drop(ids, now))
			fs::remove_all(dir+"/"+itos(id));
		m_last_backup = now;
		m_changed = false;
	}

	void find_images()
	{
		namespace fs = interface::fs;
		m_images.clear();
		m_images_bytes = 0;
		ss_ dir = m_save->path()+"/images";
		fs::create_directories(dir);
		for(const fs::Node &n : fs::list_directory(dir)){
			if(n.is_directory || !valid_image_name(n.name))
				continue;
			if(fs::file_size(dir+"/"+n.name) > MAX_IMAGE_BYTES){
				log_w(MODULE, "Image %s is too big to send; skipped",
						cs(n.name));
				continue;
			}
			m_images.push_back(n.name);
			m_images_bytes += fs::file_size(dir+"/"+n.name);
			client_file::access(m_server, [&](client_file::Interface *i){
				i->add_file_path("main/images/"+m_name+"/"+n.name, dir+"/"+n.name);
			});
		}
		log_i(MODULE, "%zu images to trace over", m_images.size());
	}

	bool load()
	{
		m_ents.clear();
		ss_ version;
		if(m_store->get("schema_version", version) &&
				std::stoi(version) > SCHEMA_VERSION){
			// A newer build's plan: refused rather than dropping what it has
			log_e(MODULE, "The plan %s is from a newer version (schema %s)",
					cs(m_name), cs(version));
			return false;
		}
		int32_t stored = version.empty() ? SCHEMA_VERSION : std::stoi(version);
		for(const ss_ &key : m_store->list("e/")){
			ss_ data;
			Entity e;
			if(!m_store->get(key, data) || !unpack(data, e) ||
					!find_schema(e.type)){
				log_w(MODULE, "Unreadable entity %s; skipped", cs(key));
				continue;
			}
			// 1 -> 2: a palette entry's colour became its own colour, and
			// `color` the paint over it
			if(stored < 2 && e.type == "palette" && e.ints.count("color") &&
					!e.ints.count("base")){
				e.ints["base"] = e.ints["color"];
				e.ints["color"] = 0xffffff;
			}
			// A field added since it was saved takes its default, and one
			// that is gone goes
			Entity d = make_default(*find_schema(e.type));
			for(auto &pair : d.ints)
				if(e.ints.count(pair.first))
					pair.second = e.ints[pair.first];
			for(auto &pair : d.strs)
				if(e.strs.count(pair.first))
					pair.second = e.strs[pair.first];
			for(auto &pair : d.lists)
				if(e.lists.count(pair.first))
					pair.second = e.lists[pair.first];
			d.id = e.id;
			e = d;
			m_ents[e.id] = e;
			if(stored < SCHEMA_VERSION)
				m_dirty.insert(e.id);
			if(e.id >= m_next_id)
				m_next_id = e.id + 1;
		}
		// The singletons, and a first palette entry so a first wall has a
		// material
		for(const TypeSchema &s : SCHEMA){
			if(!s.singleton || find_singleton(s.type))
				continue;
			Entity e = make_default(s);
			e.id = m_next_id++;
			m_ents[e.id] = e;
			m_dirty.insert(e.id);
		}
		// 2 -> 3: a plan from before layouts is one, and so is a new one
		int32_t first_layout = 0;
		for(auto &pair : m_ents)
			if(pair.second.type == "layout"){
				first_layout = pair.first;
				break;
			}
		if(first_layout == 0){
			Entity e = make_default(*find_schema("layout"));
			e.id = first_layout = m_next_id++;
			m_ents[e.id] = e;
			m_dirty.insert(e.id);
		}
		for(auto &pair : m_ents){
			Entity &e = pair.second;
			auto it = e.ints.find("layout");
			if(it == e.ints.end())
				continue;
			auto l = m_ents.find(it->second);
			if(l == m_ents.end() || l->second.type != "layout"){
				it->second = first_layout;
				m_dirty.insert(e.id);
			}
		}
		if(m_ents.size() == count_type("settings") + count_type("layout")){
			Entity e = make_default(*find_schema("palette"));
			e.id = m_next_id++;
			e.strs["name"] = "white drywall";
			m_ents[e.id] = e;
			m_dirty.insert(e.id);
		}
		m_voxels.clear();
		for(const ss_ &key : m_store->list("v/")){
			ss_ data;
			std::map<int32_t, int32_t> voxels;
			if(m_store->get(key, data) && unpack(data, voxels))
				m_voxels[std::stoi(key.substr(2))] = voxels;
		}
		m_store->set("schema_version", itos(SCHEMA_VERSION));
		log_i(MODULE, "Loaded %s: %zu entities and %zu voxel volumes",
				cs(m_name), m_ents.size(), m_voxels.size());
		return true;
	}

	size_t count_type(const ss_ &type)
	{
		size_t n = 0;
		for(auto &pair : m_ents)
			if(pair.second.type == type)
				n++;
		return n;
	}

	Entity* find_singleton(const ss_ &type)
	{
		for(auto &pair : m_ents)
			if(pair.second.type == type)
				return &pair.second;
		return nullptr;
	}

	// What the plan takes against its owner's USER_BYTES: its entities
	// and voxels as stored, and its pictures
	// simplified: the stored size by its parts, not the database file's,
	// which does not shrink when things are deleted; backups uncounted
	uint64_t bytes()
	{
		uint64_t n = m_images_bytes;
		for(auto &pair : m_ents){
			const Entity &e = pair.second;
			n += 16 + e.type.size();
			for(auto &i : e.ints)
				n += i.first.size() + 4;
			for(auto &t : e.strs)
				n += t.first.size() + t.second.size();
			for(auto &l : e.lists)
				n += l.first.size() + 4 * l.second.size();
		}
		for(auto &pair : m_voxels)
			n += 8 * pair.second.size();
		return n;
	}

	void flush()
	{
		if(!m_store || (m_dirty.empty() && m_voxels_dirty.empty()))
			return;
		m_changed = true;
		m_store->batch([&](){
			// For the next open: changed since its last backup
			m_store->set("meta/unbacked", "1");
			for(int32_t id : m_dirty){
				ss_ key = "e/"+itos(id);
				auto it = m_ents.find(id);
				if(it == m_ents.end())
					m_store->remove(key);
				else
					m_store->set(key, pack(it->second));
			}
			for(int32_t def : m_voxels_dirty)
				m_store->set("v/"+itos(def), pack(m_voxels[def]));
		});
		m_dirty.clear();
		m_voxels_dirty.clear();
	}


	// Applies ops to the document, all or nothing. On success returns ""
	// and fills changed and deleted; on failure the document is as it was.
	ss_ apply(const sv_<Op> &ops, std::map<int32_t, int32_t> &placeholders,
			set_<int32_t> &changed, set_<int32_t> &deleted)
	{
		// The previous state of every entity touched, for rolling back
		std::map<int32_t, std::pair<bool, Entity>> journal;
		int32_t next_id_before = m_next_id;
		auto touch = [&](int32_t id){
			if(journal.count(id))
				return;
			auto it = m_ents.find(id);
			journal[id] = it == m_ents.end() ? std::make_pair(false, Entity())
					: std::make_pair(true, it->second);
		};
		auto rollback = [&](const ss_ &error){
			for(auto &pair : journal){
				if(pair.second.first)
					m_ents[pair.first] = pair.second.second;
				else
					m_ents.erase(pair.first);
			}
			m_next_id = next_id_before;
			placeholders.clear();
			changed.clear();
			deleted.clear();
			return error;
		};
		auto resolve = [&](int32_t id) -> int32_t {
			if(id >= 0)
				return id;
			auto it = placeholders.find(id);
			return it == placeholders.end() ? -1 : it->second;
		};

		for(const Op &op : ops){
			const Entity &in = op.ent;
			if(op.op == 0){
				const TypeSchema *s = find_schema(in.type);
				if(!s || s->singleton)
					return rollback("Cannot create a \""+in.type+"\"");
				if(in.id >= 0 || placeholders.count(in.id))
					return rollback("A new entity needs a fresh negative id");
				if(m_ents.size() >= MAX_ENTITIES)
					return rollback("The plan is full");
				Entity e = make_default(*s);
				e.id = m_next_id++;
				placeholders[in.id] = e.id;
				touch(e.id);
				m_ents[e.id] = e;
				ss_ err = set_fields(e.id, in, resolve);
				if(!err.empty())
					return rollback(err);
				changed.insert(e.id);
			} else if(op.op == 1){
				int32_t id = resolve(in.id);
				if(!m_ents.count(id))
					return rollback("No entity "+itos(in.id));
				touch(id);
				ss_ err = set_fields(id, in, resolve);
				if(!err.empty())
					return rollback(err);
				changed.insert(id);
			} else if(op.op == 3){
				const TypeSchema *s = find_schema(in.type);
				if(!s || s->singleton)
					return rollback("Cannot restore a \""+in.type+"\"");
				if(in.id <= 0 || in.id >= m_next_id || m_ents.count(in.id))
					return rollback("Entity "+itos(in.id)+
							" cannot be restored");
				if(m_ents.size() >= MAX_ENTITIES)
					return rollback("The plan is full");
				Entity e = make_default(*s);
				e.id = in.id;
				touch(e.id);
				m_ents[e.id] = e;
				ss_ err = set_fields(e.id, in, resolve);
				if(!err.empty())
					return rollback(err);
				changed.insert(e.id);
				deleted.erase(e.id);
			} else if(op.op == 2){
				int32_t id = resolve(in.id);
				auto it = m_ents.find(id);
				if(it == m_ents.end())
					return rollback("No entity "+itos(in.id));
				if(find_schema(it->second.type)->singleton)
					return rollback("Cannot delete the "+it->second.type);
				touch(id);
				m_ents.erase(it);
				deleted.insert(id);
			} else {
				return rollback("Unknown operation");
			}
		}

		// What the deletes do to what referred to them, to a fixpoint: a
		// cascade can delete what something else refers to
		set_<int32_t> processed;
		for(;;){
			set_<int32_t> pending;
			for(int32_t id : deleted)
				if(!processed.count(id))
					pending.insert(id);
			if(pending.empty())
				break;
			processed.insert(pending.begin(), pending.end());
			sv_<int32_t> cascade;
			for(auto &pair : m_ents){
				Entity &e = pair.second;
				const TypeSchema *s = find_schema(e.type);
				for(const IntField &f : s->ints){
					if(!f.ref || !pending.count(e.ints[f.name]))
						continue;
					if(f.on_delete == OnDelete::Restrict)
						return rollback("A "+ss_(f.ref)+" still in use by "
								"a "+e.type+" cannot be deleted");
					cascade.push_back(e.id);
				}
				for(const ListField &f : s->lists){
					sv_<int32_t> &list = e.lists[f.name];
					sv_<int32_t> kept;
					for(int32_t v : list)
						if(!pending.count(v))
							kept.push_back(v);
					if(kept.size() == list.size())
						continue;
					if(f.on_delete == OnDelete::Restrict)
						return rollback("A "+ss_(f.ref)+" still in use by "
								"a "+e.type+" cannot be deleted");
					touch(e.id);
					list = kept;
					changed.insert(e.id);
					if(list.size() < f.min_len)
						cascade.push_back(e.id);
				}
			}
			for(int32_t id : cascade){
				touch(id);
				m_ents.erase(id);
				deleted.insert(id);
			}
		}

		// A palette entry voxels are made of is in use, as much as one a
		// wall is made of
		for(int32_t id : deleted){
			auto it = journal.find(id);
			if(it == journal.end() || !it->second.first ||
					it->second.second.type != "palette")
				continue;
			for(auto &vol : m_voxels){
				if(!m_ents.count(vol.first))
					continue;
				for(auto &v : vol.second)
					if(v.second == id)
						return rollback("A palette entry still in use by "
								"voxels cannot be deleted");
			}
		}

		// Every reference of what changed points at what it may
		for(int32_t id : changed){
			if(deleted.count(id))
				continue;
			ss_ err = check_refs(m_ents[id]);
			if(!err.empty())
				return rollback(err);
		}

		for(auto &pair : journal)
			m_dirty.insert(pair.first);
		return "";
	}

	// Sets the fields in `in` on entity id, with placeholders resolved and
	// every value checked against the schema. References are checked
	// after the whole batch, since they can point at what comes later.
	ss_ set_fields(int32_t id, const Entity &in,
			const std::function<int32_t(int32_t)> &resolve)
	{
		Entity &e = m_ents[id];
		const TypeSchema *s = find_schema(e.type);
		if(!in.type.empty() && in.type != e.type)
			return "Entity "+itos(id)+" is a "+e.type+", not a "+in.type;
		for(auto &pair : in.ints){
			const IntField *f = nullptr;
			for(const IntField &ff : s->ints)
				if(pair.first == ff.name)
					f = &ff;
			if(!f)
				return "A "+e.type+" has no field "+pair.first;
			int32_t v = pair.second;
			if(f->ref){
				v = resolve(v);
				if(v == 0 && f->optional){
					e.ints[f->name] = 0;
					continue;
				}
			}
			if(v < f->min || v > f->max)
				return e.type+"."+pair.first+" out of range";
			e.ints[f->name] = v;
		}
		for(auto &pair : in.strs){
			const StrField *f = nullptr;
			for(const StrField &ff : s->strs)
				if(pair.first == ff.name)
					f = &ff;
			if(!f)
				return "A "+e.type+" has no field "+pair.first;
			// simplified: the samples are one text, 4000 bytes or a
			// hundred-odd samples; a list of their own is the upgrade
			if(pair.second.size() > (ss_(f->name) == "samples" ?
					4000 : MAX_STRING) ||
					!valid_text(pair.second))
				return e.type+"."+pair.first+" is not a valid text";
			e.strs[f->name] = pair.second;
		}
		for(auto &pair : in.lists){
			const ListField *f = nullptr;
			for(const ListField &ff : s->lists)
				if(pair.first == ff.name)
					f = &ff;
			if(!f)
				return "A "+e.type+" has no field "+pair.first;
			if(pair.second.size() > MAX_LIST ||
					pair.second.size() < f->min_len)
				return e.type+"."+pair.first+" has a wrong length";
			sv_<int32_t> list;
			for(int32_t v : pair.second)
				list.push_back(resolve(v));
			e.lists[f->name] = list;
		}
		return "";
	}

	// A drag as another user's client will draw it ([SECURITY_RUN_1]):
	// what the client previews is an entity already here and its plain
	// coordinates -- x, z, along -- so that is all a preview may be, in
	// the schema's range. It went to every peer in the plan unchecked, and
	// their editors merge it over the real entity.
	ss_ check_preview(const Entity &in)
	{
		auto it = m_ents.find(in.id);
		if(it == m_ents.end())
			return "No entity "+itos(in.id);
		const Entity &e = it->second;
		if(!in.type.empty() && in.type != e.type)
			return "Entity "+itos(in.id)+" is a "+e.type;
		if(!in.strs.empty() || !in.lists.empty())
			return "A preview moves things and changes nothing else";
		const TypeSchema *s = find_schema(e.type);
		for(auto &pair : in.ints){
			const IntField *f = nullptr;
			for(const IntField &ff : s->ints)
				if(pair.first == ff.name)
					f = &ff;
			if(!f || f->ref)
				return "A "+e.type+" previews no field "+pair.first;
			if(pair.second < f->min || pair.second > f->max)
				return e.type+"."+pair.first+" out of range";
		}
		return "";
	}

	ss_ check_refs(const Entity &e)
	{
		const TypeSchema *s = find_schema(e.type);
		auto is_a = [&](int32_t id, const char *type){
			auto it = m_ents.find(id);
			return it != m_ents.end() && it->second.type == type;
		};
		for(const IntField &f : s->ints){
			if(!f.ref)
				continue;
			int32_t v = e.ints.at(f.name);
			if(v == 0 && f.optional)
				continue;
			if(!is_a(v, f.ref))
				return e.type+"."+f.name+" is not a "+f.ref;
		}
		for(const ListField &f : s->lists){
			set_<int32_t> seen;
			for(int32_t v : e.lists.at(f.name)){
				if(!is_a(v, f.ref))
					return e.type+"."+f.name+" holds what is not a "+f.ref;
				if(!seen.insert(v).second)
					return e.type+"."+f.name+" holds an id twice";
			}
		}
		if(e.type == "wall" && e.ints.at("a") == e.ints.at("b"))
			return "A wall needs two different nodes";
		if(e.type == "instance"){
			const Entity &def = m_ents[e.ints.at("def")];
			int32_t kind = def.ints.at("kind");
			bool hosted = kind == DK_OPENING || kind == DK_DOOR ||
					kind == DK_WINDOW;
			int32_t host = e.ints.at("host");
			// A switch goes on a wall or anywhere
			if(kind != DK_SWITCH && hosted != (host != 0))
				return hosted ? "An opening needs a wall" :
						"Only openings, doors, windows and switches go in a wall";
			if(!e.lists.at("lamps").empty() && kind != DK_SWITCH)
				return "Only a switch has lamps";
			// It fits the wall it is put in. Checked when the instance
			// changes, not when the wall does: a wall shortened under a
			// door is the user's to sort out, not a refused drag.
			if(host){
				const Entity &w = m_ents[host];
				const Entity &a = m_ents[w.ints.at("a")];
				const Entity &b = m_ents[w.ints.at("b")];
				double dx = b.ints.at("x") - a.ints.at("x");
				double dz = b.ints.at("z") - a.ints.at("z");
				double len = std::sqrt(dx * dx + dz * dz);
				double along = e.ints.at("along");
				double half = def.ints.at("w") / 2.0;
				if(along - half < 0 || along + half > len)
					return "It does not fit its wall";
			}
		}
		return "";
	}
};

// How long a plan with nobody in it stays open ([FP_PLANS] 3)
static const float PLAN_IDLE_S = 60;
// **Storage per user** ([FP_GROUPS]; user, 2026-10-07): the plans a user
// owns, with their pictures, at most this; the server's admin uncounted
static const uint64_t USER_BYTES = 5 * 1024 * 1024;

// [FP_ABUSE] (user, 2026-10-08) open registration made safe. Per account:
// plans owned and groups made; per group, invites pending; per inviter,
// invites a calendar day; after a decline, no invite from the group for
// DECLINE_WAIT_S. Trust: edits on TRUST_DAYS calendar days while a member
// of a trusted group, a group whose admins are all trusted.
static const size_t MAX_PLANS = 50;
static const size_t MAX_MADE_GROUPS = 10;
static const size_t MAX_PENDING_INVITES = 20;
static const int MAX_INVITES_A_DAY = 50;
static const int64_t DECLINE_WAIT_S = 7 * 86400;
static const int TRUST_DAYS = 3;

// The calendar, in seconds, which --sim-clock moves ([SIM_CLOCK])
static int64_t calendar_s()
{
	return interface::os::wall_us() / 1000000;
}

// **A group** ([FP_GROUPS]; user, 2026-10-07): members (admins are
// members with that role), the invites it has out and the plans its
// members shared into it. Seen by its members only; an invitee sees its
// name. One key each in the _groups save.
struct Group
{
	ss_ name;
	std::map<ss_, ss_> members; // user -> "admin" or "member"
	std::map<ss_, ss_> invites; // user -> who invited them
	std::map<ss_, ss_> shares;  // plan -> "viewer" or "editor"

	template<class Archive>
	void serialize(Archive &archive){
		archive(name, members, invites, shares);
	}
};

// [FP_ABUSE] What a group keeps beside that, under a key of its own so
// the groups saved before it load as they are: who made it, when each
// member joined (calendar s; 0 before this), who declined an invite and
// when, and who takes no invites from it
struct GroupMore
{
	ss_ creator;
	std::map<ss_, int64_t> joined;
	std::map<ss_, int64_t> declined;
	std::map<ss_, int64_t> blocked;

	template<class Archive>
	void serialize(Archive &archive){
		archive(creator, joined, declined, blocked);
	}
};

static ss_ mb_text(uint64_t bytes)
{
	char buf[32];
	snprintf(buf, sizeof buf, "%.1f MB", bytes / (1024.0 * 1024.0));
	return buf;
}

// A plan's name: what a save's directory can be called on every system,
// and never the server's own store, whose name begins with _
static bool valid_plan_name(const ss_ &name)
{
	if(name.empty() || name.size() > 40 || name[0] == '_')
		return false;
	for(char c : name)
		if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
			return false;
	return true;
}

struct Module: public interface::Module
{
	interface::Server *m_server;
	// The plans in use, by name
	std::map<ss_, up_<Plan>> m_plans;
	float m_flush_timer = 0;

	// Who is here; a name once they have joined, which the accounts
	// module says ([VANILLA_PUBLIC] 2: the server's accounts are
	// builtin/accounts')
	std::map<network::PeerId, Peer> m_peers;

	// [FP_GROUPS] by id, and where they are kept
	std::map<int32_t, Group> m_groups;
	std::map<int32_t, GroupMore> m_more;
	// [FP_ABUSE] the calendar day each user's last edit was noted on
	std::map<ss_, int64_t> m_edit_day;
	int32_t m_next_group = 1;
	storage::Save *m_groups_save = nullptr;
	// [FP_GROUP_CHAT] each group's last lines, for a member who comes
	// later (simplified: in memory, gone at a restart -- the user's pick)
	std::map<int32_t, std::deque<ss_>> m_group_chat;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module(){}

	void init()
	{
		check_backups_to_drop();
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:shutdown"));
		// [USER_DIR_COPY] An operator's save_now: what shutdown saves
		m_server->sub_event(this, Event::t("core:save"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this, Event::t("accounts:login"));
		m_server->sub_event(this, Event::t("accounts:privs"));
		m_server->sub_event(this, Event::t("accounts:deleted"));
		for(const char *name : {"fp:open", "fp:leave_plan",
				"fp:copy_plan", "fp:plan_admin", "fp:batch", "fp:chat",
				"fp:voxels", "fp:lock", "fp:unlock",
				"fp:preview", "fp:presence", "fp:export", "fp:import",
				"fp:backups", "fp:open_backup", "fp:restore_backup",
				"fp:set_editing", "fp:group", "fp:group_chat",
				"fp:branch_point"})
			m_server->sub_event(this,
					Event::t(ss_("network:packet_received/")+name));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:continue", on_start)
		EVENT_VOIDN("core:unload", flush_all)
		EVENT_VOIDN("core:shutdown", flush_all)
		EVENT_VOIDN("core:save", flush_all)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("accounts:login", on_accounts_login, accounts::Login)
		EVENT_TYPEN("accounts:privs", on_accounts_privs, accounts::Login)
		EVENT_TYPEN("accounts:deleted", on_accounts_deleted, accounts::Login)
		EVENT_TYPEN("network:packet_received/fp:open", on_open,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:leave_plan", on_leave_plan,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:copy_plan", on_copy_plan,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:branch_point", on_branch_point,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:export", on_export,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:import", on_import,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:plan_admin", on_plan_admin,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:backups", on_backups,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:open_backup", on_open_backup,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:restore_backup",
				on_restore_backup, network::Packet)
		EVENT_TYPEN("network:packet_received/fp:set_editing",
				on_set_editing, network::Packet)
		EVENT_TYPEN("network:packet_received/fp:group", on_group,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:batch", on_batch,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:chat", on_chat,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:group_chat", on_group_chat,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:voxels", on_voxels,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:lock", on_lock,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:unlock", on_unlock,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:preview", on_preview,
				network::Packet)
		EVENT_TYPEN("network:packet_received/fp:presence", on_presence,
				network::Packet)
	}

	// The start

	// One key of what the launcher asked for through the server's -u, as
	// apps/vanilla reads it: a value of the shape a save name has, or ""
	ss_ launch_param(const ss_ &key_name)
	{
		return interface::launch_param(
				m_server->get_config().get<ss_>("untrusted_launch"), key_name);
	}

	// A plan the launcher named (save=<name>), which the local user is
	// offered first
	ss_ m_launch_plan;

	void on_start()
	{
		// [PAGE_TITLE] the web page's title, when the admin gave none
		network::access(m_server, [&](network::Interface *i){
			i->set_page_title("Floor planner", false);
		});
		// One user's two clients, one editing and one viewing
		// ([FP_TWO_CLIENTS])
		accounts::access(m_server, [&](accounts::Interface *i){
			i->set_multiple_logins(true);
		});
		m_launch_plan = launch_param("save");
		// Backups opened to look at when the server last stopped
		storage::access(m_server, [&](storage::Interface *istorage){
			for(const storage::SaveInfo &i : istorage->list())
				if(i.name.compare(0, 8, "_backup-") == 0)
					istorage->remove(i.name);
			m_groups_save = istorage->open("_groups");
			if(!m_groups_save)
				m_groups_save = istorage->create("_groups");
		});
		if(!m_groups_save)
			throw Exception("floorplanner: could not open or create _groups");
		load_groups();
		end_public();
		// The Server window's Accounts page has what each keeps
		usage_all();
	}

	// **No public plans** ([FP_GROUPS]; user, 2026-10-07): a plan's
	// meta/public, which gave everyone a role, goes at the first start
	// that has groups; each plan it opened is in the log once, and the
	// setting stays as meta/public_was
	void end_public()
	{
		for(const ss_ &name : plan_names()){
			storage::access(m_server, [&](storage::Interface *istorage){
				storage::Save *save = istorage->open(name);
				if(!save)
					return;
				storage::Store *store = save->store("main");
				ss_ v, owner;
				if(store->get("meta/public", v)){
					store->get("meta/owner", owner);
					if(v != "0")
						log_w(MODULE, "The plan %s (%s's) was %s by everyone; "
								"now only by its owner, its members and its "
								"groups", cs(name), cs(owner), v == "2" ?
								"editable" : "readable");
					store->set("meta/public_was", v);
					store->remove("meta/public");
				}
				istorage->close(save);
			});
		}
	}

	// Plans

	// The plan of that name in use, opened (with create, made when it is not
	// there) if it is not; nullptr if it could not be
	Plan* open_plan(const ss_ &name, bool create)
	{
		auto it = m_plans.find(name);
		if(it != m_plans.end())
			return it->second.get();
		m_closed_meta.erase(name);
		if(!valid_plan_name(name))
			return nullptr;
		up_<Plan> plan(new Plan(m_server, name));
		storage::access(m_server, [&](storage::Interface *istorage){
			plan->m_save = istorage->open(name);
			if(plan->m_save){
				// A copy of the plan as it was, before anything touches it,
				// when it changed since the last: what an undo that lives
				// only for a session cannot give back
				ss_ path = plan->m_save->path();
				ss_ unbacked;
				plan->m_save->store("main")->get("meta/unbacked", unbacked);
				sv_<int64_t> ids = Plan::list_backups(path);
				plan->m_last_backup = ids.empty() ? 0 : std::max<int64_t>(0, ids[0]);
				if(unbacked != "0" || ids.empty()){
					istorage->close(plan->m_save);
					plan->backup(path);
					plan->m_save = istorage->open(name);
					if(plan->m_save)
						plan->m_save->store("main")->set("meta/unbacked", "0");
				}
			} else if(create){
				plan->m_save = istorage->create(name);
				plan->m_last_backup = (int64_t)time(nullptr);
			}
		});
		if(!plan->m_save){
			log_w(MODULE, "Could not open or create the plan %s", cs(name));
			return nullptr;
		}
		plan->m_store = plan->m_save->store("main");
		if(!plan->load()){
			close_save(plan.get());
			return nullptr;
		}
		plan->find_images();
		log_i(MODULE, "Opened the plan %s", cs(name));
		Plan *p = plan.get();
		m_plans[name] = std::move(plan);
		return p;
	}

	void close_save(Plan *plan)
	{
		storage::access(m_server, [&](storage::Interface *istorage){
			istorage->close(plan->m_save);
		});
		plan->m_save = nullptr;
		plan->m_store = nullptr;
	}

	void close_plan(const ss_ &name)
	{
		m_closed_meta.erase(name);
		auto it = m_plans.find(name);
		if(it == m_plans.end())
			return;
		it->second->flush();
		const bool view = !it->second->m_backup_of.empty();
		if(!view)
			it->second->m_store->set("meta/bytes", itos(it->second->bytes()));
		close_save(it->second.get());
		m_plans.erase(it);
		if(view){
			storage::access(m_server, [&](storage::Interface *istorage){
				istorage->remove(name);
			});
		}
		log_i(MODULE, "Closed the plan %s", cs(name));
	}

	void flush_all()
	{
		for(auto &pair : m_plans)
			pair.second->flush();
	}

	// Whether a plan of this name, in any case, is there: a new plan's name
	// must not be one, because Windows' and macOS' file systems take "ALICE"
	// for "alice" and an exact compare let a new plan open, own and
	// overwrite another's ([SECURITY_RUN_1]). Opening one is by its exact
	// name.
	bool name_taken(const ss_ &name)
	{
		auto lower = [](ss_ s){
			for(char &c : s)
				c = (char)tolower((unsigned char)c);
			return s;
		};
		const ss_ l = lower(name);
		for(const ss_ &n : plan_names())
			if(lower(n) == l)
				return true;
		return false;
	}

	sv_<ss_> plan_names()
	{
		sv_<ss_> names;
		storage::access(m_server, [&](storage::Interface *istorage){
			for(const storage::SaveInfo &i : istorage->list())
				if(valid_plan_name(i.name))
					names.push_back(i.name);
		});
		std::sort(names.begin(), names.end());
		return names;
	}

	// Who a plan is whose ([FP_PLANS] 2): read from the plan's store, which
	// for a plan not in use is opened for it
	struct PlanMeta
	{
		ss_ name;
		ss_ owner;
		std::map<ss_, ss_> roles; // name -> editor or viewer
		uint64_t bytes = 0;       // a closed plan's, as last closed
	};

	PlanMeta read_meta(storage::Store *store, const ss_ &name)
	{
		PlanMeta m;
		m.name = name;
		ss_ v;
		if(store->get("meta/owner", v))
			m.owner = v;
		for(const ss_ &key : store->list("role/"))
			if(store->get(key, v))
				m.roles[key.substr(5)] = v;
		return m;
	}

	// A closed plan's meta as last read: it changes only while the plan is
	// open, and reading it opened the save each time -- every plan for each
	// peer on the plans page, after each open, leave or group change, held
	// the server for seconds ([SECURITY_RUN_3]). Dropped when the plan
	// opens or closes, and when a closed one's store is written to.
	std::map<ss_, PlanMeta> m_closed_meta;

	PlanMeta plan_meta(const ss_ &name)
	{
		auto it = m_plans.find(name);
		if(it != m_plans.end()){
			PlanMeta m = read_meta(it->second->m_store, name);
			m.bytes = it->second->bytes();
			return m;
		}
		auto cached = m_closed_meta.find(name);
		if(cached != m_closed_meta.end())
			return cached->second;
		PlanMeta m;
		m.name = name;
		storage::access(m_server, [&](storage::Interface *istorage){
			storage::Save *save = istorage->open(name);
			if(!save)
				return;
			storage::Store *store = save->store("main");
			m = read_meta(store, name);
			ss_ v;
			if(store->get("meta/bytes", v)){
				m.bytes = std::stoull("0"+v);
			} else {
				// Closed before [FP_GROUPS]: its files
				namespace fs = interface::fs;
				const ss_ path = save->path();
				for(const char *f : {"/save.sqlite", "/save.sqlite-wal"})
					if(fs::path_exists(path+f))
						m.bytes += fs::file_size(path+f);
				for(const fs::Node &n : fs::list_directory(path+"/images"))
					if(!n.is_directory)
						m.bytes += fs::file_size(path+"/images/"+n.name);
			}
			istorage->close(save);
			m_closed_meta[name] = m;
		});
		return m;
	}

	bool is_admin(const ss_ &user)
	{
		return accounts::level(m_server, user) >= accounts::LV_ADMIN;
	}

	// What a user is in a plan: admin, owner, editor, viewer, or "" (not
	// let in). Past owner and admin, the highest of their own role and
	// those of the groups they are in that it is shared with ([FP_GROUPS])
	ss_ role_in(const PlanMeta &m, const ss_ &user)
	{
		// Owner first: the admin's own plan is theirs as well
		if(!m.owner.empty() && m.owner == user)
			return "owner";
		if(is_admin(user))
			return "admin";
		auto rank = [](const ss_ &r){
			return r == "editor" ? 2 : r == "viewer" ? 1 : 0;
		};
		ss_ role;
		auto it = m.roles.find(user);
		if(it != m.roles.end())
			role = it->second;
		for(auto &pair : m_groups){
			const Group &g = pair.second;
			auto share = g.shares.find(m.name);
			if(share != g.shares.end() && g.members.count(user) &&
					rank(share->second) > rank(role))
				role = share->second;
		}
		return role;
	}

	static bool role_edits(const ss_ &role)
	{
		return role == "admin" || role == "owner" || role == "editor";
	}

	static bool role_manages(const ss_ &role)
	{
		return role == "admin" || role == "owner";
	}

	// Whether `cost` of the peer's message budget is there, taken if so
	bool spend_msg(network::PeerId peer, double cost)
	{
		auto it = m_peers.find(peer);
		if(it == m_peers.end() || it->second.msg_budget < cost)
			return false;
		it->second.msg_budget -= cost;
		return true;
	}

	Plan* plan_of(network::PeerId peer)
	{
		auto it = m_peers.find(peer);
		if(it == m_peers.end() || it->second.name.empty() ||
				it->second.plan.empty())
			return nullptr;
		auto p = m_plans.find(it->second.plan);
		return p == m_plans.end() ? nullptr : p->second.get();
	}

	// In a backup, whoever may read the plan it is of reads it, and nobody
	// more
	ss_ peer_role(network::PeerId peer)
	{
		Plan *plan = plan_of(peer);
		if(plan && !plan->m_backup_of.empty())
			return role_in(plan_meta(plan->m_backup_of),
					m_peers[peer].name).empty() ? "" : "viewer";
		return plan ? role_in(read_meta(plan->m_store, plan->m_name),
				m_peers[peer].name) : "";
	}

	// **Viewing or editing** (user, 2026-09-30): a plan opens for viewing,
	// and one whose role edits switches to editing in the pause menu. **Per
	// connection** ([FP_TWO_CLIENTS], user 2026-10-03): one user's two
	// clients, one editing and one viewing. It is for the plan it was
	// switched on in, so entering another puts that client back to viewing;
	// EDITING_IDLE_S without an edit puts it back too, and so does leaving.
	// In memory: a server restart has everyone viewing.
	static constexpr int64_t EDITING_IDLE_S = 30 * 60;
	struct Editing
	{
		ss_ plan;
		int64_t last = 0; // the last edit, or the switch
	};
	std::map<network::PeerId, Editing> m_editing; // by connection
	float m_editing_timer = 0;

	bool editing(network::PeerId peer, const ss_ &plan)
	{
		auto it = m_editing.find(peer);
		return it != m_editing.end() && it->second.plan == plan &&
				(int64_t)time(nullptr) - it->second.last < EDITING_IDLE_S;
	}

	// Whether a peer may edit now; asking is an edit's attempt, which keeps
	// editing on
	bool can_edit(network::PeerId peer)
	{
		Plan *plan = plan_of(peer);
		if(!plan || !role_edits(peer_role(peer)) || !editing(peer, plan->m_name))
			return false;
		m_editing[peer].last = (int64_t)time(nullptr);
		return true;
	}

	ss_ edit_refusal(network::PeerId peer)
	{
		return role_edits(peer_role(peer)) ?
				"You are viewing: switch to Editing in the menu" :
				"You cannot edit this plan";
	}

	// Each of a user's clients hears the new privileges
	void send_privs_to_user(const ss_ &user)
	{
		for(auto &pair : m_peers)
			if(pair.second.name == user)
				send_privs(pair.first);
	}

	void on_set_editing(const network::Packet &packet)
	{
		uint8_t on = 0;
		Plan *plan = plan_of(packet.sender);
		if(!plan || !unpack(packet.data, on))
			return;
		const ss_ user = m_peers[packet.sender].name;
		if(on && role_edits(peer_role(packet.sender))){
			Editing &e = m_editing[packet.sender];
			e.plan = plan->m_name;
			e.last = (int64_t)time(nullptr);
			log_i(MODULE, "%s (%i) is editing %s", cs(user),
					(int)packet.sender, cs(plan->m_name));
		} else {
			m_editing.erase(packet.sender);
		}
		send_privs(packet.sender);
	}

	// Editing that has gone EDITING_IDLE_S without an edit: back to viewing,
	// and that client told
	void expire_editing()
	{
		const int64_t now = (int64_t)time(nullptr);
		sv_<network::PeerId> gone;
		for(auto &pair : m_editing)
			if(now - pair.second.last >= EDITING_IDLE_S)
				gone.push_back(pair.first);
		for(network::PeerId peer : gone){
			m_editing.erase(peer);
			if(m_peers.count(peer) == 0)
				continue;
			send_privs(peer);
			send(peer, "fp:chat", pack(ss_(
					"*** Back to viewing: no edits for 30 minutes")));
		}
	}

	struct PlanRow
	{
		ss_ name;
		ss_ owner;
		ss_ role;       // the user's
		int32_t here = 0;
		template<class Archive>
		void serialize(Archive &archive){
			archive(name, owner, role, here);
		}
	};

	// The plans a user may read, to open one or make one ([FP_PLANS] 4)
	void send_plans(network::PeerId peer)
	{
		const ss_ user = m_peers[peer].name;
		sv_<PlanRow> rows;
		for(const ss_ &name : plan_names()){
			PlanMeta m = plan_meta(name);
			PlanRow row;
			row.name = name;
			row.owner = m.owner;
			row.role = role_in(m, user);
			if(row.role.empty())
				continue;
			for(auto &pair : m_peers)
				if(pair.second.plan == name && !pair.second.name.empty())
					row.here++;
			rows.push_back(row);
		}
		send(peer, "fp:plans", pack(rows));
	}

	// A user into a plan: what it holds, where the others in it are, and what
	// this user may do in it
	void enter_plan(network::PeerId peer_id, Plan *plan)
	{
		Peer &peer = m_peers[peer_id];
		leave_plan(peer_id);
		// Editing is for the plan it was switched on in, this client's
		auto ed = m_editing.find(peer_id);
		if(ed != m_editing.end() && ed->second.plan != plan->m_name){
			m_editing.erase(ed);
			send_privs(peer_id);
		}
		peer.plan = plan->m_name;
		peer.has_presence = false;
		plan->m_idle = 0;
		send(peer_id, "fp:entered", pack(plan->m_name));
		if(!plan->m_backup_of.empty()){
			// Of, when, and whether this user may restore it
			const bool restore = role_edits(role_in(plan_meta(plan->m_backup_of),
					peer.name));
			send(peer_id, "fp:backup", pack(std::make_pair(
					std::make_pair(plan->m_backup_of, backup_label(
					plan->m_backup_id, (int64_t)time(nullptr))),
					(uint8_t)(restore ? 1 : 0))));
		}
		send_privs(peer_id);
		sv_<Entity> all;
		for(auto &pair : plan->m_ents)
			all.push_back(pair.second);
		send(peer_id, "fp:snapshot", pack(all));
		send(peer_id, "fp:images", pack(plan->m_images));
		send_ghost(plan, peer_id);
		for(auto &pair : plan->m_voxels){
			if(!plan->m_ents.count(pair.first))
				continue;
			VoxelEdit v;
			v.seq = -1;
			v.def = pair.first;
			v.sets = pair.second;
			send(peer_id, "fp:voxels", pack(v));
		}
		// Where the others are
		for(auto &pair : m_peers){
			if(pair.first == peer_id || pair.second.plan != plan->m_name ||
					!pair.second.has_presence)
				continue;
			PresenceOut out;
			out.peer = (int32_t)pair.first;
			out.name = pair.second.name;
			out.p = pair.second.presence;
			send(peer_id, "fp:presence", pack(out));
		}
		log_i(MODULE, "%s entered the plan %s", cs(peer.name),
				cs(plan->m_name));
		send_to_plan(plan->m_name, "fp:chat", pack("*** "+peer.name+" joined"));
		if(role_manages(peer_role(peer_id)))
			send_members(peer_id);
	}

	// Out of the plan the user is in, if any: their locks go, the others
	// stop showing them
	void leave_plan(network::PeerId peer_id)
	{
		auto it = m_peers.find(peer_id);
		if(it == m_peers.end() || it->second.plan.empty())
			return;
		const ss_ plan = it->second.plan;
		it->second.plan.clear();
		it->second.has_presence = false;
		auto p = m_plans.find(plan);
		if(p != m_plans.end())
			unlock_all(*p->second, peer_id);
		send_to_plan(plan, "fp:gone", pack((int32_t)peer_id));
		if(!it->second.name.empty())
			send_to_plan(plan, "fp:chat", pack("*** "+it->second.name+" left"));
	}

	// Out of the plan and back to the plans page
	void to_plans(network::PeerId peer, const ss_ &why)
	{
		leave_plan(peer);
		send(peer, "fp:closed", pack(why));
		send_plans(peer);
	}

	struct OpenRequest
	{
		ss_ name;
		uint8_t create = 0;
		template<class Archive>
		void serialize(Archive &archive){
			archive(name, create);
		}
	};

	void on_open(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		OpenRequest req;
		if(it == m_peers.end() || it->second.name.empty() ||
				!unpack(packet.data, req))
			return;
		const ss_ user = it->second.name;
		auto refuse = [&](const ss_ &why){
			send(packet.sender, "fp:open_result", pack(why));
		};
		if(!valid_plan_name(req.name))
			return refuse("A plan's name is 1 to 40 letters, digits, _ or -, "
					"not starting with _");
		bool exists = false;
		for(const ss_ &n : plan_names())
			exists |= n == req.name;
		if(req.create && (exists || name_taken(req.name)))
			return refuse("There is a plan called "+req.name+" already");
		if(!req.create && !exists)
			return refuse("There is no plan called "+req.name);
		if(exists && role_in(plan_meta(req.name), user).empty())
			return refuse("The plan "+req.name+" is not open to you");
		if(req.create && !plan_refusal(user).empty())
			return refuse(plan_refusal(user));
		Plan *plan = open_plan(req.name, req.create);
		if(!plan)
			return refuse("Could not open the plan "+req.name);
		if(req.create){
			// Anyone can make a plan, and it is theirs
			plan->m_store->set("meta/owner", user);
			usage_add(req.name, user, plan->bytes());
			log_i(MODULE, "%s made the plan %s", cs(user), cs(req.name));
		}
		refuse("");
		enter_plan(packet.sender, plan);
		send_plans_to_idle();
	}

	void on_leave_plan(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		if(it == m_peers.end() || it->second.name.empty())
			return;
		to_plans(packet.sender, "");
		send_plans_to_idle();
	}

	// The others on the plans page see who is in which
	void send_plans_to_idle()
	{
		for(auto &pair : m_peers)
			if(!pair.second.name.empty() && pair.second.plan.empty())
				send_plans(pair.first);
	}

	// **A copy of the plan under a new name, which is the copier's**
	// ([FP_COPY], [FP_PLANS] 5). The plan is flushed first, and nothing
	// writes to it until the copy is done, so its database and write-ahead
	// log are copied as they are; its images go with it, its backups and
	// its members do not.
	void on_copy_plan(const network::Packet &packet)
	{
		ss_ name;
		Plan *from_plan = plan_of(packet.sender);
		if(!from_plan || !unpack(packet.data, name))
			return;
		const ss_ user = m_peers[packet.sender].name;
		auto refuse = [&](const ss_ &why){
			send(packet.sender, "fp:open_result", pack(why));
		};
		if(!valid_plan_name(name))
			return refuse("\""+name+"\" is not a name a plan can have");
		if(name_taken(name))
			return refuse("There is a plan called \""+name+"\" already");
		const ss_ full = plan_refusal(user, from_plan->bytes());
		if(!full.empty())
			return refuse(full);
		namespace fs = interface::fs;
		from_plan->flush();
		const ss_ from = from_plan->m_save->path();
		const size_t slash = from.find_last_of("/\\");
		const ss_ to = (slash == ss_::npos ? ss_(".") : from.substr(0, slash))+
				"/"+name;
		fs::create_directories(to+"/images");
		bool ok = fs::copy_file(from+"/save.sqlite", to+"/save.sqlite");
		if(fs::path_exists(from+"/save.sqlite-wal"))
			ok = fs::copy_file(from+"/save.sqlite-wal", to+"/save.sqlite-wal") &&
					ok;
		for(const fs::Node &n : fs::list_directory(from+"/images"))
			if(!n.is_directory)
				ok = fs::copy_file(from+"/images/"+n.name, to+"/images/"+n.name) &&
						ok;
		// Its branch point with it ([FP_GHOST])
		const ss_ dir = slash == ss_::npos ? ss_(".") : from.substr(0, slash);
		if(ok && fs::path_exists(dir+"/"+bp_name(from_plan->m_name)+"/save.sqlite"))
			ok = copy_save(dir+"/"+bp_name(from_plan->m_name),
					dir+"/"+bp_name(name));
		Plan *copy = ok ? open_plan(name, false) : nullptr;
		if(!copy){
			fs::remove_all(dir+"/"+bp_name(name));
			log_e(MODULE, "Could not copy the plan %s into %s",
					cs(from_plan->m_name), cs(to));
			fs::remove_all(to);
			return refuse("Could not copy the plan");
		}
		copy->m_store->set("meta/owner", user);
		for(const ss_ &key : copy->m_store->list("role/"))
			copy->m_store->remove(key);
		usage_add(name, user, copy->bytes());
		log_i(MODULE, "%s copied the plan %s as %s", cs(user),
				cs(from_plan->m_name), cs(name));
		refuse("");
		enter_plan(packet.sender, copy);
		send_plans_to_idle();
	}

	// **The branch point** ([FP_GHOST], user 2026-10-09): the plan as it
	// was, or another plan imported as that, a frozen copy in the save
	// _bp_<plan> beside it -- hidden as every _ name is -- noted in the
	// plan's meta/branch_point ("<time> <from>"). One a plan; a new one
	// replaces it. With the plan's "ghost" setting on, its entities go to
	// everyone in the plan, and the client draws the current layout's
	// walls and rooms of it faded in 2D; the ids are the plan's own, a
	// copy keeping them, so a layout is matched by its id.
	// simplified: the whole save is sent, not only the layout viewed, and
	// its bytes are not counted in the owner's storage
	static ss_ bp_name(const ss_ &plan)
	{
		return "_bp_"+plan;
	}

	// A save's database and write-ahead log into another directory
	static bool copy_save(const ss_ &from, const ss_ &to)
	{
		namespace fs = interface::fs;
		fs::remove_all(to);
		fs::create_directories(to);
		bool ok = fs::copy_file(from+"/save.sqlite", to+"/save.sqlite");
		if(fs::path_exists(from+"/save.sqlite-wal"))
			ok = fs::copy_file(from+"/save.sqlite-wal", to+"/save.sqlite-wal") &&
					ok;
		if(!ok)
			fs::remove_all(to);
		return ok;
	}

	bool ghost_on(Plan *plan)
	{
		ss_ bp;
		if(!plan->m_store || !plan->m_store->get("meta/branch_point", bp) ||
				bp.empty())
			return false;
		for(auto &pair : plan->m_ents){
			if(pair.second.type == "settings"){
				auto it = pair.second.ints.find("ghost");
				return it != pair.second.ints.end() && it->second == 1;
			}
		}
		return false;
	}

	// The branch point's save read, and closed again
	void read_ghost(Plan *plan)
	{
		if(plan->m_ghost_read)
			return;
		plan->m_ghost_read = true;
		plan->m_ghost.clear();
		Plan bp(m_server, bp_name(plan->m_name));
		storage::access(m_server, [&](storage::Interface *istorage){
			bp.m_save = istorage->open(bp.m_name);
		});
		if(!bp.m_save){
			log_w(MODULE, "Could not open the branch point %s", cs(bp.m_name));
			return;
		}
		bp.m_store = bp.m_save->store("main");
		if(bp.load())
			for(auto &pair : bp.m_ents)
				plan->m_ghost.push_back(pair.second);
		close_save(&bp);
	}

	struct GhostOut
	{
		ss_ info;               // "" with no branch point
		sv_<Entity> ents;       // empty with the ghost off
		template<class Archive>
		void serialize(Archive &archive){
			archive(info, ents);
		}
	};

	// To everyone in the plan, or to one peer
	void send_ghost(Plan *plan, network::PeerId only = 0)
	{
		GhostOut out;
		ss_ bp;
		if(plan->m_store && plan->m_store->get("meta/branch_point", bp) &&
				!bp.empty()){
			const size_t sp = bp.find(' ');
			const int64_t t = std::atoll(bp.substr(0, sp).c_str());
			out.info = backup_label(t, (int64_t)time(nullptr))+
					(sp == ss_::npos ? ss_() : ", from "+bp.substr(sp + 1));
		}
		plan->m_ghost_on = ghost_on(plan);
		if(plan->m_ghost_on){
			read_ghost(plan);
			out.ents = plan->m_ghost;
		}
		const ss_ data = pack(out);
		for(auto &pair : m_peers)
			if(pair.second.plan == plan->m_name &&
					(only == 0 || pair.first == only))
				send(pair.first, "fp:ghost", data);
	}

	struct BranchPointRequest
	{
		ss_ cmd;   // "here", "import" or "remove"
		ss_ arg;   // the plan imported
		template<class Archive>
		void serialize(Archive &archive){
			archive(cmd, arg);
		}
	};

	// For whoever may edit the plan; an import needs the other plan read
	void on_branch_point(const network::Packet &packet)
	{
		BranchPointRequest r;
		Plan *plan = plan_of(packet.sender);
		if(!plan || !unpack(packet.data, r))
			return;
		const ss_ user = m_peers[packet.sender].name;
		auto refuse = [&](const ss_ &why){
			send(packet.sender, "fp:chat", pack(why));
		};
		if(!plan->m_backup_of.empty() || !role_edits(peer_role(packet.sender)))
			return refuse("Only an editor of the plan sets its branch point");
		namespace fs = interface::fs;
		const ss_ path = plan->m_save->path();
		const size_t slash = path.find_last_of("/\\");
		const ss_ to = (slash == ss_::npos ? ss_(".") : path.substr(0, slash))+
				"/"+bp_name(plan->m_name);
		ss_ said;
		if(r.cmd == "remove"){
			storage::access(m_server, [&](storage::Interface *istorage){
				istorage->remove(bp_name(plan->m_name));
			});
			plan->m_store->remove("meta/branch_point");
			said = user+" removed the branch point";
		} else if(r.cmd == "here" || r.cmd == "import"){
			Plan *from = plan;
			if(r.cmd == "import"){
				bool exists = false;
				for(const ss_ &n : plan_names())
					exists |= n == r.arg;
				if(!exists || role_in(plan_meta(r.arg), user).empty())
					return refuse("No plan called "+r.arg+" is open to you");
				from = open_plan(r.arg, false);
				if(!from)
					return refuse("Could not open the plan "+r.arg);
			}
			from->flush();
			if(!copy_save(from->m_save->path(), to)){
				log_e(MODULE, "Could not copy %s into %s", cs(from->m_name),
						cs(to));
				return refuse("Could not copy the plan");
			}
			plan->m_store->set("meta/branch_point",
					itos((int64_t)time(nullptr))+" "+from->m_name);
			said = user+" set the branch point"+(from == plan ? ss_() :
					" from the plan "+from->m_name);
		} else {
			return;
		}
		log_i(MODULE, "%s (%s)", cs(said), cs(plan->m_name));
		plan->m_ghost_read = false;
		send_ghost(plan);
		send_to_plan(plan->m_name, "fp:chat", pack("*** "+said));
	}

	// **A plan's backups, to look at** ([FP_BACKUPS], user 2026-09-30):
	// for anyone who may read the plan, since a reader is as likely to be
	// the one who finds it broken. One opens as a plan of its own, a copy
	// of the backup that everyone in reads and nobody edits, gone when it
	// closes; Copy this plan makes a plan of it to keep.

	// The plan a peer's backups are of: the one they are in, or the one
	// the backup they are in is of
	Plan* backups_plan(network::PeerId peer)
	{
		Plan *plan = plan_of(peer);
		if(!plan)
			return nullptr;
		if(plan->m_backup_of.empty())
			return plan;
		return open_plan(plan->m_backup_of, false);
	}

	struct BackupRow
	{
		ss_ id;
		ss_ label;
		template<class Archive>
		void serialize(Archive &archive){
			archive(id, label);
		}
	};

	void on_backups(const network::Packet &packet)
	{
		Plan *plan = backups_plan(packet.sender);
		if(!plan || peer_role(packet.sender).empty())
			return;
		const int64_t now = (int64_t)time(nullptr);
		sv_<BackupRow> rows;
		for(int64_t id : Plan::list_backups(plan->m_save->path())){
			BackupRow r;
			r.id = itos(id);
			r.label = backup_label(id, now);
			rows.push_back(r);
		}
		send(packet.sender, "fp:backups", pack(std::make_pair(plan->m_name,
				rows)));
	}

	void on_open_backup(const network::Packet &packet)
	{
		ss_ id_s;
		Plan *of = backups_plan(packet.sender);
		if(!of || peer_role(packet.sender).empty() || !unpack(packet.data, id_s))
			return;
		auto refuse = [&](const ss_ &why){
			send(packet.sender, "fp:open_result", pack(why));
		};
		const ss_ path = of->m_save->path();
		int64_t id = 0;
		for(int64_t b : Plan::list_backups(path))
			if(itos(b) == id_s)
				id = b;
		if(id == 0)
			return refuse("There is no such backup");
		const ss_ name = "_backup-"+of->m_name+"-"+itos(id);
		Plan *view = nullptr;
		auto it = m_plans.find(name);
		if(it != m_plans.end()){
			view = it->second.get();
		} else {
			// Beside the plans, as a copy is, with the plan's pictures
			namespace fs = interface::fs;
			const size_t slash = path.find_last_of("/\\");
			const ss_ to = (slash == ss_::npos ? ss_(".") : path.substr(0, slash))+
					"/"+name;
			const ss_ from = Plan::backup_dir(path, id);
			fs::remove_all(to);
			fs::create_directories(to+"/images");
			bool ok = fs::copy_file(from+"/save.sqlite", to+"/save.sqlite");
			if(fs::path_exists(from+"/save.sqlite-wal"))
				ok = fs::copy_file(from+"/save.sqlite-wal",
						to+"/save.sqlite-wal") && ok;
			for(const fs::Node &n : fs::list_directory(path+"/images"))
				if(!n.is_directory)
					ok = fs::copy_file(path+"/images/"+n.name,
							to+"/images/"+n.name) && ok;
			up_<Plan> plan(new Plan(m_server, name));
			plan->m_backup_of = of->m_name;
			plan->m_backup_id = id;
			if(ok){
				storage::access(m_server, [&](storage::Interface *istorage){
					plan->m_save = istorage->open(name);
				});
			}
			if(plan->m_save){
				plan->m_store = plan->m_save->store("main");
				if(!plan->load()){
					close_save(plan.get());
					plan->m_save = nullptr;
				}
			}
			if(!plan->m_save){
				log_e(MODULE, "Could not open the backup %s", cs(name));
				fs::remove_all(to);
				return refuse("Could not open the backup");
			}
			plan->find_images();
			view = plan.get();
			m_plans[name] = std::move(plan);
			log_i(MODULE, "%s opened the backup %s", cs(m_peers[packet.sender].name),
					cs(name));
		}
		refuse("");
		enter_plan(packet.sender, view);
		send_plans_to_idle();
	}

	// **A backup put back as the plan** (user, 2026-09-30), by someone who
	// may edit the plan, from the backup they are looking at: everyone
	// stays on the one plan rather than moving to a copy. The plan as it
	// was goes into a backup first, so a restore can be taken back the same
	// way; its members, owner and pictures stay. Everyone in it gets it
	// again, as a new join does.
	void on_restore_backup(const network::Packet &packet)
	{
		Plan *view = plan_of(packet.sender);
		if(!view || view->m_backup_of.empty())
			return;
		const ss_ user = m_peers[packet.sender].name;
		auto refuse = [&](const ss_ &why){
			send(packet.sender, "fp:open_result", pack(why));
		};
		if(!role_edits(role_in(plan_meta(view->m_backup_of), user)))
			return refuse("You cannot edit "+view->m_backup_of);
		Plan *plan = open_plan(view->m_backup_of, false);
		if(!plan)
			return refuse("Could not open "+view->m_backup_of);
		plan->flush();
		plan->backup(plan->m_save->path());
		for(auto &pair : plan->m_ents)
			if(!view->m_ents.count(pair.first))
				plan->m_dirty.insert(pair.first);
		for(auto &pair : plan->m_voxels)
			if(!view->m_voxels.count(pair.first))
				plan->m_voxels_dirty.insert(pair.first);
		plan->m_ents = view->m_ents;
		for(auto &pair : plan->m_ents)
			plan->m_dirty.insert(pair.first);
		plan->m_voxels = view->m_voxels;
		for(auto &pair : plan->m_voxels)
			plan->m_voxels_dirty.insert(pair.first);
		// Ids on from both, so nothing new takes one an undo remembers
		plan->m_next_id = std::max(plan->m_next_id, view->m_next_id);
		plan->m_locks.clear();
		plan->flush();
		const ss_ label = backup_label(view->m_backup_id, (int64_t)time(nullptr));
		log_i(MODULE, "%s restored %s to its backup %s", cs(user),
				cs(plan->m_name), cs(itos(view->m_backup_id)));
		const ss_ why = user+" restored the plan to its backup of "+label;
		for(auto &pair : m_peers){
			if(pair.second.plan != plan->m_name || pair.first == packet.sender)
				continue;
			pair.second.plan.clear();
			send(pair.first, "fp:closed", pack(why));
			enter_plan(pair.first, plan);
		}
		refuse("");
		send(packet.sender, "fp:closed", pack(why));
		enter_plan(packet.sender, plan);
		send_plans_to_idle();
	}

	// **A plan as a file** ([FP_EXPORT] 2), for anyone in it: from the plan
	// as it is in memory, so its database is not touched, with the pictures
	// its images use
	struct ExportResult
	{
		ss_ error;
		ss_ name; // the plan's
		ss_ file;

		template<class Archive>
		void serialize(Archive &archive){
			archive(error, name, file);
		}
	};

	void on_export(const network::Packet &packet)
	{
		Plan *plan = plan_of(packet.sender);
		if(!plan || !spend_msg(packet.sender, 100))
			return;
		PlanFile f;
		f.magic = EXPORT_MAGIC;
		f.format = EXPORT_FORMAT;
		f.schema = SCHEMA_VERSION;
		set_<ss_> used;
		for(auto &pair : plan->m_ents){
			f.ents.push_back(pair.second);
			auto file = pair.second.strs.find("file");
			if(pair.second.type == "image" && file != pair.second.strs.end())
				used.insert(file->second);
		}
		for(auto &pair : plan->m_voxels)
			if(plan->m_ents.count(pair.first) && !pair.second.empty())
				f.voxels[pair.first] = pair.second;
		for(const ss_ &name : plan->m_images){
			if(!used.count(name))
				continue;
			std::ifstream is(plan->m_save->path()+"/images/"+name,
					std::ios::binary);
			std::ostringstream data;
			data<<is.rdbuf();
			if(!is.good() && !is.eof())
				continue;
			f.images.push_back(ExportImage{name, data.str()});
		}
		ExportResult r;
		r.name = plan->m_name;
		r.file = pack(f);
		log_i(MODULE, "%s exported the plan %s (%zu bytes)",
				cs(m_peers[packet.sender].name), cs(plan->m_name), r.file.size());
		send(packet.sender, "fp:export_data", pack(r));
	}

	// **A plan from a file** ([FP_EXPORT] 3), for anyone logged in, as a new
	// plan of theirs. Nothing in the file is taken on trust: the entities go
	// through apply(), as every edit does, the voxels through the checks an
	// edit's do, and the pictures are checked for what they claim to be.
	// Anything refused leaves no plan behind.
	struct ImportRequest
	{
		ss_ name;
		ss_ file;

		template<class Archive>
		void serialize(Archive &archive){
			archive(name, file);
		}
	};

	void on_import(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		if(it == m_peers.end() || it->second.name.empty())
			return;
		const ss_ user = it->second.name;
		auto refuse = [&](const ss_ &why){
			send(packet.sender, "fp:open_result", pack(why));
		};
		ImportRequest req;
		if(packet.data.size() > MAX_IMPORT_BYTES)
			return refuse("The file is over "+itos(MAX_IMPORT_BYTES >> 20)+
					" MiB");
		if(!unpack(packet.data, req))
			return;
		if(!valid_plan_name(req.name))
			return refuse("\""+req.name+"\" is not a name a plan can have");
		if(name_taken(req.name))
			return refuse("There is a plan called \""+req.name+"\" already");
		const ss_ full = plan_refusal(user, req.file.size());
		if(!full.empty())
			return refuse(full);
		PlanFile f;
		if(!unpack(req.file, f) || f.magic != EXPORT_MAGIC)
			return refuse("That is not a plan file");
		if(f.format != EXPORT_FORMAT)
			return refuse("That plan file is of another format ("+
					itos(f.format)+")");
		// simplified: the same schema only; an older one needs load()'s
		// migrations applied to the file
		if(f.schema != SCHEMA_VERSION)
			return refuse("That plan file is from another version (schema "+
					itos(f.schema)+", here "+itos(SCHEMA_VERSION)+")");
		if(f.images.size() > MAX_IMPORT_IMAGES)
			return refuse("The file has over "+itos(MAX_IMPORT_IMAGES)+
					" pictures");
		set_<ss_> image_names;
		for(const ExportImage &im : f.images){
			if(!valid_image_name(im.name) || !image_names.insert(im.name).second
					|| im.data.size() > MAX_IMAGE_BYTES ||
					!image_matches_name(im.name, im.data))
				return refuse("A picture in the file is not one a plan can "
						"have");
		}

		// The ops: every entity made, and then its references set, since
		// apply() resolves a placeholder when it meets it. The file's ids
		// become placeholders; a singleton is set on the new plan's own.
		sv_<Op> makes, refs;
		set_<int32_t> ids;
		for(const Entity &e : f.ents){
			const TypeSchema *sc = find_schema(e.type);
			if(!sc)
				return refuse("The file has an entity of an unknown type");
			if(e.id <= 0 || !ids.insert(e.id).second)
				return refuse("The file's entity ids are not valid");
			Op make;
			make.op = sc->singleton ? 1 : 0;
			make.ent.id = -e.id;
			make.ent.type = e.type;
			make.ent.strs = e.strs;
			Op ref;
			ref.op = 1;
			ref.ent.id = -e.id;
			for(auto &pair : e.ints){
				const IntField *field = nullptr;
				for(const IntField &ff : sc->ints)
					if(pair.first == ff.name)
						field = &ff;
				if(!field || !field->ref){
					make.ent.ints[pair.first] = pair.second;
				} else if(pair.second < 0){
					return refuse("The file's references are not valid");
				} else {
					ref.ent.ints[pair.first] = -pair.second;
				}
			}
			for(auto &pair : e.lists){
				const ListField *field = nullptr;
				for(const ListField &ff : sc->lists)
					if(pair.first == ff.name)
						field = &ff;
				if(!field || !field->ref){
					make.ent.lists[pair.first] = pair.second;
					continue;
				}
				sv_<int32_t> &list = ref.ent.lists[pair.first];
				for(int32_t v : pair.second){
					if(v <= 0)
						return refuse("The file's references are not valid");
					list.push_back(-v);
				}
			}
			if(sc->singleton && (!ref.ent.ints.empty() ||
					!ref.ent.lists.empty()))
				return refuse("The file's references are not valid");
			makes.push_back(make);
			if(!ref.ent.ints.empty() || !ref.ent.lists.empty())
				refs.push_back(ref);
		}

		Plan *plan = open_plan(req.name, true);
		if(!plan)
			return refuse("Could not make the plan "+req.name);
		auto discard = [&](const ss_ &why){
			log_i(MODULE, "%s's import as %s refused: %s", cs(user),
					cs(req.name), cs(why));
			close_plan(req.name);
			storage::access(m_server, [&](storage::Interface *istorage){
				istorage->remove(req.name);
			});
			refuse(why);
		};
		// What a new plan starts with goes, the file's own taking its place
		sv_<Op> ops;
		for(auto &pair : plan->m_ents){
			if(find_schema(pair.second.type)->singleton)
				continue;
			Op del;
			del.op = 2;
			del.ent.id = pair.first;
			ops.push_back(del);
		}
		for(Op &op : makes){
			if(op.op == 1){
				Entity *single = plan->find_singleton(op.ent.type);
				if(!single)
					return discard("The plan has no "+op.ent.type);
				op.ent.id = single->id;
			}
			ops.push_back(op);
		}
		ops.insert(ops.end(), refs.begin(), refs.end());
		std::map<int32_t, int32_t> placeholders;
		set_<int32_t> changed, deleted;
		ss_ err = plan->apply(ops, placeholders, changed, deleted);
		if(!err.empty())
			return discard("The plan in the file is not valid: "+err);

		for(auto &vol : f.voxels){
			auto def = placeholders.find(-vol.first);
			auto e = def == placeholders.end() ? plan->m_ents.end() :
					plan->m_ents.find(def->second);
			if(vol.first <= 0 || e == plan->m_ents.end() ||
					e->second.type != "definition" ||
					e->second.ints["kind"] != DK_VOXEL)
				return discard("The file has voxels of no voxel volume");
			if(vol.second.size() > MAX_VOXELS)
				return discard("A voxel volume in the file is too big");
			std::map<int32_t, int32_t> cells;
			for(auto &c : vol.second){
				auto m = c.second > 0 ? placeholders.find(-c.second) :
						placeholders.end();
				auto p = m == placeholders.end() ? plan->m_ents.end() :
						plan->m_ents.find(m->second);
				if(!valid_voxel_key(c.first) || p == plan->m_ents.end() ||
						p->second.type != "palette")
					return discard("The file's voxels are not valid");
				cells[c.first] = m->second;
			}
			plan->m_voxels[def->second] = cells;
			plan->m_voxels_dirty.insert(def->second);
		}

		const ss_ images = plan->m_save->path()+"/images";
		interface::fs::create_directories(images);
		for(const ExportImage &im : f.images){
			std::ofstream os(images+"/"+im.name, std::ios::binary);
			os.write(im.data.data(), im.data.size());
			if(!os.good())
				return discard("Could not write the plan's pictures");
		}
		plan->find_images();
		plan->m_store->set("meta/owner", user);
		plan->flush();
		usage_add(req.name, user, plan->bytes());
		log_i(MODULE, "%s imported the plan %s: %zu entities, %zu voxel volumes,"
				" %zu pictures", cs(user), cs(req.name), f.ents.size(),
				f.voxels.size(), f.images.size());
		refuse("");
		enter_plan(packet.sender, plan);
		send_plans_to_idle();
	}

	// A plan's members ([FP_PLANS] 5), its owner's and an admin's: the
	// accounts with a role here -- not every account, which with open
	// registration is everyone's name to anyone who makes a plan
	// ([FP_GROUPS]) -- and the groups it is shared with
	struct MemberRow
	{
		ss_ name;
		ss_ role;
		template<class Archive>
		void serialize(Archive &archive){
			archive(name, role);
		}
	};

	struct MembersInfo
	{
		ss_ plan;
		ss_ owner;
		ss_ groups; // "name (can read), ..."
		sv_<MemberRow> members;
		template<class Archive>
		void serialize(Archive &archive){
			archive(plan, owner, groups, members);
		}
	};

	void send_members(network::PeerId peer)
	{
		Plan *plan = plan_of(peer);
		if(!plan)
			return;
		PlanMeta m = read_meta(plan->m_store, plan->m_name);
		MembersInfo info;
		info.plan = plan->m_name;
		info.owner = m.owner;
		for(auto &pair : m_groups){
			auto share = pair.second.shares.find(plan->m_name);
			if(share != pair.second.shares.end())
				info.groups += (info.groups.empty() ? "" : ", ")+
						pair.second.name+(share->second == "editor" ?
						" (can edit)" : " (can read)");
		}
		for(auto &pair : m.roles){
			MemberRow row;
			row.name = pair.first;
			row.role = pair.second;
			info.members.push_back(row);
		}
		send(peer, "fp:members", pack(info));
	}

	// Everyone in the plan, after its members changed: what they may do, and
	// for those who manage it the list
	void plan_rights_changed(Plan *plan)
	{
		// The plan's peers, and those in one of its backups: a backup view
		// answers to the plan's rights too (peer_role), and a reader
		// taken off the plan stayed in its backups ([SECURITY_RUN_1])
		const ss_ backups = "_backup-"+plan->m_name+"-";
		for(auto &pair : m_peers){
			const ss_ &in = pair.second.plan;
			if((in != plan->m_name && in.compare(0, backups.size(), backups) != 0)
					|| pair.second.name.empty())
				continue;
			const ss_ role = peer_role(pair.first);
			if(role.empty()){
				to_plans(pair.first, "You are no longer let into this plan");
				continue;
			}
			send_privs(pair.first);
			if(role_manages(role))
				send_members(pair.first);
		}
		send_plans_to_idle();
	}

	void on_plan_admin(const network::Packet &packet)
	{
		AdminRequest r;
		Plan *plan = plan_of(packet.sender);
		if(!plan || !role_manages(peer_role(packet.sender)) ||
				!unpack(packet.data, r))
			return;
		const ss_ by = m_peers[packet.sender].name;
		auto result = [&](const ss_ &text){
			send(packet.sender, "fp:admin_result", pack(text));
		};
		bool exists = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			exists = i->exists(r.name);
		});
		if(r.cmd == "list"){
			// The page as it opens: accounts made since they entered
			return send_members(packet.sender);
		} else if(r.cmd == "role"){
			if(!exists)
				return result("No account "+r.name);
			if(r.arg != "" && r.arg != "editor" && r.arg != "viewer")
				return result("No such role");
			if(r.arg.empty())
				plan->m_store->remove("role/"+r.name);
			else
				plan->m_store->set("role/"+r.name, r.arg);
			log_i(MODULE, "%s made %s %s in %s", cs(by), cs(r.name),
					r.arg.empty() ? "no member" : cs(r.arg), cs(plan->m_name));
			result("");
		} else if(r.cmd == "delete"){
			const ss_ name = plan->m_name;
			const PlanMeta gone = plan_meta(name);
			usage_remove(name, gone.owner, gone.bytes);
			for(auto &pair : m_peers)
				if(pair.second.plan == name)
					to_plans(pair.first, "The plan was deleted by "+by);
			close_plan(name);
			storage::access(m_server, [&](storage::Interface *istorage){
				istorage->remove(name);
				istorage->remove(bp_name(name));
			});
			log_i(MODULE, "%s deleted the plan %s", cs(by), cs(name));
			for(auto &pair : m_groups)
				if(pair.second.shares.erase(name))
					save_group(pair.first);
			send_groups_all();
			send_plans_to_idle();
			return;
		} else {
			return;
		}
		plan_rights_changed(plan);
	}

	// Storage ([FP_GROUPS]): what a user's plans take, against USER_BYTES

	// What the plans take, by owner, and how many each owns; with the
	// server's total, which [FP_ABUSE]'s budget is of.
	// simplified: kept for USAGE_KEEP_S, so that a stream of edits does
	// not open every closed plan each time; a user can go that much over
	static constexpr int64_t USAGE_KEEP_S = 10;
	struct Usage
	{
		int64_t at = -USAGE_KEEP_S;
		std::map<ss_, uint64_t> bytes;
		std::map<ss_, size_t> plans;
		uint64_t total = 0;
		std::map<ss_, ss_> owner; // plan -> its owner
	} m_usage;

	const Usage& usage_all()
	{
		const int64_t now = (int64_t)time(nullptr);
		if(now - m_usage.at < USAGE_KEEP_S)
			return m_usage;
		Usage u;
		u.at = now;
		for(const ss_ &name : plan_names()){
			PlanMeta m = plan_meta(name);
			u.bytes[m.owner] += m.bytes;
			u.plans[m.owner]++;
			u.total += m.bytes;
			u.owner[name] = m.owner;
		}
		u.bytes.erase("");
		m_usage = u;
		accounts::access(m_server, [&](accounts::Interface *i){
			i->report_storage("floorplanner", m_usage.bytes);
		});
		return m_usage;
	}

	// A plan made or gone, in the cache at once: a burst inside
	// USAGE_KEEP_S went past MAX_PLANS and USER_BYTES, and a refresh for
	// each change is every plan opened again ([SECURITY_RUN_3])
	void usage_add(const ss_ &plan, const ss_ &user, uint64_t bytes)
	{
		if((int64_t)time(nullptr) - m_usage.at >= USAGE_KEEP_S){
			usage_all(); // read from the plans, the new one with them
			return;
		}
		m_usage.plans[user]++;
		m_usage.bytes[user] += bytes;
		m_usage.total += bytes;
		m_usage.owner[plan] = user;
	}

	void usage_remove(const ss_ &plan, const ss_ &user, uint64_t bytes)
	{
		if(!m_usage.owner.erase(plan))
			return;
		if(m_usage.plans[user])
			m_usage.plans[user]--;
		m_usage.bytes[user] -= std::min(m_usage.bytes[user], bytes);
		m_usage.total -= std::min(m_usage.total, bytes);
	}

	uint64_t usage(const ss_ &user)
	{
		const Usage &u = usage_all();
		auto it = u.bytes.find(user);
		return it == u.bytes.end() ? 0 : it->second;
	}

	int level_of(const ss_ &user)
	{
		int lv = accounts::LV_NEW;
		accounts::access(m_server, [&](accounts::Interface *i){
			lv = i->level(user);
		});
		return lv;
	}

	// [FP_ABUSE] 3: why `user` may not make another plan, "" when they may
	ss_ plan_refusal(const ss_ &user, uint64_t more = 0)
	{
		if(!is_admin(user)){
			const Usage &u = usage_all();
			auto it = u.plans.find(user);
			if(it != u.plans.end() && it->second >= MAX_PLANS)
				return "You have "+itos((int)MAX_PLANS)+" plans, as many as "
						"anyone has: delete one first";
		}
		return over_limit(user, more);
	}

	// Why `user` may not take `more` bytes: "" when they may
	ss_ over_limit(const ss_ &user, uint64_t more = 0)
	{
		if(is_admin(user))
			return "";
		// [FP_ABUSE] 3: the server's budget, for an untrusted account
		if(level_of(user) < accounts::LV_MEMBER){
			uint64_t budget = 0;
			accounts::access(m_server, [&](accounts::Interface *i){
				budget = i->storage_budget();
			});
			if(usage_all().total + more > budget)
				return "This server's storage for new accounts is full: "
						"nothing more can be kept for one until it is trusted";
		}
		const uint64_t used = usage(user);
		if(used + more <= USER_BYTES)
			return "";
		return "Your plans use "+mb_text(used)+" of the "+mb_text(USER_BYTES)+
				" each user has"+(more ? ", and this takes "+mb_text(more) :
				ss_())+": delete something first";
	}

	// A batch that makes something, or voxels added, in a plan whose owner
	// is past the limit; changing and deleting go on
	ss_ grows_past_limit(Plan &plan, const sv_<Op> &ops, size_t voxels_added)
	{
		bool grows = voxels_added > 0;
		for(const Op &op : ops)
			grows |= op.op == 0;
		if(!grows)
			return "";
		ss_ owner;
		plan.m_store->get("meta/owner", owner);
		if(owner.empty())
			return "";
		const ss_ why = over_limit(owner);
		if(why.empty())
			return "";
		return "Nothing more can be added to "+owner+"'s plan, only changed "
				"or deleted: "+why;
	}

	// Groups ([FP_GROUPS])

	void load_groups()
	{
		storage::Store *store = m_groups_save->store("main");
		ss_ v;
		if(store->get("next", v))
			m_next_group = std::max(1, atoi(v.c_str()));
		for(const ss_ &key : store->list("g/")){
			Group g;
			if(store->get(key, v) && unpack(v, g))
				m_groups[atoi(key.substr(2).c_str())] = g;
		}
		for(auto &pair : m_groups){
			GroupMore more;
			if(store->get("m/"+itos(pair.first), v) && unpack(v, more))
				m_more[pair.first] = more;
		}
		log_i(MODULE, "%zu groups", m_groups.size());
	}

	void save_group(int32_t id)
	{
		storage::Store *store = m_groups_save->store("main");
		auto it = m_groups.find(id);
		if(it == m_groups.end()){
			store->remove("g/"+itos(id));
			store->remove("m/"+itos(id));
			m_more.erase(id);
		} else {
			store->set("g/"+itos(id), pack(it->second));
			store->set("m/"+itos(id), pack(m_more[id]));
		}
	}

	// [FP_ABUSE] 1: a group is trusted when every admin of it is, and its
	// maker: an untrusted maker made a trusted member an admin without
	// asking them, stepped down, and its own edits counted
	// ([SECURITY_RUN_3])
	bool group_trusted(int32_t id)
	{
		const Group &g = m_groups[id];
		auto more = m_more.find(id);
		if(more != m_more.end() && !more->second.creator.empty() &&
				level_of(more->second.creator) < accounts::LV_MEMBER)
			return false;
		for(auto &m : g.members)
			if(m.second == "admin" && level_of(m.first) < accounts::LV_MEMBER)
				return false;
		return true;
	}

	// An edit saved by `user`: a calendar day of TRUST_DAYS, while they
	// are in a trusted group, and on the last of them they are trusted
	void note_edit(const ss_ &user)
	{
		const int64_t day = calendar_s() / 86400;
		auto it = m_edit_day.find(user);
		if(it != m_edit_day.end() && it->second == day)
			return;
		m_edit_day[user] = day;
		if(level_of(user) >= accounts::LV_MEMBER)
			return;
		bool in_trusted = false;
		for(auto &pair : m_groups)
			if(pair.second.members.count(user) && group_trusted(pair.first))
				in_trusted = true;
		if(!in_trusted)
			return;
		storage::Store *store = m_groups_save->store("main");
		ss_ v;
		int64_t last = -1;
		int days = 0;
		if(store->get("days/"+user, v))
			sscanf(v.c_str(), "%lld %d", (long long*)&last, &days);
		if(last == day)
			return;
		days++;
		store->set("days/"+user, itos(day)+" "+itos(days));
		log_i(MODULE, "%s edited on a day in a trusted group (%i of %i)",
				cs(user), days, TRUST_DAYS);
		if(days < TRUST_DAYS)
			return;
		ss_ why;
		accounts::access(m_server, [&](accounts::Interface *i){
			why = i->set_level(user, accounts::LV_MEMBER);
		});
		if(!why.empty()){
			log_w(MODULE, "%s could not be trusted: %s", cs(user), cs(why));
			return;
		}
		store->remove("days/"+user);
		log_i(MODULE, "%s is trusted: edits on %i days in a trusted group",
				cs(user), TRUST_DAYS);
		send_groups_all();
	}

	// Invites made by `user` this calendar day, and one more counted
	int invites_today(const ss_ &user, bool count)
	{
		storage::Store *store = m_groups_save->store("main");
		const int64_t day = calendar_s() / 86400;
		ss_ v;
		long long last = -1;
		int n = 0;
		if(store->get("invday/"+user, v))
			sscanf(v.c_str(), "%lld %d", &last, &n);
		if(last != day)
			n = 0;
		if(count)
			store->set("invday/"+user, itos(day)+" "+itos(++n));
		return n;
	}

	struct GroupRow
	{
		int32_t id = 0;
		ss_ name;
		ss_ role; // the user's: admin or member
		std::map<ss_, ss_> members;
		sv_<ss_> invites; // for its admins
		sv_<std::pair<ss_, std::pair<ss_, ss_>>> shares; // plan, owner, role
		// [FP_ABUSE] 1: whether it is, and its members who are not
		uint8_t trusted = 0;
		sv_<ss_> untrusted;
		template<class Archive>
		void serialize(Archive &archive){
			archive(id, name, role, members, invites, shares, trusted,
					untrusted);
		}
	};
	struct InviteRow
	{
		int32_t id = 0;
		ss_ name;
		ss_ by;
		template<class Archive>
		void serialize(Archive &archive){
			archive(id, name, by);
		}
	};
	struct GroupsInfo
	{
		sv_<GroupRow> groups;
		sv_<InviteRow> invites; // to this user
		sv_<ss_> own_plans;
		int32_t used_kib = 0;
		int32_t limit_kib = 0; // 0: none (the admin)
		template<class Archive>
		void serialize(Archive &archive){
			archive(groups, invites, own_plans, used_kib, limit_kib);
		}
	};

	// A user's groups, the invites to them, their plans to share and their
	// storage
	void send_groups(network::PeerId peer)
	{
		const ss_ user = m_peers[peer].name;
		if(user.empty())
			return;
		GroupsInfo info;
		// From the usage cache: opening every plan for each peer after each
		// group's change held the server for seconds ([SECURITY_RUN_3])
		std::map<ss_, ss_> owners = usage_all().owner;
		for(auto &pair : owners)
			if(pair.second == user)
				info.own_plans.push_back(pair.first);
		for(auto &pair : m_groups){
			const Group &g = pair.second;
			auto inv = g.invites.find(user);
			if(inv != g.invites.end()){
				InviteRow i;
				i.id = pair.first;
				i.name = g.name;
				i.by = inv->second;
				info.invites.push_back(i);
			}
			auto me = g.members.find(user);
			if(me == g.members.end())
				continue;
			GroupRow row;
			row.id = pair.first;
			row.name = g.name;
			row.role = me->second;
			row.members = g.members;
			if(me->second == "admin")
				for(auto &i : g.invites)
					row.invites.push_back(i.first);
			for(auto &sh : g.shares)
				row.shares.push_back(std::make_pair(sh.first,
						std::make_pair(owners[sh.first], sh.second)));
			row.trusted = group_trusted(pair.first);
			for(auto &m : g.members)
				if(level_of(m.first) < accounts::LV_MEMBER)
					row.untrusted.push_back(m.first);
			info.groups.push_back(row);
		}
		const bool admin = is_admin(user);
		info.used_kib = (int32_t)std::min<uint64_t>(usage(user) / 1024,
				INT32_MAX);
		info.limit_kib = admin ? 0 : (int32_t)(USER_BYTES / 1024);
		send(peer, "fp:groups", pack(info));
	}

	// After a group changed: each user's view of theirs, and everyone in a
	// plan checked again, since a share or a membership changes roles
	// simplified: everyone online, each their own; a server with many
	// users would send to the group's members only
	void send_groups_all()
	{
		for(auto &pair : m_peers)
			send_groups(pair.first);
		for(auto &pair : m_peers){
			const ss_ &in = pair.second.plan;
			if(in.empty() || pair.second.name.empty())
				continue;
			const ss_ role = peer_role(pair.first);
			if(role.empty()){
				to_plans(pair.first, "You are no longer let into this plan");
				continue;
			}
			send_privs(pair.first);
			if(role_manages(role))
				send_members(pair.first);
		}
		send_plans_to_idle();
	}

	struct GroupRequest
	{
		ss_ cmd;
		int32_t group = 0;
		ss_ name; // a user's or a plan's
		ss_ arg;
		template<class Archive>
		void serialize(Archive &archive){
			archive(cmd, group, name, arg);
		}
	};

	void on_group(const network::Packet &packet)
	{
		auto pit = m_peers.find(packet.sender);
		GroupRequest r;
		if(pit == m_peers.end() || pit->second.name.empty() ||
				!spend_msg(packet.sender, 5) || !unpack(packet.data, r))
			return;
		const ss_ user = pit->second.name;
		auto result = [&](const ss_ &text){
			send(packet.sender, "fp:group_result", pack(text));
		};
		if(r.cmd == "list")
			return send_groups(packet.sender);
		if(r.cmd == "create"){
			if(r.name.empty() || r.name.size() > 40 || !valid_text(r.name))
				return result("A group's name is 1 to 40 characters");
			size_t made = 0;
			for(auto &m : m_more)
				made += m.second.creator == user;
			if(made >= MAX_MADE_GROUPS && !is_admin(user))
				return result("You have made "+itos((int)MAX_MADE_GROUPS)+
						" groups, as many as anyone makes: delete one first");
			const int32_t id = m_next_group++;
			m_groups_save->store("main")->set("next", itos(m_next_group));
			m_groups[id].name = r.name;
			m_groups[id].members[user] = "admin";
			m_more[id].creator = user;
			m_more[id].joined[user] = calendar_s();
			save_group(id);
			log_i(MODULE, "%s made the group %i (%s)", cs(user), id, cs(r.name));
			result("");
			return send_groups_all();
		}
		auto git = m_groups.find(r.group);
		if(git == m_groups.end())
			return result("There is no such group");
		Group &g = git->second;
		const int32_t id = git->first;
		GroupMore &more = m_more[id];
		auto me = g.members.find(user);
		const bool member = me != g.members.end();
		const bool admin = member && me->second == "admin";
		size_t admins = 0;
		for(auto &m : g.members)
			admins += m.second == "admin";
		// A member out: their plans' shares go with them
		auto drop_member = [&](const ss_ &who){
			g.members.erase(who);
			more.joined.erase(who);
			for(auto it = g.shares.begin(); it != g.shares.end();){
				if(plan_meta(it->first).owner == who)
					it = g.shares.erase(it);
				else
					++it;
			}
		};
		if(r.cmd == "accept" || r.cmd == "decline" || r.cmd == "block"){
			if(!g.invites.erase(user))
				return result("There is no invite to that group");
			if(r.cmd == "accept"){
				g.members[user] = "member";
				more.joined[user] = calendar_s();
			} else {
				more.declined[user] = calendar_s();
			}
			if(r.cmd == "block")
				more.blocked[user] = calendar_s();
			log_i(MODULE, "%s %s the invite to the group %i", cs(user),
					r.cmd == "accept" ? "accepted" : r.cmd == "decline" ?
					"declined" : "declined, and takes no more from", id);
		} else if(!member){
			return result("You are not in that group");
		} else if(r.cmd == "leave"){
			if(admin && admins == 1 && g.members.size() > 1)
				return result("Make another member an admin first, or delete "
						"the group");
			drop_member(user);
			log_i(MODULE, "%s left the group %i", cs(user), id);
			if(g.members.empty()){
				m_groups.erase(git);
				m_group_chat.erase(id);
				save_group(id);
				result("");
				return send_groups_all();
			}
		} else if(r.cmd == "share" || r.cmd == "unshare"){
			if(plan_meta(r.name).owner != user || !valid_plan_name(r.name))
				return result("You can share only your own plans");
			if(r.cmd == "unshare")
				g.shares.erase(r.name);
			else if(r.arg == "viewer" || r.arg == "editor")
				g.shares[r.name] = r.arg;
			else
				return result("A plan is shared to read or to edit");
			log_i(MODULE, "%s %s the plan %s in the group %i%s", cs(user),
					r.cmd == "share" ? "shared" : "unshared", cs(r.name), id,
					r.cmd == "share" ? cs(" as "+r.arg) : "");
		} else if(!admin){
			return result("Only the group's admins can do that");
		} else if(r.cmd == "invite"){
			bool exists = false;
			accounts::access(m_server, [&](accounts::Interface *i){
				exists = i->exists(r.name);
			});
			if(!exists)
				return result("No account "+r.name);
			// A member, or one invited already: nothing
			if(g.members.count(r.name) || g.invites.count(r.name))
				return result("");
			// [FP_ABUSE] 2
			auto refused = [&](const ss_ &why){
				log_i(MODULE, "%s's invite of %s to the group %i refused: %s",
						cs(user), cs(r.name), id, cs(why));
				return result(why);
			};
			if(more.blocked.count(r.name))
				return refused(r.name+" takes no invites from this group");
			auto dec = more.declined.find(r.name);
			if(dec != more.declined.end() &&
					calendar_s() - dec->second < DECLINE_WAIT_S)
				return refused(r.name+" declined an invite to this group "
						"less than "+itos((int)(DECLINE_WAIT_S / 86400))+
						" days ago");
			if(g.invites.size() >= MAX_PENDING_INVITES)
				return refused("This group has "+
						itos((int)MAX_PENDING_INVITES)+" invites waiting "
						"already");
			if(invites_today(user, false) >= MAX_INVITES_A_DAY &&
					!is_admin(user))
				return refused("You have invited "+itos(MAX_INVITES_A_DAY)+
						" today, as many as anyone does in a day");
			invites_today(user, true);
			more.declined.erase(r.name);
			g.invites[r.name] = user;
			log_i(MODULE, "%s invited %s to the group %i", cs(user),
					cs(r.name), id);
		} else if(r.cmd == "cancel"){
			g.invites.erase(r.name);
		} else if(r.cmd == "vouch"){
			// [FP_ABUSE] 1: an admin of a trusted group trusts a member
			if(!g.members.count(r.name))
				return result("No member "+r.name);
			if(!group_trusted(id))
				return result("Only a trusted group's admins vouch: every "
						"admin of it is trusted first");
			if(level_of(r.name) >= accounts::LV_MEMBER)
				return result(r.name+" is trusted already");
			ss_ why;
			accounts::access(m_server, [&](accounts::Interface *i){
				why = i->set_level(r.name, accounts::LV_MEMBER);
			});
			if(!why.empty())
				return result(why);
			m_groups_save->store("main")->remove("days/"+r.name);
			log_i(MODULE, "%s vouched for %s in the group %i", cs(user),
					cs(r.name), id);
		} else if(r.cmd == "remove"){
			if(r.name == user || !g.members.count(r.name))
				return result("Leave the group instead");
			drop_member(r.name);
			log_i(MODULE, "%s removed %s from the group %i", cs(user),
					cs(r.name), id);
		} else if(r.cmd == "admin"){
			auto m = g.members.find(r.name);
			if(m == g.members.end())
				return result("No member "+r.name);
			if(r.arg != "1" && m->second == "admin" && admins == 1)
				return result("A group keeps at least one admin");
			m->second = r.arg == "1" ? "admin" : "member";
		} else if(r.cmd == "delete"){
			log_i(MODULE, "%s deleted the group %i (%s)", cs(user), id,
					cs(g.name));
			m_groups.erase(git);
			m_group_chat.erase(id);
			save_group(id);
			result("");
			return send_groups_all();
		} else {
			return;
		}
		save_group(id);
		result("");
		send_groups_all();
	}

	// The local user: on this machine, of a server the launcher started
	bool is_local(network::PeerId peer)
	{
		bool local = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			local = i->is_local(peer);
		});
		return local;
	}

	void on_tick(const interface::TickEvent &event)
	{
		m_flush_timer += event.dtime;
		if(m_flush_timer >= 1.0f){
			m_flush_timer = 0;
			flush_all();
		}
		m_editing_timer += event.dtime;
		if(m_editing_timer >= 5.0f){
			m_editing_timer = 0;
			expire_editing();
		}
		for(auto &pair : m_peers){
			pair.second.op_budget = std::min(OPS_BURST,
					pair.second.op_budget + OPS_PER_SECOND * event.dtime);
			pair.second.msg_budget = std::min(MSGS_BURST,
					pair.second.msg_budget + MSGS_PER_SECOND * event.dtime);
		}
		// Each hour a plan stays open and is changed, a backup
		const int64_t now = (int64_t)time(nullptr);
		for(auto &pair : m_plans){
			Plan &p = *pair.second;
			if(!p.m_backup_of.empty() || !p.m_save ||
					now - p.m_last_backup < BACKUP_EVERY_S)
				continue;
			p.flush();
			if(!p.m_changed)
				continue;
			p.backup(p.m_save->path());
			p.m_store->set("meta/unbacked", "0");
		}
		// A plan nobody is in is saved and closed after a while
		sv_<ss_> idle;
		for(auto &pair : m_plans){
			bool used = false;
			for(auto &peer : m_peers)
				used |= peer.second.plan == pair.first;
			pair.second->m_idle = used ? 0 : pair.second->m_idle + event.dtime;
			if(pair.second->m_idle >= PLAN_IDLE_S)
				idle.push_back(pair.first);
		}
		for(const ss_ &name : idle)
			close_plan(name);
	}

	// Peers

	void on_client_connected(const network::NewClient &client)
	{
		Peer peer;
		peer.op_budget = OPS_BURST;
		peer.msg_budget = MSGS_BURST;
		peer.address = client.info.address;
		m_peers[client.info.id] = peer;
	}

	void on_client_disconnected(const network::OldClient &client)
	{
		auto it = m_peers.find(client.info.id);
		if(it == m_peers.end())
			return;
		const ss_ name = it->second.name;
		leave_plan(client.info.id);
		m_editing.erase(client.info.id);
		m_peers.erase(client.info.id);
		if(!name.empty())
			send_plans_to_idle();
	}

	void unlock_all(Plan &plan, network::PeerId peer)
	{
		for(auto it = plan.m_locks.begin(); it != plan.m_locks.end();){
			if(it->second == peer)
				it = plan.m_locks.erase(it);
			else
				++it;
		}
	}

	// Voxels

	void on_voxels(const network::Packet &packet)
	{
		Plan *plan = plan_of(packet.sender);
		if(!plan)
			return;
		Peer &peer = m_peers[packet.sender];
		VoxelEdit edit;
		std::pair<int32_t, ss_> result;
		if(!unpack(packet.data, edit)){
			result.second = "Malformed voxels";
		} else {
			result.first = edit.seq;
			result.second = check_voxels(*plan, packet.sender, edit);
		}
		if(result.second.empty()){
			peer.op_budget -= edit.sets.size() / 10.0;
			std::map<int32_t, int32_t> &voxels = plan->m_voxels[edit.def];
			for(auto &pair : edit.sets){
				if(pair.second == 0)
					voxels.erase(pair.first);
				else
					voxels[pair.first] = pair.second;
			}
			plan->m_voxels_dirty.insert(edit.def);
			note_edit(peer.name);
			// The sender's copy carries its number, as with fp:changes
			for(auto &pair : m_peers){
				if(pair.second.plan != plan->m_name || pair.second.name.empty())
					continue;
				edit.seq = pair.first == packet.sender ? result.first : -1;
				send(pair.first, "fp:voxels", pack(edit));
			}
		} else {
			log_i(MODULE, "Voxels from %s refused: %s", cs(peer.name),
					cs(result.second));
		}
		send(packet.sender, "fp:voxels_result", pack(result));
	}

	ss_ check_voxels(Plan &plan, network::PeerId sender, const VoxelEdit &edit)
	{
		if(!can_edit(sender))
			return edit_refusal(sender);
		auto it = plan.m_ents.find(edit.def);
		if(it == plan.m_ents.end() || it->second.type != "definition" ||
				it->second.ints.at("kind") != DK_VOXEL)
			return "Not a voxel volume";
		auto lock = plan.m_locks.find(edit.def);
		if(lock != plan.m_locks.end() && lock->second != sender)
			return m_peers[lock->second].name+" is moving that";
		if(m_peers[sender].op_budget < edit.sets.size() / 10.0)
			return "Too many voxels at once; slow down";
		const std::map<int32_t, int32_t> &voxels = plan.m_voxels[edit.def];
		size_t added = 0;
		for(auto &pair : edit.sets){
			if(!valid_voxel_key(pair.first))
				return "A voxel outside the volume";
			if(pair.second != 0){
				auto p = plan.m_ents.find(pair.second);
				if(p == plan.m_ents.end() || p->second.type != "palette")
					return "A voxel of what is not a palette entry";
				if(!voxels.count(pair.first))
					added++;
			}
		}
		if(voxels.size() + added > MAX_VOXELS)
			return "The volume is full";
		return grows_past_limit(plan, {}, added);
	}

	// Drag locks, previews and presence

	void on_lock(const network::Packet &packet)
	{
		Plan *plan = plan_of(packet.sender);
		LockRequest req;
		std::pair<int32_t, ss_> result;
		if(!plan || !unpack(packet.data, req) ||
				req.ids.size() > MAX_OPS_PER_BATCH)
			return;
		result.first = req.seq;
		if(!can_edit(packet.sender)){
			result.second = edit_refusal(packet.sender);
		} else {
			for(int32_t id : req.ids){
				auto it = plan->m_locks.find(id);
				if(it != plan->m_locks.end() && it->second != packet.sender){
					result.second = m_peers[it->second].name+
							" is moving that";
					break;
				}
			}
		}
		if(result.second.empty()){
			// One drag at a time: what this user held before is let go
			unlock_all(*plan, packet.sender);
			for(int32_t id : req.ids)
				plan->m_locks[id] = packet.sender;
		}
		send(packet.sender, "fp:lock_result", pack(result));
	}

	void on_unlock(const network::Packet &packet)
	{
		Plan *plan = plan_of(packet.sender);
		if(!plan)
			return;
		unlock_all(*plan, packet.sender);
		// And what it was showing the others goes
		relay_preview(packet.sender, {});
	}

	void relay_preview(network::PeerId sender, const sv_<Entity> &ents)
	{
		Preview p;
		p.peer = (int32_t)sender;
		p.ents = ents;
		ss_ data = pack(p);
		const ss_ plan = m_peers[sender].plan;
		for(auto &pair : m_peers)
			if(!pair.second.name.empty() && pair.second.plan == plan &&
					pair.first != sender)
				send(pair.first, "fp:preview", data);
	}

	// A drag as it goes: where the dragged things would be, for the others
	// to draw. Nothing in the document changes until the drag's batch.
	void on_preview(const network::Packet &packet)
	{
		sv_<Entity> ents;
		if(!can_edit(packet.sender) || !unpack(packet.data, ents) ||
				ents.size() > MAX_OPS_PER_BATCH)
			return;
		Plan *plan = plan_of(packet.sender);
		if(!plan || !spend_msg(packet.sender, 1))
			return;
		for(const Entity &e : ents){
			const ss_ err = plan->check_preview(e);
			if(!err.empty()){
				log_v(MODULE, "fp:preview from %zu dropped: %s",
						(size_t)packet.sender, cs(err));
				return;
			}
		}
		relay_preview(packet.sender, ents);
	}

	void on_presence(const network::Packet &packet)
	{
		Plan *plan = plan_of(packet.sender);
		if(!plan || !spend_msg(packet.sender, 1))
			return;
		Peer &peer = m_peers[packet.sender];
		Presence p;
		if(!unpack(packet.data, p) || p.sel.size() > 1000)
			return;
		peer.presence = p;
		peer.has_presence = true;
		PresenceOut out;
		out.peer = (int32_t)packet.sender;
		out.name = peer.name;
		out.p = p;
		ss_ data = pack(out);
		for(auto &pair : m_peers)
			if(!pair.second.name.empty() && pair.second.plan == plan->m_name &&
					pair.first != packet.sender)
				send(pair.first, "fp:presence", data);
	}

	void send(network::PeerId peer, const ss_ &name, const ss_ &data)
	{
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, name, data);
		});
	}

	void send_to_plan(const ss_ &plan, const ss_ &name, const ss_ &data)
	{
		for(auto &pair : m_peers)
			if(!pair.second.name.empty() && pair.second.plan == plan)
				send(pair.first, name, data);
	}

	void send_chat(network::PeerId peer, const ss_ &text)
	{
		send(peer, "fp:chat", pack(text));
	}

	// Accounts ([VANILLA_PUBLIC] 2: builtin/accounts)

	// What the user may do: the server's admin, and in the plan they are in
	// edit and manage it ([FP_PLANS] 2)
	void send_privs(network::PeerId peer)
	{
		sv_<ss_> privs;
		const ss_ role = peer_role(peer);
		if(is_admin(m_peers[peer].name))
			privs.push_back("admin");
		Plan *plan = plan_of(peer);
		if(role_edits(role)){
			privs.push_back("can_edit");
			if(plan && editing(peer, plan->m_name))
				privs.push_back("edit");
		}
		if(role_manages(role))
			privs.push_back("manage");
		send(peer, "fp:privs", pack(privs));
	}

	// In: the plans come next ([FP_PLANS] 4), and the plan the launcher
	// named for its own user
	void on_accounts_login(const accounts::Login &login)
	{
		auto it = m_peers.find(login.peer);
		if(it == m_peers.end())
			return;
		it->second.name = login.name;
		send(login.peer, "fp:launch", pack(is_local(login.peer) ?
				m_launch_plan : ss_()));
		send_privs(login.peer);
		send_plans(login.peer);
		send_groups(login.peer);
		send_group_backlog(login.peer);
	}

	// [FP_ABUSE] 4: an account deleted. Its plans go, with their
	// pictures and backups; its invites, made and had; and each group it
	// was the last admin of goes to another member -- the highest trust
	// level, then the one in it longest -- or, with none left, is deleted
	void on_accounts_deleted(const accounts::Login &login)
	{
		const ss_ &gone = login.name;
		for(const ss_ &name : plan_names()){
			if(plan_meta(name).owner != gone)
				continue;
			for(auto &pair : m_peers)
				if(pair.second.plan == name)
					to_plans(pair.first, "The plan's owner's account was deleted");
			close_plan(name);
			storage::access(m_server, [&](storage::Interface *istorage){
				istorage->remove(name);
			});
			for(auto &pair : m_groups)
				pair.second.shares.erase(name);
			log_i(MODULE, "The plan %s of the deleted account %s deleted",
					cs(name), cs(gone));
		}
		// Its roles in the others' plans: the name is free again, and a new
		// account of it got them ([SECURITY_RUN_3])
		for(const ss_ &name : plan_names()){
			auto open = m_plans.find(name);
			if(open != m_plans.end()){
				open->second->m_store->remove("role/"+gone);
				continue;
			}
			storage::access(m_server, [&](storage::Interface *istorage){
				storage::Save *save = istorage->open(name);
				if(!save)
					return;
				save->store("main")->remove("role/"+gone);
				istorage->close(save);
			});
			m_closed_meta.erase(name);
		}
		sv_<int32_t> ids;
		for(auto &pair : m_groups)
			ids.push_back(pair.first);
		for(int32_t id : ids){
			Group &g = m_groups[id];
			GroupMore &more = m_more[id];
			for(auto it = g.invites.begin(); it != g.invites.end();){
				if(it->first == gone || it->second == gone)
					it = g.invites.erase(it);
				else
					++it;
			}
			more.declined.erase(gone);
			more.blocked.erase(gone);
			const bool was_admin = g.members.count(gone) &&
					g.members[gone] == "admin";
			g.members.erase(gone);
			more.joined.erase(gone);
			if(g.members.empty()){
				log_i(MODULE, "The group %i (%s) deleted with its last "
						"member %s", id, cs(g.name), cs(gone));
				m_groups.erase(id);
				m_group_chat.erase(id);
				save_group(id);
				continue;
			}
			ss_ heir;
			bool has_admin = false;
			for(auto &m : g.members)
				has_admin |= m.second == "admin";
			if(was_admin && !has_admin){
				int best_lv = -1;
				int64_t best_joined = 0;
				for(auto &m : g.members){
					const int lv = level_of(m.first);
					const int64_t j = more.joined.count(m.first) ?
							more.joined[m.first] : 0;
					if(lv > best_lv || (lv == best_lv && j < best_joined)){
						heir = m.first;
						best_lv = lv;
						best_joined = j;
					}
				}
				g.members[heir] = "admin";
				log_i(MODULE, "The group %i (%s) of the deleted account %s "
						"goes to %s", id, cs(g.name), cs(gone), cs(heir));
			}
			if(more.creator == gone){
				for(auto &m : g.members)
					if(heir.empty() && m.second == "admin")
						heir = m.first;
				more.creator = heir;
			}
			save_group(id);
		}
		storage::Store *store = m_groups_save->store("main");
		store->remove("days/"+gone);
		store->remove("invday/"+gone);
		m_edit_day.erase(gone);
		m_usage.at = -USAGE_KEEP_S;
		usage_all();
		send_groups_all();
		send_plans_to_idle();
	}

	void on_accounts_privs(const accounts::Login &login)
	{
		if(m_peers.count(login.peer))
			send_privs(login.peer);
	}

	// Chat, in the plan the user is in

	void on_chat(const network::Packet &packet)
	{
		Plan *plan = plan_of(packet.sender);
		if(!plan || !spend_msg(packet.sender, 20))
			return;
		ss_ text;
		if(!unpack(packet.data, text) || text.empty() || text.size() > 500 ||
				!valid_text(text))
			return;
		// The chat commands are the pause menu's now ([FP_ACCESS] 4)
		if(text[0] == '/'){
			send_chat(packet.sender, "The commands are in the pause menu "
					"(Esc): Accounts..., Plan members..., My account...");
			return;
		}
		send_to_plan(plan->m_name, "fp:chat",
				pack("<"+m_peers[packet.sender].name+"> "+text));
	}

	// **A group's chat** ([FP_GROUP_CHAT]): to its members wherever they
	// are, in any plan or none; old = 1 for the kept lines a login gets
	struct GroupChat
	{
		int32_t group = 0;
		ss_ text;
		uint8_t old = 0;
		template<class Archive>
		void serialize(Archive &archive){
			archive(group, text, old);
		}
	};
	static const size_t GROUP_CHAT_KEEP = 50;

	void on_group_chat(const network::Packet &packet)
	{
		auto pit = m_peers.find(packet.sender);
		GroupChat c;
		if(pit == m_peers.end() || pit->second.name.empty() ||
				!spend_msg(packet.sender, 20) || !unpack(packet.data, c))
			return;
		if(c.text.empty() || c.text.size() > 500 || !valid_text(c.text))
			return;
		auto git = m_groups.find(c.group);
		const ss_ user = pit->second.name;
		if(git == m_groups.end() || !git->second.members.count(user))
			return send_chat(packet.sender, "Not a member of that group");
		c.text = "<"+user+"> "+c.text;
		c.old = 0;
		std::deque<ss_> &kept = m_group_chat[c.group];
		kept.push_back(c.text);
		while(kept.size() > GROUP_CHAT_KEEP)
			kept.pop_front();
		const ss_ data = pack(c);
		for(auto &pair : m_peers)
			if(git->second.members.count(pair.second.name))
				send(pair.first, "fp:group_chat", data);
	}

	void send_group_backlog(network::PeerId peer)
	{
		const ss_ user = m_peers[peer].name;
		for(auto &pair : m_group_chat){
			auto git = m_groups.find(pair.first);
			if(git == m_groups.end() || !git->second.members.count(user))
				continue;
			for(const ss_ &line : pair.second){
				GroupChat c;
				c.group = pair.first;
				c.text = line;
				c.old = 1;
				send(peer, "fp:group_chat", pack(c));
			}
		}
	}

	struct AdminRequest
	{
		ss_ cmd;
		ss_ name;
		ss_ arg;
		uint8_t on = 0;
		template<class Archive>
		void serialize(Archive &archive){
			archive(cmd, name, arg, on);
		}
	};

	// Batches

	struct Batch
	{
		int32_t seq = 0;
		sv_<Op> ops;
		template<class Archive>
		void serialize(Archive &archive){
			archive(seq, ops);
		}
	};

	struct BatchResult
	{
		int32_t seq = 0;
		ss_ error;
		std::map<int32_t, int32_t> placeholders;
		template<class Archive>
		void serialize(Archive &archive){
			archive(seq, error, placeholders);
		}
	};

	void on_batch(const network::Packet &packet)
	{
		Plan *plan = plan_of(packet.sender);
		if(!plan)
			return;
		Peer &peer = m_peers[packet.sender];
		Batch batch;
		BatchResult result;
		if(!unpack(packet.data, batch)){
			result.error = "Malformed batch";
		} else if(!can_edit(packet.sender)){
			result.error = edit_refusal(packet.sender);
		} else if(batch.ops.size() > MAX_OPS_PER_BATCH){
			result.error = "Too many operations in one batch";
		} else if(peer.op_budget < batch.ops.size()){
			result.error = "Too many operations; slow down";
		} else if(!(result.error = locked_by_other(*plan, batch.ops,
				packet.sender)).empty()){
		} else if(!(result.error = grows_past_limit(*plan, batch.ops,
				0)).empty()){
		} else {
			peer.op_budget -= batch.ops.size();
			set_<int32_t> changed, deleted;
			result.error = plan->apply(batch.ops, result.placeholders, changed,
					deleted);
			if(result.error.empty()){
				broadcast_changes(*plan, batch.seq, packet.sender, changed,
						deleted);
				note_edit(peer.name);
				if(ghost_on(plan) != plan->m_ghost_on)
					send_ghost(plan);
			}
		}
		result.seq = batch.seq;
		if(!result.error.empty())
			log_i(MODULE, "Batch %i from %s refused: %s", batch.seq,
					cs(peer.name), cs(result.error));
		send(packet.sender, "fp:batch_result", pack(result));
	}

	ss_ locked_by_other(Plan &plan, const sv_<Op> &ops, network::PeerId sender)
	{
		for(const Op &op : ops){
			auto it = plan.m_locks.find(op.ent.id);
			if(it != plan.m_locks.end() && it->second != sender)
				return m_peers[it->second].name+" is moving that";
		}
		return "";
	}

	struct Changes
	{
		int32_t seq = -1;       // the sender's batch, for the sender
		int32_t sender = 0;
		sv_<Entity> ents;
		sv_<int32_t> deleted;
		template<class Archive>
		void serialize(Archive &archive){
			archive(seq, sender, ents, deleted);
		}
	};

	void broadcast_changes(Plan &plan, int32_t seq, network::PeerId sender,
			const set_<int32_t> &changed, const set_<int32_t> &deleted)
	{
		Changes c;
		c.seq = -1;
		c.sender = (int32_t)sender;
		for(int32_t id : changed)
			if(!deleted.count(id))
				c.ents.push_back(plan.m_ents[id]);
		c.deleted.assign(deleted.begin(), deleted.end());
		// The sender's copy carries its batch's number, which is how it
		// knows the changes are its own
		ss_ others = pack(c);
		c.seq = seq;
		ss_ own = pack(c);
		for(auto &pair : m_peers)
			if(!pair.second.name.empty() && pair.second.plan == plan.m_name)
				send(pair.first, "fp:changes", pair.first == sender ? own : others);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
