-- [KIT_SYMMETRY] A symmetric map (kit_plan 7c): what is under it is copied
-- into the other slices, as real entities and voxels kept current by every
-- edit (kit.cpp does all of it; api.h says how). It stands at the World's
-- middle, one a scene. slices: halves or quadrants; angle: their seams
-- straight (along x and z) or at 45 degrees; mode: mirrored or rotational;
-- slice: the one builders edit (halves straight: +x, -x, +z, -z; halves at
-- 45: +x-z, -x+z, +x+z, -x-z; quadrants straight: +x+z, -x+z, -x-z, +x-z;
-- quadrants at 45: +x, -x, +z, -z). Not `enabled`, nothing is copied (the copies go);
-- enabled, the authored slice's voxels are copied over the others, one
-- undo. Mirroring places, it doesn't flip models: a voxel flips exactly, an
-- entity's place and facing are mirrored, its look only turned
return {
	version = 2,
	-- [KIT_SINGLE] one a scene (right under it: kit.cpp's sym_check)
	single = true,
	about = {
		group = "World",
		what = "Copies what is under it, and the voxels, into the map's other slices.",
	},
	params = {
		enabled = {type = "bool", default = false},
		slices = {type = "string", default = "halves",
			choices = {"halves", "quadrants"}},
		angle = {type = "string", default = "straight",
			choices = {"straight", "45"}},
		mode = {type = "string", default = "mirrored",
			choices = {"mirrored", "rotational"}},
		slice = {type = "string", default = "+x", choices = {"+x", "-x", "+z",
			"-z", "+x+z", "-x+z", "-x-z", "+x-z"}},
	},
	gizmo = {shape = "box", size = 0.3, color = "#d060d0"},
	-- [KIT_API_1] version 2: `enabled` was `on`
	migrate = function(params, from)
		if from < 2 then
			params.enabled, params.on = params.on, nil
		end
		return params
	end,
}
