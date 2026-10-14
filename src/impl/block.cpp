// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/block.h"
#include "core/log.h"
#define MODULE "block"

namespace interface {

static const pv::Vector3DUint8 FACE_DIRS[6] = {
	pv::Vector3DUint8(0, 1, 0),
	pv::Vector3DUint8(0, -1, 0),
	pv::Vector3DUint8(1, 0, 0),
	pv::Vector3DUint8(-1, 0, 0),
	pv::Vector3DUint8(0, 0, 1),
	pv::Vector3DUint8(0, 0, -1),
};

// Map part block segment's face to atlas segment definition
static void texmap_segment_face(const pv::Vector3DUint8 &block_size,
		const pv::Vector3DUint8 &block_segi, size_t face_i,
		magic::IntVector2 &total_segments, magic::IntVector2 &select_segment)
{
	if(face_i == 0){
		total_segments = magic::IntVector2(
				block_size.getX(),
				block_size.getZ()
		);
		select_segment = magic::IntVector2(
				block_segi.getX(),
				block_segi.getZ()
		);
	} else if(face_i == 1){
		total_segments = magic::IntVector2(
				block_size.getX(),
				block_size.getZ()
		);
		select_segment = magic::IntVector2(
				block_size.getX() - 1 - block_segi.getX(),
				block_size.getZ() - 1 - block_segi.getZ()
		);
	} else if(face_i == 2){
		total_segments = magic::IntVector2(
				block_size.getY(),
				block_size.getZ()
		);
		select_segment = magic::IntVector2(
				block_segi.getY(),
				block_segi.getZ()
		);
	} else if(face_i == 3){
		total_segments = magic::IntVector2(
				block_size.getY(),
				block_size.getZ()
		);
		select_segment = magic::IntVector2(
				block_size.getY() - 1 - block_segi.getY(),
				block_size.getZ() - 1 - block_segi.getZ()
		);
	} else if(face_i == 4){
		total_segments = magic::IntVector2(
				block_size.getX(),
				block_size.getY()
		);
		select_segment = magic::IntVector2(
				block_segi.getX(),
				block_segi.getY()
		);
	} else if(face_i == 5){
		total_segments = magic::IntVector2(
				block_size.getX(),
				block_size.getY()
		);
		select_segment = magic::IntVector2(
				block_size.getX() - 1 - block_segi.getX(),
				block_size.getY() - 1 - block_segi.getY()
		);
	}
}

struct CBlockRegistry: public BlockRegistry
{
	VoxelRegistry *m_voxel_reg;
	sv_<BlockDefinition> m_defs;
	sm_<BlockName, BlockTypeId> m_name_to_id;

	CBlockRegistry(VoxelRegistry *voxel_reg):
		m_voxel_reg(voxel_reg)
	{
		m_defs.resize(1); // Id 0 is BLOCKTYPEID_UNDEFINEDD
	}

	BlockTypeId add_block_with_predefined_segments(const BlockDefinition &def)
	{
		BlockTypeId id = m_defs.size();
		m_defs.resize(id + 1);
		m_defs[id] = def;
		m_defs[id].id = id;
		m_name_to_id[def.name] = id;
		return id;
	}

	BlockTypeId add_block_generate_segments(const BlockSourceDefinition &def)
	{
		// Check this because VoxelDefinition has a static number of textures
		if(def.side_textures.size() != 6)
			throw Exception("BlockSourceDefinition::side_textures must contain "
					"6 resource names");
		// Create block definition without segments
		BlockDefinition plain_def;
		plain_def.name = def.name;
		plain_def.num_rotations = def.num_rotations;
		plain_def.size = def.size;
		// Generate voxels for segments
		// TODO: Rotations
		// NOTE: The secondary rotation rotates the block segments (done first)
		// NOTE: The primary rotation rotates the face (done second)
		for(int z = 0; z < def.size.getZ(); z++){
			for(int y = 0; y < def.size.getY(); y++){
				for(int x = 0; x < def.size.getX(); x++){
					VoxelDefinition vdef;
					vdef.name.block_name = def.name;
					vdef.name.segment_x = x;
					vdef.name.segment_y = y;
					vdef.name.segment_z = z;
					vdef.name.rotation_primary = 0;
					vdef.name.rotation_secondary = 0;
					vdef.handler_module = def.handler_module;
					// A piece of a textured cube; air with empty edges is
					// refused ([API_DEFAULTS_07])
					vdef.edge_material_id = EDGEMATERIALID_GROUND;
					for(size_t i = 0; i < 6; i++){
						AtlasSegmentDefinition &seg = vdef.textures[i];
						seg.resource_name = def.side_textures[i];
						// Map block segment face to atlas segment
						// - x, y, z is block segment
						// - i is segment face index
						texmap_segment_face(def.size, pv::Vector3DUint8(x, y, z), i,
								seg.total_segments, seg.select_segment);
						// TODO: Rotation
					}
					VoxelTypeId vid = m_voxel_reg->add_voxel(vdef);
					plain_def.segments.push_back(vid);
				}
			}
		}
		// Add final block definition
		return add_block_with_predefined_segments(plain_def);
	}

	const BlockDefinition* get(const BlockTypeId &id)
	{
		if(id >= m_defs.size()){
			log_w(MODULE, "BlockRegistry::get(): id=%i not found", id);
			return NULL;
		}
		return &m_defs[id];
	}

	const BlockDefinition* get(const BlockName &name)
	{
		auto it = m_name_to_id.find(name);
		if(it == m_name_to_id.end()){
			log_w(MODULE, "CBlockRegistry::get(): name=\"%s\" not found", cs(name));
			return NULL;
		}
		BlockTypeId id = it->second;
		return get(id);
	}

	// TODO: Network serialization
	// TODO: Ability to track changes (just some kind of set_dirty()?)
};

BlockRegistry* createBlockRegistry(VoxelRegistry *voxel_reg)
{
	return new CBlockRegistry(voxel_reg);
}

}
// vim: set noet ts=4 sw=4:
