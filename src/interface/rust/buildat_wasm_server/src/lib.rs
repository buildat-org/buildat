// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//! interface/wasm_server_api.h in Rust ([SERVER_WASM]): the imports a
//! module's server .wasm can call. The header says what each does, which
//! group of them meta.json grants, and what the server checks; this is the
//! same, with slices for pointer and length pairs.
//!
//! A module's `"server_wasm": {"source": "server"}` with a Cargo.toml is
//! built by the server with cargo for wasm32-unknown-unknown (a cdylib,
//! `#![no_std]`). The server calls its exports `init`, `events` and those
//! meta.json names "callable", each taking and returning nothing:
//!
//! ```ignore
//! #[no_mangle]
//! pub extern "C" fn events() {
//!     let mut buf = [0u8; buildat_wasm_server::EVENT_MAX];
//!     while let Some(e) = buildat_wasm_server::next_event(&mut buf) { ... }
//! }
//! ```
#![no_std]

/// The imports as they are. Each pointer and length is checked by the
/// server: past the module's memory is a trap.
pub mod sys {
	#[link(wasm_import_module = "buildat")]
	extern "C" {
		pub fn log(text: *const u8, len: u32);
		pub fn time_ms() -> u32;
		pub fn event_take(buf: *mut u8, cap: u32) -> i32;
		pub fn drop(handle: i32);
		pub fn call_input(buf: *mut u8, cap: u32) -> i32;
		pub fn call_output(data: *const u8, len: u32);
		pub fn event_subscribe(name: *const u8, len: u32);
		pub fn packet_subscribe(name: *const u8, len: u32);
		pub fn packet_send(peer: u32, name: *const u8, name_len: u32,
				data: *const u8, data_len: u32);
		pub fn storage_get(key: *const u8, key_len: u32, out: *mut u8,
				cap: u32) -> i32;
		pub fn storage_set(key: *const u8, key_len: u32, value: *const u8,
				value_len: u32);
		pub fn storage_remove(key: *const u8, key_len: u32);
		pub fn scene_create() -> i32;
		pub fn scene_peer(scene: i32, peer: u32);
		pub fn node_create(scene: i32) -> i32;
		pub fn node_get(node: i32, transform: *mut f32);
		pub fn node_set(node: i32, transform: *const f32);
		pub fn node_remove(node: i32);
		pub fn world_create(scene: i32, sections: *const i32);
		pub fn voxel_define(scene: i32, name: *const u8, name_len: u32,
				texture: *const u8, texture_len: u32) -> i32;
		pub fn voxels_set(scene: i32, b: *const i32, ids: *const u32,
				ids_bytes: u32);
		pub fn voxels_read(scene: i32, b: *const i32, out: *mut u32,
				out_bytes: u32) -> i32;
		pub fn call(module: *const u8, module_len: u32, func: *const u8,
				func_len: u32, input: *const u8, input_len: u32, out: *mut u8,
				out_cap: u32) -> i32;
	}
}

/// A scene or a node, as the module was handed it
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Handle(pub i32);

/// Position x, y, z, rotation w, x, y, z, scale x, y, z
pub type Transform = [f32; 10];

fn len32(n: usize) -> u32 {
	// A slice of more than 4 GiB cannot be in a wasm32 memory
	n as u32
}

fn cap32(n: usize) -> u32 {
	n.min(u32::MAX as usize) as u32
}

fn opt(n: i32) -> Option<usize> {
	if n < 0 { None } else { Some(n as usize) }
}

/// A line in the server's log, prefixed with the module's name
pub fn log(text: &str) {
	unsafe { sys::log(text.as_ptr(), len32(text.len())) }
}

/// Whole milliseconds since the module was loaded
pub fn time_ms() -> u32 {
	unsafe { sys::time_ms() }
}

/// The oldest queued event into `buf`: None with none, its length, which
/// is taken only if it is at most `buf.len()`
pub fn event_take(buf: &mut [u8]) -> Option<usize> {
	opt(unsafe { sys::event_take(buf.as_mut_ptr(), cap32(buf.len())) })
}

