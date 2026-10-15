-- Buildat: extension/sandbox_test/wrapped.lua
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- **What the whitelist lets through, exercised** ([URHO_SWEEP]). The
-- hostile boot beside this says what cannot be reached; this says that
-- what was wrapped works -- **a class added to the whitelist with a
-- property missing silently does nothing**, which is the fault the
-- sweep exists to avoid, and it is found here rather than in a game.
--
-- Run from M.boot() in the sandbox, so everything here is sandboxed
-- code: extensions/sandbox_test/check.sh reads the line it logs.
local log = buildat.Logger("wrapped")
local urho3d = require("buildat/core/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe

-- Matrix3x4 (2026-09-22): a transform built, taken apart and applied
do
	local m = magic.Matrix3x4(magic.Vector3(1, 2, 3),
			magic.Quaternion(90, magic.Vector3(0, 1, 0)), 2)
	local t = m:Translation()
	assert(math.abs(t.x - 1) < 1e-4 and math.abs(t.y - 2) < 1e-4 and
			math.abs(t.z - 3) < 1e-4)
	assert(math.abs(m:Scale().x - 2) < 1e-4)
	-- Rotation 90 about Y takes +X to -Z; scaled by 2 and moved
	local p = m * magic.Vector3(1, 0, 0)
	assert(math.abs(p.x - 1) < 1e-3 and math.abs(p.z - (3 - 2)) < 1e-3,
			"Matrix3x4 * Vector3: " .. p.x .. ", " .. p.y .. ", " .. p.z)
	local back = m:Inverse() * p
	assert(math.abs(back.x - 1) < 1e-3 and math.abs(back.z) < 1e-3)
	local id = m * m:Inverse()
	assert(id:Translation():Length() < 1e-3 and
			math.abs(id:Scale().x - 1) < 1e-3)
end

-- Matrix3 and Matrix4 (2026-09-25, [URHO_SWEEP]'s Math batch): the
-- rotation without a translation and the projective one a shader
-- parameter takes -- built, multiplied, transposed, inverted and read
-- element by element
do
	-- A rotation of 90 degrees about Y, written out: +X goes to -Z
	local r = magic.Matrix3(0, 0, 1,
			0, 1, 0,
			-1, 0, 0)
	local v = r * magic.Vector3(1, 0, 0)
	assert(math.abs(v.x) < 1e-4 and math.abs(v.z + 1) < 1e-4,
			"Matrix3 * Vector3: " .. v.x .. ", " .. v.y .. ", " .. v.z)
	-- A rotation's inverse is its transpose, and the product is identity
	local id = r * r:Transpose()
	assert(math.abs(id.m00 - 1) < 1e-4 and math.abs(id.m01) < 1e-4 and
			math.abs(id.m22 - 1) < 1e-4, "Matrix3 identity: " .. id:ToString())
	assert(r:Inverse():Equals(r:Transpose()), "a rotation inverts by transpose")
	assert(math.abs(r:Scaled(magic.Vector3(2, 2, 2)).m02 - 2) < 1e-4)

	-- The four-row one, from the three plus a translation
	local m = magic.Matrix4(r)
	m:SetTranslation(magic.Vector3(5, 6, 7))
	local t = m:Translation()
	assert(math.abs(t.x - 5) < 1e-4 and math.abs(t.z - 7) < 1e-4)
	assert(m:ToMatrix3():Equals(r), "the rotation comes back out whole")
	-- A point through it, and back through its inverse
	local p = m * magic.Vector3(1, 0, 0)
	assert(math.abs(p.x - 5) < 1e-3 and math.abs(p.z - 6) < 1e-3,
			"Matrix4 * Vector3: " .. p.x .. ", " .. p.y .. ", " .. p.z)
	local back = m:Inverse() * p
	assert(math.abs(back.x - 1) < 1e-3 and math.abs(back.z) < 1e-3)
	-- And a Vector4, which is the one a shader parameter is
	local h = m * magic.Vector4(0, 0, 0, 1)
	assert(math.abs(h.x - 5) < 1e-3 and math.abs(h.w - 1) < 1e-3,
			"Matrix4 * Vector4 carries the translation")
	assert(math.abs(m.m03 - 5) < 1e-4 and math.abs(m.m33 - 1) < 1e-4,
			"Matrix4 elements: " .. m:ToString())
	log:info("wrapped: the matrices multiply, transpose and invert")
end

-- Constraint (2026-09-25, [URHO_SWEEP]'s Physics batch): two bodies in a
-- scene of this file's own, joined by a hinge, with the places and the
-- limits read back
do
	local scene = magic.Scene()
	scene:CreateComponent("Octree")
	assert(scene:CreateComponent("PhysicsWorld"), "the scene takes physics")
	local a = scene:CreateChild("anchor")
	local b = scene:CreateChild("swinging")
	assert(a:CreateComponent("RigidBody") and b:CreateComponent("RigidBody"))
	local c = b:CreateComponent("Constraint")
	assert(c, "a node takes a Constraint")
	c.constraintType = magic.CONSTRAINT_HINGE
	c.otherBody = a:GetComponent("RigidBody")
	c.position = magic.Vector3(0, 1, 0)
	c.axis = magic.Vector3(0, 0, 1)
	c.lowLimit = magic.Vector2(-45, 0)
	c.highLimit = magic.Vector2(45, 0)
	c.disableCollision = true
	assert(c.constraintType == magic.CONSTRAINT_HINGE, "the hinge is a hinge")
	assert(c.otherBody ~= nil, "the other body is the anchor's")
	assert(math.abs(c.position.y - 1) < 1e-4, "the place on the body")
	assert(math.abs(c.lowLimit.x + 45) < 1e-4 and
			math.abs(c.highLimit.x - 45) < 1e-4, "the limits")
	assert(c.disableCollision, "and the pair does not collide with itself")
	c:SetWorldPosition(magic.Vector3(2, 3, 4))
	local w = c:GetWorldPosition()
	assert(math.abs(w.x - 2) < 1e-3 and math.abs(w.z - 4) < 1e-3,
			"a world place comes back: " .. w.x .. ", " .. w.y .. ", " .. w.z)
	log:info("wrapped: a hinge joins two bodies and says where it is")
end

-- Skeleton and Bone (2026-09-25, [URHO_SWEEP]'s Graphics batch): an
-- animated model's rig, which is what hanging a thing off a hand wants
do
	local scene = magic.Scene()
	scene:CreateComponent("Octree")
	local n = scene:CreateChild("rigged")
	local am = n:CreateComponent("AnimatedModel")
	assert(am, "a node takes an AnimatedModel")
	local sk = am.skeleton
	assert(sk, "the model hands back a skeleton")
	-- Without a model there are no bones, and asking is still an answer
	-- rather than a raise -- which is what a game does on a model whose
	-- rig it has not read yet
	assert(sk:GetNumBones() == 0 and sk.numBones == 0,
			"an empty model has no bones")
	assert(sk:GetBone("Hand_R") == nil, "and no bone by that name")
	assert(sk:GetRootBone() == nil, "and no root")
	-- A rig, then another model and the node gone ([SECURITY_RUN_1]): a
	-- bone is copied out and the skeleton keeps its model, so what the
	-- script holds stays readable where it read freed memory
	am.model = magic.cache:GetResource("Model", "Models/Jack.mdl")
	sk = am.skeleton
	local bone = sk:GetBone(1)
	assert(bone and bone.name ~= "" and bone.node, "Jack has bones")
	am.model = magic.cache:GetResource("Model", "Models/Box.mdl")
	n:Remove()
	assert(bone.name ~= "" and sk:GetNumBones() == 0,
			"a bone read and a skeleton kept outlive the model's change")
	log:info("wrapped: a model's skeleton answers about its bones")
end

-- XMLElement (2026-09-25): a document out of the resource cache walked
-- -- the root, its children, an attribute and a number
do
	local f = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")
	assert(f, "the style file is in the cache")
	local root = f:GetRoot()
	assert(root:NotNull() and not root:IsNull(), "the root is there")
	assert(root:GetName() == "elements",
			"the root is <elements>: " .. root:GetName())
	local e = root:GetChild("element")
	assert(e:NotNull(), "the first element")
	assert(e:HasAttribute("type"), "an element says what type it is")
	assert(#e:GetAttribute("type") > 0, "and the attribute reads back")
	local n = 0
	while e:NotNull() do
		n = n + 1
		e = e:GetNext("element")
	end
	assert(n > 1, "the style has several elements: " .. n)
	log:info("wrapped: " .. n .. " elements under <" .. root:GetName() .. ">")
end

-- DebugRenderer (2026-09-25): a scene of this file's own, the component
-- on it, and the shapes a game draws with -- what is asserted is that
-- each call reaches the engine and comes back, the drawing itself being
-- a frame's business and nobody's to read here
do
	local scene = magic.Scene()
	scene:CreateComponent("Octree")
	local dbg = scene:CreateComponent("DebugRenderer")
	assert(dbg, "the scene takes a DebugRenderer")
	dbg:SetLineAntiAlias(true)
	local a, b = magic.Vector3(0, 0, 0), magic.Vector3(1, 2, 3)
	local white = magic.Color(1, 1, 1, 1)
	dbg:AddLine(a, b, white)
	dbg:AddTriangle(a, b, magic.Vector3(0, 1, 0), white, false)
	dbg:AddCross(b, 0.5, white)
	dbg:AddCircle(a, magic.Vector3(0, 1, 0), 2.0, white)
	dbg:AddSphere(magic.Sphere(b, 1.5), white)
	dbg:AddBoundingBox(magic.BoundingBox(a, b), white)
	dbg:AddNode(scene:CreateChild("marked"), 1.0, true)
	log:info("wrapped: the debug renderer took every shape")
end

-- Cursor:DefineShape (2026-09-25): a game's own cursor art, which was
-- off the whitelist only because Image was. The cursor made here is
-- never given to the UI, so nothing on the screen changes.
do
	-- **Out of the resource cache, not built here**: an Image the
	-- sandbox made is owned by Lua, and DefineShape hands it to a
	-- SharedPtr that frees it under the collector -- a segfault in
	-- RefCounted (2026-09-25). A game's cursor is a file it ships.
	local img = magic.cache:GetResource("Image", "launch_menu/res/icon_local.png")
	assert(img, "the image is in the cache")
	local c = magic.ui.root:CreateChild("Cursor")
	c:DefineShape("Normal", img, magic.IntRect(0, 0, 16, 16),
			magic.IntVector2(0, 0))
	-- And an image the sandbox made is refused rather than crashing
	local own = magic.Image:new()
	assert(own:SetSize(4, 4, 4), "a four by four image")
	local ok = pcall(function()
		c:DefineShape("Normal", own, magic.IntRect(0, 0, 4, 4),
				magic.IntVector2(0, 0))
	end)
	assert(not ok, "an image built in the sandbox is refused")
	c:Remove()
	log:info("wrapped: a cursor shape came off a game's own image")
end

-- VariantMap:GetPtr ([SECURITY_RUN_1], 2026-10-03): a Ptr comes back
-- as what it is or a base of it. Variant:GetPtr() casts to the name it
-- is given, and a Node read as a UIElement had its methods reading
-- past the Node (found by util/fuzz/sandbox_fuzz.lua)
do
	local scene = magic.Scene()
	local vm = magic.VariantMap()
	vm:SetPtr("n", scene:CreateChild("x"))
	assert(vm:GetPtr("Node", "n"), "a Node reads back as a Node")
	vm:SetPtr("s", scene)
	assert(vm:GetPtr("Node", "s"), "a Scene reads back as a Node")
	assert(not pcall(vm.GetPtr, vm, "UIElement", "n"),
			"a Node does not read back as a UIElement")
	assert(not pcall(vm.GetPtr, vm, "Scene", "n"),
			"a Node does not read back as a Scene")
	log:info("wrapped: a Ptr reads back only as its own class or a base")
end

-- A wrapper keeps its object ([SECURITY_RUN_1], 2026-10-04): a cloned
-- RenderPath is the viewport's to free, and a call through a wrapper of
-- one it let go of used freed memory (util/fuzz/game_fuzz.sh, under ASan)
do
	local scene = magic.Scene()
	local camera = scene:CreateChild("c"):CreateComponent("Camera")
	local viewport = magic.Viewport:new(scene, camera)
	local path = viewport.renderPath:Clone()
	viewport.renderPath = path
	viewport.renderPath = path:Clone()
	assert(path:GetNumCommands() > 0, "the path let go of is still there")
	path:SetShaderParameter("x", 1)
	-- A command is a place in the path's vector, which Append moves
	local command = path:GetCommand(0)
	assert(command.type, "a command reads")
	path:Append(magic.cache:GetResource("XMLFile", "PostProcess/FXAA2.xml"))
	local ok, err = pcall(function() return command.type end)
	assert(not ok and tostring(err):find("moved"),
			"a command from before an Append is dead: " .. tostring(err))
	assert(path:GetCommand(0).type, "and asked for again it reads")
	log:info("wrapped: a RenderPath its viewport let go of is still there")
end

-- buildat.parse_json (2026-09-25): the shapes a fetched body arrives in
do
	local v = buildat.parse_json(
			'{"a": 1, "b": [true, "two", 3.5], "c": {"d": null}}')
	assert(type(v) == "table", "an object is a table")
	assert(v.a == 1, "a number")
	assert(type(v.b) == "table" and #v.b == 3, "an array is a list")
	assert(v.b[1] == true and v.b[2] == "two" and
			math.abs(v.b[3] - 3.5) < 1e-9, "the array's three values")
	assert(type(v.c) == "table" and v.c.d == nil, "null is nothing")
	local bad, why = buildat.parse_json("{not json")
	assert(bad == nil and type(why) == "string", "a bad document says so")
	assert(buildat.parse_json("[]") ~= nil, "an empty array parses")
	log:info("wrapped: json parses to plain Lua, and says no to rubbish")
end

-- A mesh built from Lua (2026-09-25): one triangle, its vertices and
-- indices written into VectorBuffers, the geometry and the model made
-- here and hung on a node -- which is [OBJECT_ANIM]'s road and the fast
-- way past CustomGeometry's one call per vertex
do
	local vb = magic.VertexBuffer:new()
	assert(vb:SetSize(3, magic.MASK_POSITION + magic.MASK_NORMAL, false),
			"three vertices of position and normal")
	local v = magic.VectorBuffer.new()
	local tri = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}
	for _, p in ipairs(tri) do
		v:WriteFloat(p[1]); v:WriteFloat(p[2]); v:WriteFloat(p[3])
		v:WriteFloat(0); v:WriteFloat(0); v:WriteFloat(-1)
	end
	assert(vb:SetData(v), "the vertices go in")
	assert(vb.vertexCount == 3, "three vertices: " .. vb.vertexCount)

	local ib = magic.IndexBuffer:new()
	assert(ib:SetSize(3, false, false), "three 16-bit indices")
	local iv = magic.VectorBuffer.new()
	iv:WriteShort(0); iv:WriteShort(1); iv:WriteShort(2)
	assert(ib:SetData(iv), "the indices go in")
	assert(ib.indexCount == 3, "three indices: " .. ib.indexCount)

	local geom = magic.Geometry:new()
	assert(geom:SetNumVertexBuffers(1), "one vertex buffer")
	assert(geom:SetVertexBuffer(0, vb), "the buffer goes on")
	geom:SetIndexBuffer(ib)
	assert(geom:SetDrawRange(magic.TRIANGLE_LIST, 0, 3), "one triangle")
	assert(geom.indexCount == 3, "the range is three indices")

	local model = magic.Model:new()
	model:SetNumGeometries(1)
	assert(model:SetGeometry(0, 0, geom), "the geometry goes in")
	model:SetBoundingBox(magic.BoundingBox(magic.Vector3(0, 0, 0),
			magic.Vector3(1, 1, 0)))
	assert(model:GetNumGeometries() == 1, "one geometry")

	-- And a drawable takes it, which is the whole point
	local scene = magic.Scene()
	scene:CreateComponent("Octree")
	local node = scene:CreateChild("built")
	local sm = node:CreateComponent("StaticModel")
	sm.model = model
	assert(sm.model, "the static model wears what was built")
	log:info("wrapped: a mesh built from Lua hangs on a node")
end

-- [SANDBOX_API_AUDIT]: a rotation applied to a vector, and the focus
-- found under an element
do
	local v = magic.Quaternion(90, magic.Vector3(0, 1, 0)) *
			magic.Vector3(1, 0, 0)
	assert(math.abs(v.x) < 1e-4 and math.abs(v.z + 1) < 1e-4,
			"a quaternion turns a vector: " .. v.x .. " " .. v.z)
	local outer = magic.ui.root:CreateChild("UIElement")
	local inner = outer:CreateChild("Button")
	inner:SetFocusMode(magic.FM_FOCUSABLE)
	inner:SetFocus(true)
	assert(outer:HasRecursiveFocus() and not outer:HasFocus(),
			"the focus found under an element")
	outer:Remove()
	log:info("wrapped: a quaternion turns a vector; the focus under an element")
end

-- [VECTOR_NAMES]: a buildat.Vector3's Urho3D names give what the old ones
-- do; one is taken where a Vector3 goes, and a table without z is refused
-- with what it was for named
do
	local a, b = buildat.Vector3(3, 4.6, 0), buildat.Vector3(1, 2, 3)
	assert(a:Length() == a:length() and a:Length() == math.sqrt(9 + 4.6^2))
	assert(a:Floor() == a:floor() and a:Round() == a:round())
	assert(a:Floor():Equals(buildat.Vector3(3, 4, 0)) and a:eq(a))
	assert(a * b == a:mul_components(b) and a / b == a:div_components(b))
	assert(a * 2 == a:mul(2) and a / 2 == a:div(2))
	assert(b:DotProduct(b) == 14)
	assert(buildat.Vector3(1, 0, 0):CrossProduct(buildat.Vector3(0, 1, 0)) ==
			buildat.Vector3(0, 0, 1))
	assert(math.abs(a:Normalized():Length() - 1) < 1e-9)
	assert(buildat.Vector3(0, 0, 0):Normalized() == buildat.Vector3(0, 0, 0))
	local c = buildat.Vector2(3, 4)
	assert(c:Length() == 5 and c * c == buildat.Vector2(9, 16) and
			c:DotProduct(c) == 25)
	local scene = magic.Scene()
	local n1, n2 = scene:CreateChild("a"), scene:CreateChild("b")
	n1.position = magic.Vector3(1, 2, 3)
	n2.position = b
	assert(n2.position.x == n1.position.x and n2.position.y == 2 and
			n2.position.z == 3, "a buildat.Vector3 as a node's position")
	n2:Translate({x = 3, y = 3, z = 3})
	assert(n2.position.z == 6, "a plain table to Translate")
	local ok, err = pcall(function() n2.position = {x = 1, y = 2} end)
	assert(not ok and tostring(err):find("Node.position", 1, true) and
			tostring(err):find("needs numeric x, y and z", 1, true),
			"a table without z: " .. tostring(err))
	local ok2, err2 = pcall(function() n2:Translate({x = 1}) end)
	assert(not ok2 and tostring(err2):find("argument 2", 1, true),
			"Translate with no y: " .. tostring(err2))
	scene:Remove()
	log:info("wrapped: the table vectors' names, and one where a Vector3 goes")
end

return true
