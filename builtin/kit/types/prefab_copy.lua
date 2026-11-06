-- [KIT_PREFAB_ROOT] A placed prefab's root: the editor's place of a prefab
-- makes it, its members under it as its built children. It does nothing in
-- play; its place and turn are the copy's. Not in the palette.
-- [KIT_FREE_PREFAB] mode: its voxels stamped into the world, or a free object
-- of the prefab's model at its place and any turn (kit.cpp's sync_free_objects).
return {
	version = 1,
	about = {
		what = "A placed prefab's root: where the copy is and how it is turned.",
	},
	params = {
		mode = {type = "string", default = "stamped",
			choices = {"stamped", "free"}},
	},
	gizmo = {shape = "box", size = 0.25, color = "#60d0d0"},
}
