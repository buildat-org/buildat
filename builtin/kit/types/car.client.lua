-- kit/car's client part ([KIT] stage 4h): four wheels under its box
local magic = require("buildat/extension/urho3d")

return {
	on_update = function(e)
		if not e.look or e.wheels_on == e.look then
			return
		end
		e.wheels_on = e.look
		local mat = magic.Material:new()
		mat:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/NoTexture.xml"))
		mat:SetShaderParameter("MatDiffColor", magic.Color(0.12, 0.12, 0.12))
		for _, c in ipairs({{0.95, 1.3}, {-0.95, 1.3}, {0.95, -1.3},
				{-0.95, -1.3}}) do
			local n = e.look:CreateChild("Wheel")
			n.position = magic.Vector3(c[1], -0.5, c[2])
			n.rotation = magic.Quaternion(0, 0, 90)
			n.scale = magic.Vector3(0.7, 0.3, 0.7)
			local m = n:CreateComponent("StaticModel")
			m.model = magic.cache:GetResource("Model", "Models/Cylinder.mdl")
			m.material = mat
			m.castShadows = true
		end
	end,
}
