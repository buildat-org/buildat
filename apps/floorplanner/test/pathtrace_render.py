# Buildat: apps/floorplanner/test/pathtrace_render.py
# http://www.apache.org/licenses/LICENSE-2.0
# Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#
# **The path-traced reference of a viewport** (user, 2026-10-01: material
# and paint decisions are made off the 3D view, so its light is checked
# against a path tracer, not guessed): Cycles over a dump the client wrote
# with BUILDAT_FP_REFDUMP=<viewport name> in its environment, into
# <user>/meshdumps, with its own frame in <user>/screenshots, and quits
# (editor.lua's M.refdump_tick). The same triangles, each palette row's albedo as the client
# takes it, the sun and the sky as apply_daylight has them; written as
# linear radiance (<stem>_cycles.exr, and .npy for compare.py, which puts
# it through the client's own frame pipeline), with the white a grey card
# sees where the client takes its white (<stem>_cycles_white.npy).
#
#   blender -b -P pathtrace_render.py -- <dump.obj.gz> [samples]
#   pathtrace_compare.py <the client's screenshot> <dump>_cycles.npy <regions>
#
# Coordinates and the camera as builtin/luanti/test/reference_shots/
# pathtrace_render.py has them, which are checked against its screenshots.
# simplified: diffuse only, at the entry's flat albedo (no paneling gaps,
# grain or sheen); glass lets everything through, as it casts no shadow
# in the client; lamps are off; the sky is its gradient, without the
# clouds, the treeline and the sun's band; no bloom
import gzip
import json
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Matrix, Vector

LUM = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
RES = (1200, 800)
# SkyDome.glsl's
HAZE_DEPTH = 0.25


def y_up_to_blender(x, y, z):
	return (x, -z, y)


def load(path):
	co, rows, faces = [], [], []
	with gzip.open(path, "rt") as f:
		for line in f:
			t = line.split()
			if not t:
				continue
			if t[0] == "v":
				co.append(y_up_to_blender(float(t[1]), float(t[2]), float(t[3])))
			elif t[0] == "vt":
				rows.append(int(float(t[1]) + 0.5))
			elif t[0] == "usemtl":
				# Only what the palette texture is on: the plan's lines and
				# the plan view's caps are not
				palette = len(t) > 1
			elif t[0] == "f" and palette:
				a = int(t[1].split("/")[0]) - 1
				faces.append((a, a + 1, a + 2))
	return co, rows, faces


def add_camera(pos, dire, fov):
	loc = Vector(y_up_to_blender(*pos))
	forward = Vector(y_up_to_blender(*dire)).normalized()
	right = Vector((0, 0, 1)).cross(forward).normalized()
	up = forward.cross(right)
	rot = Matrix((right, up, -forward)).transposed().to_4x4()
	rot.translation = loc
	c = bpy.data.cameras.new("cam")
	c.lens_unit = "FOV"
	c.sensor_fit = "VERTICAL"
	c.angle = math.radians(fov)
	c.clip_start = 0.05
	c.clip_end = 5000.0
	ob = bpy.data.objects.new("cam", c)
	ob.matrix_world = rot
	bpy.context.scene.collection.objects.link(ob)
	return ob


def sky_image(top, hor):
	"""SkyDome.glsl's physical gradient by elevation, as an
	equirectangular image: it does not turn with the azimuth"""
	w, h = 8, 1024
	top, hor = np.array(top), np.array(hor)
	lt, lh = max(top @ LUM, 1e-6), max(hor @ LUM, 1e-6)
	px = np.zeros((h, w, 4), dtype=np.float32)
	for j in range(h):
		y = math.sin(((j + 0.5) / h - 0.5) * math.pi)
		if y < 0:
			c = hor + (hor * 0.55 - hor) * min(1.0, -y / HAZE_DEPTH)
		else:
			t = min(max(y / 0.38, 0.0), 1.0)
			lum = lh + (lt - lh) * t * t * (3 - 2 * t)
			hue = hor / lh + (top / lt - hor / lh) * (1 - math.exp(-y / 0.09))
			c = hue * lum
		px[j, :, :3] = c
		px[j, :, 3] = 1
	img = bpy.data.images.new("sky", w, h, float_buffer=True)
	img.pixels.foreach_set(px.ravel())
	return img


def material(name, albedo, kind):
	m = bpy.data.materials.new(name)
	m.use_nodes = True
	nt = m.node_tree
	nt.nodes.clear()
	out = nt.nodes.new("ShaderNodeOutputMaterial")
	if kind == 5:
		b = nt.nodes.new("ShaderNodeBsdfTransparent")
		b.inputs["Color"].default_value = (1, 1, 1, 1)
	else:
		b = nt.nodes.new("ShaderNodeBsdfDiffuse")
		b.inputs["Color"].default_value = (*albedo, 1)
	nt.links.new(b.outputs[0], out.inputs["Surface"])
	return m


