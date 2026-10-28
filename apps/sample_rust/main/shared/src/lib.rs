// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_rust: what the client's .wasm and the server's .wasm share
#![no_std]

/// The client's packet: a key was pressed
pub const KEY: &str = "key";
/// The server's answer: the count and where the cube goes
pub const MOVE: &str = "move";

/// Where the cube stands after the count-th key: -1.5, 0, 1.5 in turn
pub fn x_of(count: u32) -> f32 {
	(count % 3) as f32 * 1.5 - 1.5
}

pub fn encode_move(count: u32, x: f32) -> [u8; 8] {
	let mut b = [0u8; 8];
	b[..4].copy_from_slice(&count.to_le_bytes());
	b[4..].copy_from_slice(&x.to_bits().to_le_bytes());
	b
}

pub fn decode_move(b: &[u8]) -> Option<(u32, f32)> {
	if b.len() != 8 {
		return None;
	}
	let w = |i: usize| u32::from_le_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]]);
	Some((w(0), f32::from_bits(w(4))))
}

#[cfg(test)]
mod tests {
	#[test]
	fn round_trip() {
		assert_eq!(super::decode_move(&super::encode_move(7, -1.5)), Some((7, -1.5)));
		assert_eq!(super::decode_move(&[0; 7]), None);
	}
}
