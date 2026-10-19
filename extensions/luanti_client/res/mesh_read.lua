-- Buildat: extensions/luanti_client/res/mesh_read.lua
-- (the luanti module runs it too, from __luanti_shared_path: lua/mesh.lua)
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The model readers beside this file, by a model's extension: .obj
-- (objmesh.lua), .b3d (b3dmesh.lua), .gltf and .glb (gltfmesh.lua). One
-- copy for the module, which turns a "mesh" node or object into quads on
-- the server, and for luanti_client, which does it itself
-- ([LUANTI_SHARED_1019]). .x is read by neither, and a model in it keeps the
-- cube it had.
--
--   meshes = <this file>(load, parse_json, decode_base64)
-- load(name): a file beside this one run, what it returns.
-- parse_json(text) -> a value, or nil and why; decode_base64(text) -> bytes:
-- glTF's, the module's core ones or the client's.
--   meshes.reader(name) -> parse(data[, frame]) -> quads, groups, skipped,
-- or nil for a format none reads. parse raises on a file it cannot read;
-- frame poses a .b3d at that frame of its animation.
--   meshes.scale(quads, by): every corner times by, in place.
return function(load, parse_json, decode_base64)
	local obj = load("objmesh.lua")
	local b3d = load("b3dmesh.lua")
	local gltf = load("gltfmesh.lua")
	gltf.parse_json, gltf.decode_base64 = parse_json, decode_base64
	local by_extension = {obj = obj.parse, b3d = b3d.parse,
			gltf = gltf.parse, glb = gltf.parse}
	return {
		reader = function(name)
			return by_extension[(tostring(name):lower():match("%.(%w+)$"))]
		end,
		scale = obj.scale,
	}
end
-- vim: set noet ts=4 sw=4:
