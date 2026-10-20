// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/voxel.h"
#include <PolyVoxCore/RawVolume.h>

namespace interface
{
	// A box of voxels, stored a plane at a time.
	//
	// Where VoxelVolume is one array of words, this is one
	// array per plane holding the same bits of every voxel -- so a
	// simulation that wants one field gets a byte per voxel instead of four,
	// a plane compresses the way a column of one material does, and a module
	// can be given a plane of its own without the game finding room for it
	// in a word it has already spent. See VoxelPlane in interface/voxel.h.
	//
	// A plane nothing has written is not allocated at all, and reads of it
	// answer zero. That is not an optimisation for a mixture world: nearly
	// every chunk of one is entirely one material, and a plane per material
	// per chunk allocated eagerly is hundreds of megabytes of zeroes.
	//
	// It satisfies what PolyVox's cube extractor wants of a volume -- a
	// VoxelType, a nested Sampler it constructs and never uses, and
	// getVoxelAt -- so the mesher needs no view type and PolyVox needs no
	// patch. getVoxelAt is plane 0, which is what every caller that predates
	// planes means by a voxel.
	class VoxelVolume
	{
	public:
		typedef VoxelInstance VoxelType;

		// A cursor into plane 0, for walking a run of voxels without
		// working the index out from the coordinates each time. What wants
		// it is merging one volume into another, which is a whole section
		// of voxels at a time; PolyVox's extractor also declares one as a
		// member, and never calls anything on it.
		//
		// Only plane 0, because that is what everything walking a volume
		// this way is about. A sweep over another plane wants
		// plane_bytes(), which hands over the whole array.
		class Sampler
		{
		public:
			Sampler(){}
			Sampler(VoxelVolume *volume): m_volume(volume){}

			void setPosition(int32_t x, int32_t y, int32_t z);
			void movePositiveX();

			VoxelInstance getVoxel() const
			{
				if(m_at == nullptr)
					return VoxelInstance(0);
				return VoxelInstance(
						(uint32_t)m_at[0] | ((uint32_t)m_at[1] << 8) |
						((uint32_t)m_at[2] << 16) | ((uint32_t)m_at[3] << 24));
			}

			void setVoxel(VoxelInstance v);

		private:
			VoxelVolume *m_volume = nullptr;
			// Into plane 0's bytes, or null when the position is outside the
			// volume or nothing has written the plane
			uint8_t *m_at = nullptr;
			int32_t m_x = 0, m_y = 0, m_z = 0;
		};

		VoxelVolume(){}
		// A volume of one 32-bit plane, which is what a format says unless
		// it says otherwise
		VoxelVolume(const pv::Region &region);
		VoxelVolume(const pv::Region &region, const sv_<VoxelPlane> &planes);

		const pv::Region& getEnclosingRegion() const { return m_region; }
		int32_t getWidth() const { return m_w; }
		int32_t getHeight() const { return m_h; }
		int32_t getDepth() const { return m_d; }
		size_t voxel_count() const { return (size_t)m_w * m_h * m_d; }
		const sv_<VoxelPlane>& planes() const { return m_planes; }

		// Plane 0 as a word. Outside the region reads as zero, which is
		// VOXELTYPEID_UNDEFINED under every format that binds an id at the
		// bottom of it -- "nothing has got here yet", which is what a read
		// past the edge of a chunk means.
		VoxelInstance getVoxelAt(int32_t x, int32_t y, int32_t z) const
		{
			return VoxelInstance(plane_at(0, x, y, z));
		}
		VoxelInstance getVoxelAt(const pv::Vector3DInt32 &p) const
		{
			return getVoxelAt(p.getX(), p.getY(), p.getZ());
		}
		// Returns whether the voxel was inside the volume, which is what
		// pv::RawVolume's own setVoxelAt returns
		bool setVoxelAt(int32_t x, int32_t y, int32_t z, VoxelInstance v)
		{
			set_plane_at(0, x, y, z, v.data);
			return contains(x, y, z);
		}
		bool setVoxelAt(const pv::Vector3DInt32 &p, VoxelInstance v)
		{
			return setVoxelAt(p.getX(), p.getY(), p.getZ(), v);
		}

		// Any of these the volume does not have already, appended by name
		// and materialised on their first write like the rest. What wants
		// it is a volume that was stored before a plane existed and is now
		// in a world that has it -- which is what happens the moment a
		// module asks for a field of its own.
		//
		// A plane the volume has and the list does not is left alone, so a
		// world with a module disabled does not cost the player that
		// module's data.
		void add_planes(const sv_<VoxelPlane> &planes);

		// Every voxel of plane 0 set to one word. What a caller that is
		// about to write the whole volume starts with.
		void fill(VoxelInstance v);

		// One plane's value at one voxel
		uint32_t plane_at(uint8_t plane, int32_t x, int32_t y, int32_t z) const;
		void set_plane_at(uint8_t plane, int32_t x, int32_t y, int32_t z,
				uint32_t value);

		// Every plane at one voxel, read together; see VoxelSample
		VoxelSample sample_at(int32_t x, int32_t y, int32_t z) const;
		VoxelSample sample_at(const pv::Vector3DInt32 &p) const
		{
			return sample_at(p.getX(), p.getY(), p.getZ());
		}
		void set_sample_at(int32_t x, int32_t y, int32_t z,
				const VoxelSample &v);

		// One run of voxels along x, copied out of another volume into
		// this one across every plane the two share by name. What wants it
		// is a region read, which is rows of a chunk into rows of the
		// answer: a devtest profile had the per-voxel sampler underneath
		// one at 12% of the server's whole CPU, and a run is a memcpy.
		//
		// False when the run is not wholly inside both volumes, and then
		// nothing is written and the caller does it whatever way it did
		// before.
		bool copy_run_from(const VoxelVolume &src,
				int32_t sx, int32_t sy, int32_t sz,
				int32_t dx, int32_t dy, int32_t dz, size_t n);

		// A run of plane 0 along x as words, for a caller handing voxels
		// to something that wants an array of them -- a region read into
		// Lua is the one that asked. Zero wherever the volume has nothing.
		//
		// False when the run is not wholly inside the volume, and then
		// nothing is written.
		bool read_words(int32_t x, int32_t y, int32_t z, size_t n,
				uint32_t *out) const;

		// A whole plane's bytes, for a caller that sweeps one rather than
		// asking per voxel. Empty when nothing has written the plane, which
		// means every value in it is zero.
		//
		// The layout is x fastest, then y, then z, which is the layout
		// pv::RawVolume had and what every blob written before planes is in.
		const sv_<uint8_t>& plane_bytes(uint8_t plane) const;
		sv_<uint8_t>& plane_bytes_for_write(uint8_t plane);
		// A plane filled from bytes that cover the whole of it, without the
		// clearing plane_bytes_for_write() does when it materialises one.
		// What asks is reading a chunk back in, which overwrote every byte
		// of a plane it had just cleared -- 157 kB a chunk, and 3.5% of the
		// whole server in a devtest profile.
		void set_plane_bytes(uint8_t plane, const uint8_t *data, size_t size);
		bool plane_is_materialised(uint8_t plane) const
		{
			return plane < m_data.size() && !m_data[plane].empty();
		}

		bool contains(int32_t x, int32_t y, int32_t z) const
		{
			return x >= m_lx && y >= m_ly && z >= m_lz &&
					x - m_lx < m_w && y - m_ly < m_h && z - m_lz < m_d;
		}

	private:
		friend class VoxelVolume::Sampler;
		size_t index_of(int32_t x, int32_t y, int32_t z) const
		{
			return (size_t)(x - m_lx) + (size_t)(y - m_ly) * m_w +
					(size_t)(z - m_lz) * m_w * m_h;
		}

		pv::Region m_region{pv::Vector3DInt32(0, 0, 0),
				pv::Vector3DInt32(-1, -1, -1)};
		sv_<VoxelPlane> m_planes;
		// One entry per plane; empty means nothing has written it
		sv_<sv_<uint8_t>> m_data;
		int32_t m_w = 0, m_h = 0, m_d = 0;
		// m_region's lower corner: its getter is a call into PolyVox, and
		// contains() and index_of() run per voxel ([HC_WEB_CHOPPY])
		int32_t m_lx = 0, m_ly = 0, m_lz = 0;
	};

	// A volume seen as samples rather than as words, for PolyVox.
	//
	// The cube extractor asks the volume for voxels and hands them to the
	// face-culling callback, and what that callback has to decide from is
	// every plane of the voxel and not only the first -- a world whose
	// materials are a plane of their own answers "is there a face here" out
	// of that plane. So the type the extractor is given is this, and
	// VoxelVolume's own getVoxelAt stays the word it has always been.
	class VoxelSampleView
	{
	public:
		typedef VoxelSample VoxelType;

		// Declared and constructed by the extractor, and never used
		struct Sampler
		{
			Sampler(){}
			Sampler(VoxelSampleView*){}
		};

		VoxelSampleView(){}
		VoxelSampleView(VoxelVolume *volume): m_volume(volume){}

		VoxelSample getVoxelAt(int32_t x, int32_t y, int32_t z) const
		{
			return m_volume ? m_volume->sample_at(x, y, z) : VoxelSample();
		}

	private:
		VoxelVolume *m_volume = nullptr;
	};

	// Asserts what a VoxelVolume does: the region and the layout, a plane
	// that nothing wrote reading as zero and costing nothing, planes of
	// each width, and reads outside the region. Runs with
	// voxel_format_self_test().
	bool voxel_volume_self_test();

	ss_ serialize_volume_simple(const VoxelVolume &volume);
	ss_ serialize_volume_compressed(const VoxelVolume &volume);
	up_<VoxelVolume> deserialize_volume(const ss_ &data);

	// Moving a saved chunk from the cut it was written in to the cut the
	// world is running now.
	//
	// The rule is that the engine moves data and never reinterprets it:
	//
	//   same role, same width, somewhere else   moved
	//   a role the world has and the save does not   left zero
	//   a role the save has and the world does not   dropped, with a warning
	//   a plane the save has and the world does not  dropped, with a warning
	//   bits no role of either format claims         copied where they are
	//   any width change, of a role or a named plane the game's migration, or refused
	//
	// The last row is the point of the whole thing. Loading a 4-bit field
	// into a 3-bit one loses data and 4 bits into 5 is a choice -- scale, or
	// zero-extend? -- that only the game can make, so the engine refuses
	// rather than guessing. Returns null and fills why when it does.
	//
	// The id field moves like any other. What the ids *mean* across a format
	// change is a different question with a different answer -- the save's
	// name table -- and remap_volume_ids() is that part.
	struct VoxelMigration;
	up_<VoxelVolume> migrate_volume(const VoxelVolume &from,
			const VoxelFormat &from_format, const VoxelFormat &to_format,
			ss_ *why, VoxelMigration *migration = nullptr);

	// **A game's own migration**, for what the engine will not guess: a
	// field or a named plane whose width changed. Given to migrate_volume()
	// (a world's: voxelworld's set_migration()), it is asked per chunk:
	//
	// begin(from, to) first: false is the game declining this change, and
	// the chunk is refused as with no migration at all. Then the engine
	// does what it does alone -- moves what only moved, zeroes what is new,
	// drops what is gone -- and leaves a field or a named plane whose
	// width changed at zero; migrate(old, moved) gets the chunk as saved
	// and that result, and writes those (or anything else it likes) into
	// moved, with whatever loop it likes. A zero-extended id is
	//   to.id.set(w, from.id.get(old_word))
	// per voxel; a 4-bit field into 8 bits scaled is the value x17.
	//
	// Called on the thread that loads chunks, one chunk at a time.
	struct VoxelMigration
	{
		virtual ~VoxelMigration(){}
		virtual bool begin(const VoxelFormat &from, const VoxelFormat &to) = 0;
		virtual void migrate(const VoxelVolume &old, VoxelVolume &moved) = 0;
	};

	// Rewrites every voxel's id field through map, which is indexed by the
	// id as it is stored. An id past the end of map is left alone, and
	// map[0] has to be 0 -- nothing has generated a voxel with id 0, and a
	// plane nothing wrote is skipped on the strength of that.
	void remap_volume_ids(VoxelVolume &volume, const VoxelFormat &format,
			const sv_<VoxelTypeId> &map);

	// pv::RawVolume<int32_t>
	ss_ serialize_volume_simple(const pv::RawVolume<int32_t> &volume);
	ss_ serialize_volume_compressed(const pv::RawVolume<int32_t> &volume);
	up_<pv::RawVolume<int32_t>> deserialize_volume_int32(const ss_ &data);

	// pv::RawVolume<uint8_t>
	ss_ serialize_volume_simple(const pv::RawVolume<uint8_t> &volume);
	ss_ serialize_volume_compressed(const pv::RawVolume<uint8_t> &volume);
	up_<pv::RawVolume<uint8_t>> deserialize_volume_8bit(const ss_ &data);
}
// vim: set noet ts=4 sw=4:
