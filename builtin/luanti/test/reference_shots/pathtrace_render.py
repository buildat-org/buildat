# SPDX-License-Identifier: Apache-2.0 OR MIT
# [PATH_TRACE_REF] Cycles render of dumps from buildat.dump_meshes().
# The .obj is Urho/Luanti Y-up world space, with
#   # camera_pos x y z
#   # camera_dir x y z
# at the top (camera already at the eyes). FOV 72 vertical, Nishita at 13:00.
# Blender's OBJ importer is not used: it places verts by forward_axis/up_axis
# while the camera is placed here, and two transforms that disagree put the
# camera outside the world. Parsed here instead, so there is one conversion.
# simplified: 32 samples; the metering is
# a plain log-average, which a sun disc in frame drags (see [PT_EXPOSURE]).

import gzip
import math
from array import array
import os
import re
import sys

import bpy

OUT = os.environ.get("BUILDAT_PATHTRACE_OUT",
		os.path.abspath("local/reference_shots/pathtrace"))
# The dumps are read from IN, which is OUT unless a ladder of options is
# being rendered out of one set of dumps into directories of its own
IN = os.environ.get("BUILDAT_PATHTRACE_IN", OUT)
FOV = 72.0
SAMPLES = int(os.environ.get("SAMPLES", "32"))
RES = (1280, 720)
# [PT_EXPOSURE]: Blender writes linear radiance (EXR, exposure 0, no view
# transform) and the frame is metered here by the rule the client's
# AutoExposure.xml runs -- Urho3D's, out of Reinhard 2002: the key is the
# log-average luminance, clamped to LUM_RANGE, and the frame is scaled by
# MIDDLE_GREY / key. The three constants are the same on both sides; the
# client's adaptation rate is its own, a still having no time axis.
# The constants are in radiance, Nishita's units (a noon grass top is ~5,
# a cave floor ~0.02), and are the ones the client's AutoExposure.xml is
# given -- not Urho's defaults (0.01..1.0, 0.6), which are for a
# display-referred frame. Middle grey 0.18 is the photographic one; the
# lower bound of the range is what keeps a cave dark: a frame whose key
# meters below it is exposed as if it were at it.
LUM_WEIGHTS = (0.2126, 0.7152, 0.0722)
# The floor is how far the eye may adapt into the dark ([PT_NIGHT]):
# 0.003 puts the 02:00 snow field's probe at a median of 39 of 255 with
# the sky at 0; 0.05, the old value, was a daylight-adapted eye looking
# at the night and rendered it pitch black. LUM_FLOOR= is for arguing
# with it over EXPOSE_ONLY=1; the launcher's AUTO_EXPOSURE has the same
# number.
LUM_RANGE = (float(os.environ.get("LUM_FLOOR", "0.003")), 100.0)
MIDDLE_GREY = 0.18
# ONLY=vp1 renders the one dump whose stem contains it
ONLY = os.environ.get("ONLY", "")
# [LAMP_REF]: what a light-emitting node's tile radiates, in the sky's
# units (the noon zenith is 4.5, sunlit snow about 30), for a node at
# light_source 15; a dimmer node in proportion. The reference's choice,
# 2026-09-18, and the client's PHYS.lamp is fitted to it.
LAMP_RADIANCE = 8.0


def open_dump(path):
	if path.endswith(".gz"):
		return gzip.open(path, "rt")
	return open(path)


def load_dump(path):
	"""One conversion: file Y-up -> Blender (x, -z, y). Camera uses the same.
	Flat array buffers rather than a Python object per vertex, which is
	what took ten gigabytes at RANGE=200 ([PATH_TRACE_RAM]). Nothing is
	culled: what is behind the camera casts the shadows and bounces the
	light in front of it (user). Every `o` block is one chunk batch whose
	faces are consecutive triples of its own verts (see l_dump_meshes), so
	no face list is kept either. Verts carry the tint as an OBJ vertex
	colour and a usemtl names the albedo PNG; both come back per block."""
	pos, dire = None, None
	co = array("f")      # x y z per vert, Blender space
	tint = array("f")    # r g b a per vert
	uv = array("f")      # u v per vert
	blocks = []          # (material, first vert, vert count)
	first = 0
	mat = ""

	def flush():
		nonlocal first
		n = len(co) // 3 - first
		if n > 0:
			blocks.append((mat, first, n))
		first = len(co) // 3

	with open_dump(path) as f:
		for line in f:
			c = line[0]
			if c == "v":
				t = line.split()
				if t[0] == "v":
					x, y, z = float(t[1]), float(t[2]), float(t[3])
					co.extend(y_up_to_blender(x, y, z))
					if len(t) >= 7:
						tint.extend((float(t[4]), float(t[5]), float(t[6]), 1.0))
					else:
						tint.extend((1.0, 1.0, 1.0, 1.0))
				elif t[0] == "vt":
					# Urho's v runs down from the top; Blender's up
					uv.extend((float(t[1]), 1.0 - float(t[2])))
			elif c == "o":
				flush()
			elif c == "u":
				t = line.split(None, 1)
				mat = t[1].strip() if len(t) > 1 else ""
			elif c == "#":
				if line.startswith("# camera_pos "):
					pos = tuple(float(x) for x in line.split()[2:5])
				elif line.startswith("# camera_dir "):
					dire = tuple(float(x) for x in line.split()[2:5])
			# "f" lines are implied: consecutive triples of a block's verts
	flush()
	return pos, dire, co, tint, uv, blocks


def y_up_to_blender(x, y, z):
	# File Y → Blender Z (up), file Z → Blender -Y (forward is -Y).
	# The only place either verts or the camera change hands.
	return (x, -z, y)


def clear_scene():
	bpy.ops.object.select_all(action="SELECT")
	bpy.ops.object.delete()
	for block in list(bpy.data.meshes):
		bpy.data.meshes.remove(block)
	bpy.ops.outliner.orphans_purge(do_local_ids=True, do_linked_ids=True,
			do_recursive=True)


# Luanti's own sun path, out of sky_dome.sun_direction() in the launcher:
# the sun rises at -X, crosses the zenith and sets at +X in the plane of
# file-space X and Y, which is Blender's XZ -- then tilted out of it about
# X by set.lua's orbit_tilt, the same rotation the launcher applies, so
# the render's sun is where the pbr client's is ([PBR_FIT] 2c). The hour
# is the fixture's HOURS table -- "1300" is time_of_day 0.5417 -- so the
# reference's sun is where the client's is at the same picture.
HOURS = {"0545": 0.2396, "1000": 0.4167, "1300": 0.5417, "1500": 0.6250,
		"1830": 0.7708, "2030": 0.8542, "0200": 0.0833}

# [PT_HOURS]: the clear hours each viewpoint is rendered at, out of one
# dump -- the fixture freezes the world, so the geometry at 5:45 is the
# geometry at 20:30 -- which is set.lua's hours_of_view; the rain states
# are left out (user, 2026-09-17), nothing defining what a path trace of
# rain is. Read out of set.lua rather than copied: build.sh's env.sh is
# for the shell, and this reads the Lua table with a regexp on its text.
def hours_of_view():
	import re
	here = os.path.dirname(os.path.abspath(__file__))
	text = open(os.path.join(here, "set.lua")).read()
	m = re.search(r"hours_of_view = \{(.*?)\n\t\}", text, re.S)
	out = {}
	for v, hours in re.findall(r"\[(\d+)\] = \{([^}]*)\}", m.group(1)):
		out[int(v)] = re.findall(r'"(\d{4})"', hours)
	return out

# Night needs a moon, stated as a model choice: Nishita is a sun-and-
# atmosphere model and goes black below the horizon, with no moon and
# no stars, and the 02:00 snow state is the moonlight regression check
# ([PBR_LEVEL]). So a sun that is down gets a sun lamp at the moon's
# elevation -- the moon opposite the sun, the way the client draws it --
# with lunar irradiance, about 0.0025 W/m^2, a factor of 400 000 under the
# sun's, and a colour near 4100 K; the Nishita sky keeps the faint
# twilight it still gives. Stars are not modelled: they light nothing
# measurable.
MOON_IRRADIANCE = 0.0025
MOON_COLOR = (1.0, 0.86, 0.70)
# [NIGHT_LIGHT]'s two knobs, as environment for a ladder and as the
# defaults once the user has picked: the moon's factor over the physical
# value above, and a uniform night sky of that radiance (sRGB-linear,
# blue-ish) added to the Nishita sky, which gives none with the sun down.
# Picked 2026-09-20 off the x1 | x3 | x5 sheet: x3, night_snow_lit at 77
# of 255 (the plan's 78); see [NIGHT_LIGHT] in the master plan
MOON_FACTOR = float(os.environ.get("MOON_FACTOR", "3"))
# Picked 2026-09-20 off the 0.00002 | 0.00005 | 0.0002 sheet: 0.0001
NIGHT_SKY = float(os.environ.get("NIGHT_SKY", "0.0001"))
NIGHT_SKY_COLOR = (0.6, 0.75, 1.0)
# HOURS_ONLY=0200,2030 renders only those hours of each viewpoint
HOURS_ONLY = [h for h in os.environ.get("HOURS_ONLY", "").split(",") if h]


def sun_from_hour(hour):
	"""(elevation, rotation) for the Nishita sky, radians."""
	t = HOURS.get(hour, 0.5417)
	wn = 0.415 / 2
	if wn < t < 1 - wn:
		w = (t - wn) / (1 - wn * 2) * 0.5 + 0.25
	elif t < 0.5:
		w = t / wn * 0.25
	else:
		w = 1 - (1 - t) / wn * 0.25
	a = math.radians(w * 360 - 90)
	# File space: x = cos a, y = sin a (up), z = 0, then the tilt about X
	x, up, z = math.cos(a), math.sin(a), 0.0
	r = math.radians(orbit_tilt())
	up, z = up * math.cos(r) - z * math.sin(r), up * math.sin(r) + z * math.cos(r)
	# Blender: (x, -z, up), by y_up_to_blender()
	bx, by = x, -z
	el = math.asin(max(-1.0, min(1.0, up)))
	# Cycles: sun = (sin rot * cos el, cos rot * cos el, sin el), so a sun
	# along +X is rotation +90 degrees and along -X is -90
	rot = math.atan2(bx, by)
	return el, rot


def orbit_tilt():
	"""set.lua's orbit_tilt, degrees; read rather than copied."""
	here = os.path.dirname(os.path.abspath(__file__))
	text = open(os.path.join(here, "set.lua")).read()
	m = re.search(r"orbit_tilt = ([0-9.]+)", text)
	return float(m.group(1)) if m else 0.0


def setup_world(hour):
	world = bpy.data.worlds["World"]
	world.use_nodes = True
	nt = world.node_tree
	nt.nodes.clear()
	out = nt.nodes.new("ShaderNodeOutputWorld")
	bg = nt.nodes.new("ShaderNodeBackground")
	sky = nt.nodes.new("ShaderNodeTexSky")
	sky.sky_type = "MULTIPLE_SCATTERING"
	el, rot = sun_from_hour(hour)
	sky.sun_elevation = el
	sky.sun_rotation = rot
	if el < 0 and NIGHT_SKY > 0:
		# The night sky's diffuse light on top of Nishita's nothing
		add = nt.nodes.new("ShaderNodeMixRGB")
		add.blend_type = "ADD"
		add.inputs["Fac"].default_value = 1.0
		add.inputs["Color2"].default_value = (
				NIGHT_SKY_COLOR[0] * NIGHT_SKY, NIGHT_SKY_COLOR[1] * NIGHT_SKY,
				NIGHT_SKY_COLOR[2] * NIGHT_SKY, 1.0)
		nt.links.new(sky.outputs["Color"], add.inputs["Color1"])
		nt.links.new(add.outputs["Color"], bg.inputs["Color"])
	else:
		nt.links.new(sky.outputs["Color"], bg.inputs["Color"])
	nt.links.new(bg.outputs["Background"], out.inputs["Surface"])
	bg.inputs["Strength"].default_value = 1.0
	# The moon, when the sun is down: opposite the sun, as a lamp
	if el < 0:
		lamp = bpy.data.lights.new("moon", "SUN")
		lamp.energy = MOON_IRRADIANCE * MOON_FACTOR
		lamp.color = MOON_COLOR
		lamp.angle = math.radians(0.5)
		ob = bpy.data.objects.new("moon", lamp)
		# A sun lamp shines along its local -Z; point it from the moon's
		# place in the sky, which is the sun's mirrored through the origin
		from mathutils import Vector
		mel, mrot = -el, rot + math.pi
		d = Vector((math.sin(mrot) * math.cos(mel),
				math.cos(mrot) * math.cos(mel), math.sin(mel)))
		ob.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
		bpy.context.scene.collection.objects.link(ob)


def add_camera(pos, dire):
	from mathutils import Vector, Matrix
	loc = Vector(y_up_to_blender(*pos))
	# GetWorldDirection is the look, unflipped: checked against viewpoint 1
	# and the cave trio, which match the module's own screenshots.
	forward = Vector(y_up_to_blender(*dire))
	if forward.length < 1e-8:
		forward = Vector((0, 1, 0))
	else:
		forward.normalize()
	world_up = Vector((0, 0, 1))
	right = world_up.cross(forward)
	if right.length < 1e-6:
		right = Vector((1, 0, 0))
	else:
		right.normalize()
	up = forward.cross(right)
	# Camera looks along local -Z, local Y is up, local X is right.
	rot = Matrix((right, up, -forward)).transposed().to_4x4()
	rot.translation = loc
	c = bpy.data.cameras.new("cam")
	c.lens_unit = "FOV"
	c.sensor_fit = "VERTICAL"
	c.angle = math.radians(FOV)
	c.clip_start = 0.05
	c.clip_end = 5000.0
	ob = bpy.data.objects.new("cam", c)
	ob.matrix_world = rot
	bpy.context.scene.collection.objects.link(ob)
	return ob


def lit_segments(atlas_json_path):
	"""[LAMP_REF]: per read-back texture file, the rectangles of the atlas
	segments a light-emitting node draws, with its light_source: out of the
	dump's atlas account -- segments by atlas with the atlas texture's
	address, lights by atlas and segment, textures by address."""
	import json
	try:
		with open(atlas_json_path) as f:
			acc = json.load(f)
	except (OSError, ValueError):
		return {}
	textures = acc.get("textures") or {}
	rects = {}
	for seg in acc.get("segments") or []:
		rects[(seg["atlas"], seg["segment"])] = (
				str(seg.get("texture", 0)), seg["x"], seg["y"], seg["w"], seg["h"])
	out = {}
	for lamp in acc.get("lights") or []:
		r = rects.get((lamp["atlas"], lamp["segment"]))
		if not r:
			continue
		png = textures.get(r[0])
		if png:
			out.setdefault(png, []).append((r[1], r[2], r[3], r[4],
					lamp["light"] / 15.0))
	return out


def emission_mask(name, size, rects):
	"""A one-channel image, black with each lit segment's rectangle at its
	light_source share, to drive the Principled emission strength. The
	atlas's y runs down the image; Blender's pixels run up."""
	w, h = size
	img = bpy.data.images.new(name, w, h, alpha=False, float_buffer=True)
	img.colorspace_settings.name = "Non-Color"
	px = [0.0] * (w * h * 4)
	for x, y, rw, rh, share in rects:
		for yy in range(y, min(y + rh, h)):
			row = (h - 1 - yy) * w
			for xx in range(x, min(x + rw, w)):
				i = (row + xx) * 4
				px[i] = px[i + 1] = px[i + 2] = share
				px[i + 3] = 1.0
	img.pixels.foreach_set(px)
	return img


LAMPS = {}   # read-back png -> lit rectangles, set per dump in main()


def textured_material(name, png):
	"""The atlas on a Principled BSDF, nearest-filtered as the client draws
	it, multiplied by the tint the mesher packed; the atlas's alpha cuts the
	leaf and plant cards out."""
	mat = bpy.data.materials.new(name)
	mat.use_nodes = True
	nt = mat.node_tree
	bsdf = nt.nodes.get("Principled BSDF")
	# The values a material with no maps gets; one with maps overrides
	# them below
	bsdf.inputs["Roughness"].default_value = 0.9
	bsdf.inputs["Specular IOR Level"].default_value = 0.0
	if png and os.path.isfile(png):
		tex = nt.nodes.new("ShaderNodeTexImage")
		tex.image = bpy.data.images.load(png)
		tex.image.colorspace_settings.name = "sRGB"
		tex.interpolation = "Closest"
		tint = nt.nodes.new("ShaderNodeVertexColor")
		tint.layer_name = "tint"
		mul = nt.nodes.new("ShaderNodeMix")
		mul.data_type = "RGBA"
		mul.blend_type = "MULTIPLY"
		mul.inputs["Factor"].default_value = 1.0
		nt.links.new(tex.outputs["Color"], mul.inputs[6])
		nt.links.new(tint.outputs["Color"], mul.inputs[7])
		nt.links.new(mul.outputs[2], bsdf.inputs["Base Color"])
		nt.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
		# [LAMP_REF]: a light-emitting node's tiles radiate their own
		# colour at LAMP_RADIANCE times the node's light_source share,
		# through a mask of the atlas's lit segments
		rects = LAMPS.get(os.path.basename(png))
		# A texture the dump names but the directory no longer holds (a
		# later dump wrote fewer meshdump_texN.png) loads at size 0; the
		# mask cannot be built over it and the material stays unlit
		if rects and tex.image.size[0] > 0:
			mask = nt.nodes.new("ShaderNodeTexImage")
			mask.image = emission_mask(name + "_lamps", tex.image.size, rects)
			mask.interpolation = "Closest"
			strength = nt.nodes.new("ShaderNodeMath")
			strength.operation = "MULTIPLY"
			strength.inputs[1].default_value = LAMP_RADIANCE
			nt.links.new(mask.outputs["Color"], strength.inputs[0])
			nt.links.new(tex.outputs["Color"], bsdf.inputs["Emission Color"])
			nt.links.new(strength.outputs["Value"],
					bsdf.inputs["Emission Strength"])
		# [PT_MATERIALS]: the maps the pbr shader reads beside the albedo,
		# derived per segment in impl/atlas.cpp. spec: roughness in r, spec
		# strength in g, translucency in b, spots in a; normal: tangent
		# space, spots in a. The reference takes the definitions and Cycles
		# does the physics -- none of the shader's own arithmetic crosses.
		# simplified: the spots (spec.a, normal.a) are a buildat gloss and
		# light-through effect with no Principled input; left out.
		spec_png = png[:-4] + "_spec.png"
		if os.path.isfile(spec_png):
			spec = nt.nodes.new("ShaderNodeTexImage")
			spec.image = bpy.data.images.load(spec_png)
			spec.image.colorspace_settings.name = "Non-Color"
			spec.interpolation = "Closest"
			sep = nt.nodes.new("ShaderNodeSeparateColor")
			nt.links.new(spec.outputs["Color"], sep.inputs["Color"])
			nt.links.new(sep.outputs["Red"], bsdf.inputs["Roughness"])
			nt.links.new(sep.outputs["Green"],
					bsdf.inputs["Specular IOR Level"])
			# Translucency as the factor of a Translucent BSDF mixed in,
			# tinted by the surface's own colour, which is what the shader's
			# term is: what a leaf passes from behind
			trans = nt.nodes.new("ShaderNodeBsdfTranslucent")
			nt.links.new(mul.outputs[2], trans.inputs["Color"])
			mix = nt.nodes.new("ShaderNodeMixShader")
			nt.links.new(sep.outputs["Blue"], mix.inputs["Fac"])
			nt.links.new(bsdf.outputs["BSDF"], mix.inputs[1])
			nt.links.new(trans.outputs["BSDF"], mix.inputs[2])
			# The cutout stays outside the mix: a transparent texel is air
			# whichever BSDF is under it
			transp = nt.nodes.new("ShaderNodeBsdfTransparent")
			cut = nt.nodes.new("ShaderNodeMixShader")
			nt.links.new(tex.outputs["Alpha"], cut.inputs["Fac"])
			nt.links.new(transp.outputs["BSDF"], cut.inputs[1])
			nt.links.new(mix.outputs["Shader"], cut.inputs[2])
			out = nt.nodes.get("Material Output")
			nt.links.new(cut.outputs["Shader"], out.inputs["Surface"])
			bsdf.inputs["Alpha"].default_value = 1.0
			for l in list(bsdf.inputs["Alpha"].links):
				nt.links.remove(l)
		normal_png = png[:-4] + "_normal.png"
		if os.path.isfile(normal_png):
			nrm = nt.nodes.new("ShaderNodeTexImage")
			nrm.image = bpy.data.images.load(normal_png)
			nrm.image.colorspace_settings.name = "Non-Color"
			nrm.interpolation = "Closest"
			nmap = nt.nodes.new("ShaderNodeNormalMap")
			nmap.space = "TANGENT"
			nmap.uv_map = "atlas"
			nt.links.new(nrm.outputs["Color"], nmap.inputs["Color"])
			nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
	else:
		bsdf.inputs["Base Color"].default_value = (0.55, 0.55, 0.55, 1)
	mat.use_backface_culling = False
	return mat


def drop_twin_faces(co, tint, uv, blocks):
	"""A plant card and an allfaces leaf are emitted twice by the mesher,
	once per winding, so the client draws both sides. In Cycles the two
	coincident faces shadow each other and the card comes out black. Keep
	the first of any two triangles on the same three points."""
	seen = set()
	nco, ntint, nuv, nblocks = array("f"), array("f"), array("f"), []
	dropped = 0
	for mat, first, n in blocks:
		start = len(nco) // 3
		for t in range(first, first + n, 3):
			key = tuple(sorted((tuple(co[3 * v:3 * v + 3])
					for v in (t, t + 1, t + 2))))
			if key in seen:
				dropped += 1
				continue
			seen.add(key)
			nco.extend(co[3 * t:3 * t + 9])
			ntint.extend(tint[4 * t:4 * t + 12])
			nuv.extend(uv[2 * t:2 * t + 6])
		kept = len(nco) // 3 - start
		if kept:
			nblocks.append((mat, start, kept))
	print("dropped %d twin faces of %d" % (dropped, len(co) // 9))
	return nco, ntint, nuv, nblocks


def build_world(scene, co, tint, uv, blocks, tex_dir):
	"""The mesh out of the flat buffers, through foreach_set: no Python
	object per vertex or per loop."""
	co, tint, uv, blocks = drop_twin_faces(co, tint, uv, blocks)
	nvert = len(co) // 3
	ntri = nvert // 3
	mesh = bpy.data.meshes.new("world")
	mesh.vertices.add(nvert)
	mesh.vertices.foreach_set("co", co)
	mesh.loops.add(nvert)
	mesh.loops.foreach_set("vertex_index", array("i", range(nvert)))
	mesh.polygons.add(ntri)
	mesh.polygons.foreach_set("loop_start", array("i", range(0, nvert, 3)))
	mesh.polygons.foreach_set("loop_total", array("i", [3]) * ntri)
	uvl = mesh.uv_layers.new(name="atlas")
	uvl.data.foreach_set("uv", uv)   # loop i is vert i
	col = mesh.color_attributes.new(name="tint", type="FLOAT_COLOR",
			domain="POINT")
	col.data.foreach_set("color", tint)
	# One material slot per texture the dump named, in the order met
	slot_of = {}
	midx = array("i", [0]) * ntri
	for m, first, n in blocks:
		if m not in slot_of:
			slot_of[m] = len(mesh.materials)
			mesh.materials.append(textured_material(m or "untextured",
					os.path.join(tex_dir, m) if m else None))
		s = slot_of[m]
		for i in range(first // 3, (first + n) // 3):
			midx[i] = s
	mesh.polygons.foreach_set("material_index", midx)
	mesh.update()
	mesh.validate()
	ob = bpy.data.objects.new("world", mesh)
	scene.collection.objects.link(ob)
	return ob


def expose(exr, png):
	"""The metered 16-bit PNG out of the linear EXR: log-average luminance
	as the key, clamped, MIDDLE_GREY / key as the scale. Written through
	Blender's own image writer, sRGB, so the PNG is display-referred the
	way the client's frame is after its exposure pass."""
	import numpy as np
	img = bpy.data.images.load(exr)
	w, h = img.size
	px = np.empty(w * h * 4, dtype=np.float32)
	img.pixels.foreach_get(px)
	rgb = px.reshape(-1, 4)[:, :3]
	lum = rgb @ np.array(LUM_WEIGHTS, dtype=np.float32)
	key = float(np.exp(np.mean(np.log(lum + 1e-5))))
	key = min(max(key, LUM_RANGE[0]), LUM_RANGE[1])
	scale = MIDDLE_GREY / key
	print("expose %s: key %.4f scale %.3f" % (os.path.basename(png), key, scale))
	px.reshape(-1, 4)[:, :3] *= scale
	# The alpha the leaf cards' cutout left behind composites the PNG over
	# black; the picture is opaque
	px.reshape(-1, 4)[:, 3] = 1.0
	img.pixels.foreach_set(px)
	img.filepath_raw = png
	img.file_format = "PNG"
	# 16-bit: a shaded face is a few counts of 255 and a hue ratio out of
	# those is noise
	scene = bpy.context.scene
	scene.render.image_settings.file_format = "PNG"
	scene.render.image_settings.color_depth = "16"
	img.save_render(png, scene=scene)
	scene.render.image_settings.file_format = "OPEN_EXR"
	scene.render.image_settings.color_depth = "32"
	bpy.data.images.remove(img)


def main():
	# EXPOSE_ONLY=1: the metering alone, over the EXRs already rendered --
	# a floor is argued with in seconds this way, not in renders
	if os.environ.get("EXPOSE_ONLY"):
		for n in sorted(os.listdir(OUT)):
			if n.endswith(".exr"):
				expose(os.path.join(OUT, n), os.path.join(OUT, n[:-4] + ".png"))
		return
	# Cycles and a buildat server do not fit in memory together; a render
	# waits for a shooter rather than running beside one.
	import subprocess
	if subprocess.run(["pgrep", "-x", "buildat_server"],
			capture_output=True).returncode == 0:
		print("a buildat_server is running; not rendering beside it",
				file=sys.stderr)
		sys.exit(1)
	scene = bpy.context.scene
	scene.render.engine = "CYCLES"
	scene.cycles.samples = SAMPLES
	scene.cycles.device = "CPU"
	# A shaded face at noon is lit by bounce alone, and at 32 samples its
	# colour is Monte Carlo noise (stone in shade read B/R 0.69); the
	# denoiser is what makes a ratio out of it.
	scene.cycles.use_denoising = True
	# A VoxeLibre canopy is drawn allfaces, six leaf cards a node with
	# interior faces, and a ray through the alpha-0 texels spends a
	# transparent bounce per card: at Cycles' default of eight it is
	# terminated black two nodes in, shadow rays the same, which was the
	# black inside every tree. Transparent hits are cheap. Diffuse bounces
	# up too, for a canopy lit from within. See [PATH_TRACE_TEX].
	scene.cycles.transparent_max_bounces = 128
	scene.cycles.max_bounces = 16
	scene.cycles.diffuse_bounces = 8
	scene.render.resolution_x, scene.render.resolution_y = RES
	scene.view_settings.exposure = 0.0
	# Standard, not Blender 5's AgX: a tone curve moves every ratio the
	# probes read; the EXR is written before either applies anyway.
	scene.view_settings.view_transform = "Standard"
	scene.render.image_settings.file_format = "OPEN_EXR"
	scene.render.image_settings.color_depth = "32"
	scene.render.image_settings.exr_codec = "ZIP"

	objs = sorted(n for n in os.listdir(IN)
			if "_vp" in n and (n.endswith(".obj") or n.endswith(".obj.gz")))
	# Prefer .gz when both exist
	seen = set()
	picked = []
	for n in objs:
		stem = n[:-7] if n.endswith(".obj.gz") else n[:-4]
		if stem in seen:
			continue
		gz = stem + ".obj.gz"
		raw = stem + ".obj"
		if gz in objs:
			picked.append(gz)
		else:
			picked.append(raw)
		seen.add(stem)
	if not picked:
		print("no dumps in", IN, file=sys.stderr)
		sys.exit(1)
	for name in picked:
		if ONLY and ONLY not in name:
			continue
		# With HOURS_ONLY, a dump taken at another hour is skipped when a
		# dump of the same view at a wanted hour is there: the wanted
		# picture then comes from the dump nearest it, not from an older
		# one whose textures may be gone (the 05:45 dumps named a
		# meshdump_tex42 the 13:00 re-dump had not written, 2026-09-20)
		if HOURS_ONLY:
			p = name.split("_")
			if p[2] not in HOURS_ONLY and any(
					n.split("_")[1] == p[1] and n.split("_")[2] in HOURS_ONLY
					for n in objs):
				continue
		obj_path = os.path.join(IN, name)
		print("load", name)
		pos, dire, co, tint, uv, blocks = load_dump(obj_path)
		if not pos or not dire:
			print("no camera header in", name, file=sys.stderr)
			sys.exit(1)
		clear_scene()
		stem = name[:-7] if name.endswith(".obj.gz") else name[:-4]
		LAMPS.clear()
		LAMPS.update(lit_segments(os.path.join(IN, stem + "_atlas.json")))
		if LAMPS:
			print("lamps:", {k: len(v) for k, v in LAMPS.items()})
		# <seed>_vp<N>_<hhmm>_<weather>: the viewpoint picks the hours,
		# the dump's own hour being only the one it was taken at
		parts = stem.split("_")
		view = int(parts[1][2:])
		hours = hours_of_view().get(view) or [parts[2]]
		if HOURS_ONLY:
			hours = [h for h in hours if h in HOURS_ONLY]
		# The usemtl names are meshdump_texN.png, one set beside the dumps
		build_world(scene, co, tint, uv, blocks, IN)
		del co, tint, uv
		scene.camera = add_camera(pos, dire)
		for hour in hours:
			setup_world(hour)
			# cycles_vp6_1300_none.png: the dump's stem without the seed,
			# so the render sits beside its .obj.gz without sharing a name
			# with it, and one per hour
			base = "cycles_vp%d_%s_%s" % (view, hour, parts[3])
			exr = os.path.join(OUT, base + ".exr")
			scene.render.filepath = exr
			print("render", base)
			bpy.ops.render.render(write_still=True)
			expose(exr, os.path.join(OUT, base + ".png"))
			for ob in [o for o in scene.collection.objects if o.name == "moon"]:
				bpy.data.objects.remove(ob)


if __name__ == "__main__":
	main()
