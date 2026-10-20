// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/voxel_volume.h"
#include "interface/compress.h"
#include "interface/polyvox_cereal.h"
#include "interface/voxel_cereal.h"
#include "core/log.h"
#include <cstring>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#define MODULE "voxel_volume"

namespace interface {

// VoxelVolume

VoxelVolume::VoxelVolume(const pv::Region &region):
	VoxelVolume(region, sv_<VoxelPlane>{VoxelPlane()})
{}

VoxelVolume::VoxelVolume(const pv::Region &region,
		const sv_<VoxelPlane> &planes):
	m_region(region),
	m_planes(planes),
	m_w(region.getWidthInVoxels()),
	m_h(region.getHeightInVoxels()),
	m_d(region.getDepthInVoxels()),
	m_lx(region.getLowerCorner().getX()),
	m_ly(region.getLowerCorner().getY()),
	m_lz(region.getLowerCorner().getZ())
{
	m_data.resize(m_planes.size());
}

static const sv_<uint8_t> g_no_bytes;

const sv_<uint8_t>& VoxelVolume::plane_bytes(uint8_t plane) const
{
	if(plane >= m_data.size())
		return g_no_bytes;
	return m_data[plane];
}

sv_<uint8_t>& VoxelVolume::plane_bytes_for_write(uint8_t plane)
{
	if(plane >= m_data.size())
		throw Exception(ss_()+"VoxelVolume: there is no plane "+
				itos((int)plane));
	sv_<uint8_t> &bytes = m_data[plane];
	if(bytes.empty()){
		// Materialised on first write, zeroed; see the note on the class
		bytes.resize(voxel_count() * (m_planes[plane].bits / 8), 0);
	}
	return bytes;
}

void VoxelVolume::set_plane_bytes(uint8_t plane, const uint8_t *data,
		size_t size)
{
	if(plane >= m_data.size())
		throw Exception(ss_()+"VoxelVolume: there is no plane "+
				itos((int)plane));
	const size_t want = voxel_count() * (m_planes[plane].bits / 8);
	if(size != want)
		throw Exception(ss_()+"VoxelVolume::set_plane_bytes(): plane "+
				itos((int)plane)+" is "+itos(want)+" bytes and "+
				itos(size)+" were given");
	// assign() over an empty vector allocates and copies; it does not clear
	// what it is about to write over
	m_data[plane].assign(data, data + size);
}

bool VoxelVolume::copy_run_from(const VoxelVolume &src,
		int32_t sx, int32_t sy, int32_t sz,
		int32_t dx, int32_t dy, int32_t dz, size_t n)
{
	if(n == 0)
		return true;
	const int32_t last = (int32_t)n - 1;
	if(!src.contains(sx, sy, sz) || !src.contains(sx + last, sy, sz))
		return false;
	if(!contains(dx, dy, dz) || !contains(dx + last, dy, dz))
		return false;
	const size_t src_i = src.index_of(sx, sy, sz);
	const size_t dst_i = index_of(dx, dy, dz);
	for(size_t sp = 0; sp < src.m_planes.size(); sp++){
		// The same plane by name, because that is what identifies one; the
		// two volumes' plane orders need not line up
		size_t dp = 0;
		for(; dp < m_planes.size(); dp++){
			if(m_planes[dp].name == src.m_planes[sp].name)
				break;
		}
		if(dp >= m_planes.size() || m_planes[dp].bits != src.m_planes[sp].bits)
			continue;
		const size_t w = m_planes[dp].bits / 8;
		if(!src.plane_is_materialised((uint8_t)sp)){
			// Nothing has written the source, so the run reads as zero, and
			// only a destination that has been written needs telling
			if(plane_is_materialised((uint8_t)dp))
				memset(&m_data[dp][dst_i * w], 0, n * w);
			continue;
		}
		sv_<uint8_t> &dst_bytes = plane_bytes_for_write((uint8_t)dp);
		memcpy(&dst_bytes[dst_i * w], &src.m_data[sp][src_i * w], n * w);
	}
	return true;
}

bool VoxelVolume::read_words(int32_t x, int32_t y, int32_t z, size_t n,
		uint32_t *out) const
{
	if(n == 0)
		return true;
	if(!contains(x, y, z) || !contains(x + (int32_t)n - 1, y, z))
		return false;
	if(m_planes.empty() || m_planes[0].bits != 32 ||
			!plane_is_materialised(0)){
		// Nothing has written the plane, so every voxel of it is zero
		memset(out, 0, n * sizeof(uint32_t));
		return true;
	}
	const uint8_t *at = &m_data[0][index_of(x, y, z) * 4];
	for(size_t i = 0; i < n; i++, at += 4){
		out[i] = (uint32_t)at[0] | ((uint32_t)at[1] << 8) |
				((uint32_t)at[2] << 16) | ((uint32_t)at[3] << 24);
	}
	return true;
}

uint32_t VoxelVolume::plane_at(uint8_t plane, int32_t x, int32_t y,
		int32_t z) const
{
	if(plane >= m_data.size() || !contains(x, y, z))
		return 0;
	const sv_<uint8_t> &bytes = m_data[plane];
	if(bytes.empty())
		return 0;
	const size_t i = index_of(x, y, z);
	switch(m_planes[plane].bits){
	case 8:
		return bytes[i];
	case 16: {
		const uint8_t *p = &bytes[i * 2];
		return (uint32_t)p[0] | ((uint32_t)p[1] << 8);
	}
	default: {
		const uint8_t *p = &bytes[i * 4];
		return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
				((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
	}
	}
}

void VoxelVolume::set_plane_at(uint8_t plane, int32_t x, int32_t y, int32_t z,
		uint32_t value)
{
	if(!contains(x, y, z))
		return;
	// A write of zero to a plane nothing has written yet leaves it alone:
	// zero is what it already reads as, and materialising it would be a
	// megabyte for nothing. This is what makes a worldgen that fills a
	// chunk with air free in every plane it does not touch.
	if(value == 0 && !plane_is_materialised(plane)){
		if(plane >= m_data.size())
			throw Exception(ss_()+"VoxelVolume: there is no plane "+
					itos((int)plane));
		return;
	}
	sv_<uint8_t> &bytes = plane_bytes_for_write(plane);
	const size_t i = index_of(x, y, z);
	switch(m_planes[plane].bits){
	case 8:
		bytes[i] = (uint8_t)value;
		break;
	case 16: {
		uint8_t *p = &bytes[i * 2];
		p[0] = (uint8_t)value;
		p[1] = (uint8_t)(value >> 8);
		break;
	}
	default: {
		uint8_t *p = &bytes[i * 4];
		p[0] = (uint8_t)value;
		p[1] = (uint8_t)(value >> 8);
		p[2] = (uint8_t)(value >> 16);
		p[3] = (uint8_t)(value >> 24);
		break;
	}
	}
}

void VoxelVolume::add_planes(const sv_<VoxelPlane> &planes)
{
	for(size_t i = 0; i < planes.size(); i++){
		bool found = false;
		for(size_t j = 0; j < m_planes.size(); j++){
			if(m_planes[j].name != planes[i].name)
				continue;
			if(m_planes[j].bits != planes[i].bits)
				throw Exception(ss_()+"VoxelVolume::add_planes(): \""+
						planes[i].name+"\" is "+itos((int)m_planes[j].bits)+
						" bits here and "+itos((int)planes[i].bits)+" there");
			found = true;
			break;
		}
		if(found)
			continue;
		if(m_planes.size() >= VOXEL_MAX_PLANES)
			throw Exception(ss_()+"VoxelVolume::add_planes(): a volume has "
					"at most "+itos((int)VOXEL_MAX_PLANES)+" planes");
		m_planes.push_back(planes[i]);
		m_data.resize(m_planes.size());
	}
}

void VoxelVolume::fill(VoxelInstance v)
{
	if(v.data == 0){
		// Nothing to do, and nothing to allocate: an unwritten plane
		// already reads as zero everywhere
		return;
	}
	sv_<uint8_t> &bytes = plane_bytes_for_write(0);
	const size_t n = voxel_count();
	for(size_t i = 0; i < n; i++){
		bytes[i * 4 + 0] = (uint8_t)v.data;
		bytes[i * 4 + 1] = (uint8_t)(v.data >> 8);
		bytes[i * 4 + 2] = (uint8_t)(v.data >> 16);
		bytes[i * 4 + 3] = (uint8_t)(v.data >> 24);
	}
}

void VoxelVolume::Sampler::setPosition(int32_t x, int32_t y, int32_t z)
{
	m_x = x;
	m_y = y;
	m_z = z;
	m_at = nullptr;
	if(m_volume == nullptr || !m_volume->contains(x, y, z))
		return;
	// Plane 0 is 32 bits wide in every format that has been written so far;
	// a narrower one walks through the accessors instead
	if(m_volume->m_planes[0].bits != 32)
		return;
	sv_<uint8_t> &bytes = m_volume->m_data[0];
	if(bytes.empty())
		return;
	m_at = &bytes[m_volume->index_of(x, y, z) * 4];
}

void VoxelVolume::Sampler::movePositiveX()
{
	m_x++;
	if(m_at == nullptr){
		// Either outside the volume or on a plane nothing has written; in
		// both cases the next voxel has to be looked at properly
		setPosition(m_x, m_y, m_z);
		return;
	}
	if(!m_volume->contains(m_x, m_y, m_z)){
		m_at = nullptr;
		return;
	}
	m_at += 4;
}

void VoxelVolume::Sampler::setVoxel(VoxelInstance v)
{
	if(m_volume == nullptr)
		return;
	if(m_at == nullptr){
		// The plane may be unwritten rather than the position outside it,
		// in which case this is what materialises it
		m_volume->setVoxelAt(m_x, m_y, m_z, v);
		setPosition(m_x, m_y, m_z);
		return;
	}
	m_at[0] = (uint8_t)v.data;
	m_at[1] = (uint8_t)(v.data >> 8);
	m_at[2] = (uint8_t)(v.data >> 16);
	m_at[3] = (uint8_t)(v.data >> 24);
}

VoxelSample VoxelVolume::sample_at(int32_t x, int32_t y, int32_t z) const
{
	VoxelSample out;
	if(!contains(x, y, z))
		return out;
	const size_t n = m_data.size() < VOXEL_MAX_PLANES ?
			m_data.size() : VOXEL_MAX_PLANES;
	// The bounds and the index once, not once per plane (plane_at's)
	const size_t at = index_of(x, y, z);
	for(size_t i = 0; i < n; i++){
		const sv_<uint8_t> &bytes = m_data[i];
		if(bytes.empty())
			continue;
		switch(m_planes[i].bits){
		case 8:
			out.planes[i] = bytes[at];
			break;
		case 16:
			out.planes[i] = (uint32_t)bytes[at * 2] |
					((uint32_t)bytes[at * 2 + 1] << 8);
			break;
		default: {
			const uint8_t *p = &bytes[at * 4];
			out.planes[i] = (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
					((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
		}
		}
	}
	return out;
}

void VoxelVolume::set_sample_at(int32_t x, int32_t y, int32_t z,
		const VoxelSample &v)
{
	const size_t n = m_data.size() < VOXEL_MAX_PLANES ?
			m_data.size() : VOXEL_MAX_PLANES;
	for(size_t i = 0; i < n; i++)
		set_plane_at((uint8_t)i, x, y, z, v.planes[i]);
}

bool voxel_volume_self_test()
{
	const pv::Region region(pv::Vector3DInt32(-1, -1, -1),
			pv::Vector3DInt32(3, 4, 5));
	sv_<VoxelPlane> planes;
	planes.push_back(VoxelPlane());               // the game's own, 32 bits
	planes.push_back(VoxelPlane("mod:heat", 8));
	planes.push_back(VoxelPlane("mod:wear", 16));
	VoxelVolume vol(region, planes);

	assert(vol.getWidth() == 5 && vol.getHeight() == 6 && vol.getDepth() == 7);
	assert(vol.voxel_count() == 5 * 6 * 7);

	// A plane nothing has written reads as zero and costs nothing
	for(uint8_t p = 0; p < 3; p++){
		assert(!vol.plane_is_materialised(p));
		assert(vol.plane_at(p, 0, 0, 0) == 0);
	}
	// And writing zero to it keeps it that way
	vol.set_plane_at(1, 0, 0, 0, 0);
	assert(!vol.plane_is_materialised(1));

	// Each width round-trips, and cuts a value too large for it
	vol.setVoxelAt(0, 1, 2, VoxelInstance(0xdeadbeef));
	vol.set_plane_at(1, 0, 1, 2, 0x5a);
	vol.set_plane_at(2, 0, 1, 2, 0x1234);
	assert(vol.getVoxelAt(0, 1, 2).data == 0xdeadbeef);
	assert(vol.plane_at(1, 0, 1, 2) == 0x5a);
	assert(vol.plane_at(2, 0, 1, 2) == 0x1234);
	vol.set_plane_at(1, 0, 1, 2, 0x1ff);
	assert(vol.plane_at(1, 0, 1, 2) == 0xff);

	// Writing one voxel leaves the others alone
	assert(vol.getVoxelAt(0, 1, 3).data == 0);
	assert(vol.plane_at(1, 1, 1, 2) == 0);

	// The planes are separate arrays: a voxel's are read together
	VoxelSample s = vol.sample_at(0, 1, 2);
	assert(s.planes[0] == 0xdeadbeef);
	assert(s.planes[1] == 0xff);
	assert(s.planes[2] == 0x1234);
	s.planes[1] = 7;
	vol.set_sample_at(-1, -1, -1, s);
	assert(vol.plane_at(1, -1, -1, -1) == 7);

	// Outside the region reads as zero rather than as whatever is next to
	// it in memory, which is what a read past the edge of a chunk means
	assert(vol.getVoxelAt(-2, 1, 2).data == 0);
	assert(vol.getVoxelAt(4, 1, 2).data == 0);
	assert(vol.getVoxelAt(0, 1, 6).data == 0);
	assert(vol.sample_at(9, 9, 9).planes[0] == 0);
	// And a write outside it is dropped rather than landing on a neighbour
	vol.setVoxelAt(-2, 1, 2, VoxelInstance(0xffffffff));
	assert(vol.getVoxelAt(3, 1, 2).data == 0);

	// A plane the volume did not have is appended without disturbing what
	// is in it, and one it already has is left alone
	{
		VoxelVolume old(region);
		old.setVoxelAt(0, 0, 0, VoxelInstance(0x11223344));
		old.add_planes(planes);
		assert(old.planes().size() == 3);
		assert(old.getVoxelAt(0, 0, 0).data == 0x11223344);
		assert(old.plane_at(2, 0, 0, 0) == 0);
		old.set_plane_at(2, 0, 0, 0, 0x9999);
		assert(old.plane_at(2, 0, 0, 0) == 0x9999);
		old.add_planes(planes);
		assert(old.planes().size() == 3);
		assert(old.plane_at(2, 0, 0, 0) == 0x9999);
	}

	// A sampler walks plane 0 without working the index out each time, and
	// agrees with the accessors about what is where
	{
		VoxelVolume::Sampler sam(&vol);
		sam.setPosition(-1, 1, 2);
		for(int x = -1; x <= 0; x++){
			assert(sam.getVoxel().data == vol.getVoxelAt(x, 1, 2).data);
			sam.movePositiveX();
		}
		// Past the end reads as zero rather than as the next row
		sam.setPosition(3, 1, 2);
		sam.movePositiveX();
		assert(sam.getVoxel().data == 0);
		// And writing through it is writing to the volume
		sam.setPosition(1, 1, 2);
		sam.setVoxel(VoxelInstance(0xabcdef01));
		assert(vol.getVoxelAt(1, 1, 2).data == 0xabcdef01);
		// Including into a plane nothing had written
		VoxelVolume fresh(region);
		VoxelVolume::Sampler s2(&fresh);
		s2.setPosition(0, 0, 0);
		assert(s2.getVoxel().data == 0);
		s2.setVoxel(VoxelInstance(42));
		assert(fresh.getVoxelAt(0, 0, 0).data == 42);
		s2.movePositiveX();
		s2.setVoxel(VoxelInstance(43));
		assert(fresh.getVoxelAt(1, 0, 0).data == 43);
	}

	// The layout is x fastest, then y, then z -- what every blob written
	// before planes is in
	const sv_<uint8_t> &bytes = vol.plane_bytes(1);
	assert(!bytes.empty());
	const size_t i = (size_t)(0 - -1) + (size_t)(1 - -1) * 5 +
			(size_t)(2 - -1) * 5 * 6;
	assert(bytes[i] == 0xff);

	// Migration: a world that has moved its fields around since the save was
	// written
	{
		VoxelFormat a = VoxelFormat::luanti();
		// Every role somewhere else, and a module's plane alongside
		VoxelFormat b;
		b.planes = {VoxelPlane(), VoxelPlane("test:mix", 8)};
		b.id = VoxelField{0, 8, 16};
		b.light_sky = VoxelField{0, 0, 4};
		b.light_lamp = VoxelField{0, 4, 4};
		b.param = VoxelField{0, 24, 8};
		assert(a.validate() && b.validate());

		pv::Region r(0, 0, 0, 3, 3, 3);
		VoxelVolume from(r, a.planes);
		uint32_t w = 0;
		a.id.set(w, 0x1234);
		a.light_sky.set(w, 11);
		a.light_lamp.set(w, 5);
		a.param.set(w, 0x9a);
		from.setVoxelAt(1, 2, 3, VoxelInstance(w));

		ss_ why;
		up_<VoxelVolume> to = migrate_volume(from, a, b, &why);
		assert(to);
		VoxelSample got = to->sample_at(1, 2, 3);
		assert(b.id.get(got) == 0x1234);
		assert(b.light_sky.get(got) == 11);
		assert(b.light_lamp.get(got) == 5);
		assert(b.param.get(got) == 0x9a);
		// The plane the world gained is not allocated by a migration that
		// has nothing to put in it
		assert(!to->plane_is_materialised(1));
		// And the voxels nothing was written to are still nothing
		assert(to->sample_at(0, 0, 0).planes[0] == 0);

		// Bits no role of either format claims are the game's own and travel
		// where they are. This is demo_undermine's support field: a world that
		// binds four bits of param and no more leaves 28...31 to the game.
		VoxelFormat c = a, d = b;
		c.param = VoxelField{0, 24, 4};
		d.param = VoxelField{0, 24, 4};
		assert(c.validate() && d.validate());
		VoxelVolume from2(r, c.planes);
		uint32_t w2 = 0;
		c.id.set(w2, 7);
		w2 |= 0xa0000000UL; // bits 28...31, which no role of either claims
		from2.setVoxelAt(1, 1, 1, VoxelInstance(w2));
		up_<VoxelVolume> to2 = migrate_volume(from2, c, d, &why);
		assert(to2);
		assert(d.id.get(to2->sample_at(1, 1, 1)) == 7);
		assert((to2->getVoxelAt(1, 1, 1).data & 0xf0000000UL) == 0xa0000000UL);

		// A width change with no migration of the game's is refused rather
		// than guessed at
		VoxelFormat e = a;
		e.param = VoxelField{0, 24, 6};
		assert(e.validate());
		why = "";
		assert(!migrate_volume(from, a, e, &why));
		assert(why.find("param") != ss_::npos);
	}

	// The game's migration (VoxelMigration): the id widened 16 to 20 bits
	// and a 4-bit param to 8
	{
		VoxelFormat a = VoxelFormat::blocks();
		a.param = VoxelField{0, 20, 4};
		VoxelFormat b;
		b.id = VoxelField{0, 0, 20};
		b.light_sky = VoxelField{0, 20, 4};
		b.param = VoxelField{0, 24, 8};
		assert(a.validate() && b.validate());
		pv::Region r(0, 0, 0, 3, 3, 3);
		VoxelVolume from(r, a.planes);
		const uint32_t ids[] = {1, 2, 0x1234, 0xfffe, 0xffff};
		for(int i = 0; i < 5; i++){
			uint32_t w = 0;
			a.id.set(w, ids[i]);
			a.light_sky.set(w, (uint32_t)(i + 10));
			a.param.set(w, (uint32_t)(i + 11));
			from.setVoxelAt(i % 4, i / 4, 1, VoxelInstance(w));
		}

		// One the game writes: zero-extends the id, scales the param x17,
		// or declines
		struct Widen: VoxelMigration
		{
			bool decline = false, scale = true;
			VoxelFormat f, t;
			bool begin(const VoxelFormat &from, const VoxelFormat &to){
				f = from; t = to;
				return !decline;
			}
			void migrate(const VoxelVolume &old, VoxelVolume &moved){
				const pv::Vector3DInt32 lc =
						old.getEnclosingRegion().getLowerCorner();
				const pv::Vector3DInt32 uc =
						old.getEnclosingRegion().getUpperCorner();
				for(int32_t z = lc.getZ(); z <= uc.getZ(); z++)
				for(int32_t y = lc.getY(); y <= uc.getY(); y++)
				for(int32_t x = lc.getX(); x <= uc.getX(); x++){
					uint32_t o = old.plane_at(0, x, y, z);
					uint32_t w = moved.plane_at(0, x, y, z);
					t.id.set(w, f.id.get(o));
					if(scale)
						t.param.set(w, f.param.get(o) * 17);
					moved.set_plane_at(0, x, y, z, w);
				}
			}
		} widen;

		ss_ why;
		assert(!migrate_volume(from, a, b, &why));
		assert(why.find("id") != ss_::npos);

		up_<VoxelVolume> to = migrate_volume(from, a, b, &why, &widen);
		assert(to);
		for(int i = 0; i < 5; i++){
			VoxelSample s = to->sample_at(i % 4, i / 4, 1);
			assert(b.id.get(s) == ids[i]);
			assert(b.light_sky.get(s) == (uint32_t)(i + 10));
			assert(b.param.get(s) == (uint32_t)(i + 11) * 17);
		}
		assert(to->sample_at(3, 3, 3).planes[0] == 0);

		// Zero-extended alone: the param the hook leaves is left zero
		widen.scale = false;
		to = migrate_volume(from, a, b, &why, &widen);
		assert(to && b.id.get(to->sample_at(0, 1, 1)) == 0xffff);
		assert(b.param.get(to->sample_at(0, 1, 1)) == 0);

		widen.decline = true;
		why = "";
		assert(!migrate_volume(from, a, b, &why, &widen));
		assert(why.find("declined") != ss_::npos);
	}

	// Ids through a name table
	{
		VoxelFormat f = VoxelFormat::luanti();
		pv::Region r(0, 0, 0, 3, 3, 3);
		VoxelVolume vol(r, f.planes);
		uint32_t w = 0;
		f.id.set(w, 2);
		f.param.set(w, 0x5e);
		vol.setVoxelAt(0, 1, 2, VoxelInstance(w));
		sv_<VoxelTypeId> map = {0, 1, 40};
		remap_volume_ids(vol, f, map);
		VoxelSample got = vol.sample_at(0, 1, 2);
		assert(f.id.get(got) == 40);
		// Nothing else in the word moved
		assert(f.param.get(got) == 0x5e);
		// A plane nothing wrote stays unallocated
		VoxelVolume empty(r, f.planes);
		remap_volume_ids(empty, f, map);
		assert(!empty.plane_is_materialised(0));
	}

	// A region off the wire that no volume has -- reversed, or a voxel
	// count of gigabytes -- is refused before it is allocated
	{
		auto refused = [](pv::Vector3DInt32 lc, pv::Vector3DInt32 uc){
			std::ostringstream os(std::ios::binary);
			{
				cereal::PortableBinaryOutputArchive ar(os);
				ar((uint8_t)4, lc, uc, (uint8_t)0, (uint8_t)0, ss_());
			}
			try {
				deserialize_volume(os.str());
			} catch(Exception &e){
				return true;
			}
			return false;
		};
		assert(refused(pv::Vector3DInt32(5, 0, 0), pv::Vector3DInt32(0, 0, 0)));
		assert(refused(pv::Vector3DInt32(0, 0, 0),
				pv::Vector3DInt32(4000, 4000, 4000)));
		assert(!refused(pv::Vector3DInt32(0, 0, 0),
				pv::Vector3DInt32(63, 63, 63)));
	}

	return true;
}

// pv::RawVolume<T>

template<typename T>
		ss_ generic_serialize_volume_simple(const pv::RawVolume<T> &volume)
{
	std::ostringstream os(std::ios::binary);
	{
		cereal::PortableBinaryOutputArchive ar(os);
		ar((uint8_t)2); // Format
		auto region = volume.getEnclosingRegion();
		ar(region.getLowerCorner());
		ar(region.getUpperCorner());
		for(size_t i = 0; i<volume.m_dataSize; i++){
			const T &v = volume.m_pData[i];
			ar(v);
		}
	}
	return os.str();
}

template<typename T>
		ss_ generic_serialize_volume_compressed(const pv::RawVolume<T> &volume)
{
	std::ostringstream os(std::ios::binary);
	{
		cereal::PortableBinaryOutputArchive ar(os);
		ar((uint8_t)3); // Format
		auto region = volume.getEnclosingRegion();
		ar(region.getLowerCorner());
		ar(region.getUpperCorner());
		std::ostringstream raw_os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(raw_os);
			for(size_t i = 0; i<volume.m_dataSize; i++){
				const T &v = volume.m_pData[i];
				ar(v);
			}
		}
		std::ostringstream compressed_os(std::ios::binary);
		// NOTE: 4 uses 98% and 1 uses 58% of the CPU time of 6
		interface::compress_zlib(raw_os.str(), compressed_os, 6);
		ar(compressed_os.str());
	}
	return os.str();
}

static void check_region(const pv::Vector3DInt32 &lc,
		const pv::Vector3DInt32 &uc);

template<typename T>
		up_<pv::RawVolume<T>> generic_deserialize_volume(const ss_ &data)
{
	std::istringstream is(data, std::ios::binary);
	cereal::PortableBinaryInputArchive ar(is);
	uint8_t format = 0;
	ar(format);
	if(format == 2){
		pv::Vector3DInt32 lc, uc;
		ar(lc, uc);
		// The same bounds as deserialize_volume(): these reach Lua too
		// (deserialize_volume_int32/_8bit), and a reversed region was
		// PolyVox's assert, a huge one gigabytes (util/fuzz)
		check_region(lc, uc);
		pv::Region region(lc, uc);
		up_<pv::RawVolume<T>> volume(
				new pv::RawVolume<T>(region));
		for(size_t i = 0; i<volume->m_dataSize; i++){
			T v;
			ar(v);
			volume->m_pData[i] = v;
		}
		return volume;
	}
	if(format == 3){
		pv::Vector3DInt32 lc, uc;
		ar(lc, uc);
		// The same bounds as deserialize_volume(): these reach Lua too
		// (deserialize_volume_int32/_8bit), and a reversed region was
		// PolyVox's assert, a huge one gigabytes (util/fuzz)
		check_region(lc, uc);
		pv::Region region(lc, uc);
		up_<pv::RawVolume<T>> volume(
				new pv::RawVolume<T>(region));
		ss_ compressed_data;
		ar(compressed_data);
		std::istringstream compressed_is(compressed_data, std::ios::binary);
		std::ostringstream raw_os(std::ios::binary);
		decompress_zlib(compressed_is, raw_os);
		{
			std::istringstream raw_is(raw_os.str(), std::ios::binary);
			cereal::PortableBinaryInputArchive ar(raw_is);
			for(size_t i = 0; i<volume->m_dataSize; i++){
				T v;
				ar(v);
				volume->m_pData[i] = v;
			}
		}
		return volume;
	}
	return up_<pv::RawVolume<T>>();
}

// VoxelVolume: format 4
//
// Region, then the plane list, then the bytes of the planes that have been
// written, so a blob says what is in it without its registry. A plane
// nothing wrote is a flag and no bytes.
//
// Formats 2 and 3 are what a volume was before planes: one 32-bit plane in
// the same layout. They load, so saved worlds and older clients keep
// working, and what is loaded is written back out as 4.

static ss_ serialize_volume_planes(const VoxelVolume &volume, bool compress)
{
	std::ostringstream os(std::ios::binary);
	{
		cereal::PortableBinaryOutputArchive ar(os);
		ar((uint8_t)4); // Format
		auto region = volume.getEnclosingRegion();
		ar(region.getLowerCorner());
		ar(region.getUpperCorner());
		ar((uint8_t)compress);
		const sv_<VoxelPlane> &planes = volume.planes();
		ar((uint8_t)planes.size());
		std::ostringstream raw_os(std::ios::binary);
		for(size_t i = 0; i < planes.size(); i++){
			ar(planes[i].name, planes[i].bits);
			const sv_<uint8_t> &bytes = volume.plane_bytes((uint8_t)i);
			ar((uint8_t)!bytes.empty());
			if(!bytes.empty())
				raw_os.write((const char*)&bytes[0], bytes.size());
		}
		ss_ raw = raw_os.str();
		if(compress){
			std::ostringstream compressed_os(std::ios::binary);
			interface::compress_zstd(raw, compressed_os);
			ar(compressed_os.str());
		} else {
			ar(raw);
		}
	}
	return os.str();
}

ss_ serialize_volume_simple(const VoxelVolume &volume)
{
	return serialize_volume_planes(volume, false);
}

ss_ serialize_volume_compressed(const VoxelVolume &volume)
{
	return serialize_volume_planes(volume, true);
}

// What a serialized volume may claim to be, checked before anything is
// made that size: the region comes off the wire (a server's packet, a save
// on disk), and a reversed or huge one was a voxel count of gigabytes,
// zero-filled -- the OOM killer, not an exception ([SECURITY_RUN_1]).
// simplified: one ceiling for every volume, 256^3 voxels, sixty-four
// sections; a format that needs more names its own.
static const size_t MAX_SERIALIZED_VOXELS = (size_t)1 << 24;

static void check_region(const pv::Vector3DInt32 &lc,
		const pv::Vector3DInt32 &uc)
{
	const int64_t w = (int64_t)uc.getX() - lc.getX() + 1;
	const int64_t h = (int64_t)uc.getY() - lc.getY() + 1;
	const int64_t d = (int64_t)uc.getZ() - lc.getZ() + 1;
	if(w < 1 || h < 1 || d < 1 || w > 4096 || h > 4096 || d > 4096 ||
			(uint64_t)(w * h * d) > MAX_SERIALIZED_VOXELS)
		throw Exception(ss_()+"deserialize_volume(): a region of "+
				itos(w)+"x"+itos(h)+"x"+itos(d)+" is not one a volume has");
}

up_<VoxelVolume> deserialize_volume(const ss_ &data)
{
	std::istringstream is(data, std::ios::binary);
	cereal::PortableBinaryInputArchive ar(is);
	uint8_t format = 0;
	ar(format);
	if(format == 2 || format == 3){
		// One 32-bit plane, written a voxel at a time
		pv::Vector3DInt32 lc, uc;
		ar(lc, uc);
		check_region(lc, uc);
		up_<VoxelVolume> volume(new VoxelVolume(pv::Region(lc, uc)));
		const size_t n = volume->voxel_count();
		if(format == 2){
			sv_<uint8_t> &bytes = volume->plane_bytes_for_write(0);
			for(size_t i = 0; i < n; i++){
				VoxelInstance v;
				ar(v);
				bytes[i * 4 + 0] = (uint8_t)v.data;
				bytes[i * 4 + 1] = (uint8_t)(v.data >> 8);
				bytes[i * 4 + 2] = (uint8_t)(v.data >> 16);
				bytes[i * 4 + 3] = (uint8_t)(v.data >> 24);
			}
			return volume;
		}
		ss_ compressed_data;
		ar(compressed_data);
		std::istringstream compressed_is(compressed_data, std::ios::binary);
		std::ostringstream raw_os(std::ios::binary);
		decompress_zlib(compressed_is, raw_os);
		{
			std::istringstream raw_is(raw_os.str(), std::ios::binary);
			cereal::PortableBinaryInputArchive ar(raw_is);
			sv_<uint8_t> &bytes = volume->plane_bytes_for_write(0);
			for(size_t i = 0; i < n; i++){
				VoxelInstance v;
				ar(v);
				bytes[i * 4 + 0] = (uint8_t)v.data;
				bytes[i * 4 + 1] = (uint8_t)(v.data >> 8);
				bytes[i * 4 + 2] = (uint8_t)(v.data >> 16);
				bytes[i * 4 + 3] = (uint8_t)(v.data >> 24);
			}
		}
		return volume;
	}
	if(format == 4){
		pv::Vector3DInt32 lc, uc;
		ar(lc, uc);
		check_region(lc, uc);
		uint8_t compressed = 0;
		ar(compressed);
		uint8_t num_planes = 0;
		ar(num_planes);
		sv_<VoxelPlane> planes;
		sv_<bool> present;
		for(uint8_t i = 0; i < num_planes; i++){
			VoxelPlane p;
			uint8_t has = 0;
			ar(p.name, p.bits, has);
			if(p.bits != 8 && p.bits != 16 && p.bits != 32)
				throw Exception(ss_()+"deserialize_volume(): a plane of "+
						itos((int)p.bits)+" bits");
			planes.push_back(p);
			present.push_back(has != 0);
		}
		up_<VoxelVolume> volume(new VoxelVolume(pv::Region(lc, uc), planes));
		ss_ raw;
		ar(raw);
		// How many bytes the planes that are here come to, which is known
		// before any of them is read: the blob holds them one after another
		// and each is the volume's voxel count times its width.
		size_t want = 0;
		for(uint8_t i = 0; i < num_planes; i++){
			if(present[i])
				want += volume->voxel_count() * (planes[i].bits / 8);
		}
		// Decompressed straight into a buffer of that size and then into the
		// planes, rather than through a stream, a scratch buffer and a
		// string copy -- and the planes are filled rather than cleared and
		// then filled. A chunk read back in was 7% of the whole server
		// between the two.
		const uint8_t *src = nullptr;
		up_<uint8_t[]> buf;
		if(compressed){
			// The frame's own size first: a few bytes of header could
			// otherwise ask for 255 planes of the largest volume (util/fuzz)
			if(zstd_frame_size(raw) != (int64_t)want)
				throw Exception(ss_()+"deserialize_volume(): the planes are "+
						itos(want)+" bytes and the frame says "+
						itos(zstd_frame_size(raw)));
			// new[] without parentheses: not cleared, because every byte of
			// it is about to be written
			buf.reset(new uint8_t[want]);
			const size_t got = decompress_zstd(raw, buf.get(), want);
			if(got != want)
				throw Exception(ss_()+"deserialize_volume(): the planes are "+
						itos(want)+" bytes and the frame held "+itos(got));
			src = buf.get();
		} else {
			if(raw.size() < want)
				throw Exception("deserialize_volume(): plane data is short");
			src = (const uint8_t*)raw.data();
		}
		size_t at = 0;
		for(uint8_t i = 0; i < num_planes; i++){
			if(!present[i])
				continue;
			const size_t size = volume->voxel_count() * (planes[i].bits / 8);
			volume->set_plane_bytes(i, src + at, size);
			at += size;
		}
		return volume;
	}
	return up_<VoxelVolume>();
}

// Migration: moving a chunk from the cut it was written in to the cut the
// world is running now. See the note on migrate_volume() in the header; the
// rule the whole thing follows is that the engine moves data and never
// reinterprets it.

static uint32_t plane_mask(uint8_t bits)
{
	return bits >= 32 ? 0xffffffffUL : ((1UL << bits) - 1);
}

up_<VoxelVolume> migrate_volume(const VoxelVolume &from,
		const VoxelFormat &from_format, const VoxelFormat &to_format,
		ss_ *why, VoxelMigration *migration)
{
	auto fail = [&](const ss_ &s) -> up_<VoxelVolume> {
		if(why)
			*why = s;
		return up_<VoxelVolume>();
	};

	// A saved format is read from the save as it is: a plane past what a
	// VoxelSample holds would index the arrays below out of bounds
	ss_ fmt_why;
	if(!from_format.validate(&fmt_why))
		return fail("the format a saved chunk is tagged with is not a valid "
				"one: "+fmt_why);
	if(!to_format.validate(&fmt_why))
		return fail("this world's format is not valid: "+fmt_why);

	const sv_<VoxelPlane> &fp = from.planes();
	const sv_<VoxelPlane> &tp = to_format.planes;
	if(fp != from_format.planes)
		return fail("the chunk's planes are not the ones of the format it is "
				"tagged with, so the tag is wrong or the save is damaged");
	if(migration && !migration->begin(from_format, to_format))
		return fail("the game's migration declined "+from_format.dump()+
				" to "+to_format.dump());

	// Planes are matched by name, so a module's field follows its name
	// wherever it moved to in the list. The game's own first plane has no
	// name and matches the game's own first plane.
	sv_<int> src_of_dst(tp.size(), -1);
	for(size_t i = 0; i < tp.size(); i++){
		int j = from_format.plane_of_name(tp[i].name);
		if(j < 0)
			continue;
		// A named plane holds bits only the module that asked for it
		// understands, so its width changing is not something the engine can
		// move. The game's own plane is all roles and free bits, and both of
		// those are handled below.
		if(!tp[i].name.empty() && fp[j].bits != tp[i].bits){
			// Left zero for the game's migration to fill
			if(migration)
				continue;
			return fail("the plane \""+tp[i].name+"\" is "+
					itos((int)fp[j].bits)+" bits in the save and "+
					itos((int)tp[i].bits)+" in this world");
		}
		src_of_dst[i] = (int)j;
	}
	for(size_t j = 0; j < fp.size(); j++){
		if(to_format.plane_of_name(fp[j].name) < 0)
			log_w(MODULE, "migrate_volume(): the save has a plane \"%s\" that "
					"this world does not; it is dropped", cs(fp[j].name));
	}

	struct Move { VoxelField from, to; };
	sv_<Move> moves;
	uint32_t from_roles[VOXEL_MAX_PLANES] = {};
	uint32_t to_roles[VOXEL_MAX_PLANES] = {};
	for(const VoxelFormat::Role &r : VoxelFormat::roles()){
		const VoxelField &a = from_format.*(r.field);
		const VoxelField &b = to_format.*(r.field);
		if(a.bound() && a.plane < VOXEL_MAX_PLANES)
			from_roles[a.plane] |= a.mask() << a.shift;
		if(b.bound() && b.plane < VOXEL_MAX_PLANES)
			to_roles[b.plane] |= b.mask() << b.shift;
		if(a.bound() && b.bound()){
			// Left zero for the game's migration to fill
			if(a.width != b.width && migration)
				continue;
			if(a.width != b.width)
				return fail(ss_("the ")+r.name+" field is "+
						itos((int)a.width)+" bits in the save and "+
						itos((int)b.width)+" in this world; what that "
						"conversion is, only the game can say");
			moves.push_back(Move{a, b});
		} else if(a.bound()){
			log_w(MODULE, "migrate_volume(): the save has a %s field and this "
					"world does not; it is dropped", r.name);
		}
		// A role this world has and the save does not is left at zero, which
		// is what a new field of a world that has been played means
	}

	// Bits no role of either format claims are the game's own -- demo_undermine's
	// support field is four of them -- so they travel where they are, as
	// long as nothing has since claimed them
	uint32_t keep[VOXEL_MAX_PLANES] = {};
	sv_<bool> write(tp.size(), false);
	for(size_t i = 0; i < tp.size(); i++){
		int j = src_of_dst[i];
		if(j < 0)
			continue;
		keep[i] = ~from_roles[j] & ~to_roles[i] &
				plane_mask(fp[j].bits) & plane_mask(tp[i].bits);
		if(keep[i] != 0 && from.plane_is_materialised((uint8_t)j))
			write[i] = true;
	}
	for(const Move &m : moves){
		if(from.plane_is_materialised(m.from.plane) &&
				m.to.plane < write.size())
			write[m.to.plane] = true;
	}

	up_<VoxelVolume> to(new VoxelVolume(from.getEnclosingRegion(), tp));
	bool any = false;
	for(size_t i = 0; i < write.size(); i++)
		any = any || write[i];
	// A plane nothing wrote in the save is a plane nothing wrote here: it
	// stays unallocated rather than becoming an array of zeroes
	if(!any){
		if(migration)
			migration->migrate(from, *to);
		return to;
	}

	const pv::Region &region = from.getEnclosingRegion();
	const pv::Vector3DInt32 lc = region.getLowerCorner();
	const pv::Vector3DInt32 uc = region.getUpperCorner();
	for(int32_t z = lc.getZ(); z <= uc.getZ(); z++){
		for(int32_t y = lc.getY(); y <= uc.getY(); y++){
			for(int32_t x = lc.getX(); x <= uc.getX(); x++){
				VoxelSample s = from.sample_at(x, y, z);
				uint32_t d[VOXEL_MAX_PLANES] = {};
				for(size_t i = 0; i < tp.size(); i++){
					int j = src_of_dst[i];
					if(j >= 0)
						d[i] = s.planes[j] & keep[i];
				}
				for(const Move &m : moves){
					m.to.set(d[m.to.plane],
							m.from.get(s.planes[m.from.plane]));
				}
				for(size_t i = 0; i < tp.size(); i++){
					if(write[i])
						to->set_plane_at((uint8_t)i, x, y, z, d[i]);
				}
			}
		}
	}
	if(migration)
		migration->migrate(from, *to);
	return to;
}

void remap_volume_ids(VoxelVolume &volume, const VoxelFormat &format,
		const sv_<VoxelTypeId> &map)
{
	const VoxelField &f = format.id;
	if(!f.bound() || map.size() < 2)
		return;
	assert(map[0] == 0);
	// Every id in a plane nothing wrote is 0, and 0 maps to 0
	if(!volume.plane_is_materialised(f.plane))
		return;
	const pv::Region &region = volume.getEnclosingRegion();
	const pv::Vector3DInt32 lc = region.getLowerCorner();
	const pv::Vector3DInt32 uc = region.getUpperCorner();
	for(int32_t z = lc.getZ(); z <= uc.getZ(); z++){
		for(int32_t y = lc.getY(); y <= uc.getY(); y++){
			for(int32_t x = lc.getX(); x <= uc.getX(); x++){
				uint32_t w = volume.plane_at(f.plane, x, y, z);
				uint32_t id = f.get(w);
				// An id the table does not reach is one the save never
				// wrote; leave it rather than turning it into something
				if(id >= map.size() || map[id] == id)
					continue;
				f.set(w, map[id]);
				volume.set_plane_at(f.plane, x, y, z, w);
			}
		}
	}
}

// pv::RawVolume<int32_t>

ss_ serialize_volume_simple(const pv::RawVolume<int32_t> &volume)
{
	return generic_serialize_volume_simple(volume);
}

ss_ serialize_volume_compressed(const pv::RawVolume<int32_t> &volume)
{
	return generic_serialize_volume_compressed(volume);
}

up_<pv::RawVolume<int32_t>> deserialize_volume_int32(const ss_ &data)
{
	return generic_deserialize_volume<int32_t>(data);
}

// pv::RawVolume<uint8_t>

ss_ serialize_volume_simple(const pv::RawVolume<uint8_t> &volume)
{
	return generic_serialize_volume_simple(volume);
}

ss_ serialize_volume_compressed(const pv::RawVolume<uint8_t> &volume)
{
	return generic_serialize_volume_compressed(volume);
}

up_<pv::RawVolume<uint8_t>> deserialize_volume_8bit(const ss_ &data)
{
	return generic_deserialize_volume<uint8_t>(data);
}

}
// vim: set noet ts=4 sw=4:
