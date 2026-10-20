-- Buildat: extension/urho3d/safe_classes.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local dump = buildat.dump
local log = buildat.Logger("safe_classes")
local magic_sandbox = require("buildat/core/magic_sandbox")
local M = {}

-- A resource name a sandboxed script may ask the cache for. Urho3D's
-- ResourceCache resolves an absolute path and falls back to it outside
-- every resource dir (SearchResourceDirs, Exists), and its "../" strip is
-- one non-recursive pass; without this an app could read or probe any
-- file on the machine (GetResource("Image", "/home/.../x.png") +
-- Image:GetPixel exfiltrates it; Exists("/home/.../.ssh/id_rsa") tells it
-- the file is there). A legitimate name is relative and has no "..":
-- textures, fonts, UI styles, "generated/..." from AddManualResource.
local function resource_name_ok(name)
	return type(name) == "string" and name ~= "" and
			name:sub(1, 1) ~= "/" and name:sub(1, 1) ~= "\\" and
			not name:find("%.%.") and not name:find(":")
end

-- **Keys typed into a secret field are nobody else's, polled either**
-- ([SECURITY_RUN_1] withholds the events; [SANDBOX_API_AUDIT]): a
-- script asking GetKeyPress of every key each frame read a Starport
-- password as well as KeyDown did. While one has the focus only the keys
-- that move or finish answer.
local function secret_focus()
	return magic_sandbox.keys_withheld()
end
local MOVE_KEYS = {}
for _, name in ipairs({"KEY_RETURN", "KEY_RETURN2", "KEY_KP_ENTER",
		"KEY_ESCAPE", "KEY_TAB", "KEY_UP", "KEY_DOWN", "KEY_LEFT", "KEY_RIGHT",
		"KEY_HOME", "KEY_END", "KEY_PAGEUP", "KEY_PAGEDOWN", "KEY_BACKSPACE",
		"KEY_DELETE"}) do
	if _G[name] then MOVE_KEYS[_G[name]] = true end
end
assert(MOVE_KEYS[KEY_RETURN], "safe_classes: no key constants")
local function hidden_key(key)
	return not MOVE_KEYS[key] and secret_focus()
end