def main():
	args = sys.argv[sys.argv.index("--") + 1:]
	dump = args[0]
	samples = int(args[1]) if len(args) > 1 else 256
	stem = dump[:-len(".obj.gz")]
	meta = json.load(open(stem + "_atlas.json"))
	bpy.ops.wm.read_factory_settings(use_empty=True)
	scene = bpy.context.scene
	scene.render.engine = "CYCLES"
	scene.cycles.samples = samples
	scene.cycles.use_denoising = True
	scene.cycles.max_bounces = 32
	scene.cycles.diffuse_bounces = 32
	scene.cycles.transparent_max_bounces = 16
	scene.render.resolution_x, scene.render.resolution_y = RES
	scene.view_settings.view_transform = "Standard"
	scene.render.image_settings.file_format = "OPEN_EXR"
	scene.render.image_settings.color_depth = "32"

	co, rows, faces = load(dump)
	mesh = bpy.data.meshes.new("plan")
	mesh.from_pydata(co, [], faces)
	used = sorted({rows[f[0]] for f in faces})
	index = {}
	for r in used:
		row = meta["rows"].get(str(r), {"albedo": [0.5, 0.5, 0.5], "kind": 0})
		index[r] = len(mesh.materials)
		mesh.materials.append(material("row%d" % r, row["albedo"], row["kind"]))
	mesh.polygons.foreach_set("material_index",
			[index[rows[f[0]]] for f in faces])
	mesh.update()
	ob = bpy.data.objects.new("plan", mesh)
	scene.collection.objects.link(ob)
	print("%d triangles, rows %s" % (len(faces), used))

	scene.camera = add_camera(meta["camera_pos"], meta["camera_dir"], meta["fov"])

	# The sun: the client's irradiance (its Lambert has the 1/pi in the
	# brightness, so this is W/m2 as Cycles takes it), its colour at
	# luminance one, the disc SkyDome draws (daylight.lua's SUN_HALF)
	sc = meta["sun_color"]
	m = max(sc)
	ld = bpy.data.lights.new("sun", "SUN")
	ld.energy = meta["sun_irradiance"] * m
	ld.color = [c / m for c in sc]
	ld.angle = 2 * 0.04
	sun = bpy.data.objects.new("sun", ld)
	toward = Vector(y_up_to_blender(*meta["sun_toward"])).normalized()
	sun.rotation_euler = toward.to_track_quat("Z", "Y").to_euler()
	scene.collection.objects.link(sun)

	world = bpy.data.worlds.new("sky")
	world.use_nodes = True
	nt = world.node_tree
	env = nt.nodes.new("ShaderNodeTexEnvironment")
	env.image = sky_image(meta["sky_zenith"], meta["sky_horizon"])
	bg = nt.nodes["Background"]
	nt.links.new(env.outputs["Color"], bg.inputs["Color"])
	scene.world = world

	exr = stem + "_cycles.exr"
	scene.render.filepath = exr
	bpy.ops.render.render(write_still=True)
	# And the white the eye is adapted to (FpFrame.glsl): what a grey card
	# is lit by where the client takes it (the room's probe), the mean of a
	# panorama there by solid angle
	scene.camera.matrix_world.translation = Vector(
			y_up_to_blender(*meta["white_at"]))
	cam = scene.camera.data
	cam.type = "PANO"
	cam.panorama_type = "EQUIRECTANGULAR"
	scene.render.resolution_x, scene.render.resolution_y = 128, 64
	scene.cycles.samples = 64
	pano = stem + "_cycles_pano.exr"
	scene.render.filepath = pano
	bpy.ops.render.render(write_still=True)
	pimg = bpy.data.images.load(pano)
	pp = np.empty(128 * 64 * 4, dtype=np.float32)
	pimg.pixels.foreach_get(pp)
	pp = pp.reshape(64, 128, 4)[:, :, :3]
	lat = (np.arange(64) + 0.5) / 64 * math.pi - math.pi / 2
	wgt = np.cos(lat)[:, None, None]
	white = (pp * wgt).sum(axis=(0, 1)) / (wgt.sum() * 128)
	np.save(stem + "_cycles_white.npy", white)
	print("white", white)
	# The pixels, top row first, for compare.py
	img = bpy.data.images.load(exr)
	w, h = img.size
	px = np.empty(w * h * 4, dtype=np.float32)
	img.pixels.foreach_get(px)
	np.save(stem + "_cycles.npy", px.reshape(h, w, 4)[::-1, :, :3])
	print("wrote", exr, stem + "_cycles.npy")


main()
