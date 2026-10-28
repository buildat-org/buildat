// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_rust's counter: bump(), callable by other wasm modules
// (meta.json), adds one to a count in the module's own storage and hands
// it back; the count survives a restart of the server.
#![no_std]

use buildat_wasm_server as b;

fn count() -> u32 {
	let mut v = [0u8; 4];
	match b::storage_get(b"count", &mut v) {
		Some(4) => u32::from_le_bytes(v),
		_ => 0,
	}
}

#[no_mangle]
pub extern "C" fn init() {
	let mut line = *b"the count is 0000000000";
	let (mut n, mut i) = (count(), line.len());
	loop {
		i -= 1;
		line[i] = b'0' + (n % 10) as u8;
		n /= 10;
		if n == 0 {
			break;
		}
	}
	// The digits moved to follow the text
	line.copy_within(i.., 13);
	let end = 13 + line.len() - i;
	b::log(core::str::from_utf8(&line[..end]).unwrap_or("?"));
}

#[no_mangle]
pub extern "C" fn bump() {
	let n = count().wrapping_add(1);
	b::storage_set(b"count", &n.to_le_bytes());
	b::call_output(&n.to_le_bytes());
}
