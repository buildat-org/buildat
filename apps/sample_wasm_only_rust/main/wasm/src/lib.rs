// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_wasm_only's client (main/wasm/main.c) in Rust: run by the
// engine's default client_main, a cube it builds and turns, space changing
// its colour and sending a packet, the server's answer logged. The same
// log lines as the C one: the client cannot tell them apart.
#![no_std]

use buildat_wasm::{self as b, Event, Handle};
use core::fmt::Write;

struct State {
	camera: Handle,
	cube: Option<Handle>,
	colour: u32,
	time: f32,
}

static mut STATE: State = State { camera: Handle(-1), cube: None, colour: 0, time: 0.0 };
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

// sin on [-pi, pi], near enough for turning a cube (no libm here)
fn sin_near(mut x: f32) -> f32 {
	let pi = core::f32::consts::PI;
	while x > pi { x -= 2.0 * pi; }
	while x < -pi { x += 2.0 * pi; }
	let x2 = x * x;
	x * (1.0 - x2 / 6.0 * (1.0 - x2 / 20.0 * (1.0 - x2 / 42.0 * (1.0 - x2 / 72.0))))
}

fn draw_cube(cube: Handle, colour: u32) {
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
	const COLOURS: [[f32; 3]; 3] = [[1.0, 0.5, 0.1], [0.2, 0.8, 0.3], [0.3, 0.4, 1.0]];
	let c = COLOURS[(colour % 3) as usize];
	let mut v = [0f32; 24 * 12];
	let mut ix = [0u32; 36];
	for f in 0..6 {
		for k in 0..4 {
			let o = &mut v[(f * 4 + k) * 12..(f * 4 + k + 1) * 12];
			for a in 0..3 {
				o[a] = FACES[f][k][a] * 0.5;
				o[3 + a] = NORMALS[f][a];
				o[6 + a] = c[a] * (0.7 + 0.05 * f as f32);
			}
			o[9] = 1.0;
			o[10] = if k == 2 || k == 3 { 1.0 } else { 0.0 };
			o[11] = if k == 1 || k == 2 { 1.0 } else { 0.0 };
		}
		for (k, q) in [0u32, 1, 2, 0, 2, 3].iter().enumerate() {
			ix[f * 6 + k] = f as u32 * 4 + q;
		}
	}
	b::geometry_set(cube, 0, &v, &ix);
}

#[no_mangle]
pub extern "C" fn packets() -> *const u8 {
	b"echo\0".as_ptr()
}

#[no_mangle]
pub extern "C" fn frame(dt: f32) {
	// One thread, and no export calls another: the only reference
	let s = unsafe { &mut *core::ptr::addr_of_mut!(STATE) };
	let buf = unsafe { &mut *core::ptr::addr_of_mut!(EVENT) };
	while let Some(e) = b::next_event(buf) {
		match e {
			Event::Start { camera, nodes, .. } => {
				let Some((cube, _texture)) = nodes.get(0) else { continue };
				s.camera = camera;
				s.cube = Some(cube);
				// Back from the cube and a little above, looking down 20 degrees
				b::node_set(camera, &[0., 1.5, -4., 0.98481, 0.17365, 0., 0., 1., 1., 1.]);
				draw_cube(cube, s.colour);
				logf!("drew a cube, handed nodes: {}", nodes.len());
			}
			Event::KeyDown { key: 32, repeat: false, .. } => {
				s.colour += 1;
				if let Some(cube) = s.cube {
					draw_cube(cube, s.colour);
				}
				logf!("space: the colour is now {}", s.colour % 3);
				b::send_packet("key", &[b'0' + (s.colour % 3) as u8]);
			}
			Event::Packet { name, data } => {
				let name = core::str::from_utf8(name).unwrap_or("?");
				let data = core::str::from_utf8(data).unwrap_or("?");
				logf!("the server answered {}: {}", name, data);
			}
			_ => {}
		}
	}
	let Some(cube) = s.cube else { return };
	s.time += dt;
	// A turn about y, half an angle a second
	let h = s.time * 0.5;
	b::node_set(cube, &[0., 0., 0., sin_near(h + 1.5707963), 0., sin_near(h), 0., 1., 1., 1.]);
}
