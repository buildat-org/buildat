// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// One Luanti mapblock, as a world's map.sqlite holds it. Read-only and
// one-shot: this is what the importer reads a Luanti world with, and it
// bails on anything it does not recognise rather than guessing.
//
// The format is Luanti's MapBlock::deSerialize, serialization versions 25 to
// 29 -- what every world written since 2013 is in. A block is 16x16x16
// nodes, x fastest and then y and then z, and each node is a content id, a
// param1 and a param2. The content ids are the block's own: every block
// carries the name-id mapping it was written with, which is what makes a
// world readable by a game that registers its nodes in another order.
//
// What hangs off the nodes comes too: the metadata of every node that has
// any, as its fields and its inventory lists; the timer on a node that has
// one; and the entities the block was holding when it was written.
//
// The two shapes, which is the whole of the version difference here:
//
//   25..28  version | flags | [27+: lighting_complete] | widths
//           | zlib(nodes) | zlib(metadata) | static objects | timestamp
//           | name-id mapping | node timers
//   29      version | zstd( flags | lighting_complete | timestamp
//           | name-id mapping | widths | nodes | metadata | static objects
//           | node timers )
//
// So at 29 it is one frame in order; below it the name-id mapping is at the
// back, with the two compressed streams and the static objects in front of
// it and the timers behind.
#pragma once
#include "core/types.h"
#include "interface/compress.h"
#include <PolyVoxCore/Vector.h>
#include <sstream>
#include <cstring>

namespace luanti_mapblock
{
	namespace pv = PolyVox;

	static const size_t BLOCK_SIDE = 16;
	static const size_t NODECOUNT = BLOCK_SIDE * BLOCK_SIDE * BLOCK_SIDE;

	// What hangs off one node: a chest's contents, a sign's text
	struct NodeMeta
	{
		sm_<ss_, ss_> fields;
		// List name to the item string in each slot, "" for an empty one
		sm_<ss_, sv_<ss_>> lists;
	};

	// The timer on a node that has one: how long it runs for and how far it
	// has got, both in seconds
	struct NodeTimer
	{
		float timeout = 0.0f;
		float elapsed = 0.0f;
	};

	// One of the entities a block was holding. The position is in nodes --
	// the format writes thousandths of a BS, which is ten nodes -- and what
	// is in the data depends on the type: 7 is Luanti's LuaEntity, which is
	// what a mod's entity is, and the rest are the engine's own from before
	// that existed.
	struct StaticObject
	{
		uint8_t type = 0;
		float x = 0.0f, y = 0.0f, z = 0.0f;
		ss_ data;
	};

	struct Block
	{
		uint16_t param0[NODECOUNT];
		uint8_t param1[NODECOUNT];
		uint8_t param2[NODECOUNT];
		// The block's own content ids to the names they stand for
		sm_<uint16_t, ss_> names;
		// Keyed by the index into the block, which is what the format keys
		// it by: x + 16*y + 256*z
		sm_<uint16_t, NodeMeta> meta;
		// The same key, for the nodes that carry a timer
		sm_<uint16_t, NodeTimer> timers;
		// And what the block was holding, in the order it was written
		sv_<StaticObject> objects;
	};

	// A cursor over a string, big-endian, that throws rather than reading
	// past the end
	struct Reader
	{
		const ss_ &s;
		size_t p = 0;

		Reader(const ss_ &s, size_t p = 0): s(s), p(p){}

		void need(size_t n)
		{
			if(p + n > s.size())
				throw Exception("mapblock: ran out of data");
		}
		uint8_t u8()
		{
			need(1);
			return (uint8_t)s[p++];
		}
		uint16_t u16()
		{
			need(2);
			uint16_t v = ((uint8_t)s[p] << 8) | (uint8_t)s[p + 1];
			p += 2;
			return v;
		}
		uint32_t u32()
		{
			need(4);
			uint32_t v = ((uint32_t)(uint8_t)s[p] << 24) |
					((uint32_t)(uint8_t)s[p + 1] << 16) |
					((uint32_t)(uint8_t)s[p + 2] << 8) |
					(uint32_t)(uint8_t)s[p + 3];
			p += 4;
			return v;
		}
		ss_ string16()
		{
			size_t n = u16();
			need(n);
			ss_ v = s.substr(p, n);
			p += n;
			return v;
		}
		ss_ string32()
		{
			size_t n = u32();
			need(n);
			ss_ v = s.substr(p, n);
			p += n;
			return v;
		}
		// Up to the next newline, which is how an inventory is written
		ss_ line()
		{
			size_t end = s.find('\n', p);
			if(end == ss_::npos)
				end = s.size();
			ss_ v = s.substr(p, end - p);
			p = end < s.size() ? end + 1 : s.size();
			if(!v.empty() && v[v.size() - 1] == '\r')
				v.resize(v.size() - 1);
			return v;
		}
		void skip(size_t n)
		{
			need(n);
			p += n;
		}
		ss_ rest() const
		{
			return s.substr(p);
		}
	};

	// u8 version, u16 count, then id and name each
	static void read_name_id_mapping(Reader &r, Block &block)
	{
		uint8_t version = r.u8();
		if(version != 0)
			throw Exception("mapblock: name-id mapping version "+
					itos(version));
		uint16_t count = r.u16();
		for(uint16_t i = 0; i < count; i++){
			uint16_t id = r.u16();
			block.names[id] = r.string16();
		}
	}

	// The three arrays, one after the other rather than one node at a time,
	// which is how Luanti writes them
	static void read_nodes(Reader &r, Block &block,
			uint8_t content_width, uint8_t params_width)
	{
		if(content_width != 1 && content_width != 2)
			throw Exception("mapblock: content_width "+itos(content_width));
		if(params_width != 2)
			throw Exception("mapblock: params_width "+itos(params_width));
		r.need(NODECOUNT * (content_width + params_width));
		for(size_t i = 0; i < NODECOUNT; i++)
			block.param0[i] = content_width == 1 ? r.u8() : r.u16();
		for(size_t i = 0; i < NODECOUNT; i++)
			block.param1[i] = r.u8();
		for(size_t i = 0; i < NODECOUNT; i++){
			block.param2[i] = r.u8();
			// The oldest trick in the format: with one byte of content, the
			// ids above 0x7f take four bits of param2 with them
			if(content_width == 1 && block.param0[i] > 0x7f){
				block.param0[i] = (block.param0[i] << 4) |
						((block.param2[i] & 0xf0) >> 4);
				block.param2[i] &= 0x0f;
			}
		}
	}

	// An inventory is lines: "List <name> <size>", then one line per slot,
	// then "EndInventoryList", and "EndInventory" at the end of the lot.
	static void read_inventory(Reader &r, NodeMeta &meta)
	{
		sv_<ss_> *list = nullptr;
		while(r.p < r.s.size()){
			ss_ line = r.line();
			size_t sp = line.find(' ');
			ss_ head = line.substr(0, sp);
			ss_ rest = sp == ss_::npos ? "" : line.substr(sp + 1);
			if(head == "EndInventory" || head == "end")
				return;
			if(head == "List"){
				size_t sp2 = rest.find(' ');
				ss_ name = rest.substr(0, sp2);
				list = &meta.lists[name];
				list->clear();
			} else if(head == "EndInventoryList"){
				list = nullptr;
			} else if(head == "Item" && list){
				list->push_back(rest);
			} else if((head == "Empty" || head == "Keep") && list){
				list->push_back("");
			}
		}
	}

	// The metadata of every node in the block that has any
	static void read_node_metadata(Reader &r, Block &block)
	{
		uint8_t version = r.u8();
		if(version == 0)
			return; // Nothing in this block has any
		if(version > 2)
			throw Exception("mapblock: node metadata version "+itos(version));
		uint16_t count = r.u16();
		for(uint16_t i = 0; i < count; i++){
			uint16_t index = r.u16();
			NodeMeta meta;
			uint32_t num_vars = r.u32();
			for(uint32_t j = 0; j < num_vars; j++){
				ss_ name = r.string16();
				ss_ value = r.string32();
				if(version >= 2)
					r.u8(); // private, which is a client-side matter
				meta.fields[name] = value;
			}
			read_inventory(r, meta);
			block.meta[index] = meta;
		}
	}

