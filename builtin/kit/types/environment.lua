-- An environment ([KIT_ENVIRONMENT], kit_plan 4k): the sky's colour (the
-- far fog's), the fog's distances, the ambient light, the time of day and
-- how fast it goes (day_minutes: a day's length in minutes, 0: the time
-- stands), gravity (times each movement's own), the weather and the
-- season. On the app root it is every scene's; a scene with one of its own
-- (placed while one is on the root) has that instead, whole.
--
-- Kit keeps the clock and tells the clients; they draw the light of the
-- hour, the weather under open sky (rain, snow, a storm: rain and a dark
-- sky) and the season by the voxels' season textures (a material's
-- "seasons", materials.json), the voxels unchanged.
--
-- [KIT_LIGHTING] Its lighting is the composition's, the root's alone (a
-- scene's says nothing): cartoon (the default; LDR, the ambient, one sun,
-- the fog) or physical (HDR: sky_render's exposure, bloom and tonemap,
-- physical_sky's light by the hour, the voxels' light drawn). The World's
-- sky light darkens caves in both when it is on.
--
-- Its signals: set_time (hours, 0 to 24), set_day_minutes, set_weather,
-- set_season, set_sky (a colour), set_fog (the fog's end, cells),
-- set_ambient (a colour) and set_gravity. Out: dawn and dusk (6 and 18
-- o'clock, while the time goes), weather_changed and season_changed (the
-- new one).
local WEATHER = {clear = true, rain = true, snow = true, storm = true}
local SEASONS = {spring = true, summer = true, autumn = true, winter = true}

local function colour(v)
	return type(v) == "string" and v:match("^#%x%x%x%x%x%x$") ~= nil
end

-- What the signals changed, over the parameters (Kit reads state.set)
local function set(c, k, v)
	local s = {}
	for key, val in pairs(c.state.set or {}) do
		s[key] = val
	end
	s[k] = v
	c.state.set = s
end

local function now(c, k)
	local s = c.state.set or {}
	if s[k] ~= nil then
		return s[k]
	end
	return c.params[k]
end

return {
	version = 1,
	root = true,
	environment = true,
	params = {
		sky = {type = "string", default = "#8cadd9"},
		fog_start = {type = "number", default = 120, min = 0, max = 2000},
		fog_end = {type = "number", default = 200, min = 1, max = 2000},
		ambient = {type = "string", default = "#737380"},
		time = {type = "number", default = 12, min = 0, max = 24},
		day_minutes = {type = "number", default = 0, min = 0, max = 1440},
		gravity = {type = "number", default = 1, min = 0, max = 10},
		weather = {type = "string", default = "clear",
			choices = {"clear", "rain", "snow", "storm"}},
		season = {type = "string", default = "summer",
			choices = {"spring", "summer", "autumn", "winter"}},
		lighting = {type = "string", default = "cartoon",
			choices = {"cartoon", "physical"}},
	},
	state = {
		-- {key = value}: what the signals set, shared with the clients
		-- through Kit; time_set counts set_time's (the clock starts over)
		set = {default = {}, shared = true},
		time_set = {default = 0, shared = true},
	},
	inputs = {set_time = "number", set_day_minutes = "number",
		set_weather = "string", set_season = "string", set_sky = "string",
		set_fog = "number", set_ambient = "string", set_gravity = "number"},
	outputs = {dawn = "none", dusk = "none", weather_changed = "string",
		season_changed = "string"},
	on_start = function(c)
		c.state.set = {}
	end,
	on_input = function(c, input, value, by)
		local k = input:sub(5)
		if input == "set_time" then
			if type(value) ~= "number" or value ~= value then
				return
			end
			set(c, "time", value % 24)
			c.state.time_set = (c.state.time_set or 0) + 1
		elseif input == "set_weather" then
			if not WEATHER[value] or now(c, "weather") == value then
				return
			end
			set(c, "weather", value)
			c:emit("weather_changed", value)
		elseif input == "set_season" then
			if not SEASONS[value] or now(c, "season") == value then
				return
			end
			set(c, "season", value)
			c:emit("season_changed", value)
		elseif input == "set_sky" or input == "set_ambient" then
			if not colour(value) then
				return
			end
			set(c, k, value)
		elseif input == "set_fog" then
			if type(value) ~= "number" or not (value >= 1) then
				return
			end
			set(c, "fog_end", math.min(value, 2000))
			set(c, "fog_start", math.min(value, 2000) * 0.6)
		elseif type(value) == "number" and value >= 0 then
			-- set_day_minutes, set_gravity
			set(c, k, math.min(value, k == "gravity" and 10 or 1440))
		else
			return
		end
		c:log(input, tostring(value), by and ("by " .. c:name(by)) or "")
	end,
	-- Kit's, as the clock passes 6 and 18
	on_daytime = function(c, what)
		c:log(what)
		c:emit(what)
	end,
}