function M.define(dst, util)
	util.wc("StringHash", {
		unsafe_constructor = util.wrap_function({{"string"}},
		function(value)
			return util.wrap_instance("StringHash", StringHash(value))
		end),
		instance = {
		}
	})

	util.wc("VectorBuffer", {
		class = {
			new = function()
				return util.wrap_instance("VectorBuffer", VectorBuffer())
			end,
		},
		instance = {
			-- Writing, for handing a shader a float array: a Variant made of
			-- one of these is VAR_BUFFER, which Urho sets as a float array of
			-- whatever length the uniform declares
			WriteFloat = util.self_function(
					"WriteFloat", {"boolean"}, {"VectorBuffer", "number"}),
			-- One 16-bit PCM sample; a block of these is what a
			-- BufferedSoundStream is fed ([LAUNCH_WORLD]'s synth)
			WriteShort = util.self_function(
					"WriteShort", {"boolean"}, {"VectorBuffer", "number"}),
			Clear = util.self_function(
					"Clear", {}, {"VectorBuffer"}),
			GetSize = util.self_function(
					"GetSize", {"number"}, {"VectorBuffer"}),
			ReadString = util.self_function(
					"ReadString", {"string"}, {"VectorBuffer"}),
			ReadInt = util.self_function(
					"ReadInt", {"number"}, {"VectorBuffer"}),
			ReadFloat = util.self_function(
					"ReadFloat", {"number"}, {"VectorBuffer"}),
			ReadVector3 = util.wrap_function({"VectorBuffer"},
				function(self)
					return util.wrap_instance("Vector3", self:ReadVector3())
				end
			),
		},
		properties = {
			size = util.simple_property("number"),
			eof = util.simple_property("boolean"),
		},
	})

	util.wc("Variant", {
		unsafe_constructor = util.wrap_function({{"Color", "VectorBuffer"}},
		function(value)
			return util.wrap_instance("Variant", Variant(value))
		end),
		instance = {
			IsEmpty = util.self_function(
					"IsEmpty", {"boolean"}, {"Variant"}),
			GetString = util.self_function(
					"GetString", {"string"}, {"Variant"}),
			GetInt = util.self_function(
					"GetInt", {"number"}, {"Variant"}),
			GetBool = util.self_function(
					"GetBool", {"boolean"}, {"Variant"}),
			GetBuffer = util.wrap_function({"Variant"},
				function(self)
					return util.wrap_instance("VectorBuffer", self:GetBuffer())
				end
			),
		}
	})

	util.wc("VariantMap", {
		unsafe_constructor = util.wrap_function({},
		function()
			return util.wrap_instance("VariantMap", VariantMap())
		end),
		instance = {
			-- 1.7 Lua VariantMap has no Get/Set methods; values are Variants
			-- via eventData["Key"]. Keep the 2014 method names for games.
			SetFloat = util.wrap_function({"VariantMap", "string", "number"},
				function(self, key, value)
					self[key] = value
				end),
			GetFloat = util.wrap_function({"number"}, {"VariantMap", "string"},
				function(self, key)
					local v = self[key]
					if v == nil or (v.IsEmpty and v:IsEmpty()) then
						error("VariantMap:GetFloat("..tostring(key)..
								"): missing or empty")
					end
					return v:GetFloat()
				end),
			SetInt = util.wrap_function({"VariantMap", "string", "number"},
				function(self, key, value)
					self[key] = value
				end),
			GetInt = util.wrap_function({"number"}, {"VariantMap", "string"},
				function(self, key)
					local v = self[key]
					if v == nil or (v.IsEmpty and v:IsEmpty()) then
						error("VariantMap:GetInt("..tostring(key)..
								"): missing or empty")
					end
					return v:GetInt()
				end),
			SetBool = util.wrap_function({"VariantMap", "string", "boolean"},
				function(self, key, value)
					self[key] = value
				end),
			GetBool = util.wrap_function({"boolean"}, {"VariantMap", "string"},
				function(self, key)
					local v = self[key]
					if v == nil or (v.IsEmpty and v:IsEmpty()) then
						error("VariantMap:GetBool("..tostring(key)..
								"): missing or empty")
					end
					return v:GetBool()
				end),
			SetString = util.wrap_function({"VariantMap", "string", "string"},
				function(self, key, value)
					self[key] = value
				end),
			GetString = util.wrap_function({"string"}, {"VariantMap", "string"},
				function(self, key)
					local v = self[key]
					if v == nil or (v.IsEmpty and v:IsEmpty()) then
						error("VariantMap:GetString("..tostring(key)..
								"): missing or empty")
					end
					return v:GetString()
				end),
			SetBuffer = util.wrap_function({"VariantMap", "string", "VectorBuffer"},
				function(self, key, value)
					self[key] = value
				end),
			GetBuffer = util.wrap_function({dst.VectorBuffer},
					{"VariantMap", "string"},
				function(self, key)
					local v = self[key]
					if v == nil or (v.IsEmpty and v:IsEmpty()) then
						error("VariantMap:GetBuffer("..tostring(key)..
								"): missing or empty")
					end
					return v:GetBuffer()
				end),
			-- UIElement too: the UI events' Element fields (ItemSelected,
			-- MenuSelected, ...) go through here on their way to a handler,
			-- and without it none of them ever arrived
			SetPtr = util.wrap_function({"VariantMap", "string",
					{"Node", "Component", "UIElement"}},
				function(self, key, value)
					self[key] = value
				end),
			GetPtr = util.wrap_function({"VariantMap", "string", "string"},
				function(self, type, key)
					local v = self[key]
					if v == nil or (v.IsEmpty and v:IsEmpty()) then
						error("VariantMap:GetPtr("..tostring(key)..
								"): missing or empty")
					end
					-- **As what it is, or a base of it** ([SECURITY_RUN_1]):
					-- Variant:GetPtr() casts to whatever it is told, so a
					-- Node read back as a UIElement had UIElement's methods
					-- reading past it. Every Ptr here is an Object: what
					-- SetPtr takes and what the whitelisted events carry
					local obj = v:GetPtr("Object")
					if obj == nil then
						error("VariantMap:GetPtr("..tostring(key)..", "..
								tostring(type).."): ptr is nil")
					end
					-- simplified: a class the sandbox does not wrap is
					-- refused even when it derives from the asked one
					local actual = util.wrap_instance(obj:GetTypeName(), obj)
					if actual == nil then return nil end
					magic_sandbox.safe_to_unsafe(actual, type)
					return util.wrap_instance(type, v:GetPtr(type))
				end),
		}
	})

	util.wc("Quaternion", {
		unsafe_constructor = util.wrap_function({
				"number", {"number", "Vector3"}, {"number", "__nil"},
						{"number", "__nil"}},
		function(w, x, y, z)
			if type(w) == "number" and type(x) == "number" and
					type(y) == "number" and type(z) == "number" then
				return util.wrap_instance("Quaternion", Quaternion(w, x, y, z))
			elseif type(w) == "number" and type(x) == "number" and
					type(y) == "number" and z == nil then
				-- y, x, z (euler angles)
				return util.wrap_instance("Quaternion", Quaternion(w, x, y))
			else
				-- angle: float, axis: Vector3
				return util.wrap_instance("Quaternion", Quaternion(w, x))
			end
		end),
		instance = {
			YawAngle = util.self_function(
					"YawAngle", {"number"}, {"Quaternion"}),
			PitchAngle = util.self_function(
					"PitchAngle", {"number"}, {"Quaternion"}),
			RollAngle = util.self_function(
					"RollAngle", {"number"}, {"Quaternion"}),
			EulerAngles = util.wrap_function({"Quaternion"},
				function(self)
					return util.wrap_instance("Vector3", self:EulerAngles())
				end
			),
			-- **Turning smoothly rather than snapping**: pure maths on
			-- two rotations, and the only way a sandboxed scene can
			-- interpolate one ([LAUNCH_WORLD]'s orbs turn to face
			-- whoever walks past)
			Slerp = util.wrap_function({"Quaternion", "Quaternion", "number"},
				function(self, other, t)
					return util.wrap_instance("Quaternion",
							self:Slerp(other, t))
				end
			),
			Nlerp = util.wrap_function({"Quaternion", "Quaternion", "number",
					{"boolean", "__nil"}},
				function(self, other, t, shortest)
					return util.wrap_instance("Quaternion",
							self:Nlerp(other, t, shortest and true or false))
				end
			),
		},
		instance_meta = {
			-- A Vector3 rotated by it too ([SANDBOX_API_AUDIT]: a drone's
			-- axes were child nodes' world positions for want of it)
			__mul = util.wrap_function({"Quaternion",
					{"number", "Quaternion", "Vector3"}},
			function(self, n)
				local is_vector = type(n) ~= "number" and n.w == nil
				return util.wrap_instance(is_vector and "Vector3" or
						"Quaternion", self * n)
			end),
			__add = util.wrap_function({"Quaternion", "Quaternion"}, function(self, other)
				return util.wrap_instance("Quaternion", self + other)
			end),
			__sub = util.wrap_function({"Quaternion", "Quaternion"}, function(self, other)
				return util.wrap_instance("Quaternion", self - other)
			end),
			__eq = util.wrap_function({"Quaternion", "Quaternion"}, function(self, other)
				return (self == other)
			end),
		},
		properties = {
			w = util.simple_property("number"),
			x = util.simple_property("number"),
			y = util.simple_property("number"),
			z = util.simple_property("number"),
		},
	})

	util.wc("Vector3", {
		unsafe_constructor = util.wrap_function({"number", "number", "number"},
		function(x, y, z)
			return util.wrap_instance("Vector3", Vector3(x, y, z))
		end),
		instance = {
			Length = util.self_function(
					"Length", {"number"}, {"Vector3"}),
			CrossProduct = util.wrap_function({"Vector3", "Vector3"},
				function(self, other)
					return util.wrap_instance("Vector3", self:CrossProduct(other))
				end
			),
			Normalized = util.wrap_function({"Vector3"},
				function(self)
					return util.wrap_instance("Vector3", self:Normalized())
				end
			),
		},
		instance_meta = {
			__mul = util.wrap_function({"Vector3", "number"}, function(self, n)
				return util.wrap_instance("Vector3", self * n)
			end),
			__div = util.wrap_function({"Vector3", "number"}, function(self, n)
				return util.wrap_instance("Vector3", self / n)
			end),
			__add = util.wrap_function({"Vector3", "Vector3"}, function(self, other)
				return util.wrap_instance("Vector3", self + other)
			end),
			__sub = util.wrap_function({"Vector3", "Vector3"}, function(self, other)
				return util.wrap_instance("Vector3", self - other)
			end),
			__eq = util.wrap_function({"Vector3", "Vector3"}, function(self, other)
				return (self == other)
			end),
		},
		properties = {
			x = util.simple_property("number"),
			y = util.simple_property("number"),
			z = util.simple_property("number"),
		},
	})

	-- Whole-number coordinates, which is what a voxel world counts in.
	-- Added 2026-09-15 with the Math batch of [URHO_SWEEP]; arithmetic draws
	-- nothing and reaches nothing, which is the policy's clearest yes.
	-- A node's transform as one value ([URHO_SWEEP], Math): built from a
	-- translation, a rotation and a scale, taken apart the same way,
	-- applied to a Vector3, composed and inverted. After Vector3 and
	-- Quaternion, whose wrappers it names.
	util.wc("Matrix3x4", {
		unsafe_constructor = util.wrap_function({{"Vector3", "__nil"},
				{"Quaternion", "__nil"}, {"number", "Vector3", "__nil"}},
		function(translation, rotation, scale)
			if translation == nil then
				return util.wrap_instance("Matrix3x4", Matrix3x4())
			end
			return util.wrap_instance("Matrix3x4",
					Matrix3x4(translation, rotation, scale or 1.0))
		end),
		instance = {
			Translation = util.wrap_function({"Matrix3x4"}, function(self)
				return util.wrap_instance("Vector3", self:Translation())
			end),
			Rotation = util.wrap_function({"Matrix3x4"}, function(self)
				return util.wrap_instance("Quaternion", self:Rotation())
			end),
			Scale = util.wrap_function({"Matrix3x4"}, function(self)
				return util.wrap_instance("Vector3", self:Scale())
			end),
			Inverse = util.wrap_function({"Matrix3x4"}, function(self)
				return util.wrap_instance("Matrix3x4", self:Inverse())
			end),
			SetTranslation = util.self_function("SetTranslation", {},
					{"Matrix3x4", "Vector3"}),
			SetScale = util.self_function("SetScale", {},
					{"Matrix3x4", {"number", "Vector3"}}),
			ToString = util.self_function("ToString", {"string"},
					{"Matrix3x4"}),
		},
		instance_meta = {
			__mul = util.wrap_function({"Matrix3x4",
					{"Vector3", "Matrix3x4", "number"}},
			function(self, other)
				-- The unwrapped values arrive here: a Vector3 is the one
				-- with an x, a number a number, the rest a Matrix3x4
				local r = self * other
				if type(other) ~= "number" and other.x ~= nil then
					return util.wrap_instance("Vector3", r)
				end
				return util.wrap_instance("Matrix3x4", r)
			end),
			__eq = util.wrap_function({"Matrix3x4", "Matrix3x4"},
			function(self, other)
				return (self == other)
			end),
		},
		properties = {
			m00 = util.simple_property("number"),
			m01 = util.simple_property("number"),
			m02 = util.simple_property("number"),
			m03 = util.simple_property("number"),
			m10 = util.simple_property("number"),
			m11 = util.simple_property("number"),
			m12 = util.simple_property("number"),
			m13 = util.simple_property("number"),
			m20 = util.simple_property("number"),
			m21 = util.simple_property("number"),
			m22 = util.simple_property("number"),
			m23 = util.simple_property("number"),
		},
	})

	util.wc("IntVector3", {
		unsafe_constructor = util.wrap_function({"number", "number", "number"},
		function(x, y, z)
			return util.wrap_instance("IntVector3", IntVector3(x, y, z))
		end),
		instance = {
			Length = util.self_function("Length", {"number"},
					{"IntVector3"}),
		},
		instance_meta = {
			__add = util.wrap_function({"IntVector3", "IntVector3"},
			function(self, other)
				return util.wrap_instance("IntVector3", self + other)
			end),
			__sub = util.wrap_function({"IntVector3", "IntVector3"},
			function(self, other)
				return util.wrap_instance("IntVector3", self - other)
			end),
			__mul = util.wrap_function({"IntVector3", "number"},
			function(self, n)
				return util.wrap_instance("IntVector3", self * n)
			end),
			__eq = util.wrap_function({"IntVector3", "IntVector3"},
			function(self, other)
				return (self == other)
			end),
		},
		properties = {
			x = util.simple_property("number"),
			y = util.simple_property("number"),
			z = util.simple_property("number"),
		},
	})

	-- The fourth component is what a shader parameter and a homogeneous
	-- coordinate want; Material:SetShaderParameter() already takes the
	-- others.
	-- The rest of the matrix family ([URHO_SWEEP]'s Math batch,
	-- 2026-09-25), after Matrix3x4 because Matrix4 names Matrix3 and both
	-- name the vectors: **a rotation without a translation (Matrix3), and
	-- the projective one a shader parameter takes (Matrix4)**, with the
	-- 2x2 left out because Urho3D does not bind it at all (see the
	-- refusal above). Arithmetic draws nothing and
	-- reaches nothing, which is the policy's clearest yes; the elements
	-- are plain numbers, so they are properties rather than accessors.
	-- refused: Matrix2 -- Urho3D's own Lua API does not bind it: Matrix2.pkg
	-- exists but MathLuaAPI.pkg does not include it, so the global is nil
	-- and a wrapper for it raises on the first call (2026-09-25)
	util.wc("Matrix3", {
		unsafe_constructor = util.wrap_function({{"number", "__nil"},
				{"number", "__nil"}, {"number", "__nil"}, {"number", "__nil"}, {"number", "__nil"}, {"number", "__nil"}, {"number", "__nil"},
				{"number", "__nil"}, {"number", "__nil"}},
		function(a, b, c, d, e, f, g, h, i)
			if a == nil then
				return util.wrap_instance("Matrix3", Matrix3())
			end
			return util.wrap_instance("Matrix3",
					Matrix3(a, b, c, d, e, f, g, h, i))
		end),
		instance = {
			Scale = util.wrap_function({"Matrix3"}, function(self)
				return util.wrap_instance("Vector3", self:Scale())
			end),
			SetScale = util.self_function("SetScale", {},
					{"Matrix3", {"number", "Vector3"}}),
			Scaled = util.wrap_function({"Matrix3", "Vector3"},
			function(self, scale)
				return util.wrap_instance("Matrix3", self:Scaled(scale))
			end),
			Transpose = util.wrap_function({"Matrix3"}, function(self)
				return util.wrap_instance("Matrix3", self:Transpose())
			end),
			Inverse = util.wrap_function({"Matrix3"}, function(self)
				return util.wrap_instance("Matrix3", self:Inverse())
			end),
			Equals = util.self_function("Equals", {"boolean"},
					{"Matrix3", "Matrix3"}),
			ToString = util.self_function("ToString", {"string"},
					{"Matrix3"}),
		},
		instance_meta = {
			__mul = util.wrap_function({"Matrix3",
					{"Vector3", "Matrix3", "number"}},
			function(self, other)
				local r = self * other
				if type(other) ~= "number" and other.x ~= nil then
					return util.wrap_instance("Vector3", r)
				end
				return util.wrap_instance("Matrix3", r)
			end),
			__add = util.wrap_function({"Matrix3", "Matrix3"},
			function(self, other)
				return util.wrap_instance("Matrix3", self + other)
			end),
			__sub = util.wrap_function({"Matrix3", "Matrix3"},
			function(self, other)
				return util.wrap_instance("Matrix3", self - other)
			end),
			__eq = util.wrap_function({"Matrix3", "Matrix3"},
			function(self, other)
				return (self == other)
			end),
		},
		properties = {
			m00 = util.simple_property("number"),
			m01 = util.simple_property("number"),
			m02 = util.simple_property("number"),
			m10 = util.simple_property("number"),
			m11 = util.simple_property("number"),
			m12 = util.simple_property("number"),
			m20 = util.simple_property("number"),
			m21 = util.simple_property("number"),
			m22 = util.simple_property("number"),
		},
	})

	util.wc("Matrix4", {
		unsafe_constructor = util.wrap_function({{"number", "Matrix3",
				"__nil"}, {"number", "__nil"}, {"number", "__nil"}, {"number", "__nil"}, {"number", "__nil"}, {"number", "__nil"},
				{"number", "__nil"}, {"number", "__nil"}, {"number", "__nil"}, {"number", "__nil"}, {"number", "__nil"}, {"number", "__nil"},
				{"number", "__nil"}, {"number", "__nil"}, {"number", "__nil"}, {"number", "__nil"}},
		function(a, ...)
			if a == nil then
				return util.wrap_instance("Matrix4", Matrix4())
			end
			if type(a) ~= "number" then
				-- A rotation grown to four rows
				return util.wrap_instance("Matrix4", Matrix4(a))
			end
			return util.wrap_instance("Matrix4", Matrix4(a, ...))
		end),
		instance = {
			Translation = util.wrap_function({"Matrix4"}, function(self)
				return util.wrap_instance("Vector3", self:Translation())
			end),
			Rotation = util.wrap_function({"Matrix4"}, function(self)
				return util.wrap_instance("Quaternion", self:Rotation())
			end),
			RotationMatrix = util.wrap_function({"Matrix4"}, function(self)
				return util.wrap_instance("Matrix3", self:RotationMatrix())
			end),
			ToMatrix3 = util.wrap_function({"Matrix4"}, function(self)
				return util.wrap_instance("Matrix3", self:ToMatrix3())
			end),
			Scale = util.wrap_function({"Matrix4"}, function(self)
				return util.wrap_instance("Vector3", self:Scale())
			end),
			Transpose = util.wrap_function({"Matrix4"}, function(self)
				return util.wrap_instance("Matrix4", self:Transpose())
			end),
			Inverse = util.wrap_function({"Matrix4"}, function(self)
				return util.wrap_instance("Matrix4", self:Inverse())
			end),
			SetTranslation = util.self_function("SetTranslation", {},
					{"Matrix4", "Vector3"}),
			SetRotation = util.self_function("SetRotation", {},
					{"Matrix4", "Matrix3"}),
			SetScale = util.self_function("SetScale", {},
					{"Matrix4", {"number", "Vector3"}}),
			Equals = util.self_function("Equals", {"boolean"},
					{"Matrix4", "Matrix4"}),
			ToString = util.self_function("ToString", {"string"},
					{"Matrix4"}),
		},
		instance_meta = {
			__mul = util.wrap_function({"Matrix4",
					{"Vector3", "Vector4", "Matrix4", "Matrix3x4",
					"number"}},
			function(self, other)
				local r = self * other
				if type(other) == "number" then
					return util.wrap_instance("Matrix4", r)
				end
				-- The unwrapped values arrive here: a vector is the one
				-- with an x, and a w tells the four from the three
				if other.x ~= nil then
					return util.wrap_instance(
							other.w ~= nil and "Vector4" or "Vector3", r)
				end
				return util.wrap_instance("Matrix4", r)
			end),
			__add = util.wrap_function({"Matrix4", "Matrix4"},
			function(self, other)
				return util.wrap_instance("Matrix4", self + other)
			end),
			__sub = util.wrap_function({"Matrix4", "Matrix4"},
			function(self, other)
				return util.wrap_instance("Matrix4", self - other)
			end),
			__eq = util.wrap_function({"Matrix4", "Matrix4"},
			function(self, other)
				return (self == other)
			end),
		},
		properties = {
			m00 = util.simple_property("number"),
			m01 = util.simple_property("number"),
			m02 = util.simple_property("number"),
			m03 = util.simple_property("number"),
			m10 = util.simple_property("number"),
			m11 = util.simple_property("number"),
			m12 = util.simple_property("number"),
			m13 = util.simple_property("number"),
			m20 = util.simple_property("number"),
			m21 = util.simple_property("number"),
			m22 = util.simple_property("number"),
			m23 = util.simple_property("number"),
			m30 = util.simple_property("number"),
			m31 = util.simple_property("number"),
			m32 = util.simple_property("number"),
			m33 = util.simple_property("number"),
		},
	})

	util.wc("Vector4", {
		unsafe_constructor = util.wrap_function(
				{"number", "number", "number", "number"},
		function(x, y, z, w)
			return util.wrap_instance("Vector4", Vector4(x, y, z, w))
		end),
		instance = {
			DotProduct = util.self_function("DotProduct", {"number"},
					{"Vector4", "Vector4"}),
			Length = util.self_function("Length", {"number"}, {"Vector4"}),
		},
		instance_meta = {
			__add = util.wrap_function({"Vector4", "Vector4"},
			function(self, other)
				return util.wrap_instance("Vector4", self + other)
			end),
			__sub = util.wrap_function({"Vector4", "Vector4"},
			function(self, other)
				return util.wrap_instance("Vector4", self - other)
			end),
			__mul = util.wrap_function({"Vector4", "number"},
			function(self, n)
				return util.wrap_instance("Vector4", self * n)
			end),
			__eq = util.wrap_function({"Vector4", "Vector4"},
			function(self, other)
				return (self == other)
			end),
		},
		properties = {
			x = util.simple_property("number"),
			y = util.simple_property("number"),
			z = util.simple_property("number"),
			w = util.simple_property("number"),
		},
	})

	-- A point and a direction, and what it runs into. This is what a game
	-- does its own picking with -- Camera:WorldToScreenPoint() is the other
	-- direction of the same question -- and the HitDistance family answers
	-- in distance along the ray, with a huge number for a miss rather than
	-- a nil.
	--
	-- simplified: the box and the sphere, which are the shapes this sandbox
	-- has. Urho3D also tests a frustum, a plane and a triangle; the first
	-- two are not whitelisted classes and the third wants three vectors and
	-- has no consumer.
	util.wc("Ray", {
		unsafe_constructor = util.wrap_function({"Vector3", "Vector3"},
		function(origin, direction)
			return util.wrap_instance("Ray", Ray(origin, direction))
		end),
		instance = {
			Define = util.self_function("Define", {},
					{"Ray", "Vector3", "Vector3"}),
			-- How far along the ray the point is, and how far off it
			Project = util.wrap_function({"Ray", "Vector3"},
				function(self, point)
					return util.wrap_instance("Vector3", self:Project(point))
				end
			),
			Distance = util.self_function("Distance", {"number"},
					{"Ray", "Vector3"}),
			HitDistanceBox = util.self_function("HitDistance", {"number"},
					{"Ray", "BoundingBox"}),
			HitDistanceSphere = util.self_function("HitDistance", {"number"},
					{"Ray", "Sphere"}),
		},
		properties = {
			origin = util.simple_property(dst.Vector3),
			direction = util.simple_property(dst.Vector3),
		},
	})

	-- A centre and a radius: what a thing occupies, for anything deciding
	-- whether to bother with it.
	util.wc("Sphere", {
		unsafe_constructor = util.wrap_function({"Vector3", "number"},
		function(center, radius)
			return util.wrap_instance("Sphere", Sphere(center, radius))
		end),
		instance = {
			Define = util.self_function("Define", {},
					{"Sphere", "Vector3", "number"}),
			Merge = util.self_function("Merge", {}, {"Sphere", "Vector3"}),
			Clear = util.self_function("Clear", {}, {"Sphere"}),
			Distance = util.self_function("Distance", {"number"},
					{"Sphere", "Vector3"}),
		},
		properties = {
			center = util.simple_property(dst.Vector3),
			radius = util.simple_property("number"),
		},
	})

	-- A rectangle of two corners. What wants it is a particle's texture
	-- frames, which are the parts of an image an animation runs through.
	util.wc("Rect", {
		unsafe_constructor = util.wrap_function(
				{"number", "number", "number", "number"},
		function(left, top, right, bottom)
			return util.wrap_instance("Rect", Rect(left, top, right, bottom))
		end),
		properties = {
			min = util.simple_property(dst.Vector2),
			max = util.simple_property(dst.Vector2),
		},
	})

	util.wc("Vector2", {
		unsafe_constructor = util.wrap_function({"number", "number"},
		function(x, y)
			return util.wrap_instance("Vector2", Vector2(x, y))
		end),
		instance = {
			Length = util.self_function(
					"Length", {"number"}, {"Vector2"}),
			Normalized = util.wrap_function({"Vector2"},
				function(self)
					return util.wrap_instance("Vector2", self:Normalized())
				end
			),
		},
		instance_meta = {
			__mul = util.wrap_function({"Vector2", "number"}, function(self, n)
				return util.wrap_instance("Vector2", self * n)
			end),
			__div = util.wrap_function({"Vector2", "number"}, function(self, n)
				return util.wrap_instance("Vector2", self / n)
			end),
			__add = util.wrap_function({"Vector2", "Vector2"}, function(self, other)
				return util.wrap_instance("Vector2", self + other)
			end),
			__sub = util.wrap_function({"Vector2", "Vector2"}, function(self, other)
				return util.wrap_instance("Vector2", self - other)
			end),
			__eq = util.wrap_function({"Vector2", "Vector2"}, function(self, other)
				return (self == other)
			end),
		},
		properties = {
			x = util.simple_property("number"),
			y = util.simple_property("number"),
		},
	})

	util.wc("IntVector2", {
		unsafe_constructor = util.wrap_function({"number", "number"},
		function(x, y)
			return util.wrap_instance("IntVector2", IntVector2(x, y))
		end),
		instance = {
		},
		instance_meta = {
			__mul = util.wrap_function({"IntVector2", "number"}, function(self, n)
				return util.wrap_instance("IntVector2", self * n)
			end),
			__add = util.wrap_function({"IntVector2", "IntVector2"}, function(self, other)
				return util.wrap_instance("IntVector2", self + other)
			end),
			__sub = util.wrap_function({"IntVector2", "IntVector2"}, function(self, other)
				return util.wrap_instance("IntVector2", self - other)
			end),
			__eq = util.wrap_function({"IntVector2", "IntVector2"}, function(self, other)
				return (self == other)
			end),
		},
		properties = {
			x = util.simple_property("number"),
			y = util.simple_property("number"),
		},
	})

	util.wc("IntRect", {
		unsafe_constructor = util.wrap_function({"number", "number", "number", "number"},
		function(left, top, right, bottom)
			return util.wrap_instance("IntRect", IntRect(left, top, right, bottom))
		end),
		properties = {
			left = util.simple_property("number"),
			top = util.simple_property("number"),
			right = util.simple_property("number"),
			bottom = util.simple_property("number"),
		},
	})

	util.wc("Color", {
		unsafe_constructor = util.wrap_function({"number", "number", "number",
				{"number", "__nil"}},
		function(r, g, b, a)
			a = a or 1.0
			return util.wrap_instance("Color", Color(r, g, b, a))
		end),
		instance_meta = {
			__mul = util.wrap_function({"Color", "number"}, function(self, n)
				return util.wrap_instance("Color", self * n)
			end),
		},
		properties = {
			r = util.simple_property("number"),
			g = util.simple_property("number"),
			b = util.simple_property("number"),
			a = util.simple_property("number"),
		},
	})

	util.wc("BoundingBox", {
		unsafe_constructor = util.wrap_function({
				{"number", "Vector3"}, {"number", "Vector3"}},
		function(min, max)
			return util.wrap_instance("BoundingBox", BoundingBox(min, max))
		end),
		instance_meta = {
		},
		properties = {
			-- Read to settle where a mesher actually put its geometry,
			-- which no amount of reading the offsets settled
			min = util.simple_property(dst.Vector3),
			max = util.simple_property(dst.Vector3),
		},
	})

	util.wc("BiasParameters", {
		-- The third one is Urho3D's normal offset, which moves the lookup
		-- along the surface normal instead of along the light: it is what
		-- keeps a large flat face out of its own shadow without pushing the
		-- shadow off the foot of what casts it
		unsafe_constructor = util.wrap_function(
		{"number", "number", {"number", "__nil"}},
		function(constant_bias, slope_scaled_bias, normal_offset)
			return util.wrap_instance("BiasParameters",
					BiasParameters(constant_bias, slope_scaled_bias,
							normal_offset or 0.0))
		end),
	})

	util.wc("CascadeParameters", {
		unsafe_constructor = util.wrap_function({"number", "number", "number", "number", "number", {"number", "__nil"}},
		function(split1, split2, split3, split4, fadeStart, biasAutoAdjust)
			biasAutoAdjust = biasAutoAdjust or 1.0
			return util.wrap_instance("CascadeParameters",
					CascadeParameters(split1, split2, split3, split4, fadeStart, biasAutoAdjust))
		end),
	})

	util.wc("Resource", {
		properties = {
			-- The resource's name, which is its path under a resource dir:
			-- read-only here (writing one raises), for what reports which
			-- picture an element shows ([SCAN_EVENT])
			name = {get = util.simple_property("string").get},
		},
	})

	util.wc("Component", {
		properties = {
			-- Whether it takes part: a model switched off for a shape in
			-- the same node ([WIELD_MESH])
			enabled = util.simple_property("boolean"),
		},
	})

	util.wc("Octree", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			GetDrawables = util.wrap_function({"table"}, {"Octree", "BoundingBox"},
				function(self, query)
					local unsafe_result = self:GetDrawables(query)
					-- The result is a list of OctreeQueryResults; we will
					-- convert it to a list of tables that contain the fields of
					-- OctreeQueryResult.
					local result = {}
					if unsafe_result == nil then
						log:error("GetDrawables returned nil")
						return result
					end
					for _, v in ipairs(unsafe_result) do
						if v.drawable ~= nil and v.node ~= nil then
							table.insert(result, {
								drawable = util.wrap_instance("Drawable",
										v.drawable),
								node = util.wrap_instance("Node", v.node),
							})
						end
					end
					return result
				end
			),
		},
	})

	util.wc("Drawable", {
		inherited_from_by_wrapper = dst.Component,
		properties = {
			-- Urho3D has this on Drawable, so a billboard set has it as
			-- much as a static model does
			castShadows = util.simple_property("boolean"),
			-- Where the thing ended up, in the scene: the one way to ask
			-- a mesher what it built without reading its offsets
			worldBoundingBox = util.simple_property(dst.BoundingBox),
		},
	})

	util.wc("CustomGeometry", {
		inherited_from_by_wrapper = dst.Drawable,
		instance = {
			SetNumGeometries = util.self_function(
					"SetNumGeometries", {}, {"CustomGeometry", "number"}),
			BeginGeometry = util.self_function(
					"BeginGeometry", {}, {"CustomGeometry", "number", "number"}),
			DefineVertex = util.self_function(
					"DefineVertex", {}, {"CustomGeometry", "Vector3"}),
			DefineNormal = util.self_function(
					"DefineNormal", {}, {"CustomGeometry", "Vector3"}),
			DefineTexCoord = util.self_function(
					"DefineTexCoord", {}, {"CustomGeometry", "Vector2"}),
			DefineColor = util.self_function(
					"DefineColor", {}, {"CustomGeometry", "Color"}),
			Commit = util.self_function(
					"Commit", {}, {"CustomGeometry"}),
			-- Urho returns null past the last geometry, which is how a caller
			-- finds out how many there are
			GetMaterial = util.wrap_function({"CustomGeometry", "number"},
			function(self, index)
				local material = self:GetMaterial(index)
				if not material then
					return nil
				end
				return util.wrap_instance("Material", material)
			end),
			SetMaterial = util.self_function(
					"SetMaterial", {}, {"CustomGeometry", "number", "Material"}),
		},
		properties = {
			dynamic = util.simple_property("boolean"),
		},
	})

	util.wc("Camera", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			-- Where a point in the world lands on the screen, as a
			-- fraction of it. What wants it is anything a game draws over
			-- a place rather than over a corner: Luanti's waypoints are
			-- that, and a marker over another player would be.
			WorldToScreenPoint = util.self_function("WorldToScreenPoint",
					{dst.Vector2}, {"Camera", "Vector3"}),
		},
		properties = {
			nearClip = util.simple_property("number"),
			farClip = util.simple_property("number"),
			-- Urho3D's fov is the vertical one (Camera::UpdateProjection
			-- puts 1/tan(fov/2) on the Y axis and derives X from the
			-- aspect), which is what Luanti's own fov setting is too
			fov = util.simple_property("number"),
			orthographic = util.simple_property("boolean"),
			orthoSize = util.simple_property("number"),
			-- What the viewport's shape is, which is the other half of
			-- reading a frame's geometry: a script that works out how
			-- much of a node a screen pixel is needs both ([URHO_SWEEP],
			-- wanted 2026-09-22 while reading a third-person shot)
			aspectRatio = util.simple_property("number"),
			zoom = util.simple_property("number"),
		},
	})

	util.wc("RigidBody", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			ApplyForce = util.self_function(
					"ApplyForce", {}, {"RigidBody", "Vector3"}),
			ApplyImpulse = util.self_function(
					"ApplyImpulse", {}, {"RigidBody", "Vector3"}),
		},
		properties = {
			mass = util.simple_property("number"),
			gravityOverride = util.simple_property(dst.Vector3),
			friction = util.simple_property("number"),
			angularFactor = util.simple_property(dst.Vector3),
			kinematic = util.simple_property("boolean"),
			linearVelocity = util.simple_property(dst.Vector3),
			angularVelocity = util.simple_property(dst.Vector3),
			collisionEventMode = util.simple_property("number"),
			restitution = util.simple_property("number"),
			linearDamping = util.simple_property("number"),
			angularDamping = util.simple_property("number"),
			useGravity = util.simple_property("boolean"),
			-- Which layers this body is in and which it collides with.
			-- What wants them from a game is a free camera: a body that
			-- collides with nothing goes through the terrain, which is the
			-- escape hatch from every way of ending up inside it.
			collisionLayer = util.simple_property("number"),
			collisionMask = util.simple_property("number"),
		},
	})

	-- What joins two bodies ([URHO_SWEEP]'s Physics batch, 2026-09-25),
	-- after RigidBody because it names one: a point, a hinge, a slider or
	-- a cone twist, at a place on each body, with limits. A component on
	-- a node like any other -- it draws nothing, reads nothing of the
	-- machine and moves only what the physics already moves -- and what
	-- wants it first is [VOXEL_PHYSICS_SAMPLE], where a body that comes
	-- off a hill is otherwise loose in the world.
	--
	-- simplified: no Bullet handle and no constraint-space accessors; the
	-- positions and axes are the ones a game sets from its own nodes.
	util.wc("Constraint", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			SetWorldPosition = util.self_function("SetWorldPosition", {},
					{"Constraint", "Vector3"}),
			GetWorldPosition = util.wrap_function({"Constraint"},
			function(self)
				return util.wrap_instance("Vector3", self:GetWorldPosition())
			end),
		},
		properties = {
			constraintType = util.simple_property("number"),
			otherBody = util.simple_property(dst.RigidBody),
			position = util.simple_property(dst.Vector3),
			rotation = util.simple_property(dst.Quaternion),
			axis = util.simple_property(dst.Vector3),
			otherPosition = util.simple_property(dst.Vector3),
			otherRotation = util.simple_property(dst.Quaternion),
			otherAxis = util.simple_property(dst.Vector3),
			highLimit = util.simple_property(dst.Vector2),
			lowLimit = util.simple_property(dst.Vector2),
			erp = util.simple_property("number"),
			cfm = util.simple_property("number"),
			disableCollision = util.simple_property("boolean"),
		},
	})

	util.wc("CollisionShape", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			SetBox = util.self_function(
					"SetBox", {}, {"CollisionShape", "Vector3"}),
			SetCapsule = util.self_function(
					"SetCapsule", {}, {"CollisionShape", "number", "number"}),
			SetSphere = util.self_function(
					"SetSphere", {}, {"CollisionShape", "number"}),
			SetStaticPlane = util.self_function(
					"SetStaticPlane", {}, {"CollisionShape"}),
			SetCylinder = util.self_function(
					"SetCylinder", {}, {"CollisionShape", "number", "number"}),
			SetCone = util.self_function(
					"SetCone", {}, {"CollisionShape", "number", "number"}),
		},
	})

	-- **A game builds its own mesh** ([URHO_SWEEP], and what
	-- [OBJECT_ANIM] wants under it): CustomGeometry beside this defines
	-- a vertex at a time, which is a Lua call per vertex and fine for a
	-- few hundred; these three take the whole thing at once, as bytes
	-- in a VectorBuffer. Nothing here reaches a path or the network --
	-- it is memory a game fills and the GPU draws.
	--
	-- The lifetimes hold themselves: a Geometry keeps its buffers, a
	-- Model keeps its geometries and a StaticModel keeps the Model, all
	-- by reference count, so the Lua side can drop any of them.
	util.wc("VertexBuffer", {
		class = {
			new = function()
				return util.wrap_instance("VertexBuffer", VertexBuffer:new())
			end,
		},
		instance = {
			-- The mask is MASK_POSITION and friends, ored together; the
			-- data is that many vertices of those elements, in Urho3D's
			-- own order (position, normal, colour, texcoord...)
			SetSize = util.self_function("SetSize", {"boolean"},
					{"VertexBuffer", "number", "number",
					{"boolean", "__nil"}}),
			SetData = util.self_function("SetData", {"boolean"},
					{"VertexBuffer", "VectorBuffer"}),
			SetShadowed = util.self_function("SetShadowed", {},
					{"VertexBuffer", "boolean"}),
		},
		properties = {
			vertexCount = {get = util.simple_property("number").get},
			vertexSize = {get = util.simple_property("number").get},
			elementMask = {get = util.simple_property("number").get},
		},
	})

	util.wc("IndexBuffer", {
		class = {
			new = function()
				return util.wrap_instance("IndexBuffer", IndexBuffer:new())
			end,
		},
		instance = {
			-- largeIndices is 32-bit indices; 16 bits reach 65536
			-- vertices and are half the memory
			SetSize = util.self_function("SetSize", {"boolean"},
					{"IndexBuffer", "number", "boolean",
					{"boolean", "__nil"}}),
			SetData = util.self_function("SetData", {"boolean"},
					{"IndexBuffer", "VectorBuffer"}),
			SetShadowed = util.self_function("SetShadowed", {},
					{"IndexBuffer", "boolean"}),
		},
		properties = {
			indexCount = {get = util.simple_property("number").get},
			indexSize = {get = util.simple_property("number").get},
		},
	})

	util.wc("Geometry", {
		class = {
			new = function()
				return util.wrap_instance("Geometry", Geometry:new())
			end,
		},
		instance = {
			SetNumVertexBuffers = util.self_function("SetNumVertexBuffers",
					{"boolean"}, {"Geometry", "number"}),
			SetVertexBuffer = util.self_function("SetVertexBuffer",
					{"boolean"}, {"Geometry", "number", "VertexBuffer"}),
			SetIndexBuffer = util.self_function("SetIndexBuffer", {},
					{"Geometry", "IndexBuffer"}),
			-- The type is TRIANGLE_LIST and the rest of Urho3D's own
			SetDrawRange = util.self_function("SetDrawRange", {"boolean"},
					{"Geometry", "number", "number", "number",
					{"boolean", "__nil"}}),
			SetLodDistance = util.self_function("SetLodDistance", {},
					{"Geometry", "number"}),
		},
		properties = {
			indexCount = {get = util.simple_property("number").get},
			vertexCount = {get = util.simple_property("number").get},
		},
	})

	util.wc("Model", {
		inherited_from_by_wrapper = dst.Resource,
		class = {
			-- A model built here rather than loaded from a file: what a
			-- StaticModel's `model` takes, either way
			new = function()
				return util.wrap_instance("Model", Model:new())
			end,
		},
		instance = {
			SetNumGeometries = util.self_function("SetNumGeometries", {},
					{"Model", "number"}),
			SetNumGeometryLodLevels = util.self_function(
					"SetNumGeometryLodLevels", {"boolean"},
					{"Model", "number", "number"}),
			SetGeometry = util.self_function("SetGeometry", {"boolean"},
					{"Model", "number", "number", "Geometry"}),
			-- **Without this nothing draws**: the box is what the culler
			-- tests, and a model with an empty one is never in view
			SetBoundingBox = util.self_function("SetBoundingBox", {},
					{"Model", "BoundingBox"}),
			SetGeometryCenter = util.self_function("SetGeometryCenter",
					{"boolean"}, {"Model", "number", "Vector3"}),
			GetNumGeometries = util.self_function("GetNumGeometries",
					{"number"}, {"Model"}),
		},
	})

	util.wc("Material", {
		inherited_from_by_wrapper = dst.Resource,
		class = {
			new = function()
				return util.wrap_instance("Material", Material:new())
			end,
		},
		instance = {
			--SetTexture = util.wrap_function({"Material", "number", "Texture"},
			--function(self, index, texture)
			--	log:info("Material:SetTexture("..dump(index)..", "..dump(texture)..")")
			--	self:SetTexture(index, texture)
			--end),
			SetShaderParameter = util.wrap_function(
				{"Material", "string",
					{"number", "boolean", "Vector2", "Vector3", "Color",
						"Variant"}},
				function(self, name, value)
					self:SetShaderParameter(name, Variant(value))
				end
			),
			SetTexture = util.self_function(
					"SetTexture", {}, {"Material", "number", "Texture"}),
			SetTechnique = util.self_function(
					"SetTechnique", {}, {"Material", "number", "Technique",
							{"number", "__nil"}, {"number", "__nil"}}),
			-- A copy of its own, for a shader parameter per object
			-- ([OBJECT_LIGHT]); the name stays empty, as a Lua-made one's
			Clone = util.wrap_function({"Material"},
				function(self)
					return util.wrap_instance("Material", self:Clone(""))
				end
			),
		},
		properties = {
			-- Which faces are thrown away, as CULL_NONE, CULL_CCW or
			-- CULL_CW. A technique carries one and a material overrides it,
			-- which is how Urho3D's own skybox material is drawn: a box
			-- seen from the inside is entirely back-facing, so a skybox
			-- with the default culling draws nothing at all.
			cullMode = util.simple_property("number"),
			-- The same for the shadow pass: a face turned away from the
			-- light still casts, which a ceiling seen from above is
			shadowCullMode = util.simple_property("number"),
			-- FILL_WIREFRAME draws a selection box the way every voxel
			-- game draws one, without twelve thin boxes to move about
			fillMode = util.simple_property("number"),
		},
	})

	util.wc("Texture", {
		inherited_from_by_wrapper = dst.Resource,
		properties = {
			-- Read-only in Urho3D, so writing one raises. What wanted them
			-- is a HUD element whose size is a multiple of its own image's.
			width = util.simple_property("number"),
			height = util.simple_property("number"),
			-- FILTER_NEAREST and the rest of Urho3D's TextureFilterMode.
			-- What wants it is pixel art, which is what a Luanti game's
			-- textures are: smoothing them is wrong at every size.
			filterMode = util.simple_property("number"),
		},
		instance = {
			-- **How many mip levels**, 0 being the whole chain, and it
			-- is a method rather than a property: Urho3D's `levels` is
			-- read-only and a write to it goes nowhere at all
			-- ([PBR_HDR], 2026-09-23 -- a probe asked for one level for
			-- an afternoon and had a full chain the whole time). Set it
			-- before SetSize. A render target's chain is not generated
			-- unless something generates it, and sampling a level
			-- nobody wrote is undefined: in eight bits a wrong colour,
			-- in float16 a NaN.
			SetNumLevels = util.self_function("SetNumLevels", {},
					{"Texture", "number"}),
		},
	})

	util.wc("Texture2D", {
		inherited_from_by_wrapper = dst.Texture,
		class = {
			new = function()
				return util.wrap_instance("Texture2D", Texture2D:new())
			end,
		},
		instance = {
			-- A texture filled from an Image the script built itself, which
			-- is how a program with no texture files of its own gets one
			-- ([LAUNCH_WORLD]). Urho3D keeps the Image for a device reset,
			-- so this survives a mode change where a hand-filled
			-- Texture2D::SetData(level, x, y, ...) does not; see
			-- [BOX_PLAYTEST_3] (1).
			SetData = util.self_function("SetData", {"boolean"},
					{"Texture2D", "Image", {"boolean", "__nil"}}),
			SetSize = util.self_function("SetSize", {"boolean"},
					{"Texture2D", "number", "number", "number",
					{"number", "__nil"}}),
			-- A render target's surface (SetSize with TEXTURE_RENDERTARGET),
			-- which viewports draw into: apps/floorplanner's room probes
			GetRenderSurface = util.wrap_function({"Texture2D"},
				function(self)
					return util.wrap_instance("RenderSurface",
							self:GetRenderSurface())
				end),
		},
	})

	-- Declared here rather than next to Drawable: its ramp property needs
	-- Texture, and these are wrapped in the order they are written in
	util.wc("Light", {
		inherited_from_by_wrapper = dst.Drawable,
		properties = {
			lightType = util.simple_property("number"),
			brightness = util.simple_property("number"),
			shadowIntensity = util.simple_property("number"),
			shadowBias = util.simple_property("BiasParameters"),
			shadowCascade = util.simple_property("CascadeParameters"),
			color = util.simple_property(dst.Color),
			range = util.simple_property("number"),
			fadeDistance = util.simple_property("number"),
			fov = util.simple_property("number"),
			specularIntensity = util.simple_property("number"),
			-- How the light falls off over its range, sampled at
			-- distance/range; Textures/Ramp.png is the default one
			rampTexture = util.simple_property(dst.Texture),
		},
	})

	util.wc("Zone", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
		},
		properties = {
			boundingBox = util.simple_property(dst.BoundingBox),
			ambientColor = util.simple_property(dst.Color),
			fogColor = util.simple_property(dst.Color),
			fogStart = util.simple_property("number"),
			fogEnd = util.simple_property("number"),
			priority = util.simple_property("number"),
			heightFog = util.simple_property("boolean"),
			override = util.simple_property("boolean"),
			ambientGradient = util.simple_property("boolean"),
			-- The environment cube map the PBR shaders reflect
			zoneTexture = util.simple_property(dst.Texture),
		},
	})

	util.wc("Font", {
		inherited_from_by_wrapper = dst.Resource,
	})

	-- **A game reads its own XML** ([URHO_SWEEP]): an XMLFile comes out
	-- of the resource cache, which is how a game's own media arrives,
	-- and this is what walks it. The reading half only -- the setters
	-- build a document that has nowhere to go, `XMLFile:Save()` taking
	-- a path on the user's disk, and `FromString` rewrites a file the
	-- cache may be handing to somebody else.
	util.wc("XMLElement", {
		instance = {
			IsNull = util.self_function(
					"IsNull", {"boolean"}, {"XMLElement"}),
			NotNull = util.self_function(
					"NotNull", {"boolean"}, {"XMLElement"}),
			GetName = util.self_function(
					"GetName", {"string"}, {"XMLElement"}),
			GetValue = util.self_function(
					"GetValue", {"string"}, {"XMLElement"}),
			HasChild = util.self_function(
					"HasChild", {"boolean"}, {"XMLElement", "string"}),
			HasAttribute = util.self_function(
					"HasAttribute", {"boolean"}, {"XMLElement", "string"}),
			GetNumAttributes = util.self_function(
					"GetNumAttributes", {"number"}, {"XMLElement"}),
			GetAttribute = util.self_function(
					"GetAttribute", {"string"}, {"XMLElement", "string"}),
			GetBool = util.self_function(
					"GetBool", {"boolean"}, {"XMLElement", "string"}),
			GetInt = util.self_function(
					"GetInt", {"number"}, {"XMLElement", "string"}),
			GetUInt = util.self_function(
					"GetUInt", {"number"}, {"XMLElement", "string"}),
			GetFloat = util.self_function(
					"GetFloat", {"number"}, {"XMLElement", "string"}),
			GetDouble = util.self_function(
					"GetDouble", {"number"}, {"XMLElement", "string"}),
			-- The ones that hand back another wrapped thing: an element,
			-- or one of the maths types an attribute can be written as
			GetChild = util.wrap_function({"XMLElement", {"string", "__nil"}},
				function(self, name)
					return util.wrap_instance("XMLElement",
							self:GetChild(name or ""))
				end
			),
			GetNext = util.wrap_function({"XMLElement", {"string", "__nil"}},
				function(self, name)
					return util.wrap_instance("XMLElement",
							self:GetNext(name or ""))
				end
			),
			GetParent = util.wrap_function({"XMLElement"},
				function(self)
					return util.wrap_instance("XMLElement", self:GetParent())
				end
			),
			GetFile = util.wrap_function({"XMLElement"},
				function(self)
					return util.wrap_instance("XMLFile", self:GetFile())
				end
			),
			GetVector2 = util.wrap_function({"XMLElement", "string"},
				function(self, name)
					return util.wrap_instance("Vector2", self:GetVector2(name))
				end
			),
			GetVector3 = util.wrap_function({"XMLElement", "string"},
				function(self, name)
					return util.wrap_instance("Vector3", self:GetVector3(name))
				end
			),
			GetColor = util.wrap_function({"XMLElement", "string"},
				function(self, name)
					return util.wrap_instance("Color", self:GetColor(name))
				end
			),
			GetIntVector2 = util.wrap_function({"XMLElement", "string"},
				function(self, name)
					return util.wrap_instance("IntVector2",
							self:GetIntVector2(name))
				end
			),
		},
	})

	util.wc("XMLFile", {
		inherited_from_by_wrapper = dst.Resource,
		instance = {
			-- The document's root, by name or whatever is there
			GetRoot = util.wrap_function({"XMLFile", {"string", "__nil"}},
				function(self, name)
					return util.wrap_instance("XMLElement",
							self:GetRoot(name or ""))
				end
			),
			ToString = util.self_function(
					"ToString", {"string"}, {"XMLFile"}),
		},
	})
	-- refused: JSONFile -- its GetRoot() hands Lua a pointer into the file
	-- rather than a copy, so the value dangles when the file is collected;
	-- buildat.parse_json() is the JSON here and answers plain Lua
	-- refused: JSONValue -- the same lifetime, one level down: Get(key)
	-- answers a reference into its parent, and a game wants a table anyway
	-- refused: Localization -- the engine's own string table, loaded from a
	-- JSON resource by language; buildat's translations are the Luanti
	-- module's ([TRANSLATIONS]) and a game's own strings are its own
	-- refused: ResourceWithMetadata -- a resource's metadata by name, which
	-- is the engine's own bookkeeping; a game's data belongs in the game's
	-- own files

	-- Drawable, which is what Urho3D says it is; it used to say Octree here,
	-- which gave it the octree's query methods and none of a drawable's
	-- properties
	util.wc("StaticModel", {
		inherited_from_by_wrapper = dst.Drawable,
		instance = {
			SetModel = util.self_function(
					"SetModel", {}, {"StaticModel", "Model"}),
		},
		properties = {
			model = util.simple_property(dst.Model),
			material = util.simple_property(dst.Material),
		},
	})

	util.wc("Technique", {
		inherited_from_by_wrapper = dst.Resource,
	})

	-- **2D sprites** ([GENVADERS]): pixel art drawn by Urho2D. A sprite
	-- sheet comes from the resource cache only (no constructor is bound),
	-- an XML naming its image and its rectangles; the cache keeps both
	-- inside the resource paths. What it reads is its own image; it writes
	-- nothing. A sprite is an opaque handle to give a StaticSprite2D. Not
	-- the 2D physics, particles or tile maps.
	util.wc("Sprite2D", {
		inherited_from_by_wrapper = dst.Resource,
	})
	util.wc("SpriteSheet2D", {
		inherited_from_by_wrapper = dst.Resource,
		instance = {
			-- nil for a name the sheet does not have
			GetSprite = util.wrap_function({"SpriteSheet2D", "string"},
				function(self, name)
					local s = self:GetSprite(name)
					return s and util.wrap_instance("Sprite2D", s) or nil
				end),
		},
	})
	util.wc("Drawable2D", {
		inherited_from_by_wrapper = dst.Drawable,
		properties = {
			-- The draw order: by layer, then by order in it
			layer = util.simple_property("number"),
			orderInLayer = util.simple_property("number"),
		},
	})
	-- Setters rather than properties for the colour and the hot spot: a
	-- `Color&` property's write is lost (urho3d-tolua-const-ref-property)
	util.wc("StaticSprite2D", {
		inherited_from_by_wrapper = dst.Drawable2D,
		instance = {
			SetSprite = util.self_function("SetSprite", {},
					{"StaticSprite2D", "Sprite2D"}),
			SetColor = util.self_function("SetColor", {},
					{"StaticSprite2D", "Color"}),
			SetAlpha = util.self_function("SetAlpha", {},
					{"StaticSprite2D", "number"}),
			SetFlipX = util.self_function("SetFlipX", {},
					{"StaticSprite2D", "boolean"}),
			SetFlipY = util.self_function("SetFlipY", {},
					{"StaticSprite2D", "boolean"}),
			-- (0, 1) puts the sprite's top left corner on its node
			SetUseHotSpot = util.self_function("SetUseHotSpot", {},
					{"StaticSprite2D", "boolean"}),
			SetHotSpot = util.self_function("SetHotSpot", {},
					{"StaticSprite2D", "Vector2"}),
		},
	})

	util.wc("Node", {
		class = {
			new = function()
				return util.wrap_instance("Node", Node:new())
			end,
		},
		instance = {
			SetTransform = util.self_function("SetTransform", {},
					{"Node", "Matrix3x4"}),
			CreateChild = util.wrap_function({"Node", "string",
					{"number", "__nil"}},
				function(self, name, mode)
					if mode ~= nil then
						return util.wrap_instance("Node", self:CreateChild(name, mode))
					else
						return util.wrap_instance("Node", self:CreateChild(name, LOCAL))
					end
				end
			),
			CreateComponent = util.wrap_function(
					{"Node", "string", {"number", "__nil"}},
				function(self, name, mode)
					local component = nil
					if mode ~= nil then
						component = self:CreateComponent(name, mode)
					else
						component = self:CreateComponent(name, LOCAL)
					end
					assert(component)
					return util.wrap_instance(name, component)
				end
			),
			GetComponent = util.wrap_function({"Node", "string"}, function(self, name)
				local component = self:GetComponent(name)
				if not component then
					return nil
				end
				return util.wrap_instance(name, component)
			end),
			LookAt = util.wrap_function({"Node", "Vector3"}, function(self, p)
				self:LookAt(p)
			end),
			Translate = util.wrap_function({"Node", "Vector3"}, function(self, v)
				self:Translate(v)
			end),
			RemoveChild = util.wrap_function({"Node", "Node"}, function(self, v)
				self:RemoveChild(v)
			end),
			GetID = util.self_function("GetID", {"number"}, {"Node"}),
			GetName = util.self_function("GetName", {"string"}, {"Node"}),
			GetNumChildren = util.self_function(
					"GetNumChildren", {"number"}, {"Node"}),
			GetChild = util.wrap_function({"Node", {"string", "number"}},
				function(self, name_or_index)
					return util.wrap_instance("Node",
							self:GetChild(name_or_index))
				end
			),
			SetScale = util.self_function("SetScale", {}, {"Node", "Vector3"}),
			GetVar = util.wrap_function({"Node", {"string", "StringHash"}},
				function(self, name_or_stringhash)
					if type(name_or_stringhash) == "string" then
						return util.wrap_instance("Variant",
								self:GetVar(StringHash(name_or_stringhash)))
					else
						return util.wrap_instance("Variant",
								self:GetVar(name_or_stringhash))
					end
				end
			),
			SetVar = util.wrap_function({"Node", {"string", "StringHash"}, "Variant"},
				function(self, name_or_stringhash, value)
					if type(name_or_stringhash) == "string" then
						self:SetVar(StringHash(name_or_stringhash), value)
					else
						self:SetVar(name_or_stringhash, value)
					end
				end
			),
			SetVar = util.self_function("SetVar", {},
					{"Node", "StringHash", "Variant"}),
			GetWorldPosition = util.self_function("GetWorldPosition", {dst.Vector3}, {"Node"}),
			GetWorldDirection = util.self_function("GetWorldDirection", {dst.Vector3}, {"Node"}),
			GetRotation = util.self_function("GetRotation", {dst.Quaternion}, {"Node"}),
			Pitch = util.self_function("Pitch", {}, {"Node", "number"}),
			Yaw = util.self_function("Yaw", {}, {"Node", "number"}),
			Roll = util.self_function("Roll", {}, {"Node", "number"}),
			Rotate = util.wrap_function({"Node", "Quaternion", {"number", "__nil"}},
				function(self, q, space)
					if space ~= nil then
						self:Rotate(q, space)
					else
						self:Rotate(q)
					end
				end
			),
			Remove = util.self_function("Remove", {}, {"Node"}),
			SetEnabled = util.self_function(
					"SetEnabled", {}, {"Node", "boolean"}),
			-- The node, its children and their components: what hides a
			-- whole subtree, where SetEnabled is only the node's own
			SetDeepEnabled = util.self_function(
					"SetDeepEnabled", {}, {"Node", "boolean"}),
			-- A copy of the node and its components, in the same parent.
			-- Urho3D copies a component through its attributes, which is in
			-- the engine: what wants this is geometry that costs a sandbox
			-- call per vertex to build and is wanted more than once.
			-- Attributes are all it copies, so a material made in Lua --
			-- which has no resource name to refer to -- is not among them
			-- and has to be set on the copy.
			Clone = util.wrap_function({"Node", {"number", "__nil"}},
				function(self, mode)
					return util.wrap_instance("Node",
							self:Clone(mode ~= nil and mode or LOCAL))
				end
			),
		},
		properties = {
			scale = util.simple_property(dst.Vector3),
			direction = util.simple_property(dst.Vector3),
			position = util.simple_property(dst.Vector3),
			worldDirection = util.simple_property(dst.Vector3),
			worldPosition = util.simple_property(dst.Vector3),
			enabled = util.simple_property("boolean"),
			rotation = util.simple_property(dst.Quaternion),
			-- Read-only in tolua, as its worldTransform; SetTransform() is
			-- the write
			transform = util.simple_property(dst.Matrix3x4),
			worldTransform = util.simple_property(dst.Matrix3x4),
		},
	})

	util.wc("Plane", {
	})

	util.wc("Scene", {
		inherited_from_by_wrapper = dst.Node,
		properties = {
			-- What cElapsedTime(PS) in the shaders is
			elapsedTime = util.simple_property("number"),
			timeScale = util.simple_property("number"),
		},
		unsafe_constructor = util.wrap_function({}, function()
			return util.wrap_instance("Scene", Scene())
		end),
		class = {
			new = function()
				return util.wrap_instance("Scene", Scene:new())
			end,
		},
		instance = {
			GetNode = util.wrap_function({"Scene", "number"},
				function(self, id)
					return util.wrap_instance("Node", self:GetNode(id))
				end
			),
		},
	})

	-- Add properties to Node, using types defined later
	getmetatable(dst.Node).def.properties["scene"] =
			util.simple_property(dst.Scene),

	util.wc("ResourceCache", {
		instance = {
			-- **A resource the game built itself, under a name the engine
			-- can load it by** -- which is the only way a generated
			-- texture reaches a voxel atlas, since a tile is loaded by
			-- resource name ([WORLD_UV], [LAUNCH_WORLD]).
			--
			-- **The name is forced into "generated/"**, which is the
			-- whole of the sandbox question: a script that could name any
			-- resource could shadow one the engine or another module
			-- loads -- a technique, a style, another game's texture. It
			-- can only shadow its own.
			AddManualResource = util.wrap_function(
				{"ResourceCache", {"Image", "Texture2D", "Resource"},
					"string"},
				function(self, resource, name)
					if type(name) ~= "string" or name == "" or
							name:find("[^%w%._%-/]") or name:find("%.%.") then
						error("AddManualResource(): a name may only be "..
								"letters, digits, dot, dash, underscore "..
								"and slash")
					end
					return self:AddManualResource(resource,
							"generated/"..name)
				end
			),
			GetResource = util.wrap_function({"ResourceCache", "string", "string"},
			function(self, resource_type, unsafe_resource_name)
				if not resource_name_ok(unsafe_resource_name) then
					return nil
				end
				-- Nil, and no error in the log, for what is not there: a
				-- game's texture asked for before its media arrived on a
				-- cold cache is not an error, it is later, and the caller
				-- asks again ([FIRST_RUN]; Urho3D's own GetResource logs
				-- an ERROR for a missing file). A resource already loaded
				-- is found whatever the file's fate.
				if not cache:Exists(unsafe_resource_name) and
						not cache:GetExistingResource(resource_type, unsafe_resource_name) then
					return nil
				end
				local res = cache:GetResource(resource_type, unsafe_resource_name)
				return util.wrap_instance(resource_type, res)
			end),
			Exists = util.wrap_function({"ResourceCache", "string"},
			function(self, unsafe_resource_name)
				if not resource_name_ok(unsafe_resource_name) then
					return false
				end
				return cache:Exists(unsafe_resource_name)
			end),
		},
	})

	-- One command of a render path. A scene pass command's shader parameters
	-- reach every batch it draws, which is how one value can be handed to
	-- every material in the viewport at once; see builtin/voxel_shading.
	util.wc("RenderPathCommand", {
		instance = {
			SetShaderParameter = util.wrap_function(
				{"RenderPathCommand", "string",
					{"number", "boolean", "Vector2", "Vector3", "Color",
						"Variant"}},
				function(self, name, value)
					self:SetShaderParameter(name, Variant(value))
				end
			),
			RemoveShaderParameter = util.self_function(
					"RemoveShaderParameter", {},
					{"RenderPathCommand", "string"}),
			-- A texture every batch the command draws gets on a unit its
			-- material leaves free, by resource name: one of the script's
			-- own (AddManualResource's "generated/...") or a render
			-- target's. A world-wide field the voxel shader reads
			-- ([SKELENTI_DANGER_LOOK]). The name is checked as
			-- GetResource's is: a path off the disk is not one.
			SetTextureName = util.wrap_function(
				{"RenderPathCommand", "number", "string"},
				function(self, unit, name)
					if not resource_name_ok(name) or unit < 0 or
							unit >= 16 or unit % 1 ~= 0 then
						error("SetTextureName(): a unit 0..15 and a " ..
								"relative resource name")
					end
					self:SetTextureName(unit, name)
				end
			),
		},
		properties = {
			-- One of the CMD_ constants; CMD_SCENEPASS is the one that draws
			-- scene geometry
			type = util.simple_property("number"),
			-- The technique pass it draws, "base" and so on
			pass = util.simple_property("string"),
			enabled = util.simple_property("boolean"),
		},
	})

	-- **A command is a place in its path's vector** ([SECURITY_RUN_1]):
	-- its wrapper keeps the path (so the path's held reference stays), and
	-- Append and Load, which move the vector, mark the wrappers handed out
	-- dead. path -> {command wrapper -> true}, weak both ways.
	local path_commands = setmetatable({}, {__mode = "k"})
	local function commands_moved(path)
		for c in pairs(path_commands[path] or {}) do
			getmetatable(c).dead = "the RenderPath's commands moved " ..
					"(Append or Load); GetCommand again"
		end
		path_commands[path] = nil
	end
	util.wc("RenderPath", {
		instance = {
			GetNumCommands = util.self_function(
					"GetNumCommands", {"number"}, {"RenderPath"}),
			-- 0-based, as Urho counts them
			GetCommand = util.wrap_function({"RenderPath", "number"},
				function(self, index)
					local c = util.wrap_instance("RenderPathCommand",
							self:GetCommand(index))
					if c then
						getmetatable(c).path = self
						path_commands[self] = path_commands[self] or
								setmetatable({}, {__mode = "k"})
						path_commands[self][c] = true
					end
					return c
				end
			),
			Clone = util.wrap_function({"RenderPath"},
				function(self)
					return util.wrap_instance("RenderPath", self:Clone())
				end
			),
			Append = util.wrap_function({"boolean"}, {"RenderPath", "XMLFile"},
				function(self, file)
					local ok = self:Append(file)
					commands_moved(self)
					return ok
				end
			),
			Load = util.wrap_function({"boolean"}, {"RenderPath", "XMLFile"},
				function(self, file)
					local ok = self:Load(file)
					commands_moved(self)
					return ok
				end
			),
			SetEnabled = util.self_function(
					"SetEnabled", {}, {"RenderPath", "string", "boolean"}),
			ToggleEnabled = util.self_function(
					"ToggleEnabled", {}, {"RenderPath", "string"}),
			SetShaderParameter = util.wrap_function(
				{"RenderPath", "string",
					{"number", "boolean", "Vector2", "Vector3", "Color",
						"Variant"}},
				function(self, name, value)
					self:SetShaderParameter(name, Variant(value))
				end
			),
		},
	})

	util.wc("Viewport", {
		class = {
			new = util.wrap_function({"__to_nil", "Scene", "Camera"},
			function(_, scene, camera_component)
				return util.wrap_instance("Viewport", Viewport:new(scene, camera_component))
			end),
		},
		instance = {
			GetScene = util.wrap_function({"Viewport"},
				function(self)
					return util.wrap_instance("Scene", self:GetScene())
				end
			),
			GetCamera = util.wrap_function({"Viewport"},
				function(self)
					return util.wrap_instance("Camera", self:GetCamera())
				end
			),
			-- Backbuffer pixels; an all-zero rect is the whole window
			SetRect = util.self_function("SetRect", {}, {"Viewport", "IntRect"}),
		},
		properties = {
			renderPath = util.simple_property(dst.RenderPath),
			rect = util.simple_property(dst.IntRect),
		},
	})

	-- **A game draws its own debug geometry** ([URHO_SWEEP]): lines, a
	-- box round what is pointed at, a sphere where a ray landed. It is
	-- a component on the scene -- scene:CreateComponent("DebugRenderer")
	-- -- and what it is given each frame is drawn by
	-- renderer:DrawDebugGeometry() and then forgotten, so nothing here
	-- outlives a frame. It draws and reaches nothing.
	util.wc("DebugRenderer", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			-- Which camera it is drawn for; the renderer does this
			-- itself for the viewport it draws, and a game that draws
			-- into its own viewport says it here
			SetView = util.self_function("SetView", {},
					{"DebugRenderer", "Camera"}),
			SetLineAntiAlias = util.self_function("SetLineAntiAlias", {},
					{"DebugRenderer", "boolean"}),
			AddLine = util.self_function("AddLine", {},
					{"DebugRenderer", "Vector3", "Vector3", "Color",
					{"boolean", "__nil"}}),
			AddTriangle = util.self_function("AddTriangle", {},
					{"DebugRenderer", "Vector3", "Vector3", "Vector3",
					"Color", {"boolean", "__nil"}}),
			AddNode = util.self_function("AddNode", {},
					{"DebugRenderer", "Node", {"number", "__nil"},
					{"boolean", "__nil"}}),
			AddBoundingBox = util.self_function("AddBoundingBox", {},
					{"DebugRenderer", "BoundingBox", "Color",
					{"boolean", "__nil"}, {"boolean", "__nil"}}),
			AddSphere = util.self_function("AddSphere", {},
					{"DebugRenderer", "Sphere", "Color",
					{"boolean", "__nil"}}),
			AddCircle = util.self_function("AddCircle", {},
					{"DebugRenderer", "Vector3", "Vector3", "number",
					"Color", {"number", "__nil"}, {"boolean", "__nil"}}),
			AddCross = util.self_function("AddCross", {},
					{"DebugRenderer", "Vector3", "number", "Color",
					{"boolean", "__nil"}}),
		},
	})

	util.wc("Renderer", {
		instance = {
			-- What the scene's DebugRenderer was given this frame, drawn
			-- ([URHO_SWEEP]): a game calls this from its own post-render
			-- handler, the engine does it for the debug HUD it owns
			DrawDebugGeometry = util.self_function("DrawDebugGeometry", {},
					{"Renderer", {"boolean", "__nil"}}),
			SetViewport = util.wrap_function({"Renderer", "number", "Viewport"},
				function(self, index, viewport)
					self:SetViewport(index, viewport)
				end
			),
			GetViewport = util.wrap_function({"Renderer", "number"},
				function(self, index)
					-- The game's preferred viewport when the renderer holds
					-- none (it is on a texture then); see init.lua
					local ret = self:GetViewport(index) or
							util.preferred_viewport(index)
					if ret == nil then return nil end
					return util.wrap_instance("Viewport", ret)
				end
			),
		},
		properties = {
			HDRRendering = util.simple_property("boolean"),
			numViewports = util.simple_property("number"),
			-- Shadows are a renderer-wide setting and not a light's: how big
			-- the shadow map is, how it is filtered (Urho3D's ShadowQuality),
			-- and whether any are drawn at all
			shadowMapSize = util.simple_property("number"),
			shadowQuality = util.simple_property("number"),
			drawShadows = util.simple_property("boolean"),
			-- The software occlusion buffer's budget: how many triangles
			-- of occluder it rasterises before it stops, and how large on
			-- screen an occluder has to be to be worth rasterising. A
			-- voxel chunk is thousands of triangles, so Urho3D's default
			-- 5000 is spent on the first few ([CLIENT_FRAME]).
			maxOccluderTriangles = util.simple_property("number"),
			occluderSizeThreshold = util.simple_property("number"),
		},
	})

	-- Window size in backbuffer pixels, which is what a Viewport rect is in
	util.wc("Graphics", {
		class = {
			-- The texture format a render target is made in, static in
			-- Urho3D; see TextureCube:SetSize()
			GetRGBAFormat = function()
				return Graphics:GetRGBAFormat()
			end,
			-- Half floats: a target that holds an HDR sky's radiance
			GetRGBAFloat16Format = function()
				return Graphics:GetRGBAFloat16Format()
			end,
		},
		properties = {
			width = util.simple_property("number"),
			height = util.simple_property("number"),
		},
	})

	-- A texture's face as something a viewport draws into. What wants it
	-- is the sky rendered into a cube for the world to reflect, six
	-- viewports of one skybox scene -- [SKY_REFLECTIONS] in
	-- doc/plan/rendering_plan.md. Manual update, queued when the sky has
	-- moved, is the mode; a surface that redraws every frame is six extra
	-- renders a frame for a reflection nobody watches change.
	util.wc("RenderSurface", {
		instance = {
			SetViewport = util.wrap_function({"RenderSurface", "number",
					"Viewport"},
				function(self, index, viewport)
					self:SetViewport(index, viewport)
				end),
			QueueUpdate = util.self_function("QueueUpdate", {},
					{"RenderSurface"}),
		},
		properties = {
			updateMode = util.simple_property("number"),
		},
	})

	util.wc("Animatable", {
	})

	util.wc("UIElement", {
		inherited_from_by_wrapper = dst.Animatable,
		instance = {
			-- A string the engine reads off the element: a LineEdit's
			-- "autocomplete", what it is for, to a browser ([LOGIN_UNLOADED])
			SetVar = util.wrap_function({"UIElement", "string", "string"},
				function(self, name, value)
					self:SetVar(StringHash(name), Variant(value))
				end
			),
			CreateChild = util.wrap_function({"UIElement", "string",
					{"string", "__nil"}},
				function(self, element_type, name)
					return util.wrap_instance(element_type,
							self:CreateChild(element_type, name))
				end
			),
			GetChild = util.wrap_function({"UIElement", {"string", "number"}},
				function(self, name_or_index)
					-- Wrapped as what it is when that class is whitelisted
					-- -- a BorderImage's texture, a Text's text -- and as a
					-- plain UIElement otherwise ([SCAN_EVENT] reads a form's
					-- elements this way)
					local child = self:GetChild(name_or_index)
					if child == nil then
						return nil
					end
					local tn = child:GetTypeName()
					local class = dst[tn]
					if class and getmetatable(class) and getmetatable(class).wrap then
						return util.wrap_instance(tn, child)
					end
					return util.wrap_instance("UIElement", child)
				end
			),
			GetNumChildren = util.self_function(
					"GetNumChildren", {"number"}, {"UIElement"}),
			RemoveChild = util.wrap_function({"UIElement", "UIElement"},
				function(self, child)
					self:RemoveChild(child)
				end
			),
			Remove = util.self_function("Remove", {}, {"UIElement"}),
			-- Everything under it at once, which is what redrawing a screen
			-- full of elements from scratch wants
			-- But not the client's own ([TRUST_COLOR]): its dialogs and the
			-- trust colour's sample are children of the same root, and a
			-- script clearing the root took them with it
			RemoveAllChildren = function(self)
				local m = getmetatable(self)
				local raw = m and m.unsafe
				if raw == nil then
					error("RemoveAllChildren: not an element")
				end
				for i = raw:GetNumChildren(false) - 1, 0, -1 do
					local c = raw:GetChild(i)
					local name = c and c:GetName() or ""
					if name:sub(1, 9) ~= "__trusted" then
						raw:RemoveChildAtIndex(i)
					end
				end
			end,
			-- Not a client's secret field's name taken away: that name is what
			-- keeps what is typed into it from other scripts
			SetName = function(self, name)
				local m = getmetatable(self)
				local raw = m and m.unsafe
				if raw == nil or type(name) ~= "string" then
					error("SetName(name): an element and a string")
				end
				if magic_sandbox.is_secret_field(raw) then
					return
				end
				raw:SetName(name)
			end,
			-- Not into a client's secret field by any wrapper but its maker's
			-- ([SECURITY_RUN_7]; the property's guard is magic_sandbox's)
			SetText = function(self, text)
				local m = getmetatable(self)
				local raw = m and m.unsafe
				if raw ~= nil and magic_sandbox.is_secret_field(raw) and
						not m.trusted_reader then
					error("a client's secret field is not a script's to write")
				end
				return util.self_function("SetText", {},
						{"UIElement", "string"})(self, text)
			end,
			-- Text::SetFont(Font*, float size), and **the size is the
			-- argument that was missing**: without it in the signature the
			-- sandbox dropped it and every caller drew at Urho3D's own
			-- DEFAULT_FONT_SIZE of 12, whatever it asked for -- thirty-four
			-- call sites across the tree, and a HUD text element's size.X
			-- could not work at all ([UI_PARITY]). Text3D's entry has had
			-- it all along. Optional, as the binding has it.
			SetFont = util.self_function("SetFont", {},
					{"UIElement", "Font", {"number", "__nil"}}),
			SetPosition = util.self_function(
					"SetPosition", {}, {"UIElement", "number", "number"}),
			SetStyleAuto = util.self_function("SetStyleAuto", {}, {"UIElement"}),
			-- A non-auto style of the element's defaultStyle, by name
			-- ("PrimaryButton", [MENU_BRAND])
			SetStyle = util.self_function("SetStyle", {},
					{"UIElement", "string"}),
			-- A size that is both the minimum and the maximum, which is what
			-- a layout leaves alone. Functions rather than the fixedWidth /
			-- fixedHeight / fixedSize properties, which have no setter in
			-- the bindings; see the note by them below.
			SetFixedWidth = util.self_function("SetFixedWidth", {},
					{"UIElement", "number"}),
			SetFixedHeight = util.self_function("SetFixedHeight", {},
					{"UIElement", "number"}),
			SetFixedSize = util.self_function("SetFixedSize", {},
					{"UIElement", "number", "number"}),
			SetVisible = util.self_function("SetVisible", {},
					{"UIElement", "boolean"}),
			SetLayout = util.wrap_function({"UIElement", "number",
					{"number", "__nil"}, {"IntRect", "__nil"}},
				function(self, mode, spacing, border)
					spacing = spacing or 0
					border = border or dst.IntRect()
					self:SetLayout(mode, spacing, border)
				end
			),
			SetAlignment = util.self_function(
					"SetAlignment", {}, {"UIElement", "number", "number"}),
			SetFocusMode = util.self_function(
					"SetFocusMode", {}, {"UIElement", "number"}),
			-- **Not off the client's login** ([SEC_SECRET_FOCUS]): while
			-- its password field is shown (magic_sandbox.secret_open) a
			-- script focuses nothing but a client field -- one of its own
			-- would take the keys the user types into what looks like the
			-- login -- and drops no focus
			SetFocus = util.wrap_function({"UIElement", "boolean"},
				function(self, enable)
					if magic_sandbox.keys_withheld() and
							(not enable or not magic_sandbox.is_secret_field(self)) then
						return
					end
					self:SetFocus(enable)
				end),
			HasFocus = util.self_function(
					"HasFocus", {"boolean"}, {"UIElement"}),
			-- Whether it or one under it has the focus ([SANDBOX_API_AUDIT]:
			-- list_view named the focus and searched every row for it)
			HasRecursiveFocus = util.wrap_function({"UIElement"},
				function(self)
					local f = ui:GetFocusElement()
					for _ = 1, 64 do
						if f == nil then return false end
						if f == self then return true end
						f = f:GetParent()
					end
					return false
				end),
			GetName = util.self_function("GetName", {"string"}, {"UIElement"}),
			-- Which kind of element this is -- "Button", "LineEdit" --
			-- which is how the one with the focus is told apart from the
			-- rest; see button_menu_nav() in extensions/ui_utils
			GetTypeName = util.self_function(
					"GetTypeName", {"string"}, {"UIElement"}),
			-- Whether this is a multi-line LineEdit, asked of the focus,
			-- which reads as a UIElement here ([HEARTH_MVP]: its rows own
			-- up and down, see keyboard_page() in extensions/ui_utils)
			IsMultiLine = function(self)
				local m = getmetatable(self)
				local raw = m and m.unsafe
				if raw == nil then
					error("IsMultiLine: not an element")
				end
				return raw:GetTypeName() == "LineEdit" and raw:IsMultiLine()
			end,
			-- A multi-line LineEdit's caret, nil for the rest, and whether
			-- it is on the text's first row (IsCaretOnLastRow: its last),
			-- asked of the focus, which reads as a UIElement: a page keeps the
			-- caret in view as the field grows, and Up and Down leave the
			-- field from its ends ([HEARTH_PAGE_SCROLL]; see keyboard_page()
			-- in extensions/ui_utils)
			GetCaret = util.wrap_function({"__safe", "__safe"}, {"UIElement"},
				function(self)
					if self:GetTypeName() ~= "LineEdit" or
							not self:IsMultiLine() then
						return nil, false
					end
					local c, t = self:GetCursor(), self:GetTextElement()
					local y = c:GetPosition().y - t:GetPosition().y
					return util.wrap_instance("UIElement", c), y < c:GetHeight()
				end),
			IsCaretOnLastRow = util.wrap_function({"boolean"}, {"UIElement"},
				function(self)
					if self:GetTypeName() ~= "LineEdit" or
							not self:IsMultiLine() then
						return false
					end
					local c, t = self:GetCursor(), self:GetTextElement()
					local y = c:GetPosition().y - t:GetPosition().y
					return y + c:GetHeight() >= t:GetHeight()
				end),
			-- Whether the wheel at window pixel (x, y), a click of delta, is
			-- a multi-line edit's under this element, one with more text to
			-- show that way ([TEXTAREA_WHEEL]): a page that scrolls by the
			-- wheel steps aside for it, and takes it at the text's end
			WheelTakenAt = util.wrap_function(
				{"UIElement", "number", "number", "number"},
				function(self, x, y, delta)
					local sc = ui:GetScale()
					local e = ui:GetElementAt(math.floor(x / sc),
							math.floor(y / sc))
					local edit = nil
					for _ = 1, 64 do
						if e == nil then return false end
						if edit == nil and e:GetTypeName() == "LineEdit" then
							edit = e
						end
						if e == self then
							return edit ~= nil and edit:WheelScrolls(delta)
						end
						e = e:GetParent()
					end
					return false
				end),
			GetText = function(self)
				local m = getmetatable(self)
				local raw = m and m.unsafe
				if raw == nil then
					error("GetText: not an element")
				end
				if magic_sandbox.is_secret_field(raw) and not m.trusted_reader then
					return ""
				end
				return raw:GetText()
			end,
		},
		properties = {
			-- Where the element is in its parent. Note that this is an
			-- offset from whatever the alignment anchors it to, not a
			-- corner: a centred element sits at 0,0. screenPosition is the
			-- resolved place, and read-only in the bindings.
			position = util.simple_property(dst.IntVector2),
			screenPosition = {get = util.simple_property(dst.IntVector2).get},
			horizontalAlignment = util.simple_property("number"),
			verticalAlignment = util.simple_property("number"),
			height = util.simple_property("number"),
			width = util.simple_property("number"),
			size = util.simple_property(dst.IntVector2),
			-- What a client's own trusted element is coloured is not a
			-- script's to read ([TRUST_COLOR]): a Starport field's colour is
			-- the trust colour, and with it a script drew a look-alike
			color = {
				get = function(v, raw)
					local name = raw and raw:GetName() or ""
					if name:sub(1, 9) == "__trusted" then
						return util.simple_property(dst.Color).get(Color(1, 1, 1, 1))
					end
					return util.simple_property(dst.Color).get(v)
				end,
				set = util.simple_property(dst.Color).set,
			},
			-- Whether children outside the element are drawn: a viewport
			-- over a grid taller than the window ([LAUNCH_GRID])
			clipChildren = util.simple_property("boolean"),
			minHeight = util.simple_property("number"),
			minWidth = util.simple_property("number"),
			minSize = util.simple_property(dst.IntVector2),
			-- What a layout may stretch an element to: a list in a column
			-- beside a longer one keeps its rows' height
			maxHeight = util.simple_property("number"),
			maxWidth = util.simple_property("number"),
			-- Read-only, and not because Urho3D says so: tolua++ generates
			-- no setter for these (the generated binding is
			-- tolua_variable("fixedWidth", getter, NULL)), so assigning
			-- them wrote nowhere and read back what was assigned. Use
			-- SetFixedWidth / SetFixedHeight / SetFixedSize below.
			fixedHeight = {get = util.simple_property("number").get},
			fixedWidth = {get = util.simple_property("number").get},
			fixedSize = {get = util.simple_property(dst.IntVector2).get},
			-- "__nil" because an element that has not been given a style
			-- reads back nil, and a property that can be unset has to say so
			-- or reading it throws. The same is true of every other
			-- object-typed property here that a game might read before
			-- setting it.
			defaultStyle = util.simple_property({dst.XMLFile, "__nil"}),
			selected = util.simple_property("boolean"),
			-- Off by default in Urho3D: an element that is not enabled is
			-- not hit by a click, so nothing under the mouse is found and
			-- no click event is sent at all
			enabled = util.simple_property("boolean"),
			visible = util.simple_property("boolean"),
			opacity = util.simple_property("number"),
			-- Under the client's own dialogs (the network permission one
			-- is at 1000): a script's element drawn over one could put its
			-- own buttons where the user's answer goes ([SECURITY_RUN_1])
			priority = {
				get = function(v)
					return v
				end,
				set = function(v)
					if type(v) ~= "number" then
						error("priority: a number")
					end
					return math.min(v, 999)
				end,
			},
			-- Whether a click raises it over the rest, a Window's habit:
			-- false keeps a panel under a menu given a higher priority
			-- ([FP_MENU_BEHIND]). Only off: on, a click would lift it to
			-- a priority past the cap above.
			bringToFront = {
				get = function(v)
					return v
				end,
				set = function(v)
					if v ~= false then
						error("bringToFront: only false")
					end
					return v
				end,
			},
		},
	})

	util.wc("Text", {
		inherited_from_by_wrapper = dst.UIElement,
		instance = {
			SetTextAlignment = util.self_function(
					"SetTextAlignment", {}, {"UIElement", "number"}),
			SetFontSize = util.self_function(
					"SetFontSize", {}, {"Text", "number"}),
			-- The whole text's colour. Text3D has had this; Text had no
			-- way to set one at all, so every label drew in the style's
			-- default ([WHITELIST_POLICY]: plainly safe).
			SetColor = util.self_function("SetColor", {}, {"Text", "Color"}),
			-- **A Text does have a selection** -- it is what a LineEdit's
			-- own is drawn with -- and nothing could reach it, so a
			-- screen showing a document had no way to point at the line
			-- it had just found ([LAUNCH_CONSOLE], 2026-09-23)
			SetSelection = util.self_function("SetSelection", {},
					{"Text", "number", {"number", "__nil"}}),
			ClearSelection = util.self_function("ClearSelection", {},
					{"Text"}),
			SetSelectionColor = util.self_function("SetSelectionColor", {},
					{"Text", "Color"}),
			-- The background under the mouse: a dropdown's entries
			SetHoverColor = util.self_function("SetHoverColor", {},
					{"Text", "Color"}),
			-- A shadow or an outline under the letters, which is what makes
			-- text over a world readable: a HUD over snow or sand is white
			-- on white without it. effectColor is what it is drawn with.
			SetTextEffect = util.self_function(
					"SetTextEffect", {}, {"Text", "number"}),
			-- Wrapped within the element's width ([LAUNCH_DESC])
			SetWordwrap = util.self_function(
					"SetWordwrap", {}, {"Text", "boolean"}),
		},
		properties = {
			text = util.simple_property("string"),
			effectColor = util.simple_property(dst.Color),
			-- Where a field's selection is, for a check's scan ([TEXT_KEYS])
			selectionStart = util.read_only_property("number"),
			selectionLength = util.read_only_property("number"),
		},
	})

	util.wc("BorderImage", {
		inherited_from_by_wrapper = dst.UIElement,
		properties = {
			-- Texture2D, the tolua type a BorderImage's texture reads back as;
			-- a setter given one passes the same check
			texture = util.simple_property(dst.Texture2D),
			hoverOffset = util.simple_property(dst.IntVector2),
			-- The border widths, which is what makes an image nine-sliced:
			-- the corners keep their size and only the middle stretches
			border = util.simple_property(dst.IntRect),
			imageBorder = util.simple_property(dst.IntRect),
			imageRect = util.simple_property(dst.IntRect),
			tiled = util.simple_property("boolean"),
			-- BLEND_REPLACE is the default and is what an image with
			-- transparency in it has to be taken off: a fully opaque colour
			-- keeps it, and then the transparent pixels are drawn black
			blendMode = util.simple_property("number"),
		},
	})

	util.wc("Window", {
		inherited_from_by_wrapper = dst.BorderImage,
	})

	-- A UI element that draws a scene of its own. Urho3D renders the scene
	-- into a texture of the element's size and shows it, which is the one
	-- way to get something three-dimensional in among the UI rather than
	-- behind all of it. What wants it here is a formspec's model[].
	util.wc("View3D", {
		inherited_from_by_wrapper = dst.Window,
		instance = {
			-- The scene and the camera it is drawn from. own_scene, which
			-- is what it defaults to, means the element takes ownership of
			-- both: a scene made for one element dies with it and a caller
			-- that keeps no reference cannot leak one. False is for a view
			-- of a scene somebody else owns -- the world seen from above,
			-- say -- which the element must not take with it when it goes.
			SetView = util.wrap_function({"View3D", "Scene", "Camera",
					{"boolean", "__nil"}},
				function(self, scene, camera, own_scene)
					self:SetView(scene, camera, own_scene ~= false)
				end
			),
			-- Draw it again once. With autoUpdate off, which is what a view
			-- of a whole scene wants, this is what refreshes it: a picture
			-- of the world costs a second pass over the world.
			QueueUpdate = util.self_function("QueueUpdate", {}, {"View3D"}),
			-- The viewport it renders through. What a caller wants from it
			-- is its render path: a scene drawn without the one the window
			-- itself is drawn with is a different picture of the same world
			-- -- with HDR on and no tonemap in the way, a white one.
			GetViewport = util.wrap_function({"View3D"},
				function(self)
					return util.wrap_instance("Viewport", self:GetViewport())
				end
			),
		},
		properties = {
			autoUpdate = util.simple_property("boolean"),
			-- The render target's texture format; Graphics.GetRGBAFormat()
			-- gives it an alpha channel to be transparent through
			format = util.simple_property("number"),
		},
	})

	util.wc("Button", {
		inherited_from_by_wrapper = dst.BorderImage,
		properties = {
			pressedOffset = util.simple_property(dst.IntVector2),
		},
	})

	-- A box that is ticked or not. The style sheet draws it; the element
	-- carries the state.
	util.wc("CheckBox", {
		inherited_from_by_wrapper = dst.BorderImage,
		properties = {
			checked = util.simple_property("boolean"),
		},
	})

	util.wc("LineEdit", {
		inherited_from_by_wrapper = dst.BorderImage,
		properties = {
			-- **What is in the field**, which nothing could read: a
			-- sandboxed screen could make a text field and never learn
			-- what was typed into it ([LAUNCH_CONSOLE] found this). The
			-- field is the user's own and its contents are what they
			-- just typed into this program.
			text = {
				get = function(v, raw, meta)
					if magic_sandbox.is_secret_field(raw) and
							not (meta and meta.trusted_reader) then
						return ""
					end
					return v
				end,
				set = util.simple_property("string").set,
			},
			cursorPosition = util.simple_property("number"),
			-- The text's inset from the field's edges
			clipBorder = util.simple_property(dst.IntRect),
			-- **The two elements a field is made of**, read-only, so a
			-- screen can give a field a font and a colour of its own:
			-- without them the only way to a readable field is Urho3D's
			-- default style, which paints it light and leaves the text
			-- whatever the screen set ([LAUNCH_CONSOLE]'s playtest --
			-- white on white until something was selected)
			textElement = {get = util.simple_property(dst.Text).get},
			cursor = {get = util.simple_property(dst.BorderImage).get},
			-- The character a password field shows instead of what was
			-- typed, as its code point; 0 shows the text itself
			echoCharacter = util.simple_property("number"),
			maxLength = util.simple_property("number"),
			-- Whether Ctrl+C and Ctrl+V work in the field, which Urho3D
			-- does itself and which nothing here turned on
			-- ([NEW_WORLD_FORM]): a friend's seed can be pasted in. The
			-- clipboard is the user's own and the field is the user's own,
			-- so this moves nothing the user did not ask to move.
			textCopyable = util.simple_property("boolean"),
			textSelectable = util.simple_property("boolean"),
			-- A field to read and copy from, not to type into
			editable = util.simple_property("boolean"),
			-- Enter breaks the line, Ctrl+Enter finishes, the text wraps
			-- ([HEARTH_MVP]: a message has paragraphs)
			multiLine = util.simple_property("boolean"),
		},
	})

	-- The scrolling family, added 2026-09-15 by the whitelist policy: a look
	-- rather than a proof, and a look says a panel that clips its children
	-- and two bars that say how far down it is draw and compute and do
	-- nothing else. `ui_utils.add_paged()` exists because none of this was
	-- here; see [URHO_SWEEP] and [WHITELIST_POLICY] in
	-- doc/plan/master_plan.md.
	--
	-- In dependency order, because a wrapper names the classes its
	-- properties are of and they have to exist by then.

	util.wc("Slider", {
		inherited_from_by_wrapper = dst.BorderImage,
		instance = {
			ChangeValue = util.self_function("ChangeValue", {},
					{"Slider", "number"}),
		},
		properties = {
			orientation = util.simple_property("number"),
			range = util.simple_property("number"),
			value = util.simple_property("number"),
			-- Read-only: the part that is dragged
			knob = util.simple_property(dst.BorderImage),
			repeatRate = util.simple_property("number"),
		},
	})

	util.wc("ScrollBar", {
		inherited_from_by_wrapper = dst.BorderImage,
		instance = {
			ChangeValue = util.self_function("ChangeValue", {},
					{"ScrollBar", "number"}),
			StepBack = util.self_function("StepBack", {}, {"ScrollBar"}),
			StepForward = util.self_function("StepForward", {},
					{"ScrollBar"}),
		},
		properties = {
			-- O_HORIZONTAL or O_VERTICAL
			orientation = util.simple_property("number"),
			-- How much there is to scroll through, and where in it we are
			range = util.simple_property("number"),
			value = util.simple_property("number"),
			scrollStep = util.simple_property("number"),
			stepFactor = util.simple_property("number"),
			-- Read-only: the bar's own parts
			effectiveScrollStep = util.simple_property("number"),
			backButton = util.simple_property(dst.Button),
			forwardButton = util.simple_property(dst.Button),
			slider = util.simple_property(dst.Slider),
		},
	})

	util.wc("ProgressBar", {
		inherited_from_by_wrapper = dst.BorderImage,
		instance = {
			ChangeValue = util.self_function("ChangeValue", {},
					{"ProgressBar", "number"}),
		},
		properties = {
			orientation = util.simple_property("number"),
			range = util.simple_property("number"),
			value = util.simple_property("number"),
			knob = util.simple_property(dst.BorderImage),
			-- Read-only: the style the percentage text is drawn with
			loadingPercentStyle = util.simple_property("string"),
			showPercentText = util.simple_property("boolean"),
		},
	})

	-- The content element is the one that scrolls: make it, fill it, and
	-- give it to the view, which clips it and puts bars beside it.
	util.wc("ScrollView", {
		inherited_from_by_wrapper = dst.UIElement,
		instance = {
			-- Which bars are drawn at all, whatever auto-visible would do
			SetScrollBarsVisible = util.self_function("SetScrollBarsVisible",
					{}, {"ScrollView", "boolean", "boolean"}),
		},
		properties = {
			-- How far into the content the top left corner is, in pixels
			viewPosition = util.simple_property(dst.IntVector2),
			contentElement = util.simple_property(dst.UIElement),
			-- Read-only in Urho3D: the bars the view made for itself. A
			-- write here is dropped rather than refused, which is the one
			-- sharp edge of a property list.
			horizontalScrollBar = util.simple_property(dst.ScrollBar),
			verticalScrollBar = util.simple_property(dst.ScrollBar),
			scrollPanel = util.simple_property(dst.BorderImage),
			scrollBarsAutoVisible = util.simple_property("boolean"),
			-- A wheel notch, and a page: fractions of the content
			scrollStep = util.simple_property("number"),
			pageStep = util.simple_property("number"),
			-- What a flick does after the finger leaves, and when it stops
			scrollDeceleration = util.simple_property("number"),
			scrollSnapEpsilon = util.simple_property("number"),
		},
	})

	-- A list of elements with a selection, which is a ScrollView that knows
	-- what is in it. The items are whatever elements the game makes; the
	-- list owns them once they are added.
	util.wc("ListView", {
		inherited_from_by_wrapper = dst.ScrollView,
		instance = {
			AddItem = util.self_function("AddItem", {},
					{"ListView", "UIElement"}),
			InsertItem = util.self_function("InsertItem", {},
					{"ListView", "number", "UIElement"}),
			-- simplified: the by-index form only. Urho3D also removes by
			-- element, and the two are one overloaded name, which a type
			-- check cannot tell apart from here; FindItem() turns an
			-- element into its index, which is the same thing in two calls.
			RemoveItem = util.self_function("RemoveItem", {},
					{"ListView", "number"}),
			RemoveAllItems = util.self_function("RemoveAllItems", {},
					{"ListView"}),
			GetItem = util.wrap_function({"ListView", "number"},
				function(self, index)
					return util.wrap_instance("UIElement", self:GetItem(index))
				end
			),
			FindItem = util.self_function("FindItem", {"number"},
					{"ListView", "UIElement"}),
			SetSelection = util.self_function("SetSelection", {},
					{"ListView", "number"}),
			AddSelection = util.self_function("AddSelection", {},
					{"ListView", "number"}),
			RemoveSelection = util.self_function("RemoveSelection", {},
					{"ListView", "number"}),
			ToggleSelection = util.self_function("ToggleSelection", {},
					{"ListView", "number"}),
			ChangeSelection = util.self_function("ChangeSelection", {},
					{"ListView", "number", {"boolean", "__nil"}}),
			ClearSelection = util.self_function("ClearSelection", {},
					{"ListView"}),
			IsSelected = util.self_function("IsSelected", {"boolean"},
					{"ListView", "number"}),
			-- The hierarchy half, which is what makes a tree out of a list
			Expand = util.self_function("Expand", {},
					{"ListView", "number", "boolean",
					{"boolean", "__nil"}}),
			ToggleExpand = util.self_function("ToggleExpand", {},
					{"ListView", "number", {"boolean", "__nil"}}),
			IsExpanded = util.self_function("IsExpanded", {"boolean"},
					{"ListView", "number"}),
		},
		properties = {
			-- Read-only: how many items, and which one is selected
			numItems = util.simple_property("number"),
			selectedItem = util.simple_property(dst.UIElement),
			selection = util.simple_property("number"),
			-- HM_NEVER, HM_FOCUS or HM_ALWAYS
			highlightMode = util.simple_property("number"),
			multiselect = util.simple_property("boolean"),
			clearSelectionOnDefocus = util.simple_property("boolean"),
			selectOnClickEnd = util.simple_property("boolean"),
			hierarchyMode = util.simple_property("boolean"),
			baseIndent = util.simple_property("number"),
		},
	})

	-- A button that opens something when it is pressed, and the list that
	-- is one. Added 2026-09-15 with the rest of the UI sweep; a menu draws
	-- and computes and does nothing else. The popup is an element the game
	-- makes and hands over, so what a menu opens is the game's own.
	util.wc("Menu", {
		inherited_from_by_wrapper = dst.Button,
		instance = {
			ShowPopup = util.self_function("ShowPopup", {},
					{"Menu", "boolean"}),
			-- No SetAccelerator ([SECURITY_RUN_7]): a menu's key is heard
			-- in any focused field, the client's own login among them
		},
		properties = {
			popup = util.simple_property(dst.UIElement),
			-- Where the popup lands relative to the menu
			popupOffset = util.simple_property(dst.IntVector2),
			showPopup = util.simple_property("boolean"),
		},
	})

	-- The one a game reaches for: a menu whose popup is a list, which is
	-- what a settings screen is made of. The items are elements the game
	-- makes, as ListView's are.
	util.wc("DropDownList", {
		inherited_from_by_wrapper = dst.Menu,
		instance = {
			AddItem = util.self_function("AddItem", {},
					{"DropDownList", "UIElement"}),
			InsertItem = util.self_function("InsertItem", {},
					{"DropDownList", "number", "UIElement"}),
			-- simplified: the by-index form only, as ListView's is, the two
			-- being one overloaded name that a type check cannot tell apart
			RemoveItem = util.self_function("RemoveItem", {},
					{"DropDownList", "number"}),
			RemoveAllItems = util.self_function("RemoveAllItems", {},
					{"DropDownList"}),
			SetSelection = util.self_function("SetSelection", {},
					{"DropDownList", "number"}),
			GetItem = util.wrap_function({"DropDownList", "number"},
				function(self, index)
					return util.wrap_instance("UIElement", self:GetItem(index))
				end
			),
		},
		properties = {
			-- Read-only: how many, which one, and the parts it is made of
			numItems = util.simple_property("number"),
			selectedItem = util.simple_property(dst.UIElement),
			listView = util.simple_property(dst.ListView),
			placeholder = util.simple_property(dst.UIElement),
			selection = util.simple_property("number"),
			-- What it says with nothing chosen
			placeholderText = util.simple_property("string"),
			-- Whether the popup takes the list's width or the button's
			resizePopup = util.simple_property("boolean"),
		},
	})

	-- What hangs under the pointer after it has rested a moment. The
	-- element it shows is a child of it, which the game makes.
	util.wc("ToolTip", {
		inherited_from_by_wrapper = dst.UIElement,
		properties = {
			-- Seconds of rest before it appears
			delay = util.simple_property("number"),
		},
	})

	-- The pointer itself, as an element the style sheet draws. A game can
	-- say which named shape it is wearing; **DefineShape is not here**,
	-- because it takes an Image and images are not on this whitelist yet.
	util.wc("Cursor", {
		inherited_from_by_wrapper = dst.BorderImage,
		instance = {
			-- **A game's own cursor art** ([URHO_SWEEP]): the shape is
			-- Urho3D's own name for one ("Normal", "ResizeVertical",
			-- ...), and what draws it is the game's Image, a rectangle
			-- of it and the hot spot. It was off the whitelist only
			-- because Image was, which it is not any more.
			DefineShape = util.wrap_function({"Cursor", "string", "Image",
					"IntRect", "IntVector2"},
				function(self, shape, image, rect, hotspot)
					-- **The image comes out of the resource cache**: Urho3D
					-- hands it to a SharedPtr, which frees an Image the
					-- sandbox owns from under the collector -- a segfault
					-- in RefCounted rather than an error (2026-09-25,
					-- found by the exercise in sandbox_test). A cached
					-- resource has a name; one built here does not, and
					-- that is the difference this can see.
					if image.name == "" then
						error("Cursor:DefineShape(): the image has to come " ..
								"from the resource cache", 2)
					end
					self:DefineShape(shape, image, rect, hotspot)
				end
			),
		},
		properties = {
			shape = util.simple_property("string"),
			-- The system's own arrow instead of the style's, which is a
			-- look rather than a reach: the shape is still Urho3D's list
			useSystemShapes = util.simple_property("boolean"),
		},
	})

	-- Text in the world rather than on the screen: a nameplate over a
	-- player, a sign a game can read from a distance. A Drawable, so it
	-- goes on a scene node and not in the UI tree.
	util.wc("Text3D", {
		inherited_from_by_wrapper = dst.Drawable,
		instance = {
			SetFont = util.self_function("SetFont", {"boolean"},
					{"Text3D", "Font", {"number", "__nil"}}),
			SetAlignment = util.self_function("SetAlignment", {},
					{"Text3D", "number", "number"}),
			SetColor = util.self_function("SetColor", {},
					{"Text3D", "Color"}),
		},
		properties = {
			text = util.simple_property("string"),
			-- **A font has to be set before this does anything.**
			-- Text::SetFontSize() begins "Initial font must be set" and
			-- returns false without one, so a size written first is
			-- silently the default. SetFont() takes both at once.
			fontSize = util.simple_property("number"),
			-- Wrapped at this many pixels of its own space, 0 for not
			width = util.simple_property("number"),
			wordwrap = util.simple_property("boolean"),
			-- Whether it is always the same size on the screen however far
			-- away it is, and which way it turns to face the camera
			fixedScreenSize = util.simple_property("boolean"),
			faceCameraMode = util.simple_property("number"),
			opacity = util.simple_property("number"),
			-- An outline or a shadow, which is what makes text readable
			-- over a world it has no control over
			textEffect = util.simple_property("number"),
			effectColor = util.simple_property(dst.Color),
			effectStrokeThickness = util.simple_property("number"),
			material = util.simple_property(dst.Material),
		},
	})

	-- Looked at and refused, so that the next sweep does not look again.
	-- util/whitelist_sweep.py reads these lines, so the shape is fixed:
	-- "-- refused: <Class> -- <why>", one per line.
	--
	-- refused: FileSelector -- shows the user's own filesystem, and hands the chosen path back
	-- refused: HierarchyContainer -- ListView makes its own; a game never does
	-- refused: MessageBox -- its constructor wants the engine context and it loads a layout resource by name; ui_utils.show_message_dialog is the dialog here

	-- IO, which is the shape this policy exists to refuse: a game's data is
	-- what the server sends it and what the resource cache serves it, and
	-- neither of those is a path.
	--
	-- refused: File -- opens a path on the user's disk and reads or writes it
	-- refused: FileSystem -- lists, copies, deletes and renames the user's own files, and runs a program
	-- refused: NamedPipe -- a pipe is a path, and the other end is another program
	-- refused: PackageFile -- opens an archive by path, and the resource cache is how a game's media arrives
	-- refused: Deserializer -- the base a File is one of, so wrapping it hands over every File method
	-- refused: Serializer -- the same, the writing half
	-- refused: Log -- writes the engine's own log file and can be pointed at a path; buildat.Logger is the log here

	-- Engine, which is the process rather than the scene.
	--
	-- refused: Engine -- exits the process, sets the engine's own parameters and dumps its resources
	-- refused: Console -- an in-engine command line that runs script, which is what the sandbox exists to stop
	-- refused: DebugHud -- draws the engine's own profiler over the game, and a game has no say in it

	-- Core, which is the engine itself.
	--
	-- refused: Context -- the engine context: every subsystem, whitelisted or not, is one GetSubsystem() away
	-- refused: Object -- the base every wrapped class already inherits from, and its SendEvent() reaches events safe_events.lua does not list

	-- And the attribute family, which is one bypass in three shapes: an
	-- attribute is reached by its name as a string, so anything that
	-- animates or writes one reaches every property this file leaves out.
	--
	-- refused: Serializable -- reads and writes any attribute by name, whitelisted or not
	-- refused: ValueAnimation -- the value an attribute takes over time, set by that attribute's name
	-- refused: ObjectAnimation -- a table of those, applied to a node by name

	util.wc("Sprite", {
		inherited_from_by_wrapper = dst.UIElement,
		instance = {
			SetTexture = util.self_function(
					"SetTexture", {}, {"Sprite", "Texture"}),
			SetFixedSize = util.self_function(
					"SetFixedSize", {}, {"Sprite", "number", "number"}),
		},
		properties = {
			-- A Sprite is the one UI element Urho3D turns, which is what a
			-- compass needs: the rotation is in degrees and the hot spot is
			-- the point it turns about, in the sprite's own pixels.
			rotation = util.simple_property("number"),
			hotSpot = util.simple_property(dst.IntVector2),
		},
	})

	util.wc("UI", {
		instance = {
			SetFocusElement = util.wrap_function({"UI", {"UIElement", "__nil"}},
				function(self, element)
					-- **Not off the client's login** ([SEC_SECRET_FOCUS]):
					-- see UIElement:SetFocus
					if magic_sandbox.keys_withheld() and
							not magic_sandbox.is_secret_field(element) then
						return
					end
					if element == nil then
						self:SetFocusElement(nil)
					else
						self:SetFocusElement(element)
					end
				end
			),
			SetScale = util.wrap_function({"UI", "number"},
				function(self, scale)
					__buildat_set_ui_scale(scale)
				end),
			GetScale = util.self_function(
					"GetScale", {"number"}, {"UI"}),
			-- **Putting text on the clipboard, and never taking it off**
			-- ([LAUNCH_CONSOLE]: the document copies out, and a seed or
			-- an address pastes in). Writing is the user's own action --
			-- they selected the text and pressed the key -- while
			-- *reading* the clipboard is a capability of its own: what
			-- is on it is whatever the user last copied anywhere, which
			-- is a password as often as anything, and a sandbox that can
			-- read it can send it. So `SetClipboardText` is here and
			-- `GetClipboardText` is deliberately not, nor a property
			-- that would read as one. **And only right after the user's
			-- key or click** ([SECURITY_RUN_1]): a server's script wrote
			-- it every frame if it liked, the window in the background
			-- included, and what the user then pasted into a terminal was
			-- the script's command (a browser asks the same activation)
			SetClipboardText = util.wrap_function({"UI", "string"},
				function(self, text)
					if not __buildat_user_activated() then
						error("SetClipboardText: only right after the "..
								"user's own key or click")
					end
					self:SetClipboardText(text)
				end),
			-- Whether Urho3D's own Ctrl+C and Ctrl+V in a LineEdit go
			-- through the OS clipboard rather than a copy of its own.
			-- The paste is read by the C++ side into the field the user
			-- has focused; nothing of it reaches this sandbox.
			SetUseSystemClipboard = util.self_function(
					"SetUseSystemClipboard", {}, {"UI", "boolean"}),
		},
		properties = {
			root = util.simple_property(dst.UIElement),
			-- Read-only ([SEC_SECRET_FOCUS]): the focus moves by
			-- SetFocusElement, which keeps it on a secret field
			-- Wrapped as what it is, as GetChild does: a focused field reads
			-- as a LineEdit, its cursor and selection with it ([TEXT_KEYS])
			focusElement = {
				get = function(v)
					if v == nil then
						return nil
					end
					local tn = v:GetTypeName()
					local class = dst[tn]
					if class and getmetatable(class) and getmetatable(class).wrap then
						return util.wrap_instance(tn, v)
					end
					return util.wrap_instance("UIElement", v)
				end,
			},
			scale = {
				get = function(current_value)
					return current_value
				end,
				set = function(new_value)
					if type(new_value) ~= "number" then
						error("UI.scale must be a number")
					end
					__buildat_set_ui_scale(new_value)
					return new_value
				end,
			},
		},
	})

	-- A scripted client (bin/buildat -c) never hides or captures the
	-- cursor. Its mouse_move is injected and relative, so a game loses
	-- nothing; the person whose desktop the run shares keeps their cursor,
	-- which the re-show after a hide used to warp to the window's corner.
	-- See [SCRIPTED_CURSOR] in doc/plan/miscellaneous_plan.md.
	-- **Asked each time, not once at load.** It was read here while the
	-- extensions loaded, which is before a command sequence is up, so
	-- every guard below read false and a scripted run took the cursor
	-- anyway (user, 2026-09-23).
	local function scripted_now()
		return __buildat_is_scripted()
	end
	util.wc("Input", {
		properties = {
			-- **Read-only, and now actually so**: the setter is
			-- SetMouseVisible above, which logs why the cursor changed
			-- and stands down in a scripted run. As a plain property it
			-- was writable, so game code could take the cursor past both
			-- rules -- and did, off a desk the run was sharing with the
			-- person whose mouse it is (user, 2026-09-23).
			mouseVisible = util.read_only_property("boolean"),
		},
		instance = {
			-- The second argument is a word for the log ([FOCUS_LOG]): what
			-- asked for the cursor to change
			SetMouseVisible = util.wrap_function({"Input", "boolean", {"string", "__nil"}},
				function(self, enable, reason)
					if scripted_now() and not enable then
						return
					end
					-- Left false in a scripted run, so init.lua's
					-- click-to-recapture stays inert too
					if util.mouse then
						util.mouse.hide_wanted = not enable
					end
					self:SetMouseChangeReason(reason or "")
					self:SetMouseVisible(enable)
				end),
			SetMouseMode = util.wrap_function({"Input", "number"},
				function(self, mode)
					if scripted_now() and
							(mode == MM_RELATIVE or mode == MM_WRAP) then
						return
					end
					self:SetMouseMode(mode)
				end),
			-- F9 to F12 are the client's ([CLIENT_KEYS]): never down
			GetKeyDown = util.wrap_function({"Input", "number"},
				function(self, key)
					return not __buildat_client_keys[key] and
							not hidden_key(key) and self:GetKeyDown(key)
				end),
			-- Whether shift, ctrl or alt is held (QUAL_*): what GetKeyDown
			-- of those keys says in one call ([V2_TYPING])
			GetQualifierDown = util.wrap_function({"Input", "number"},
				function(self, qualifier)
					return not secret_focus() and self:GetQualifierDown(qualifier)
				end),
			IsMouseVisible = util.self_function("IsMouseVisible", {"boolean"},
					{"Input"}),
			-- Whether the pointer is held: on the web the browser's lock
			-- ([WEB_LOCK_LOST])
			IsMouseLocked = util.self_function("IsMouseLocked", {"boolean"},
					{"Input"}),
			-- A key's name and back, for a bindings file a person can read
			-- ([KEY_BINDINGS])
			GetKeyName = util.self_function("GetKeyName", {"string"}, {"Input", "number"}),
			GetKeyFromName = util.self_function("GetKeyFromName", {"number"}, {"Input", "string"}),
			GetKeyPress = util.wrap_function({"Input", "number"},
				function(self, key)
					return not __buildat_client_keys[key] and
							not hidden_key(key) and self:GetKeyPress(key)
				end),
			-- Still while the trusted overlay is open over a game
			-- ([OVERLAY_DISCUSS]): its cursor is the player's to point with
			GetMouseMove = util.wrap_function({dst.IntVector2}, {"Input"},
				function(self)
					if util.mouse and util.mouse.overlay_open then
						return IntVector2(0, 0)
					end
					return self:GetMouseMove()
				end),
			-- Where the pointer is, in window pixels: what the MouseMove
			-- events add up to, read when a click needs it
			GetMousePosition = util.self_function("GetMousePosition",
					{dst.IntVector2}, {"Input"}),
			-- Whether a mouse button is held, which the click events do not
			-- say: a dig is held down rather than clicked
			GetMouseButtonDown = util.self_function("GetMouseButtonDown",
					{"boolean"}, {"Input", "number"}),
		},
	})

	util.wc("PhysicsWorld", {
		inherited_from_by_wrapper = dst.Component,
	})

	-- Pixels in memory. Added 2026-09-15 for the cube map a game's own six
	-- sky textures make; see [SKY_LEFTOVERS] in doc/plan/master_plan.md.
	--
	-- **What is deliberately not here is every method that names a file.**
	-- Image has SaveBMP, SavePNG, SaveTGA, SaveJPG, SaveDDS, SaveWEBP and
	-- LoadColorLUT, and all of them take a path from their caller: a server's
	-- Lua writing where it likes is the first disqualifier in
	-- [WHITELIST_POLICY]. What is here reads and writes pixels and nothing
	-- else. An image comes from the resource cache, which only looks in the
	-- directories the client registered, or is made empty and filled.
	util.wc("Image", {
		inherited_from_by_wrapper = dst.Resource,
		class = {
			new = function()
				return util.wrap_instance("Image", Image:new())
			end,
		},
		instance = {
			-- components is 1 to 4: luminance, luminance and alpha, rgb, rgba
			SetSize = util.self_function("SetSize", {"boolean"},
					{"Image", "number", "number", "number"}),
			SetPixel = util.self_function("SetPixel", {},
					{"Image", "number", "number", "Color"}),
			-- **The same write without a Colour** ([ROOM_BOOT],
			-- 2026-09-24): a generated tile is four thousand pixels and
			-- the room draws seventy of them at boot, so a Colour an
			-- object a pixel is a quarter of a million allocations
			-- nobody looks at. The integer is 0xAABBGGRR, which is what
			-- Urho3D's Color::ToUInt() packs.
			SetPixelInt = util.self_function("SetPixelInt", {},
					{"Image", "number", "number", "number"}),
			GetPixel = util.self_function("GetPixel", {dst.Color},
					{"Image", "number", "number"}),
			-- Scaled rather than cropped, which is what a cube map face
			-- wants when a game's textures are not all one size
			Resize = util.self_function("Resize", {"boolean"},
					{"Image", "number", "number"}),
			Clear = util.self_function("Clear", {}, {"Image", "Color"}),
			FlipVertical = util.self_function("FlipVertical", {"boolean"},
					{"Image"}),
			FlipHorizontal = util.self_function("FlipHorizontal",
					{"boolean"}, {"Image"}),
		},
		properties = {
			-- All read-only in Urho3D: what the image turned out to be
			width = util.simple_property("number"),
			height = util.simple_property("number"),
			components = util.simple_property("number"),
			compressed = util.simple_property("boolean"),
		},
	})

	-- Six square faces around a point, which is what a sky is drawn on.
	-- SetData sizes the cube from face 0 and refuses a face that does not
	-- match it, so the order is FACE_POSITIVE_X first and every face the
	-- same square.
	util.wc("TextureCube", {
		inherited_from_by_wrapper = dst.Texture,
		class = {
			new = function()
				return util.wrap_instance("TextureCube", TextureCube:new())
			end,
		},
		instance = {
			SetData = util.self_function("SetData", {"boolean"},
					{"TextureCube", "number", "Image"}),
			-- SetSize(size, format, usage): TEXTURE_RENDERTARGET makes the
			-- six faces drawable, each through GetRenderSurface(face)
			SetSize = util.self_function("SetSize", {"boolean"},
					{"TextureCube", "number", "number", "number"}),
			GetRenderSurface = util.wrap_function({"TextureCube", "number"},
				function(self, face)
					return util.wrap_instance("RenderSurface",
							self:GetRenderSurface(face))
				end),
		},
	})

	-- What a ParticleEmitter emits, and the only way to say it: an effect
	-- built here rather than loaded from a resource, because the description
	-- comes over the network. EmitterType is 0 for a sphere and 1 for a box.
	util.wc("ParticleEffect", {
		inherited_from_by_wrapper = dst.Resource,
		class = {
			new = function()
				return util.wrap_instance("ParticleEffect",
						ParticleEffect:new())
			end,
		},
		instance = {
			AddColorTime = util.self_function("AddColorTime", {},
					{"ParticleEffect", "Color", "number"}),
			-- Zero clears the colour frames, for AddColorTime() to set a
			-- new colour: what the live particles are drawn in, as Urho3D
			-- reads the frames on every update. A method, as tolua's
			-- numColorFrames has no setter and a write to it is lost.
			SetNumColorFrames = util.self_function("SetNumColorFrames", {},
					{"ParticleEffect", "number"}),
			-- One frame of a texture animation: the part of the image, and
			-- how many seconds into a particle's life it is shown from
			AddTextureTime = util.self_function("AddTextureTime", {},
					{"ParticleEffect", "Rect", "number"}),
			-- The vector-valued fields are functions rather than properties
			-- because tolua++ generates no setter for a property whose type
			-- is a const reference: Urho3D's own binding registers
			-- ("minDirection", getter, NULL). Assigning the property writes
			-- nowhere and reads back what was assigned, so the effect keeps
			-- Urho3D's defaults and every particle flies off in a random
			-- direction at the default size. Every `const Vector3&` and
			-- `const Vector2&` property in these bindings is like that.
			SetEmitterSize = util.self_function("SetEmitterSize", {},
					{"ParticleEffect", "Vector3"}),
			SetMinDirection = util.self_function("SetMinDirection", {},
					{"ParticleEffect", "Vector3"}),
			SetMaxDirection = util.self_function("SetMaxDirection", {},
					{"ParticleEffect", "Vector3"}),
			SetConstantForce = util.self_function("SetConstantForce", {},
					{"ParticleEffect", "Vector3"}),
			SetMinParticleSize = util.self_function("SetMinParticleSize", {},
					{"ParticleEffect", "Vector2"}),
			SetMaxParticleSize = util.self_function("SetMaxParticleSize", {},
					{"ParticleEffect", "Vector2"}),
		},
		properties = {
			material = util.simple_property(dst.Material),
			numParticles = util.simple_property("number"),
			emitterType = util.simple_property("number"),
			emitterSize = {get = util.simple_property(dst.Vector3).get},
			minDirection = {get = util.simple_property(dst.Vector3).get},
			maxDirection = {get = util.simple_property(dst.Vector3).get},
			constantForce = {get = util.simple_property(dst.Vector3).get},
			dampingForce = util.simple_property("number"),
			activeTime = util.simple_property("number"),
			inactiveTime = util.simple_property("number"),
			minEmissionRate = util.simple_property("number"),
			maxEmissionRate = util.simple_property("number"),
			minParticleSize = {get = util.simple_property(dst.Vector2).get},
			maxParticleSize = {get = util.simple_property(dst.Vector2).get},
			minTimeToLive = util.simple_property("number"),
			maxTimeToLive = util.simple_property("number"),
			minVelocity = util.simple_property("number"),
			maxVelocity = util.simple_property("number"),
			minRotation = util.simple_property("number"),
			maxRotation = util.simple_property("number"),
			minRotationSpeed = util.simple_property("number"),
			maxRotationSpeed = util.simple_property("number"),
			sizeAdd = util.simple_property("number"),
			sizeMul = util.simple_property("number"),
			relative = util.simple_property("boolean"),
			scaled = util.simple_property("boolean"),
			sorted = util.simple_property("boolean"),
			updateInvisible = util.simple_property("boolean"),
		},
	})

	util.wc("Animation", {
		inherited_from_by_wrapper = dst.Resource,
	})

	-- A Sound filled from samples a script made ([SOUND_FROM_SAMPLES]), so
	-- that a generated sound is made once and played by any number of
	-- sources as a loaded one is: new(), SetFormat(), then SetData() once.
	-- Once only, and the format before it: Urho3D frees the old samples on
	-- a new SetData while a source's mixer may be reading them.
	-- simplified: one cap on the samples of all the Sounds alive, for every
	-- sandbox at once (they share these wrappers); per sandbox if one
	-- crowds another out.
	local SOUND_MAX_BYTES = 8 * 1024 * 1024
	local SOUNDS_MAX_BYTES = 64 * 1024 * 1024
	-- Unsafe Sound -> its samples' bytes, gone when the script's wrapper is
	local sound_bytes = setmetatable({}, {__mode = "k"})
	local function sounds_total()
		local n = 0
		for _, b in pairs(sound_bytes) do
			n = n + b
		end
		return n
	end
	util.wc("Sound", {
		inherited_from_by_wrapper = dst.Resource,
		class = {
			new = function()
				return util.wrap_instance("Sound", Sound:new())
			end,
		},
		instance = {
			-- rate in Hz, 1000..96000; 16-bit or 8-bit; stereo or mono
			SetFormat = util.wrap_function(
					{"Sound", "number", "boolean", "boolean"},
					function(self, rate, sixteen_bit, stereo)
						if self.dataSize > 0 then
							error("Sound:SetFormat(): the Sound has its"..
									" samples already; set the format first")
						end
						if rate ~= math.floor(rate) or rate < 1000 or
								rate > 96000 then
							error("Sound:SetFormat(): the rate "..
									tostring(rate).." is not a whole"..
									" 1000..96000")
						end
						self:SetFormat(rate, sixteen_bit, stereo)
					end),
			-- The samples, as SetFormat() said, little-endian: a
			-- VectorBuffer, since tolua cuts a string at its first zero
			SetData = util.wrap_function({"Sound", "VectorBuffer"},
					function(self, buffer)
						if self.dataSize > 0 then
							error("Sound:SetData(): a Sound is filled"..
									" once; make a new one")
						end
						local n = buffer:GetSize()
						if n == 0 or n > SOUND_MAX_BYTES then
							error("Sound:SetData(): "..n.." bytes; a Sound"..
									" holds 1.."..SOUND_MAX_BYTES)
						end
						-- Whole frames: the mixer reads a frame and the
						-- next past a cut one's end, and a looped Sound
						-- shorter than a frame spun the mixer for good
						if n % self.sampleSize ~= 0 then
							error("Sound:SetData(): "..n.." bytes is not"..
									" whole frames of "..self.sampleSize)
						end
						if sounds_total() + n > SOUNDS_MAX_BYTES then
							collectgarbage("collect")
							if sounds_total() + n > SOUNDS_MAX_BYTES then
								error("Sound:SetData(): the Sounds made from"..
										" samples hold "..sounds_total()..
										" bytes, and "..n.." more is over"..
										" the "..SOUNDS_MAX_BYTES)
							end
						end
						-- Copied: tolua knows no Deserializer in a
						-- VectorBuffer, so LoadRaw() does not take it
						self:SetData(buffer:GetData(), n)
						sound_bytes[self] = n
					end),
		},
		properties = {
			looped = util.simple_property("boolean"),
			length = util.simple_property("number"),
			frequency = util.simple_property("number"),
		},
	})

	-- A stream of samples a script makes itself, rather than a Sound loaded
	-- from a file: the mixer thread asks the stream for data as it plays
	-- and the script tops it up ahead of the playhead. See [LAUNCH_WORLD],
	-- whose whole audio is synthesised and has no assets at all.
	util.wc("SoundStream", {
		instance = {
			SetFormat = util.self_function("SetFormat", {},
					{"SoundStream", "number", "boolean", "boolean"}),
		},
		properties = {
			-- Whether playback stops when the stream runs dry; false (the
			-- default) leaves it playing silence, which is what a stream
			-- that is topped up every frame wants -- an underrun is a gap,
			-- not the end of the sound
			stopAtEnd = util.simple_property("boolean"),
			sampleSize = util.simple_property("number"),
			frequency = util.simple_property("number"),
		},
	})

	util.wc("BufferedSoundStream", {
		inherited_from_by_wrapper = dst.SoundStream,
		class = {
			new = function()
				return util.wrap_instance("BufferedSoundStream",
						BufferedSoundStream:new())
			end,
		},
		instance = {
			-- A VectorBuffer of samples rather than a string: tolua puts a
			-- Lua string through const char*, so the first zero byte in a
			-- block of PCM would end it
			AddData = util.self_function("AddData", {},
					{"BufferedSoundStream", "VectorBuffer"}),
			Clear = util.self_function("Clear", {}, {"BufferedSoundStream"}),
		},
		properties = {
			-- How far ahead of the playhead the buffer is filled, which is
			-- what a script tops up against
			bufferLength = util.simple_property("number"),
			bufferNumBytes = util.simple_property("number"),
		},
	})

	util.wc("SoundSource", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			Play = util.self_function(
					"Play", {}, {"SoundSource", {"Sound", "SoundStream"}}),
			Stop = util.self_function("Stop", {}, {"SoundSource"}),
		},
		properties = {
			gain = util.simple_property("number"),
			frequency = util.simple_property("number"),
			panning = util.simple_property("number"),
			soundType = util.simple_property("string"),
			autoRemoveMode = util.simple_property("number"),
			playing = util.simple_property("boolean"),
			-- ms, 20 to 1000, for the next Play() of a stream
			-- ([SKELDAT_BOARD_SOUND_LAG]); checked here as well as clamped
			-- in C++, since tolua casts a NaN to an int before that
			streamBufferLength = {
				get = util.simple_property("number").get,
				set = function(v, what)
					if type(v) ~= "number" or not (v >= 20 and v <= 1000) then
						error((what or "streamBufferLength") ..
								": a number of ms from 20 to 1000", 2)
					end
					return math.floor(v)
				end,
			},
		},
	})

	util.wc("SoundSource3D", {
		inherited_from_by_wrapper = dst.SoundSource,
		properties = {
			nearDistance = util.simple_property("number"),
			farDistance = util.simple_property("number"),
			innerAngle = util.simple_property("number"),
			outerAngle = util.simple_property("number"),
			rolloffFactor = util.simple_property("number"),
		},
	})

	util.wc("SoundListener", {
		inherited_from_by_wrapper = dst.Component,
	})

	-- The engine's clock: how long it has run, this frame's step and its
	-- number. Reads nothing but time, which is the policy's clearest yes
	-- ([URHO_SWEEP]); what wants it is anything paced by wall time rather
	-- than by a scene's own clock -- a reflection cube re-rendered once a
	-- second. Not the static system-time getters: a game has os.time().
	util.wc("Time", {
		instance = {
			GetElapsedTime = util.self_function("GetElapsedTime", {"number"},
					{"Time"}),
		},
		properties = {
			frameNumber = util.simple_property("number"),
			timeStep = util.simple_property("number"),
		},
	})

	util.wc("Audio", {
		instance = {
			-- Urho3D multiplies a type's gain by the "Master" one, so the
			-- master is the user's volume preference and not a game's to
			-- write. "Effect", "Music", "Ambient" and "Voice" are what a
			-- game's own mixing is for, and they multiply under it.
			SetMasterGain = util.wrap_function(
					{"Audio", "string", "number"},
					function(self, type_name, gain)
						if type_name == "Master" then
							error("Audio:SetMasterGain(\"Master\") is the"..
									" client's volume preference; use a sound"..
									" type such as \"Effect\" or \"Music\"")
						end
						self:SetMasterGain(type_name, gain)
					end),
			Play = util.self_function("Play", {"boolean"}, {"Audio"}),
			Stop = util.self_function("Stop", {}, {"Audio"}),
		},
		properties = {
			listener = util.simple_property({dst.SoundListener, "__nil"}),
			playing = util.simple_property("boolean"),
			-- [SKELDAT_BOARD_SOUND_FAULT] The device buffer obtained and a
			-- mixing fragment, ms: a stream's queue must outrun the first
			bufferLengthMs = util.read_only_property("number"),
			fragmentLengthMs = util.read_only_property("number"),
		},
	})

	util.wc("Billboard", {
		properties = {
			position = util.simple_property(dst.Vector3),
			size = util.simple_property(dst.Vector2),
			-- The part of the texture drawn, 0..1: a sprite sheet's frame
			uv = util.simple_property(dst.Rect),
			color = util.simple_property(dst.Color),
			rotation = util.simple_property("number"),
			enabled = util.simple_property("boolean"),
		},
	})

	util.wc("BillboardSet", {
		inherited_from_by_wrapper = dst.Drawable,
		instance = {
			Commit = util.self_function("Commit", {}, {"BillboardSet"}),
			GetBillboard = util.wrap_function({"BillboardSet", "number"},
				function(self, index)
					local b = self:GetBillboard(index)
					if b == nil then
						return nil
					end
					return util.wrap_instance("Billboard", b)
				end
			),
		},
		properties = {
			material = util.simple_property(dst.Material),
			numBillboards = util.simple_property("number"),
			sorted = util.simple_property("boolean"),
			relative = util.simple_property("boolean"),
			faceCameraMode = util.simple_property("number"),
		},
	})

	util.wc("ParticleEmitter", {
		inherited_from_by_wrapper = dst.BillboardSet,
		instance = {
			Reset = util.self_function("Reset", {}, {"ParticleEmitter"}),
			-- Magic's floor map (doc/client_api.txt): where falling
			-- particles stop or go, by node column
			SetFloorMap = util.self_function("SetFloorMap", {},
					{"ParticleEmitter", "number", "number", "boolean"}),
			SetFloorOrigin = util.self_function("SetFloorOrigin", {},
					{"ParticleEmitter", "number", "number"}),
			SetFloorHeight = util.self_function("SetFloorHeight", {},
					{"ParticleEmitter", "number", "number", "number"}),
		},
		properties = {
			effect = util.simple_property(dst.ParticleEffect),
			emitting = util.simple_property("boolean"),
			numParticles = util.simple_property("number"),
		},
	})

	util.wc("Skybox", {
		inherited_from_by_wrapper = dst.StaticModel,
	})

	-- A model's bones ([URHO_SWEEP]'s Graphics batch, 2026-09-25), which
	-- is what hanging a thing off a hand wants: a Bone carries the scene
	-- node the skin drives, so a game parents its own node to that node
	-- and the engine moves it. [OVER_SHOULDER] put the wielded item at
	-- the player's feet for want of exactly this.
	--
	-- simplified: reading, and the node. A bone's offset matrix, its
	-- bounding shape and the skinning flags are the model's own business
	-- and no game here sets them.
	--
	-- **A bone is read, not wrapped** ([SECURITY_RUN_1]): a Bone is a place
	-- in its skeleton's vector, which a new model -- the game's, or the
	-- server's replicated attribute -- puts somewhere else, and a wrapper
	-- of one read freed memory. What a game wants of it is copied out; the
	-- node is a wrapper of its own and held.
	local function read_bone(b)
		if b == nil then
			return nil
		end
		return {name = b.name, parentIndex = b.parentIndex,
				animated = b.animated, node = util.wrap_instance("Node", b.node)}
	end
	util.wc("Skeleton", {
		instance = {
			GetNumBones = util.self_function("GetNumBones", {"number"},
					{"Skeleton"}),
			GetRootBone = util.wrap_function({{"table", "__nil"}}, {"Skeleton"},
			function(self)
				return read_bone(self:GetRootBone())
			end),
			-- By name or by index, which is what Urho3D offers and what a
			-- game asks with: "Hand_R" from a model's own rig, or a walk
			-- over the count
			GetBone = util.wrap_function({{"table", "__nil"}},
					{"Skeleton", {"string", "number"}},
			function(self, which)
				return read_bone(self:GetBone(which))
			end),
		},
		properties = {
			numBones = util.simple_property("number"),
			rootBone = {get = function(b) return read_bone(b) end},
		},
	})

	util.wc("AnimatedModel", {
		inherited_from_by_wrapper = dst.StaticModel,
		properties = {
			-- Readonly in Urho3D and a reference: what comes back follows
			-- the model, so it is asked for again rather than kept. It is
			-- a part of the model, so its wrapper keeps the model's.
			skeleton = {get = function(v, model)
				local skeleton = util.wrap_instance("Skeleton", v)
				if skeleton then
					getmetatable(skeleton).model = model
				end
				return skeleton
			end},
		},
	})

	util.wc("AnimationController", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			Play = util.wrap_function({"boolean"},
					{"AnimationController", "string", "number", "boolean",
							{"number", "__nil"}},
				function(self, name, layer, looped, fade)
					if fade ~= nil then
						return self:Play(name, layer, looped, fade)
					end
					return self:Play(name, layer, looped)
				end
			),
			Stop = util.wrap_function({"boolean"},
					{"AnimationController", "string", {"number", "__nil"}},
				function(self, name, fade)
					if fade ~= nil then
						return self:Stop(name, fade)
					end
					return self:Stop(name)
				end
			),
			SetSpeed = util.self_function(
					"SetSpeed", {"boolean"},
					{"AnimationController", "string", "number"}),
			IsPlaying = util.self_function(
					"IsPlaying", {"boolean"},
					{"AnimationController", "string"}),
		},
	})

	util.wc("RibbonTrail", {
		inherited_from_by_wrapper = dst.Drawable,
		properties = {
			material = util.simple_property(dst.Material),
			vertexDistance = util.simple_property("number"),
			width = util.simple_property("number"),
			startColor = util.simple_property(dst.Color),
			endColor = util.simple_property(dst.Color),
			startScale = util.simple_property("number"),
			endScale = util.simple_property("number"),
			trailType = util.simple_property("number"),
			lifetime = util.simple_property("number"),
			emitting = util.simple_property("boolean"),
			sorted = util.simple_property("boolean"),
		},
	})

	dst.cache = util.wrap_instance("ResourceCache", cache)
	dst.renderer = util.wrap_instance("Renderer", renderer)
	dst.graphics = util.wrap_instance("Graphics", graphics)
	dst.ui = util.wrap_instance("UI", ui)
	dst.input = util.wrap_instance("Input", input)
	dst.time = util.wrap_instance("Time", time)
	if audio ~= nil then
		dst.audio = util.wrap_instance("Audio", audio)
	end
end

return M
-- vim: set noet ts=4 sw=4:
