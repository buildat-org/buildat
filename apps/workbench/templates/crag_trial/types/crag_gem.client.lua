-- Crag Trial's gem on the rider's own screen: [KIT_CLIENT_REACT] (1) gone at
-- once as their bike meets its zone (the client's own test of it), the
-- server's take following a round trip later; without it, back after the
-- prediction's second
return {
	on_enter = function(e)
		if e:shown("taken") ~= true then
			e:predict("taken", true, 1)
		end
	end,
}
