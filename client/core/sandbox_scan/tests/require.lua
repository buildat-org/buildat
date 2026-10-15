-- Buildat: extension/sandbox_test/tests/require.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>

-- What a sandbox may require and what it may not. The sandbox's own require
-- used to search package.loaded by name, and package.loaded holds every
-- standard library the host state has -- so require("os") was os.execute in
-- the hands of whatever server the client had connected to.
local log = buildat.Logger("require.lua")

local function refuses(name)
	local ok = pcall(require, name)
	assert(not ok, "require(\"" .. name .. "\") was allowed in the sandbox")
end

for _, name in ipairs({
	-- The standard libraries, each of which is in package.loaded
	"os", "io", "debug", "string", "table", "math", "coroutine",
	"package", "_G",
	-- LuaJIT's, in case this is ever built on it
	"ffi", "jit", "bit",
	-- And the namespaces that are allowed, with something else at the end
	-- of them: the patterns are anchored, so neither of these is a name
	"buildat/extension/../../os",
	"buildat/core/../../os",
	"buildat/module/../../io",
	"buildat/extension/",
	"buildat/core/",
	"buildat/module/",
	-- An extension is not a part of the client core ([CLIENT_CORE])
	"buildat/core/cereal",
}) do
	refuses(name)
end

-- What it may: an extension's safe interface, and twice over -- the second
-- one comes out of package.loaded under its own full name
local cereal = require("buildat/extension/cereal")
assert(type(cereal) == "table", "an extension did not load in the sandbox")
assert(type(cereal.binary_output) == "function",
		"the extension that loaded is not the safe interface")
assert(require("buildat/extension/cereal") == cereal,
		"an extension loaded twice is not the same table")

-- A core part by its name and by the old one, kept until the next break,
-- is the same table ([CLIENT_CORE])
local magic = require("buildat/core/urho3d")
assert(type(magic) == "table", "a core part did not load in the sandbox")
assert(require("buildat/extension/urho3d") == magic,
		"buildat/extension/urho3d is not buildat/core/urho3d")

log:info("require.lua: the standard libraries are not requirable")

-- An extension without a safe interface is refused, and one with it hands
-- out that table alone: the launch grid's check file used to try this
-- from the menu at every start ([UI_UAF]), which is not where a probe of
-- the sandbox belongs
refuses("buildat/extension/sandbox_test")
assert(cereal.safe == nil and cereal.run == nil,
		"an extension's own table reached the sandbox")

-- And the libraries the sandbox never had
assert(io == nil or io.open == nil, "io.open is in the sandbox")
assert(os.execute == nil, "os.execute is in the sandbox")
