-- [KIT_GENERATORS] (4z37f) A generator for util/kit_generators_check.sh: a
-- kit/sign at each of its corners (a level points param, each point's
-- `h` its sign's height) and `count` signs scattered by `seed` in a 20 m
-- square, none within 3 m of another entity of the scene (c.entities);
-- past the default cap of 63. In play `reseed` (not 0) builds it again
-- live from that seed at the round's start (c:generate on itself). Its log
-- says whether c.move_lib (move.lua) is there.
return {
	version = 1,
	children = 200,
	params = {
		count = {type = "number", default = 70, min = 0, max = 190},
		seed = {type = "number", default = 1, min = 0, max = 1000000},
		reseed = {type = "number", default = 0, min = 0, max = 1000000},
		corners = {type = "points", level = true, values = {{name = "h", min = 0, max = 5,
			default = 1}}, default = {{-8, -8, 1}, {8, -8, 1}, {0, 8, 2}}},
	},
	on_build = function(c)
		local s = math.floor(c.params.seed) % 2147483646 + 1
		local function r()
			s = s * 16807 % 2147483647
			return (s - 1) / 2147483646
		end
		local o = c.pos or {0, 0, 0}
		for _, p in ipairs(c.params.corners) do
			c:child{type = "kit/sign", name = "corner", pos = {p[1], p[3], p[2]}}
		end
		local made, clear = 0, 0
		for _ = 1, c.params.count do
			local x, z = r() * 20 - 10, r() * 20 - 10
			local ok = true
			for _, e in ipairs(c.entities) do
				local dx, dz = e.pos and e.pos[1] - o[1] - x, e.pos and e.pos[3] - o[3] - z
				if e.pos and dx * dx + dz * dz < 9 then
					ok = false
				end
			end
			if ok then
				c:child{type = "kit/sign", name = "post", pos = {x, 0, z}}
				made = made + 1
			else
				clear = clear + 1
			end
		end
		c:log(string.format("gen_posts: seed %d, %d posts, %d kept clear of %d entities%s",
			c.params.seed, made, clear, #c.entities, type(c.move_lib) == "table" and c.move_lib.world and
			", move.lua there" or ""))
	end,
	on_start = function(c)
		if c.params.reseed ~= 0 then
			c:generate(c.id, {seed = c.params.reseed})
		end
	end,
}
