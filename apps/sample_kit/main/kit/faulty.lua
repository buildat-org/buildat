-- A component with a bug: its error is logged, and the others go on in
-- the same box
return {
	version = 1,
	usable = true,
	on_use = function(c, by)
		local t = nil
		return t.x
	end,
}
