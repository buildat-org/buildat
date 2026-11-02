-- [KIT_GENERATORS] A generator past the cap: `count` children (Kit takes
-- 63 at most)
return {
	version = 1,
	params = {count = {type = "number", default = 70, min = 0, max = 1000}},
	on_build = function(c)
		for i = 1, c.params.count do
			c:child{type = "kit/sign", pos = {i, 0, 0}}
		end
	end,
}
