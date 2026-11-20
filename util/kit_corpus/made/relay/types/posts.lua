-- A generator: `count` signposts along the east side, spaced by a seeded
-- draw; in play `reseed` (not 0) builds them again from that seed as the
-- round starts
return {
	version = 1,
	about = {group = "Building", what = "Signposts along a side, placed by a seed."},
	params = {
		count = {type = "number", default = 4, min = 0, max = 20},
		seed = {type = "number", default = 1, min = 0, max = 1000000},
		reseed = {type = "number", default = 0, min = 0, max = 1000000},
	},
	on_build = function(c)
		local s = math.floor(c.params.seed) % 2147483646 + 1
		local z = -8
		for i = 1, c.params.count do
			s = s * 16807 % 2147483647
			z = z + 1 + s % 4
			c:child{type = "kit/sign", name = "post " .. i, pos = {0, 0, z},
				params = {text = "Post " .. i}}
		end
		c:log("posts: seed", c.params.seed, "count", c.params.count, "last at", z)
	end,
	on_start = function(c)
		if c.params.reseed ~= 0 then
			c:generate(c.id, {seed = c.params.reseed})
		end
	end,
}
