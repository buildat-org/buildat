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
-- scene's says nothing): cartoon (LDR, the ambient, one sun, the fog),
-- physical (HDR: sky_render's exposure, bloom and tonemap, physical_sky's
-- light by the hour and its sky, the sun's shadow map, the voxels' light
-- drawn) or fast_physical, the default ([KIT_FAST_PHYSICAL]: physical
-- without the shadow map and the bloom, near cartoon's frame time; the
-- three a choice of style). The World's sky light darkens caves in all
-- three when it is on (cartoon where the root has no environment).
--
-- The sky, each mode its own (cartoon Luanti's, physical physical_sky's),
-- by the same parameters: the time places the sun and the moon and fades
-- the stars in; sun, moon and stars switch them (off for a scene
-- underground or in space: no sun, no moon, no light of theirs); the
-- clouds' cover (0..1, 0 none), height (cells) and wind (cells a second,
-- toward a direction in degrees, 0 +z, 90 +x).
--
-- Its signals: set_time (hours, 0 to 24), set_day_minutes, set_weather,
-- set_season, set_sky (a colour), set_fog (the fog's end, cells),
-- set_ambient (a colour), set_gravity, set_clouds (the cover),
-- set_cloud_height, set_wind (its speed), set_wind_dir, set_sun, set_moon
-- and set_stars (on or off), set_intensity.
--
-- The weather is a modifier on those (the scene with no weather): clear
-- leaves them as set, cloudy covers at least 0.7 of the sky and dims the
-- light to 0.9, rain and snow 0.8 and 0.8 with their drops, a storm 0.95
-- and 0.55, the fog at half and the wind at least 10, heavy rain; the
-- intensity (0..1) scales the drops and those floors and factors. A change
-- of the weather or of the parameters fades over weather_fade seconds.
-- set_weather moves the modifier, set_clouds, set_fog and the rest the
-- base, each apart: a gloomy clear day stays gloomy through the rain.
--
-- Out: dawn and dusk (6 and 18 o'clock, while the time goes),
-- weather_changed and season_changed (the new one).
local WEATHER = {clear = true, cloudy = true, rain = true, snow = true,
	storm = true}
local SEASONS = {spring = true, summer = true, autumn = true, winter = true}
-- The clouds' signals: the parameter, its range
local CLOUDS = {set_clouds = {"cloud_cover", 0, 1},
	set_intensity = {"intensity", 0, 1},
	set_cloud_height = {"cloud_height", 10, 1000},
	set_wind = {"cloud_wind_speed", 0, 100},
	set_wind_dir = {"cloud_wind_dir", 0, 360}}

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
		sky = {cat = "look", type = "string", default = "#8cadd9"},
		fog_start = {cat = "look", type = "number", default = 120, min = 0,
			max = 2000},
		fog_end = {cat = "look", type = "number", default = 200, min = 1,
			max = 2000},
		ambient = {cat = "look", type = "string", default = "#737380"},
		time = {type = "number", default = 12, min = 0, max = 24},
		day_minutes = {type = "number", default = 0, min = 0, max = 1440},
		gravity = {cat = "physics", type = "number", default = 1, min = 0,
			max = 10},
		weather = {cat = "look", type = "string", default = "clear",
			choices = {"clear", "cloudy", "rain", "snow", "storm"}},
		intensity = {cat = "look", type = "number", default = 1, min = 0,
			max = 1},
		weather_fade = {cat = "look", type = "number", default = 5, min = 0,
			max = 600},
		latitude = {cat = "look", type = "number", default = 25, min = -89,
			max = 89},
		north = {cat = "look", type = "number", default = 30, min = 0,
			max = 360},
		season = {cat = "look", type = "string", default = "summer",
			choices = {"spring", "summer", "autumn", "winter"}},
		lighting = {cat = "look", type = "string", default = "fast_physical",
			choices = {"cartoon", "fast_physical", "physical"}},
		cloud_cover = {cat = "look", type = "number", default = 0.4, min = 0,
			max = 1},
		cloud_height = {cat = "look", type = "number", default = 120, min = 10,
			max = 1000},
		cloud_wind_speed = {cat = "look", type = "number", default = 2, min = 0,
			max = 100},
		cloud_wind_dir = {cat = "look", type = "number", default = 180, min = 0,
			max = 360},
		sun = {cat = "look", type = "bool", default = true},
		moon = {cat = "look", type = "bool", default = true},
		stars = {cat = "look", type = "bool", default = true},
	},
	state = {
		-- {key = value}: what the signals set, shared with the clients
		-- through Kit; time_set counts set_time's (the clock starts over)
		set = {default = {}, shared = true},
		time_set = {default = 0, shared = true},
	},
	about = {
		what = "The sky, the light, the time of day, the weather and the season.",
		inputs = {
			set_time = "Sets the hour. Value: 0 to 24.",
			set_day_minutes = "Sets a day's length. Value: minutes; 0 stops the clock.",
			set_weather = "Sets the weather. Value: clear, cloudy, rain, snow or storm.",
			set_season = "Sets the season. Value: spring, summer, autumn or winter.",
			set_sky = "Sets the sky's colour. Value: #rrggbb.",
			set_fog = "Sets where the fog ends. Value: cells, 1 or more.",
			set_ambient = "Sets the ambient light. Value: #rrggbb.",
			set_gravity = "Sets gravity. Value: times each movement's own, 0 to 10.",
			set_clouds = "Sets the cloud cover. Value: 0 to 1.",
			set_cloud_height = "Sets the clouds' height. Value: cells.",
			set_wind = "Sets the wind's speed. Value: cells a second.",
			set_wind_dir = "Sets the wind's direction. Value: degrees, 0 is +z, 90 is +x.",
			set_sun = "Turns the sun on or off. Value: true or false.",
			set_moon = "Turns the moon on or off. Value: true or false.",
			set_stars = "Turns the stars on or off. Value: true or false.",
			set_intensity = "Sets how strong the weather is. Value: 0 to 1.",
		},
		outputs = {
			dawn = "The clock passed 6.",
			dusk = "The clock passed 18.",
			weather_changed = "The weather changed. Value: the new one.",
			season_changed = "The season changed. Value: the new one.",
		},
	},
	inputs = {set_time = "number", set_day_minutes = "number",
		set_weather = "string:weather", set_season = "string:season",
		set_sky = "string:color",
		set_fog = "number", set_ambient = "string:color", set_gravity = "number",
		set_clouds = "number", set_cloud_height = "number",
		set_wind = "number", set_wind_dir = "number", set_sun = "bool",
		set_moon = "bool", set_stars = "bool", set_intensity = "number"},
	outputs = {dawn = "none", dusk = "none", weather_changed = "string:weather",
		season_changed = "string:season"},
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
		elseif input == "set_sun" or input == "set_moon" or
				input == "set_stars" then
			if type(value) ~= "boolean" then
				return
			end
			set(c, k, value)
		elseif CLOUDS[input] then
			local p = CLOUDS[input]
			if type(value) ~= "number" or value ~= value then
				return
			end
			if input == "set_wind_dir" then
				value = value % 360
			end
			set(c, p[1], math.max(p[2], math.min(p[3], value)))
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
