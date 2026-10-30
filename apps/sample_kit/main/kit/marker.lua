-- A marker: a place others refer to (a spawn point, a target), with no
-- behaviour and nothing to see in play; its gizmo shows it in edit mode
return {
	version = 1,
	params = {label = {type = "string", default = ""}},
	gizmo = {shape = "sphere", size = 0.4, color = "#40e0ff"},
}
