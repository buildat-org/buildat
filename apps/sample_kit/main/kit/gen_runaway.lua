-- [KIT_GENERATORS] A generator whose build never ends: the meter cuts it
return {
	version = 1,
	on_build = function(c)
		local n = 0
		while true do
			n = n + 1
		end
	end,
}