/// The module is done with a handle
pub fn drop(handle: Handle) {
	unsafe { sys::drop(handle.0) }
}

/// Inside a call of a "callable" export: its input into `buf`, its length
/// (taken only if it fits); None outside one
pub fn call_input(buf: &mut [u8]) -> Option<usize> {
	opt(unsafe { sys::call_input(buf.as_mut_ptr(), cap32(buf.len())) })
}

/// The output of the call being served, at most 1 MiB
pub fn call_output(data: &[u8]) {
	unsafe { sys::call_output(data.as_ptr(), len32(data.len())) }
}

/// "events": "core:start", "core:tick", "network:client_connected" or
/// "network:client_disconnected"
pub fn event_subscribe(name: &str) {
	unsafe { sys::event_subscribe(name.as_ptr(), len32(name.len())) }
}

/// "packets": the packets "<module>:<name>" peers send, as Packet events
pub fn packet_subscribe(name: &str) {
	unsafe { sys::packet_subscribe(name.as_ptr(), len32(name.len())) }
}

/// "packets": a packet "<module>:<name>" to a peer, sent when the call
/// returns
pub fn packet_send(peer: u32, name: &str, data: &[u8]) {
	unsafe {
		sys::packet_send(peer, name.as_ptr(), len32(name.len()), data.as_ptr(),
				len32(data.len()))
	}
}

/// "storage": a key's value into `out`: None if there is none, else its
/// length, written only if it is at most `out.len()`
pub fn storage_get(key: &[u8], out: &mut [u8]) -> Option<usize> {
	opt(unsafe {
		sys::storage_get(key.as_ptr(), len32(key.len()), out.as_mut_ptr(),
				cap32(out.len()))
	})
}

pub fn storage_set(key: &[u8], value: &[u8]) {
	unsafe {
		sys::storage_set(key.as_ptr(), len32(key.len()), value.as_ptr(),
				len32(value.len()))
	}
}

pub fn storage_remove(key: &[u8]) {
	unsafe { sys::storage_remove(key.as_ptr(), len32(key.len())) }
}

/// "scene": a new scene
pub fn scene_create() -> Handle {
	Handle(unsafe { sys::scene_create() })
}

/// The scene a peer is shown; None: none of the module's
pub fn scene_peer(scene: Option<Handle>, peer: u32) {
	unsafe { sys::scene_peer(scene.map_or(0, |s| s.0), peer) }
}

pub fn node_create(scene: Handle) -> Handle {
	Handle(unsafe { sys::node_create(scene.0) })
}

pub fn node_get(node: Handle) -> Transform {
	let mut t = [0f32; 10];
	unsafe { sys::node_get(node.0, t.as_mut_ptr()) };
	t
}

/// A value not finite or past 1e9, or a zero rotation, is a trap
pub fn node_set(node: Handle, transform: &Transform) {
	unsafe { sys::node_set(node.0, transform.as_ptr()) }
}

pub fn node_remove(node: Handle) {
	unsafe { sys::node_remove(node.0) }
}

/// "voxels": the scene's world, from section sections[0..3] to
/// sections[3..6], both included
pub fn world_create(scene: Handle, sections: &[i32; 6]) {
	unsafe { sys::world_create(scene.0, sections.as_ptr()) }
}

/// A voxel type: its id. An empty texture is air.
pub fn voxel_define(scene: Handle, name: &str, texture: &str) -> u32 {
	unsafe {
		sys::voxel_define(scene.0, name.as_ptr(), len32(name.len()),
				texture.as_ptr(), len32(texture.len())) as u32
	}
}

/// A box (corner, size) of voxels set, an id each (0 leaves one as it is),
/// x fastest, then y, then z; `ids.len()` is the box's voxels
pub fn voxels_set(scene: Handle, b: &[i32; 6], ids: &[u32]) {
	let bytes = ids.len().saturating_mul(4).min(u32::MAX as usize);
	unsafe { sys::voxels_set(scene.0, b.as_ptr(), ids.as_ptr(), bytes as u32) }
}

