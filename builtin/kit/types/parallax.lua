-- A parallax layer ([KIT_SIDE_SCENERY] (8)): backdrops for a side view,
-- no look of its own. What is under it (set_parent, the editor's tree:
-- polygons, parts, any look, nested too) is drawn by each client offset by
-- the camera's travel from the layer's place: 1 - follow of it along x (0:
-- it stays with the camera, as the sky; 1: the world), 1 - follow_y of it
-- up and down (1, the default: a skyline's foot stays on the horizon as
-- the body jumps). A place authored is where it is drawn with the camera
-- at the layer's x. `repeat` (metres, 0: none): copies every repeat along
-- x, as many as the view needs. Visual only: what is under it is never met
-- (the server's collision and the bots' grid leave it out, as the clients
-- do). Play, spectating and get_view draw it from their camera; the editor
-- draws it where authored and says so (module.lua's parallax pass).
-- [KIT_TOP_DOWN] (5) With kit/controls' plane horizontal (a top-down view)
-- follow_y is along z, the view's up on the screen, and nothing moves up and
-- down: ground far under the play (or clouds over it) lagging the camera
-- both ways. The name kept: follow_y is the view's second axis
-- [KIT_3D_GAINS_1] (4z38) `far`: its looks drawn behind the world, as the sky is
-- (module.lua's parallax pass: unlit in their colours, no fog, where nothing of the
-- world is drawn, after the sky), a skyline or a mountain ring round a 3D view
-- (follow 0 and follow_y 0: always round the camera), however far it is placed;
-- no look's draw distance culls it. `repeat_z` (metres, 0: none): with kit/controls'
-- plane horizontal, copies every repeat_z along z too (a grid with `repeat`)
return {
	version = 1,
	-- [KIT_API_1] outside Kit API 1: it may change in any release
	experimental = true,
	parallax = {follow = "param:follow", follow_y = "param:follow_y",
		["repeat"] = "param:repeat", far = "param:far", repeat_z = "param:repeat_z"},
	params = {
		follow = {cat = "look", type = "number", default = 0.5, min = 0, max = 1},
		follow_y = {cat = "look", type = "number", default = 1, min = 0,
			max = 1},
		["repeat"] = {cat = "look", type = "number", default = 0, min = 0,
			max = 4096},
		far = {cat = "look", type = "bool", default = false},
		repeat_z = {cat = "look", type = "number", default = 0, min = 0,
			max = 4096},
	},
	gizmo = {shape = "box", size = 0.3, color = "#8090e0"},
	about = {
		group = "Building",
		what = "A backdrop layer for side views. What is under it (polygons, parts) moves with the camera by 1 - follow (0: as far as the sky, 1: like the world; follow_y does the same up and down, or along z in a top-down game with kit/controls' plane horizontal, 1 by default). It repeats every `repeat` m along x (0: once), and nothing collides with it. Place it where it looks right with the camera at the layer's x. E.g. {\"follow\": 0.2, \"repeat\": 128} with a far skyline polygon under it. far draws what is under it behind the world (unlit, unfogged, as the sky): {\"far\": true, \"follow\": 0, \"follow_y\": 0} with a ring of mountain polygons is a horizon round a 3D view.",
		keywords = "backdrop background skyline scenery scroll depth layer far mountains horizon",
		params = {
			follow = "How much it moves like the world along x (0: stays with the camera, as the sky; 1: the world).",
			follow_y = "The same up and down, or along z in a top-down game.",
			["repeat"] = "Copies it every this many metres along x (0: once).",
			far = "Drawn behind the world, unlit and unfogged, as the sky is: a skyline or mountains round a 3D view.",
			repeat_z = "In a top-down game, copies it every this many metres along z too (0: once).",
		},
	},
}
