-- A component that never returns once used: the budget stops it
return {
	version = 1,
	usable = true,
	on_use = function(c, by)
		c:log("used by", c:name(by), "; looping")
		local n = 0
		while true do n = n + 1 end
	end,
}