	// A thousandth of a BS as the nodes it is: what the format writes a
	// position in, and BS is ten nodes
	static float f1000_nodes(uint32_t raw)
	{
		return (float)(int32_t)raw / 1000.0f / 10.0f;
	}

	// Static objects: what a block was holding of the world's entities
	static void read_static_objects(Reader &r, Block &block)
	{
		r.u8(); // version
		uint16_t count = r.u16();
		for(uint16_t i = 0; i < count; i++){
			StaticObject o;
			o.type = r.u8();
			o.x = f1000_nodes(r.u32());
			o.y = f1000_nodes(r.u32());
			o.z = f1000_nodes(r.u32());
			o.data = r.string16();
			block.objects.push_back(o);
		}
	}

	// The timers, which are the last thing in a block: a length for one of
	// them, how many there are, and then each one's place in the block and
	// its two times in thousandths of a second
	static void read_node_timers(Reader &r, Block &block)
	{
		if(r.p >= r.s.size())
			return; // A block written without any
		const uint8_t length = r.u8();
		if(length != 2 + 4 + 4)
			throw Exception("mapblock: a node timer is "+itos(length)+
					" bytes, and this reads ten");
		uint16_t count = r.u16();
		for(uint16_t i = 0; i < count; i++){
			uint16_t index = r.u16();
			NodeTimer t;
			t.timeout = (float)(int32_t)r.u32() / 1000.0f;
			t.elapsed = (float)(int32_t)r.u32() / 1000.0f;
			block.timers[index] = t;
		}
	}

	// Everything a zlib stream holds, and where in the data it ended
	static size_t read_zlib_stream(const ss_ &data, size_t begin, ss_ &out)
	{
		std::istringstream is(data.substr(begin), std::ios::binary);
		std::ostringstream os(std::ios::binary);
		interface::decompress_zlib(is, os);
		out = os.str();
		// decompress_zlib ungets what inflate did not take, so tellg is
		// where the stream ended
		std::streampos end = is.tellg();
		if(end < 0)
			throw Exception("mapblock: zlib stream has no end");
		return begin + (size_t)end;
	}

	void deserialize_block(const ss_ &data, Block &block)
	{
		if(data.size() < 2)
			throw Exception("mapblock: two bytes is not a block");
		uint8_t version = (uint8_t)data[0];
		if(version < 25 || version > 29)
			throw Exception("mapblock: serialization version "+itos(version)+
					", and this reads 25 to 29");
		if(version >= 29){
			ss_ raw;
			{
				std::ostringstream os(std::ios::binary);
				interface::decompress_zstd(data.substr(1), os);
				raw = os.str();
			}
			Reader r(raw);
			r.u8();  // flags
			r.u16(); // lighting_complete
			r.u32(); // timestamp
			read_name_id_mapping(r, block);
			uint8_t content_width = r.u8();
			uint8_t params_width = r.u8();
			read_nodes(r, block, content_width, params_width);
			read_node_metadata(r, block);
			read_static_objects(r, block);
			read_node_timers(r, block);
			return;
		}
		Reader r(data);
		r.u8();  // version
		r.u8();  // flags
		if(version >= 27)
			r.u16(); // lighting_complete
		uint8_t content_width = r.u8();
		uint8_t params_width = r.u8();
		{
			ss_ raw;
			r.p = read_zlib_stream(data, r.p, raw);
			Reader nodes(raw);
			read_nodes(nodes, block, content_width, params_width);
		}
		{
			ss_ raw;
			r.p = read_zlib_stream(data, r.p, raw);
			Reader meta(raw);
			read_node_metadata(meta, block);
		}
		read_static_objects(r, block);
		r.u32(); // timestamp
		read_name_id_mapping(r, block);
		read_node_timers(r, block);
	}

	// What a map.sqlite row's key is: three twelve-bit coordinates, offset
	// so that the negative ones are non-negative. Luanti's
	// MapDatabase::getIntegerAsBlock.
	pv::Vector3DInt16 block_pos_of_key(int64_t key)
	{
		int64_t i = key + 0x800800800LL;
		return pv::Vector3DInt16(
				(int16_t)((i & 0xfff) - 0x800),
				(int16_t)(((i >> 12) & 0xfff) - 0x800),
				(int16_t)(((i >> 24) & 0xfff) - 0x800));
	}

	// The one runnable check the mapblock reader leaves behind: a block put
	// together here in each of the two shapes the format has, and read back.
	// It proves the reader against the spec it was written from; that it
	// agrees with Luanti was checked by importing real worlds at versions
	// 25, 28 and 29 and comparing what arrived with an independent decode of
	// the same database. See doc/plan/luanti_module_plan.md, M7.
	inline void check_mapblock()
	{
		const size_t N = NODECOUNT;
		// What the check puts in and expects back
		sv_<uint16_t> id(N, 0);
		sv_<uint8_t> p1(N, 0), p2(N, 0);
		for(size_t i = 0; i < N; i++){
			id[i] = (uint16_t)(i % 300);
			p1[i] = (uint8_t)(i % 251);
			p2[i] = (uint8_t)(i % 253);
		}
		auto u8s = [](ss_ &os, uint32_t v){ os += (char)(v & 0xff); };
		auto u16s = [&](ss_ &os, uint32_t v){
			u8s(os, v >> 8); u8s(os, v);
		};
		auto u32s = [&](ss_ &os, uint32_t v){
			u16s(os, v >> 16); u16s(os, v);
		};
		auto string16 = [&](ss_ &os, const ss_ &v){
			u16s(os, (uint32_t)v.size());
			os += v;
		};
		// Two names, one of them at an id that needs two bytes
		auto nimap = [&](ss_ &os){
			u8s(os, 0);
			u16s(os, 2);
			u16s(os, 7);
			string16(os, "check:stone");
			u16s(os, 299);
			string16(os, "check:sand");
		};
		auto nodes = [&](ss_ &os){
			for(size_t i = 0; i < N; i++)
				u16s(os, id[i]);
			for(size_t i = 0; i < N; i++)
				u8s(os, p1[i]);
			for(size_t i = 0; i < N; i++)
				u8s(os, p2[i]);
		};
		// One node with something hanging off it: a field and a two-slot
		// inventory with one thing in it
		auto node_metadata = [&](){
			ss_ os;
			u8s(os, 2);                 // version
			u16s(os, 1);                // one node has any
			u16s(os, 258);              // x=2, y=0, z=1
			u32s(os, 1);                // one field
			string16(os, "infotext");
			u16s(os, 0);                // a field's length is four bytes
			u16s(os, 11);
			os += "a sign says";
			u8s(os, 0);                 // not private
			os += "List main 2\n";
			os += "Width 0\n";
			os += "Item check:stone 5\n";
			os += "Empty\n";
			os += "EndInventoryList\n";
			os += "EndInventory\n";
			return os;
		};
		// One entity, at one node and two up and three across, and one
		// timer on the node the metadata is on
		auto static_objects = [&](ss_ &os){
			u8s(os, 0);                 // version
			u16s(os, 1);                // one object
			u8s(os, 7);                 // a LuaEntity, which is a mod's own
			u32s(os, 1 * 10 * 1000);    // the position, in BS thousandths
			u32s(os, 2 * 10 * 1000);
			u32s(os, 3 * 10 * 1000);
			string16(os, "an object");
		};
		auto node_timers = [&](ss_ &os){
			u8s(os, 2 + 4 + 4);         // how long one of them is
			u16s(os, 1);                // one node has one
			u16s(os, 258);              // the same node the metadata is on
			u32s(os, 5000);             // five seconds long
			u32s(os, 2500);             // and half way through
		};
		auto check_block = [&](const Block &b,
				const char *what){
			for(size_t i = 0; i < N; i++){
				if(b.param0[i] != id[i] || b.param1[i] != p1[i] ||
						b.param2[i] != p2[i])
					throw Exception(ss_("check_mapblock: ")+what+" came back "
							"wrong at "+itos(i));
			}
			if(b.names.size() != 2 || b.names.at(7) != "check:stone" ||
					b.names.at(299) != "check:sand")
				throw Exception(ss_("check_mapblock: ")+what+" lost its "
						"name-id mapping");
			if(b.meta.size() != 1 || b.meta.count(258) == 0)
				throw Exception(ss_("check_mapblock: ")+what+" came back "
						"with "+itos(b.meta.size())+" nodes of metadata");
			const NodeMeta &m = b.meta.at(258);
			if(m.fields.size() != 1 ||
					m.fields.at("infotext") != "a sign says")
				throw Exception(ss_("check_mapblock: ")+what+" lost the "
						"field hanging off a node");
			if(m.lists.size() != 1 || m.lists.at("main").size() != 2 ||
					m.lists.at("main")[0] != "check:stone 5" ||
					!m.lists.at("main")[1].empty())
				throw Exception(ss_("check_mapblock: ")+what+" lost the "
						"inventory hanging off a node");
			if(b.objects.size() != 1 || b.objects[0].type != 7 ||
					b.objects[0].data != "an object" ||
					b.objects[0].x != 1.0f || b.objects[0].y != 2.0f ||
					b.objects[0].z != 3.0f)
				throw Exception(ss_("check_mapblock: ")+what+" lost the "
						"entity it was holding");
			if(b.timers.size() != 1 || b.timers.count(258) == 0 ||
					b.timers.at(258).timeout != 5.0f ||
					b.timers.at(258).elapsed != 2.5f)
				throw Exception(ss_("check_mapblock: ")+what+" lost the "
						"timer on a node");
		};

		// Version 29: one zstd frame, and what is wanted is in front of it
		{
			ss_ inside;
			u8s(inside, 0x00);          // flags
			u16s(inside, 0xffff);       // lighting_complete
			u32s(inside, 12345);        // timestamp
			nimap(inside);
			u8s(inside, 2);             // content_width
			u8s(inside, 2);             // params_width
			nodes(inside);
			inside += node_metadata();
			static_objects(inside);
			node_timers(inside);
			ss_ data;
			u8s(data, 29);
			std::ostringstream os(std::ios::binary);
			interface::compress_zstd(inside, os);
			data += os.str();
			Block block;
			deserialize_block(data, block);
			check_block(block, "the version 29 block");
		}

		// Version 25: two zlib streams, and the mapping at the back behind
		// the static objects
		{
			ss_ data;
			u8s(data, 25);
			u8s(data, 0x00);            // flags
			u8s(data, 2);               // content_width
			u8s(data, 2);               // params_width
			ss_ raw_nodes;
			nodes(raw_nodes);
			{
				std::ostringstream os(std::ios::binary);
				interface::compress_zlib(raw_nodes, os);
				data += os.str();
			}
			{
				std::ostringstream os(std::ios::binary);
				interface::compress_zlib(node_metadata(), os);
				data += os.str();
			}
			static_objects(data);
			u32s(data, 12345);          // timestamp
			nimap(data);
			node_timers(data);
			Block block;
			deserialize_block(data, block);
			check_block(block, "the version 25 block");
		}

		// The key a row has, which is three twelve-bit coordinates in one
		// integer and has to survive the negative ones
		const int coords[6] = {0, 1, -1, 2047, -2048, -3};
		for(int i = 0; i < 6; i++){
			for(int j = 0; j < 6; j++){
				int64_t key = (int64_t)coords[j] * 0x1000000 +
						(int64_t)coords[i] * 0x1000 + (int64_t)coords[i];
				pv::Vector3DInt16 p =
						block_pos_of_key(key);
				if(p.getX() != coords[i] || p.getY() != coords[i] ||
						p.getZ() != coords[j])
					throw Exception("check_mapblock: the block key of ("+
							itos(coords[i])+", "+itos(coords[i])+", "+
							itos(coords[j])+") came back as ("+
							itos(p.getX())+", "+itos(p.getY())+", "+
							itos(p.getZ())+")");
			}
		}
		log_v("luanti", "check_mapblock: both shapes of a block read back");
	}

	// What the LBM list and "[combine" readers make of a few known
	// inputs. Runs once, from run_game(), beside the shapes' and the
	// registry's own checks.
}
// vim: set noet ts=4 sw=4:
