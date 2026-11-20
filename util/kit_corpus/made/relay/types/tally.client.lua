-- The score keeper on each player's screen: a line in the entity's Log as
-- the score changes
return {
	on_state = function(e)
		if e:shown("score") ~= 0 then
			e:log("score " .. tostring(e:shown("score")))
		end
	end,
}
