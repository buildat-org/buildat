-- Brimstone Speedway's crate on the driver's own screen: gone at once as
-- their car meets it ([KIT_CLIENT_REACT] (1)), the server's take a round
-- trip later
return {
	on_enter = function(e)
		if e:shown("taken") ~= true then
			e:predict("taken", true, 1)
		end
	end,
}
