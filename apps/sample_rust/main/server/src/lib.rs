// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_rust's server module, a .wasm (meta.json's "server_wasm"):
// a scene with a voxel world and a node, shown to each peer that joins;
// a peer's "key" packet bumps the counter module's count (buildat_call)
// and is answered with "move", which moves the client's cube, and the
// node here too.
#![no_std]

use buildat_wasm_server::{self as b, Event, Handle};
use core::fmt::Write;
use sample_rust_shared as s;

struct State {
	scene: Handle,
	node: Handle,
}

static mut STATE: State = State { scene: Handle(0), node: Handle(0) };
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

fn place(node: Handle, x: f32) {
	b::node_set(node, &[x, 0., 0., 1., 0., 0., 0., 1., 1., 1.]);
}

#[no_mangle]
pub extern "C" fn init() {
	// One thread, and no export calls another: the only reference
	let st = unsafe { &mut *core::ptr::addr_of_mut!(STATE) };
	b::packet_subscribe(s::KEY);
	b::event_subscribe("network:client_connected");
	st.scene = b::scene_create();
	st.node = b::node_create(st.scene);
	place(st.node, s::x_of(0));
	// A world of one section, a floor of rock and a block of it on top
	b::world_create(st.scene, &[0, 0, 0, 0, 0, 0]);
	let rock = b::voxel_define(st.scene, "sample_rust:rock", "main/rock.png");
	let floor = [rock; 16];
	b::voxels_set(st.scene, &[0, 0, 0, 4, 1, 4], &floor);
	b::voxels_set(st.scene, &[1, 1, 1, 1, 1, 1], &[rock]);
	let mut back = [0u32; 32];
	let n = b::voxels_read(st.scene, &[0, 0, 0, 4, 2, 4], &mut back);
	let rocks = back[..n].iter().filter(|&&v| v == rock).count();
	logf!("voxels: {} read back, {} of them rock", n, rocks);
}

#[no_mangle]
pub extern "C" fn events() {
	let st = unsafe { &mut *core::ptr::addr_of_mut!(STATE) };
	let buf = unsafe { &mut *core::ptr::addr_of_mut!(EVENT) };
	while let Some(e) = b::next_event(buf) {
		match e {
			Event::PeerJoined { peer } => {
				b::scene_peer(Some(st.scene), peer);
				logf!("peer {} joined, shown the scene", peer);
			}
			Event::Packet { peer, name, .. } if name == s::KEY.as_bytes() => {
				let mut out = [0u8; 4];
				let count = match b::call("counter", "bump", &[], &mut out) {
					Some(4) => u32::from_le_bytes(out),
					_ => { logf!("the counter did not answer"); continue }
				};
				let x = s::x_of(count);
				place(st.node, x);
				b::packet_send(peer, s::MOVE, &s::encode_move(count, x));
				let t = b::node_get(st.node);
				logf!("key from peer {}: count {}, the node at x {}", peer, count, t[0]);
			}
			_ => {}
		}
	}
}
