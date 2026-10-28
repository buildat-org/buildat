// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_rust's client, run by the engine's default client_main: a
// cube; space sends "key", and the server's "move" puts the cube where it
// says.
#![no_std]

use buildat_wasm::{self as b, Event, Handle};
use core::fmt::Write;
use sample_rust_shared as s;

static mut CUBE: Option<Handle> = None;
static mut EVENT: [u8; b::EVENT_MAX] = [0; b::EVENT_MAX];

// A log line of at most 200 bytes, formatted
struct Line { b: [u8; 200], n: usize }
impl Write for Line {
	fn write_str(&mut self, s: &str) -> core::fmt::Result {
		let take = s.len().min(self.b.len() - self.n);
		self.b[self.n..self.n + take].copy_from_slice(&s.as_bytes()[..take]);
		self.n += take;
		Ok(())
	}
}
macro_rules! logf {
	($($a:tt)*) => {{
		let mut l = Line { b: [0; 200], n: 0 };
		let _ = write!(l, $($a)*);
		unsafe { b::sys::log(l.b.as_ptr(), l.n as u32) };
	}};
}

// An orange cube of side 1, its faces a little apart in shade
fn draw_cube(cube: Handle) {
	const FACES: [[[f32; 3]; 4]; 6] = [
		[[-1.,-1.,-1.], [-1., 1.,-1.], [ 1., 1.,-1.], [ 1.,-1.,-1.]],
		[[ 1.,-1., 1.], [ 1., 1., 1.], [-1., 1., 1.], [-1.,-1., 1.]],
		[[-1.,-1., 1.], [-1., 1., 1.], [-1., 1.,-1.], [-1.,-1.,-1.]],
		[[ 1.,-1.,-1.], [ 1., 1.,-1.], [ 1., 1., 1.], [ 1.,-1., 1.]],
		[[-1., 1.,-1.], [-1., 1., 1.], [ 1., 1., 1.], [ 1., 1.,-1.]],
		[[-1.,-1., 1.], [-1.,-1.,-1.], [ 1.,-1.,-1.], [ 1.,-1., 1.]],
	];
	const NORMALS: [[f32; 3]; 6] = [
		[0., 0., -1.], [0., 0., 1.], [-1., 0., 0.], [1., 0., 0.], [0., 1., 0.], [0., -1., 0.],
	];
	let mut v = [0f32; 24 * 12];
	let mut ix = [0u32; 36];
	for f in 0..6 {
		for k in 0..4 {
			let o = &mut v[(f * 4 + k) * 12..(f * 4 + k + 1) * 12];
			for a in 0..3 {
				o[a] = FACES[f][k][a] * 0.5;
				o[3 + a] = NORMALS[f][a];
				o[6 + a] = [1.0, 0.5, 0.1][a] * (0.7 + 0.05 * f as f32);
			}
			o[9] = 1.0;
		}
		for (k, q) in [0u32, 1, 2, 0, 2, 3].iter().enumerate() {
			ix[f * 6 + k] = f as u32 * 4 + q;
		}
	}
	b::geometry_set(cube, 0, &v, &ix);
}

#[no_mangle]
pub extern "C" fn packets() -> *const u8 {
	b"move\0".as_ptr()
}

#[no_mangle]
pub extern "C" fn frame(_dt: f32) {
	// One thread, and no export calls another: the only reference
	let cube = unsafe { &mut *core::ptr::addr_of_mut!(CUBE) };
	let buf = unsafe { &mut *core::ptr::addr_of_mut!(EVENT) };
	while let Some(e) = b::next_event(buf) {
		match e {
			Event::Start { camera, nodes, .. } => {
				let Some((c, _texture)) = nodes.get(0) else { continue };
				*cube = Some(c);
				b::node_set(camera, &[0., 0., -5., 1., 0., 0., 0., 1., 1., 1.]);
				draw_cube(c);
				b::node_set(c, &[s::x_of(0), 0., 0., 1., 0., 0., 0., 1., 1., 1.]);
				logf!("drew a cube");
			}
			Event::KeyDown { key: 32, repeat: false, .. } => {
				b::send_packet(s::KEY, &[]);
				logf!("space: sent key");
			}
			Event::Packet { name, data } if name == s::MOVE.as_bytes() => {
				let (Some(c), Some((count, x))) = (*cube, s::decode_move(data)) else {
					continue
				};
				b::node_set(c, &[x, 0., 0., 1., 0., 0., 0., 1., 1., 1.]);
				logf!("moved: count {}, x {}", count, x);
			}
			_ => {}
		}
	}
}
