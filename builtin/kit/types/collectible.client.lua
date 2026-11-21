-- kit/collectible's client part ([KIT_COLLECTIBLE]): gone on this
-- player's screen as their own body meets its zone ([KIT_CLIENT_REACT]
-- (1)), the server's take a round trip later; without it, back after the
-- prediction's second. The look's when.vanish draws the going
return {
	on_enter = function(e)
		if e:shown("taken") ~= true then
			e:predict("taken", true, 1)
		end
	end,
}
