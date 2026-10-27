// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// Raster operations over an RGBA canvas: load an image by resource name, blit
// it, blend a colour into it, shift its hue, turn it, crop it, scale it, and
// write what comes out as a PNG.
//
// What wanted this is Luanti's texture modifiers -- "dirt.png^grass.png",
// "[colorize:#ff0000:128", "[combine:32x32:0,0=a.png:16,0=b.png" -- which are
// a small language over exactly these operations. The language is not here:
// parsing it is a page of Lua, and what is worth having in the engine is the
// pixels. Nothing in this file knows what a node or a modifier is.
//
// A composition writes one file, and a nested expression is one composition
// per level with the inner results referenced by name, which is why there is
// no way to hold an intermediate image: the file is the intermediate, and it
// doubles as a cache between runs.
#include "lua_bindings/util.h"
#include "lua_bindings/luabind_util.h"
#include "core/log.h"
#include "client/app.h"
#include "client/config.h"
#include "interface/fs.h"
#include <luabind/luabind.hpp>
#include <luabind/object.hpp>
#include <luabind/iterator_policy.hpp>
#include <Context.h>
#include <Image.h>
#include <MemoryBuffer.h>
#include <ResourceCache.h>
#include <Scene.h>
#include <Color.h>
#include <cstring>
#include <cmath>
#include <algorithm>
#define MODULE "lua_bindings"

namespace magic = Urho3D;

extern client::Config g_client_config;

namespace lua_bindings {

// A canvas is 4 bytes per pixel, r g b a, top row first. Nothing bigger than
// this is a texture; the limit is here so that a broken size cannot ask for an
// arbitrary allocation.
static const int IMAGE_MAX_SIZE = 4096;

struct Canvas
{
	int w = 0;
	int h = 0;
	sv_<uint8_t> data;

	void reset(int w_, int h_)
	{
		if(w_ <= 0 || h_ <= 0 || w_ > IMAGE_MAX_SIZE || h_ > IMAGE_MAX_SIZE)
			throw Exception(ss_()+"compose_image(): bad image size "+
					itos(w_)+"x"+itos(h_));
		w = w_;
		h = h_;
		data.assign((size_t)w * h * 4, 0);
	}

	uint8_t* at(int x, int y){ return &data[((size_t)y * w + x) * 4]; }
};

static double table_number(const luabind::object &t, const char *key,
		double default_value)
{
	luabind::object v = t[key];
	if(!v || luabind::type(v) != LUA_TNUMBER)
		return default_value;
	return luabind::object_cast<double>(v);
}

static double table_number_at(const luabind::object &t, int index,
		double default_value)
{
	luabind::object v = t[index];
	if(!v || luabind::type(v) != LUA_TNUMBER)
		return default_value;
	return luabind::object_cast<double>(v);
}

static ss_ table_string(const luabind::object &t, const char *key)
{
	luabind::object v = t[key];
	if(!v || luabind::type(v) != LUA_TSTRING)
		return "";
	return luabind::object_cast<ss_>(v);
}

// The same, for a string that is bytes rather than text: the conversion above
// goes through const char* and a PNG's second byte is already a zero.
static ss_ table_bytes(const luabind::object &t, const char *key)
{
	luabind::object v = t[key];
	if(!v || luabind::type(v) != LUA_TSTRING)
		return "";
	lua_State *L = v.interpreter();
	v.push(L);
	size_t len = 0;
	const char *p = lua_tolstring(L, -1, &len);
	ss_ result(p, len);
	lua_pop(L, 1);
	return result;
}

// An array of numbers, as the caller writes a position, a size, a rectangle or
// a colour. Returns how many entries were there.
static int table_ints(const luabind::object &t, const char *key, int *result,
		int count)
{
	luabind::object v = t[key];
	if(!v || luabind::type(v) != LUA_TTABLE)
		return 0;
	int got = 0;
	for(int i = 0; i < count; i++){
		luabind::object e = v[i + 1];
		if(!e || luabind::type(e) != LUA_TNUMBER)
			break;
		result[i] = (int)luabind::object_cast<double>(e);
		got++;
	}
	return got;
}

// The same for the one thing given as fractions rather than as pixels: a
// blit's clip rectangle
static int table_numbers(const luabind::object &t, const char *key,
		double *result, int count)
{
	luabind::object v = t[key];
	if(!v || luabind::type(v) != LUA_TTABLE)
		return 0;
	int got = 0;
	for(int i = 0; i < count; i++){
		luabind::object e = v[i + 1];
		if(!e || luabind::type(e) != LUA_TNUMBER)
			break;
		result[i] = luabind::object_cast<double>(e);
		got++;
	}
	return got;
}

static uint8_t clamp_byte(int v)
{
	return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

// An image as RGBA. Urho3D's images come in whatever the file had, so they are
// read through GetPixel() rather than out of the buffer.
static void copy_image(magic::Image *img, Canvas &dst)
{
	dst.reset(img->GetWidth(), img->GetHeight());
	// Urho3D's GetPixel() reads a two-component image -- grey and alpha,
	// which VoxeLibre's water is -- as r and g with the alpha left at one,
	// so every liquid composed through here came out opaque
	// ([LIQUID_SURFACE]). Read the bytes for that layout.
	const unsigned comps = img->GetComponents();
	const unsigned char *data = img->GetData();
	for(int y = 0; y < dst.h; y++){
		for(int x = 0; x < dst.w; x++){
			uint8_t *p = dst.at(x, y);
			if(comps == 2 && data){
				const unsigned char *src = data + (y * dst.w + x) * 2;
				p[0] = p[1] = p[2] = src[0];
				p[3] = src[1];
				continue;
			}
			magic::Color c = img->GetPixel(x, y);
			p[0] = clamp_byte((int)(c.r_ * 255.0f + 0.5f));
			p[1] = clamp_byte((int)(c.g_ * 255.0f + 0.5f));
			p[2] = clamp_byte((int)(c.b_ * 255.0f + 0.5f));
			p[3] = clamp_byte((int)(c.a_ * 255.0f + 0.5f));
		}
	}
}

static void load_source(magic::Context *context, const ss_ &name,
		Canvas &dst)
{
	auto *cache = context->GetSubsystem<magic::ResourceCache>();
	// Exists() first: GetResource() logs an ERROR for a file that is not
	// there, and on a cold cache the media is on its way ([FIRST_RUN]);
	// the throw below is the caller's to handle, as it already is
	if(!cache->Exists(name.c_str()) &&
			cache->GetExistingResource<magic::Image>(name.c_str()) == nullptr)
		throw Exception("compose_image(): \""+name+"\" is not here");
	magic::Image *img = cache->GetResource<magic::Image>(name.c_str());
	if(img == nullptr)
		throw Exception("compose_image(): could not load \""+name+"\"");
	copy_image(img, dst);
}

// An image the caller has the bytes of rather than a name for. What wants this
// is Luanti's "[png:<base64>", which carries a whole file in the expression.
static void load_source_data(magic::Context *context, const ss_ &data,
		Canvas &dst)
{
	magic::MemoryBuffer buf(data.c_str(), data.size());
	magic::SharedPtr<magic::Image> img(new magic::Image(context));
	if(!img->Load(buf))
		throw Exception("compose_image(): src_data is not an image");
	copy_image(img, dst);
}

enum BlendMode {
	BLEND_OVER,     // Alpha compositing, which is what an overlay is
	BLEND_SET,      // Replace, alpha included
	BLEND_AND,      // Bitwise, per channel; this is what a mask is
	BLEND_MULTIPLY,
	BLEND_SCREEN,
	BLEND_HARDLIGHT, // Luanti's [hardlight: multiply below half, screen above
};

static BlendMode parse_blend(const ss_ &s)
{
	if(s == "" || s == "over")
		return BLEND_OVER;
	if(s == "set")
		return BLEND_SET;
	if(s == "and")
		return BLEND_AND;
	if(s == "multiply")
		return BLEND_MULTIPLY;
	if(s == "screen")
		return BLEND_SCREEN;
	if(s == "hardlight")
		return BLEND_HARDLIGHT;
	throw Exception("compose_image(): unknown blend \""+s+"\"");
}

static void blend_pixel(const uint8_t *src, uint8_t *dst, BlendMode mode)
{
	switch(mode){
	case BLEND_SET:
		for(int i = 0; i < 4; i++)
			dst[i] = src[i];
		return;
	case BLEND_AND:
		for(int i = 0; i < 4; i++)
			dst[i] = src[i] & dst[i];
		return;
	case BLEND_MULTIPLY:
		for(int i = 0; i < 3; i++)
			dst[i] = (uint8_t)(dst[i] * src[i] / 255);
		return;
	case BLEND_SCREEN:
		for(int i = 0; i < 3; i++)
			dst[i] = (uint8_t)(255 - (255 - dst[i]) * (255 - src[i]) / 255);
		return;
	case BLEND_HARDLIGHT:
		for(int i = 0; i < 3; i++)
			dst[i] = src[i] < 128 ?
					(uint8_t)(2 * src[i] * dst[i] / 255) :
					(uint8_t)(255 - 2 * (255 - src[i]) * (255 - dst[i]) / 255);
		return;
	case BLEND_OVER:
		break;
	}
	// Alpha compositing, gamma-incorrect, which is what every 2D blit of this
	// kind does and what the textures were painted against
	uint8_t sa = src[3];
	if(sa == 0)
		return;
	if(sa == 255 || dst[3] == 0){
		for(int i = 0; i < 4; i++)
			dst[i] = src[i];
		return;
	}
	int out_a = sa + dst[3] * (255 - sa) / 255;
	for(int i = 0; i < 3; i++){
		int s = src[i] * sa;
		int d = dst[i] * dst[3] * (255 - sa) / 255;
		dst[i] = clamp_byte(out_a > 0 ? (s + d) / out_a : 0);
	}
	dst[3] = clamp_byte(out_a);
}

// dst[x0..x0+w, y0..y0+h] gets src's from-rectangle, scaled by nearest
// neighbour, which is what pixel art wants. Anything outside dst is clipped.
// clip, when given, is a rectangle of the destination outside which nothing
// is written: {x0, y0, x1, y1} with x1 and y1 past the end. What wanted it is
// Luanti's [lowpart, which draws only the bottom part of an overlay that has
// been stretched over the whole image.
static void blit(Canvas &dst, const Canvas &src, int from[4], int at[2],
		int size[2], BlendMode mode, const int *clip = nullptr)
{
	if(size[0] <= 0 || size[1] <= 0 || from[2] <= 0 || from[3] <= 0)
		return;
	for(int dy = 0; dy < size[1]; dy++){
		int y = at[1] + dy;
		if(y < 0 || y >= dst.h)
			continue;
		if(clip && (y < clip[1] || y >= clip[3]))
			continue;
		int sy = from[1] + (int)((int64_t)dy * from[3] / size[1]);
		if(sy < 0 || sy >= src.h)
			continue;
		for(int dx = 0; dx < size[0]; dx++){
			int x = at[0] + dx;
			if(x < 0 || x >= dst.w)
				continue;
			if(clip && (x < clip[0] || x >= clip[2]))
				continue;
			int sx = from[0] + (int)((int64_t)dx * from[2] / size[0]);
			if(sx < 0 || sx >= src.w)
				continue;
			blend_pixel(&src.data[((size_t)sy * src.w + sx) * 4],
					dst.at(x, y), mode);
		}
	}
}

// The source mapped onto a parallelogram: its own four corners go to at,
// at+u, at+u+v and at+v. This is the one thing a rectangular blit cannot do
// and the little cube an inventory draws a voxel as needs -- three faces,
// three parallelograms.
//
// Worked backwards, from each destination pixel to the source pixel it came
// from, so that the result has no gaps whatever the edges are: the matrix of
// the two edge vectors is inverted and every pixel of the parallelogram's
// bounding box is asked which source pixel it holds. Pixel centres decide it,
// so two parallelograms sharing an edge claim the pixels along it once each.
static void shear(Canvas &dst, const Canvas &src, const int at[2],
		const int u[2], const int v[2], BlendMode mode)
{
	double det = (double)u[0] * v[1] - (double)u[1] * v[0];
	if(std::fabs(det) < 1e-9)
		return; // A parallelogram with no area covers nothing
	double xs[4] = {(double)at[0], (double)(at[0] + u[0]),
			(double)(at[0] + v[0]), (double)(at[0] + u[0] + v[0])};
	double ys[4] = {(double)at[1], (double)(at[1] + u[1]),
			(double)(at[1] + v[1]), (double)(at[1] + u[1] + v[1])};
	int x0 = std::max(0, (int)std::floor(*std::min_element(xs, xs + 4)));
	int x1 = std::min(dst.w, (int)std::ceil(*std::max_element(xs, xs + 4)));
	int y0 = std::max(0, (int)std::floor(*std::min_element(ys, ys + 4)));
	int y1 = std::min(dst.h, (int)std::ceil(*std::max_element(ys, ys + 4)));
	for(int y = y0; y < y1; y++){
		for(int x = x0; x < x1; x++){
			double px = x + 0.5 - at[0];
			double py = y + 0.5 - at[1];
			// (a, b) such that the pixel is at a*u + b*v from at
			double a = (v[1] * px - v[0] * py) / det;
			double b = (u[0] * py - u[1] * px) / det;
			if(a < 0.0 || a >= 1.0 || b < 0.0 || b >= 1.0)
				continue;
			int sx = (int)(a * src.w);
			int sy = (int)(b * src.h);
			if(sx < 0 || sx >= src.w || sy < 0 || sy >= src.h)
				continue;
			blend_pixel(&src.data[((size_t)sy * src.w + sx) * 4],
					dst.at(x, y), mode);
		}
	}
}

// The eight symmetries of a square, in Luanti's order: 0 identity, 1..3
// rotations by 90 degrees counterclockwise, 4 flip x, 5..7 that flip followed
// by the rotations. An odd transform swaps the two dimensions.
static void transform_canvas(Canvas &c, int transform)
{
	if(transform < 0 || transform > 7)
		throw Exception(ss_()+"compose_image(): transform "+itos(transform)+
				" is not one of the eight");
	if(transform == 0)
		return;
	Canvas out;
	out.reset((transform % 2) ? c.h : c.w, (transform % 2) ? c.w : c.h);
	static const int SXN[8] = {0, 3, 1, 2, 1, 2, 0, 3};
	static const int SYN[8] = {2, 0, 3, 1, 2, 0, 3, 1};
	for(int dy = 0; dy < out.h; dy++){
		for(int dx = 0; dx < out.w; dx++){
			int entries[4] = {dx, out.w - 1 - dx, dy, out.h - 1 - dy};
			int sx = entries[SXN[transform]];
			int sy = entries[SYN[transform]];
			if(sx < 0 || sx >= c.w || sy < 0 || sy >= c.h)
				continue;
			memcpy(out.at(dx, dy), c.at(sx, sy), 4);
		}
	}
	c.w = out.w;
	c.h = out.h;
	c.data.swap(out.data);
}

// Blends every pixel towards a colour. ratio is 0...255; a fully transparent
// pixel is left alone, because its rgb is not a colour anybody chose.
static void colorize(Canvas &c, const int color[4], int ratio)
{
	for(size_t i = 0; i < c.data.size(); i += 4){
		uint8_t *p = &c.data[i];
		if(p[3] == 0)
			continue;
		if(ratio >= 255){
			for(int k = 0; k < 3; k++)
				p[k] = clamp_byte(color[k]);
			p[3] = clamp_byte(p[3] * clamp_byte(color[3]) / 255);
			continue;
		}
		for(int k = 0; k < 3; k++)
			p[k] = clamp_byte((color[k] * ratio + p[k] * (255 - ratio)) / 255);
	}
}

// Hue in degrees, saturation and lightness as percentages of the way towards
// full or empty, which is how an image editor's hue-saturation tool reads.
static void hue_saturation(Canvas &c, double hue, double saturation,
		double lightness)
{
	double norm_s = saturation / 100.0;
	double norm_l = lightness / 100.0;
	for(size_t i = 0; i < c.data.size(); i += 4){
		uint8_t *p = &c.data[i];
		magic::Color in(p[0] / 255.0f, p[1] / 255.0f, p[2] / 255.0f);
		float h = in.Hue();
		float s = in.SaturationHSL();
		float l = in.Lightness();
		if(norm_l < 0)
			l *= (float)(norm_l + 1.0);
		else
			l = (float)(l + norm_l * (1.0 - l));
		s = (float)(s * (norm_s + 1.0));
		if(s < 0.0f)
			s = 0.0f;
		if(s > 1.0f)
			s = 1.0f;
		h = (float)fmod(h + hue / 360.0, 1.0);
		if(h < 0.0f)
			h += 1.0f;
		magic::Color out;
		out.FromHSL(h, s, l, 1.0f);
		p[0] = clamp_byte((int)(out.r_ * 255.0f + 0.5f));
		p[1] = clamp_byte((int)(out.g_ * 255.0f + 0.5f));
		p[2] = clamp_byte((int)(out.b_ * 255.0f + 0.5f));
	}
}

static void apply_op(magic::Context *context, Canvas &c,
		const luabind::object &t, bool &have_canvas)
{
	if(luabind::type(t) != LUA_TTABLE)
		throw Exception("compose_image(): an op is not a table");
	ss_ op = table_string(t, "op");

	if(op == "blit"){
		ss_ src_name = table_string(t, "src");
		ss_ src_data = table_bytes(t, "src_data");
		if(src_name == "" && src_data == "")
			throw Exception("compose_image(): blit has no src");
		Canvas src;
		if(src_name != "")
			load_source(context, src_name, src);
		else
			load_source_data(context, src_data, src);
		int from[4] = {0, 0, src.w, src.h};
		table_ints(t, "from", from, 4);
		int at[2] = {0, 0};
		table_ints(t, "at", at, 2);
		int size[2] = {from[2], from[3]};
		table_ints(t, "size", size, 2);
		// The first blit of a composition that was given no size decides it,
		// which is what makes a chain of overlays take the base image's size
		if(!have_canvas){
			c.reset(at[0] + size[0], at[1] + size[1]);
			have_canvas = true;
		}
		// fill stretches the source over the whole canvas, which is what an
		// overlay of a different size wants
		luabind::object fill_o = t["fill"];
		if(fill_o && luabind::object_cast<bool>(fill_o)){
			at[0] = 0;
			at[1] = 0;
			size[0] = c.w;
			size[1] = c.h;
		}
		// A clip rectangle in fractions of the canvas, because what wants
		// one -- an overlay stretched over the whole image, of which only a
		// part is drawn -- does not know the canvas in pixels
		double clip_f[4] = {0.0, 0.0, 1.0, 1.0};
		int clip[4] = {0, 0, c.w, c.h};
		const int *clip_p = nullptr;
		if(table_numbers(t, "clip", clip_f, 4) == 4){
			clip[0] = (int)std::floor(clip_f[0] * c.w + 0.5);
			clip[1] = (int)std::floor(clip_f[1] * c.h + 0.5);
			clip[2] = (int)std::floor(clip_f[2] * c.w + 0.5);
			clip[3] = (int)std::floor(clip_f[3] * c.h + 0.5);
			clip_p = clip;
		}
		blit(c, src, from, at, size, parse_blend(table_string(t, "blend")),
				clip_p);
		return;
	}

	if(op == "fill"){
		int color[4] = {0, 0, 0, 255};
		table_ints(t, "color", color, 4);
		if(!have_canvas)
			throw Exception("compose_image(): fill before there is a canvas");
		int at[2] = {0, 0};
		table_ints(t, "at", at, 2);
		int size[2] = {c.w, c.h};
		table_ints(t, "size", size, 2);
		BlendMode mode = parse_blend(table_string(t, "blend"));
		uint8_t px[4] = {clamp_byte(color[0]), clamp_byte(color[1]),
				clamp_byte(color[2]), clamp_byte(color[3])};
		for(int y = at[1]; y < at[1] + size[1]; y++){
			if(y < 0 || y >= c.h)
				continue;
			for(int x = at[0]; x < at[0] + size[0]; x++){
				if(x < 0 || x >= c.w)
					continue;
				blend_pixel(px, c.at(x, y), mode);
			}
		}
		return;
	}

	if(!have_canvas)
		throw Exception("compose_image(): \""+op+
				"\" before there is a canvas");

	if(op == "shear"){
		ss_ src_name = table_string(t, "src");
		if(src_name == "")
			throw Exception("compose_image(): shear has no src");
		Canvas src;
		load_source(context, src_name, src);
		// Only a part of the source, in fractions of it: a face of a
		// node box is the part of the tile its extent covers
		double part[4] = {0.0, 0.0, 1.0, 1.0};
		if(table_numbers(t, "part", part, 4) == 4){
			const int x0 = std::max(0, std::min(src.w - 1,
					(int)std::floor(part[0] * src.w + 0.5)));
			const int y0 = std::max(0, std::min(src.h - 1,
					(int)std::floor(part[1] * src.h + 0.5)));
			const int x1 = std::max(x0 + 1, std::min(src.w,
					(int)std::floor(part[2] * src.w + 0.5)));
			const int y1 = std::max(y0 + 1, std::min(src.h,
					(int)std::floor(part[3] * src.h + 0.5)));
			Canvas cut;
			cut.reset(x1 - x0, y1 - y0);
			for(int y = y0; y < y1; y++)
				memcpy(cut.at(0, y - y0), src.at(x0, y), (size_t)cut.w * 4);
			src = cut;
		}
		int at[2] = {0, 0};
		table_ints(t, "at", at, 2);
		int u[2] = {src.w, 0};
		int v[2] = {0, src.h};
		table_ints(t, "u", u, 2);
		table_ints(t, "v", v, 2);
		shear(c, src, at, u, v, parse_blend(table_string(t, "blend")));
		return;
	}

	if(op == "multiply"){
		int color[4] = {255, 255, 255, 255};
		table_ints(t, "color", color, 4);
		for(size_t i = 0; i < c.data.size(); i += 4){
			for(int k = 0; k < 4; k++)
				c.data[i + k] = (uint8_t)(c.data[i + k] *
						clamp_byte(color[k]) / 255);
		}
		return;
	}
	if(op == "invert"){
		// Which channels, as flags; Luanti's [invert:<mode> with r, g, b, a
		int channels[4] = {0, 0, 0, 0};
		table_ints(t, "channels", channels, 4);
		for(size_t i = 0; i < c.data.size(); i += 4){
			for(int k = 0; k < 4; k++)
				if(channels[k])
					c.data[i + k] = (uint8_t)(255 - c.data[i + k]);
		}
		return;
	}
	if(op == "contrast"){
		// Luanti's [contrast:<contrast>:<brightness>, both -127..127, its
		// own curve: the factor 259 (c + 255) / (255 (259 - c)) about 128
		const float contrast = (float)table_number(t, "contrast", 0);
		const float brightness = (float)table_number(t, "brightness", 0);
		const float factor = (259.0f * (contrast + 255.0f)) /
				(255.0f * (259.0f - contrast));
		for(size_t i = 0; i < c.data.size(); i += 4){
			for(int k = 0; k < 3; k++)
				c.data[i + k] = clamp_byte((int)(factor *
						((float)c.data[i + k] - 128.0f) + 128.0f + brightness));
		}
		return;
	}
	if(op == "colorize"){
		int color[4] = {255, 255, 255, 255};
		table_ints(t, "color", color, 4);
		colorize(c, color, (int)table_number(t, "ratio", 255));
		return;
	}
	if(op == "hsl"){
		hue_saturation(c, table_number(t, "hue", 0),
				table_number(t, "saturation", 0),
				table_number(t, "lightness", 0));
		return;
	}
	if(op == "chromakey"){
		// Every pixel of one colour becomes fully transparent, which is what
		// Luanti's [makealpha does: a texture drawn on a solid background
		// with no alpha channel of its own says which colour the background
		// was. The colour is compared as it is, because that is what a
		// texture like that is drawn with -- one exact background colour.
		int color[3] = {0, 0, 0};
		table_ints(t, "color", color, 3);
		uint8_t r = clamp_byte(color[0]);
		uint8_t g = clamp_byte(color[1]);
		uint8_t b = clamp_byte(color[2]);
		for(size_t i = 0; i + 3 < c.data.size(); i += 4){
			if(c.data[i] == r && c.data[i + 1] == g && c.data[i + 2] == b)
				c.data[i + 3] = 0;
		}
		return;
	}
	if(op == "alpha"){
		uint8_t a = clamp_byte((int)table_number(t, "value", 255));
		for(size_t i = 3; i < c.data.size(); i += 4)
			c.data[i] = a;
		return;
	}
	if(op == "transform"){
		transform_canvas(c, (int)table_number(t, "transform", 0));
		return;
	}
	if(op == "resize" || op == "crop"){
		int from[4] = {0, 0, c.w, c.h};
		if(op == "crop"){
			// Either a rectangle, or one cell of a grid the canvas is cut
			// into, which is what a sprite sheet or a stack of animation
			// frames is
			int grid[2] = {1, 1};
			if(table_ints(t, "grid", grid, 2) == 2){
				// A zero says to work that side out so that the cells come
				// out square, which is what a strip of animation frames is:
				// as many frames as its height holds of its width.
				if(grid[0] == 0 && grid[1] > 0)
					grid[0] = std::max(1, c.w / std::max(1, c.h / grid[1]));
				if(grid[1] == 0 && grid[0] > 0)
					grid[1] = std::max(1, c.h / std::max(1, c.w / grid[0]));
				if(grid[0] < 1 || grid[1] < 1)
					throw Exception("compose_image(): crop grid is empty");
				int cell[2] = {0, 0};
				table_ints(t, "cell", cell, 2);
				from[2] = c.w / grid[0] > 0 ? c.w / grid[0] : 1;
				from[3] = c.h / grid[1] > 0 ? c.h / grid[1] : 1;
				from[0] = cell[0] * from[2];
				from[1] = cell[1] * from[3];
			} else {
				table_ints(t, "from", from, 4);
			}
		}
		int size[2] = {from[2], from[3]};
		table_ints(t, "size", size, 2);
		Canvas out;
		out.reset(size[0], size[1]);
		int at[2] = {0, 0};
		blit(out, c, from, at, size, BLEND_SET);
		c.w = out.w;
		c.h = out.h;
		c.data.swap(out.data);
		return;
	}
	throw Exception("compose_image(): unknown op \""+op+"\"");
}

// compose_image(args) -> width, height
//
// args.size is the canvas, args.ops the operations over it and args.write the
// path the result is saved to. See doc/client_api.txt.
static int l_compose_image(lua_State *L)
{
	try {
		luabind::object args(luabind::from_stack(L, 1));
		if(!args || luabind::type(args) != LUA_TTABLE)
			throw Exception("compose_image(): args is not a table");

		// A written file has to end up somewhere the client owns; the caller
		// puts it where its resource dirs are, which is under the cache
		ss_ write = table_string(args, "write");
		if(write == "")
			throw Exception("compose_image(): args.write is missing");
		ss_ path = interface::fs::get_absolute_path(write);
		if(!interface::fs::is_inside_path(path,
				g_client_config.get<ss_>("cache_path")))
			throw Exception("compose_image(): \""+path+
					"\" is not under the cache path");
		// Only a .png: the bytes are one, and a file under the cache can
		// answer a plain-name load of a name no installed dir has
		if(path.size() < 4 || path.compare(path.size() - 4, 4, ".png") != 0)
			throw Exception("compose_image(): \""+path+"\" is not a .png");
		// The directory the file goes in, made if it is not there. Sandboxed
		// code has no way to make one and every caller would otherwise need
		// one made for it; it is under the cache like the file itself.
		size_t slash = path.find_last_of('/');
		if(slash != ss_::npos && slash > 0)
			interface::fs::create_directories(path.substr(0, slash));

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		magic::Context *context = buildat_app->get_scene()->GetContext();

		Canvas c;
		bool have_canvas = false;
		int size[2] = {0, 0};
		if(table_ints(args, "size", size, 2) == 2){
			c.reset(size[0], size[1]);
			have_canvas = true;
		}

		luabind::object ops = args["ops"];
		if(ops && luabind::type(ops) == LUA_TTABLE){
			for(luabind::iterator it(ops), end; it != end; ++it)
				apply_op(context, c, *it, have_canvas);
		}
		if(!have_canvas)
			throw Exception("compose_image(): nothing made a canvas");

		magic::SharedPtr<magic::Image> out(new magic::Image(context));
		out->SetSize(c.w, c.h, 4);
		out->SetData(&c.data[0]);
		if(!out->SavePNG(path.c_str()))
			throw Exception("compose_image(): could not write \""+path+"\"");

		lua_pushinteger(L, c.w);
		lua_pushinteger(L, c.h);
		return 2;
	} catch(std::exception &e){
		return luaL_error(L, "%s", e.what());
	}
}

// read_image(resource_name) -> width, height, rgba
//
// The pixels themselves, for whoever has to look at them rather than draw
// them. What wanted this is a colour palette: an image of a few dozen pixels
// that a game indexes to say what colour something is drawn in.
static int l_read_image(lua_State *L)
{
	try {
		ss_ name = luaL_checkstring(L, 1);

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		magic::Context *context = buildat_app->get_scene()->GetContext();

		Canvas c;
		load_source(context, name, c);

		lua_pushinteger(L, c.w);
		lua_pushinteger(L, c.h);
		lua_pushlstring(L, (const char*)&c.data[0], c.data.size());
		return 3;
	} catch(std::exception &e){
		return luaL_error(L, "%s", e.what());
	}
}

void init_image(lua_State *L)
{
	lua_pushcfunction(L, guarded<l_compose_image>);
	lua_setglobal(L, "__buildat_compose_image");
	lua_pushcfunction(L, guarded<l_read_image>);
	lua_setglobal(L, "__buildat_read_image");
}

} // namespace lua_bindings
// vim: set noet ts=4 sw=4:
