// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//! interface/wasm_api.h in Rust ([CLIENT_WASM]): the imports a module's
//! client .wasm can call, and the events of the engine's default
//! client_main. The header says what each does and what the client
//! checks; this is the same, with slices for pointer and length pairs.
//!
//! A module's `wasm/` with a Cargo.toml is built by the server with cargo
//! for wasm32-unknown-unknown (a cdylib, `#![no_std]`). Its exports are
//! `#[no_mangle] pub extern "C" fn`s, as an `int f(int)` is in C:
//!
//! ```ignore
//! #[no_mangle]
//! pub extern "C" fn frame(dt: f32) { ... }
//! ```
#![no_std]

/// The imports as they are, for what the safe functions below do not
/// cover. Each pointer and length is checked by the client: past the
/// module's memory is a trap.
pub mod sys {
	#[link(wasm_import_module = "buildat")]
	extern "C" {
		pub fn log(text: *const u8, len: u32);
		pub fn time_ms() -> u32;
		pub fn voxels_size(volume: i32, out: *mut i32);
		pub fn voxels_read(volume: i32, region: *const i32, out: *mut u32,
				out_bytes: u32) -> i32;
		pub fn geometry_set(node: i32, geometry: u32, vertices: *const f32,
				vertex_count: u32, indices: *const u32, index_count: u32);
		pub fn texture_set(texture: i32, width: u32, height: u32,
				rgba: *const u8, len: u32);
		pub fn node_get(node: i32, transform: *mut f32);
		pub fn node_set(node: i32, transform: *const f32);
		pub fn send_packet(name: *const u8, name_len: u32, data: *const u8,
				data_len: u32);
		pub fn event_take(buf: *mut u8, cap: u32) -> i32;
		pub fn drop(handle: i32);
	}
}

/// [CLIENT_WASM_BINDINGS] interface/buildat_client.h's calls (the classes
/// and verbs of the client's Lua sandbox), generated: the feature "client"
#[cfg(feature = "client")]
pub mod client;

/// A node, a texture or a voxel volume, as the module was handed it
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Handle(pub i32);

/// Position x, y, z, rotation w, x, y, z, scale x, y, z, in the parent's
/// space
pub type Transform = [f32; 10];

fn len32(n: usize) -> u32 {
	// A slice of more than 4 GiB cannot be in a wasm32 memory
	n as u32
}

/// A line in the client's log (at most 1000 bytes shown)
pub fn log(text: &str) {
	unsafe { sys::log(text.as_ptr(), len32(text.len())) }
}

/// Whole milliseconds since the module was loaded
pub fn time_ms() -> u32 {
	unsafe { sys::time_ms() }
}

/// A volume's lowest corner and its size in voxels, x, y, z
pub fn voxels_size(volume: Handle) -> [i32; 6] {
	let mut out = [0i32; 6];
	unsafe { sys::voxels_size(volume.0, out.as_mut_ptr()) };
	out
}

/// The first plane of each voxel of a box (corner, size) of the volume, x
/// fastest, then y, then z; how many were written
pub fn voxels_read(volume: Handle, region: &[i32; 6], out: &mut [u32]) -> usize {
	let bytes = out.len().saturating_mul(4).min(u32::MAX as usize);
	unsafe {
		sys::voxels_read(volume.0, region.as_ptr(), out.as_mut_ptr(),
				bytes as u32) as usize
	}
}

/// A node's geometry number `geometry` (0 to 15): 12 floats a vertex
/// (position, normal, colour r, g, b, a, texture coordinate) and a
/// triangle list of indices into them
pub fn geometry_set(node: Handle, geometry: u32, vertices: &[f32], indices: &[u32]) {
	unsafe {
		sys::geometry_set(node.0, geometry, vertices.as_ptr(),
				len32(vertices.len() / 12), indices.as_ptr(), len32(indices.len()))
	}
}

/// A texture's pixels, RGBA, rows from the top; `rgba` is width * height
/// * 4 bytes
pub fn texture_set(texture: Handle, width: u32, height: u32, rgba: &[u8]) {
	unsafe {
		sys::texture_set(texture.0, width, height, rgba.as_ptr(),
				len32(rgba.len()))
	}
}

pub fn node_get(node: Handle) -> Transform {
	let mut t = [0f32; 10];
	unsafe { sys::node_get(node.0, t.as_mut_ptr()) };
	t
}

/// A value not finite or past 1e9 is a trap
pub fn node_set(node: Handle, transform: &Transform) {
	unsafe { sys::node_set(node.0, transform.as_ptr()) }
}

/// A packet to the server, named "<module>:<name>", sent when the call
/// returns
pub fn send_packet(name: &str, data: &[u8]) {
	unsafe {
		sys::send_packet(name.as_ptr(), len32(name.len()), data.as_ptr(),
				len32(data.len()))
	}
}

/// The oldest queued event into `buf`: None with none, its length, which
/// is taken only if it is at most `buf.len()`
pub fn event_take(buf: &mut [u8]) -> Option<usize> {
	let cap = buf.len().min(u32::MAX as usize) as u32;
	let n = unsafe { sys::event_take(buf.as_mut_ptr(), cap) };
	if n < 0 { None } else { Some(n as usize) }
}

/// The longest event the default client_main sends
pub const EVENT_MAX: usize = 8 + 64 + 65536;

pub const EVENT_START: i32 = 1;
pub const EVENT_KEY_DOWN: i32 = 2;
pub const EVENT_KEY_UP: i32 = 3;
pub const EVENT_MOUSE_DOWN: i32 = 4;
pub const EVENT_MOUSE_UP: i32 = 5;
pub const EVENT_MOUSE_MOVE: i32 = 6;
pub const EVENT_WHEEL: i32 = 7;
pub const EVENT_PACKET: i32 = 8;
pub const EVENT_RESIZE: i32 = 9;
pub const EVENT_OBJECT: i32 = 10;

/// The mesh nodes of a Start event, each with its texture
#[derive(Clone, Copy, Debug)]
pub struct Nodes<'a>(&'a [u8]);

impl<'a> Nodes<'a> {
	pub fn len(&self) -> usize { self.0.len() / 8 }
	pub fn is_empty(&self) -> bool { self.len() == 0 }
	/// The node and its texture
	pub fn get(&self, i: usize) -> Option<(Handle, Handle)> {
		if i >= self.len() {
			return None;
		}
		Some((Handle(word(self.0, i * 2)), Handle(word(self.0, i * 2 + 1))))
	}
}

/// An event of the default client_main (interface/wasm_api.h)
#[derive(Clone, Copy, Debug)]
pub enum Event<'a> {
	Start { camera: Handle, light: Handle, width: i32, height: i32, nodes: Nodes<'a> },
	KeyDown { key: i32, repeat: bool, qualifiers: i32 },
	KeyUp { key: i32 },
	MouseDown { button: i32 },
	MouseUp { button: i32 },
	MouseMove { x: i32, y: i32, dx: i32, dy: i32 },
	Wheel { steps: i32 },
	/// The name without "<module>:"
	Packet { name: &'a [u8], data: &'a [u8] },
	Resize { width: i32, height: i32 },
	/// An object's event the module subscribed to (the feature "client"),
	/// handle 0 for a global one: its name, and its fields as
	/// client::fields() reads them
	Object { handle: Handle, name: &'a [u8], fields: &'a [u8] },
	/// A kind this crate does not know, or one too short for its kind
	Other(&'a [u8]),
}

fn word(b: &[u8], i: usize) -> i32 {
	match b.get(i * 4..i * 4 + 4) {
		Some(w) => i32::from_le_bytes([w[0], w[1], w[2], w[3]]),
		None => 0,
	}
}

impl<'a> Event<'a> {
	pub fn parse(b: &'a [u8]) -> Event<'a> {
		let words = b.len() / 4;
		let need = |n: usize| words >= n;
		match word(b, 0) {
			EVENT_START if need(6) => {
				let n = word(b, 5).max(0) as usize;
				let end = (24 + n.saturating_mul(8)).min(b.len() / 8 * 8);
				Event::Start { camera: Handle(word(b, 1)), light: Handle(word(b, 2)),
						width: word(b, 3), height: word(b, 4),
						nodes: Nodes(&b[24.min(end)..end]) }
			}
			EVENT_KEY_DOWN if need(4) => Event::KeyDown { key: word(b, 1),
					repeat: word(b, 2) != 0, qualifiers: word(b, 3) },
			EVENT_KEY_UP if need(2) => Event::KeyUp { key: word(b, 1) },
			EVENT_MOUSE_DOWN if need(2) => Event::MouseDown { button: word(b, 1) },
			EVENT_MOUSE_UP if need(2) => Event::MouseUp { button: word(b, 1) },
			EVENT_MOUSE_MOVE if need(5) => Event::MouseMove { x: word(b, 1),
					y: word(b, 2), dx: word(b, 3), dy: word(b, 4) },
			EVENT_WHEEL if need(2) => Event::Wheel { steps: word(b, 1) },
			EVENT_PACKET if need(2) => {
				let n = word(b, 1).max(0) as usize;
				match b.get(8..8usize.saturating_add(n)) {
					Some(name) => Event::Packet { name, data: &b[8 + n..] },
					None => Event::Other(b),
				}
			}
			EVENT_RESIZE if need(3) => Event::Resize { width: word(b, 1),
					height: word(b, 2) },
			EVENT_OBJECT if need(3) => {
				let n = word(b, 2).max(0) as usize;
				match b.get(12..12usize.saturating_add(n)) {
					Some(name) => Event::Object { handle: Handle(word(b, 1)), name,
							fields: &b[12 + n..] },
					None => Event::Other(b),
				}
			}
			_ => Event::Other(b),
		}
	}
}

/// The next event, parsed, in `buf`, which should be EVENT_MAX bytes: None
/// with none queued, or one too long for `buf` (it stays queued)
pub fn next_event(buf: &mut [u8]) -> Option<Event<'_>> {
	let n = event_take(buf)?;
	if n > buf.len() {
		return None;
	}
	Some(Event::parse(&buf[..n]))
}

#[cfg(all(feature = "panic_handler", target_arch = "wasm32", not(test)))]
#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
	use core::fmt::Write;
	struct Line { b: [u8; 512], n: usize }
	impl Write for Line {
		fn write_str(&mut self, s: &str) -> core::fmt::Result {
			let take = s.len().min(self.b.len() - self.n);
			self.b[self.n..self.n + take].copy_from_slice(&s.as_bytes()[..take]);
			self.n += take;
			Ok(())
		}
	}
	let mut line = Line { b: [0; 512], n: 0 };
	let _ = write!(line, "panic: {}", info);
	unsafe { sys::log(line.b.as_ptr(), line.n as u32) };
	core::arch::wasm32::unreachable()
}

#[cfg(test)]
mod tests {
	use super::*;

	fn words(w: &[i32]) -> [u8; 64] {
		let mut b = [0u8; 64];
		for (i, v) in w.iter().enumerate() {
			b[i * 4..i * 4 + 4].copy_from_slice(&v.to_le_bytes());
		}
		b
	}

	#[test]
	fn parse() {
		let b = words(&[EVENT_START, 3, 4, 640, 480, 2, 10, 11, 12, 13]);
		match Event::parse(&b[..40]) {
			Event::Start { camera, light, width, height, nodes } => {
				assert_eq!((camera, light, width, height), (Handle(3), Handle(4), 640, 480));
				assert_eq!(nodes.len(), 2);
				assert_eq!(nodes.get(1), Some((Handle(12), Handle(13))));
				assert_eq!(nodes.get(2), None);
			}
			e => panic!("{:?}", e),
		}
		// n says more nodes than there are bytes: as many as there are
		match Event::parse(&b[..32]) {
			Event::Start { nodes, .. } => assert_eq!(nodes.len(), 1),
			e => panic!("{:?}", e),
		}
		let b = words(&[EVENT_KEY_DOWN, 32, 1, 2]);
		assert!(matches!(Event::parse(&b[..16]),
				Event::KeyDown { key: 32, repeat: true, qualifiers: 2 }));
		assert!(matches!(Event::parse(&b[..12]), Event::Other(_)));
		let mut p = [0u8; 15];
		p[..12].copy_from_slice(&words(&[EVENT_PACKET, 4, 0])[..12]);
		p[8..12].copy_from_slice(b"echo");
		p[12..].copy_from_slice(b"abc");
		match Event::parse(&p) {
			Event::Packet { name, data } => assert_eq!((name, data), (&b"echo"[..], &b"abc"[..])),
			e => panic!("{:?}", e),
		}
		// A name past the event's end
		p[4] = 200;
		assert!(matches!(Event::parse(&p), Event::Other(_)));
		// An object's event: the handle, the name and the fields after it
		let mut o = [0u8; 18];
		o[..12].copy_from_slice(&words(&[EVENT_OBJECT, 7, 4])[..12]);
		o[12..16].copy_from_slice(b"Name");
		o[16..].copy_from_slice(&[1, 0]);
		match Event::parse(&o) {
			Event::Object { handle, name, fields } =>
				assert_eq!((handle, name, fields), (Handle(7), &b"Name"[..], &[1u8, 0][..])),
			e => panic!("{:?}", e),
		}
		o[8] = 100;
		assert!(matches!(Event::parse(&o), Event::Other(_)));
		assert!(matches!(Event::parse(&[]), Event::Other(_)));
	}
}