/// A box's voxel ids into `out` (0: undefined): how many
pub fn voxels_read(scene: Handle, b: &[i32; 6], out: &mut [u32]) -> usize {
	let bytes = out.len().saturating_mul(4).min(u32::MAX as usize);
	unsafe {
		sys::voxels_read(scene.0, b.as_ptr(), out.as_mut_ptr(), bytes as u32)
				as usize
	}
}

/// "calls": another wasm module's callable export, with input; its
/// output's length (written into `out` only if it fits), or None when the
/// call was refused or failed (the log says why)
pub fn call(module: &str, func: &str, input: &[u8], out: &mut [u8]) -> Option<usize> {
	opt(unsafe {
		sys::call(module.as_ptr(), len32(module.len()), func.as_ptr(),
				len32(func.len()), input.as_ptr(), len32(input.len()),
				out.as_mut_ptr(), cap32(out.len()))
	})
}

/// The longest event the server queues: a packet with its name
pub const EVENT_MAX: usize = 12 + 64 + 65536;

pub const EVENT_START: i32 = 1;
pub const EVENT_TICK: i32 = 2;
pub const EVENT_PEER_JOINED: i32 = 3;
pub const EVENT_PEER_LEFT: i32 = 4;
pub const EVENT_PACKET: i32 = 5;

/// A server event (interface/wasm_server_api.h)
#[derive(Clone, Copy, Debug)]
pub enum Event<'a> {
	Start,
	Tick { dtime: f32 },
	PeerJoined { peer: u32 },
	PeerLeft { peer: u32 },
	/// The name without "<module>:"
	Packet { peer: u32, name: &'a [u8], data: &'a [u8] },
	/// A kind this crate does not know, or one too short for its kind
	Other(&'a [u8]),
}

fn word(b: &[u8], i: usize) -> u32 {
	match b.get(i * 4..i * 4 + 4) {
		Some(w) => u32::from_le_bytes([w[0], w[1], w[2], w[3]]),
		None => 0,
	}
}

impl<'a> Event<'a> {
	pub fn parse(b: &'a [u8]) -> Event<'a> {
		let need = |n: usize| b.len() / 4 >= n;
		match word(b, 0) as i32 {
			EVENT_START if need(1) => Event::Start,
			EVENT_TICK if need(2) => Event::Tick { dtime: f32::from_bits(word(b, 1)) },
			EVENT_PEER_JOINED if need(2) => Event::PeerJoined { peer: word(b, 1) },
			EVENT_PEER_LEFT if need(2) => Event::PeerLeft { peer: word(b, 1) },
			EVENT_PACKET if need(3) => {
				let n = word(b, 2) as usize;
				match b.get(12..12usize.saturating_add(n)) {
					Some(name) => Event::Packet { peer: word(b, 1), name,
							data: &b[12 + n..] },
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

	#[test]
	fn parse() {
		let mut b = [0u8; 20];
		b[..4].copy_from_slice(&5u32.to_le_bytes());
		b[4..8].copy_from_slice(&7u32.to_le_bytes());
		b[8..12].copy_from_slice(&3u32.to_le_bytes());
		b[12..15].copy_from_slice(b"key");
		b[15..].copy_from_slice(b"hello");
		match Event::parse(&b) {
			Event::Packet { peer, name, data } =>
				assert_eq!((peer, name, data), (7, &b"key"[..], &b"hello"[..])),
			e => panic!("{:?}", e),
		}
		// A name past the event's end
		b[8] = 100;
		assert!(matches!(Event::parse(&b), Event::Other(_)));
		let mut t = [0u8; 8];
		t[..4].copy_from_slice(&2u32.to_le_bytes());
		t[4..].copy_from_slice(&0.5f32.to_bits().to_le_bytes());
		assert!(matches!(Event::parse(&t), Event::Tick { dtime } if dtime == 0.5));
		assert!(matches!(Event::parse(&t[..4]), Event::Other(_)));
		assert!(matches!(Event::parse(&[]), Event::Other(_)));
	}
}
