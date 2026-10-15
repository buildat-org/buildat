-- Buildat: extension/urho3d/safe_events.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>

return {
	Update = {
		TimeStep = {variant = "Float", safe = "number"},
	},
	PostRenderUpdate = {
		TimeStep = {variant = "Float", safe = "number"},
	},
	-- The client is going away: the window was closed, or something asked
	-- the engine to exit. It carries nothing; what it is for is closing what
	-- a module opened, such as telling a server that we are leaving.
	ExitRequested = {},
	KeyDown = {
		Key = {variant = "Int", safe = "number"},
		-- True when this is a key repeat rather than a fresh press
		Repeat = {variant = "Bool", safe = "boolean"},
		-- Which modifiers were held: shift 1, ctrl 2, alt 4, summed.
		-- A shortcut wants this rather than the two control keys' own
		-- states, and it says nothing the key itself does not
		-- ([LAUNCH_CONSOLE]: Ctrl+C copies the line it is pointing at).
		Qualifiers = {variant = "Int", safe = "number"},
	},
	KeyUp = {
		Key = {variant = "Int", safe = "number"},
	},
	-- What a key typed, as the layout and shift make it ([V2_TYPING]):
	-- "_" from Shift+"-" on a Finnish keyboard, which KeyDown's key code
	-- cannot say. Nothing KeyDown does not already tell; withheld in a
	-- secret field as KeyDown is (urho3d/init.lua).
	TextInput = {
		Text = {variant = "String", safe = "string"},
	},
	-- The window gained or lost input focus ([FOCUS_LOG]): what the
	-- mouse's capture follows
	InputFocus = {
		Focus = {variant = "Bool", safe = "boolean"},
	},
	-- Fingers on a touchscreen ([FP_TOUCH]): which one, and where in the
	-- window's pixels. The first finger is also the left mouse button,
	-- which SDL makes of it, so the UI and a tap work without these.
	TouchBegin = {
		TouchID = {variant = "Int", safe = "number"},
		X = {variant = "Int", safe = "number"},
		Y = {variant = "Int", safe = "number"},
	},
	TouchMove = {
		TouchID = {variant = "Int", safe = "number"},
		X = {variant = "Int", safe = "number"},
		Y = {variant = "Int", safe = "number"},
		DX = {variant = "Int", safe = "number"},
		DY = {variant = "Int", safe = "number"},
	},
	TouchEnd = {
		TouchID = {variant = "Int", safe = "number"},
		X = {variant = "Int", safe = "number"},
		Y = {variant = "Int", safe = "number"},
	},
	MouseButtonDown = {
		Button = {variant = "Int", safe = "number"},
		Buttons = {variant = "Int", safe = "number"},
		Qualifiers = {variant = "Int", safe = "number"},
	},
	MouseButtonUp = {
		Button = {variant = "Int", safe = "number"},
		Buttons = {variant = "Int", safe = "number"},
		Qualifiers = {variant = "Int", safe = "number"},
	},
	-- A click on the UI, which carries where it landed. MouseButtonDown does
	-- not: the position of a click is the UI's business, and a game that has
	-- put something on screen needs to know where in it the player clicked.
	-- The element that was hit is deliberately not passed on.
	UIMouseClick = {
		X = {variant = "Int", safe = "number"},
		Y = {variant = "Int", safe = "number"},
		Button = {variant = "Int", safe = "number"},
		Buttons = {variant = "Int", safe = "number"},
		Qualifiers = {variant = "Int", safe = "number"},
	},
	MouseMove = {
		X = {variant = "Int", safe = "number"},
		Y = {variant = "Int", safe = "number"},
		DX = {variant = "Int", safe = "number"},
		DY = {variant = "Int", safe = "number"},
		Buttons = {variant = "Int", safe = "number"},
		Qualifiers = {variant = "Int", safe = "number"},
	},
	MouseWheel = {
		Wheel = {variant = "Int", safe = "number"},
		Buttons = {variant = "Int", safe = "number"},
		Qualifiers = {variant = "Int", safe = "number"},
	},
	-- The window's size or fullscreen state changed. What wants to know is
	-- anything that put something on the GPU by hand: Urho3D can bring back
	-- what it loaded from a file, and nothing else.
	ScreenMode = {
		Width = {variant = "Int", safe = "number"},
		Height = {variant = "Int", safe = "number"},
		Fullscreen = {variant = "Bool", safe = "boolean"},
		Resizable = {variant = "Bool", safe = "boolean"},
		Borderless = {variant = "Bool", safe = "boolean"},
	},
	HoverBegin = {
	},
	HoverEnd = {
	},
	-- A button pressed down and let go: a touchscreen's held buttons
	-- (apps/vanilla's Jump and Sneak) are held between the two
	Pressed = {
	},
	Released = {
	},
	TextFinished = {
	},
	-- A field's text changed as it is typed ([ONE_FOCUS]: a filter that
	-- filters as it is typed); the handler reads the field
	TextChanged = {
	},
	-- An element losing the UI's focus: a field left by a click elsewhere
	Defocused = {
	},
	-- And gaining it: a form's field drawn in its focused colour
	Focused = {
	},
	-- What the scrolling family says happened; see the classes of the same
	-- name in safe_classes.lua. Element is the list, the bar or the slider
	-- it happened to.
	ItemSelected = {
		Element = {variant = "Ptr", safe = "UIElement"},
		Selection = {variant = "Int", safe = "number"},
	},
	ItemDeselected = {
		Element = {variant = "Ptr", safe = "UIElement"},
		Selection = {variant = "Int", safe = "number"},
	},
	SelectionChanged = {
		Element = {variant = "Ptr", safe = "UIElement"},
	},
	-- A menu's own item was chosen, which for a DropDownList arrives
	-- alongside ItemSelected
	MenuSelected = {
		Element = {variant = "Ptr", safe = "UIElement"},
	},
	ItemClicked = {
		Element = {variant = "Ptr", safe = "UIElement"},
		Item = {variant = "Ptr", safe = "UIElement"},
		Selection = {variant = "Int", safe = "number"},
		Button = {variant = "Int", safe = "number"},
	},
	ItemDoubleClicked = {
		Element = {variant = "Ptr", safe = "UIElement"},
		Item = {variant = "Ptr", safe = "UIElement"},
		Selection = {variant = "Int", safe = "number"},
		Button = {variant = "Int", safe = "number"},
	},
	SliderChanged = {
		Element = {variant = "Ptr", safe = "UIElement"},
		Value = {variant = "Float", safe = "number"},
	},
	ScrollBarChanged = {
		Element = {variant = "Ptr", safe = "UIElement"},
		Value = {variant = "Float", safe = "number"},
	},
	ViewChanged = {
		Element = {variant = "Ptr", safe = "UIElement"},
		X = {variant = "Int", safe = "number"},
		Y = {variant = "Int", safe = "number"},
	},
	NodeAdded = {
		Scene = {variant = "Ptr", safe = "Scene"},
		Parent = {variant = "Ptr", safe = "Node"},
		Node = {variant = "Ptr", safe = "Node"},
	},
	NodeRemoved = {
		Scene = {variant = "Ptr", safe = "Scene"},
		Parent = {variant = "Ptr", safe = "Node"},
		Node = {variant = "Ptr", safe = "Node"},
	},
	ComponentAdded = {
		Scene = {variant = "Ptr", safe = "Scene"},
		Node = {variant = "Ptr", safe = "Node"},
		Component = {variant = "Ptr", safe = "Component"},
	},
	ComponentRemoved = {
		Scene = {variant = "Ptr", safe = "Scene"},
		Node = {variant = "Ptr", safe = "Node"},
		Component = {variant = "Ptr", safe = "Component"},
	},
	NodeNameChanged = {
		Scene = {variant = "Ptr", safe = "Scene"},
		Node = {variant = "Ptr", safe = "Node"},
	},
	PhysicsPreStep = {
		TimeStep = {variant = "Float", safe = "number"},
	},
	PhysicsCollision = {
		NodeA = {variant = "Ptr", safe = "Node"},
		NodeB = {variant = "Ptr", safe = "Node"},
		BodyA = {variant = "Ptr", safe = "RigidBody"},
		BodyB = {variant = "Ptr", safe = "RigidBody"},
		Contacts = {variant = "Buffer", safe = "VectorBuffer", get_type = "Buffer"},
	},
	PhysicsPostStep = {
		TimeStep = {variant = "Float", safe = "number"},
	},
	SoundFinished = {
		Node = {variant = "Ptr", safe = "Node"},
		SoundSource = {variant = "Ptr", safe = "SoundSource"},
		Sound = {variant = "Ptr", safe = "Sound"},
	},
}
-- vim: set noet ts=4 sw=4:
