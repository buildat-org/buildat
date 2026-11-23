-- stunt_barrel's client part: the barrel under e.node (its movement's place:
-- half a cell over the feet, the road's top 0.45 under it), a red drum, two
-- dark hoops and a yellow lid
local magic = require("buildat/extension/urho3d")
local kit = require("buildat/module/kit")

local function box(parent, y, size, mat)
	local n = parent:CreateChild("barrel part")
	n.position, n.scale = magic.Vector3(0, y, 0), size
	local m = n:CreateComponent("StaticModel")
	m.model = magic.cache:GetResource("Model", "Models/Box.mdl")
	m.material = mat
	m.castShadows = true
	m.drawDistance = 170
	return n
end

local drums = {}
return {
	on_add = function(e)
		local root = e.node:CreateChild("barrel")
		local red, hoop = kit.material("#b8321e"), kit.material("#2a2622")
		box(root, 0.1, magic.Vector3(0.86, 1.1, 0.86), red)
		box(root, 0.1, magic.Vector3(1.0, 0.86, 0.7), red)
		box(root, 0.1, magic.Vector3(0.7, 0.86, 1.0), red)
		box(root, -0.2, magic.Vector3(0.9, 0.08, 0.9), hoop)
		box(root, 0.4, magic.Vector3(0.9, 0.08, 0.9), hoop)
		box(root, 0.65, magic.Vector3(0.72, 0.02, 0.72), kit.material("#e8c020"))
		drums[e.id] = root
	end,
	on_remove = function(e)
		if drums[e.id] then
			drums[e.id]:Remove()
		end
		drums[e.id] = nil
	end,
}
