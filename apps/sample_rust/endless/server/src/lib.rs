// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_rust's endless: init() never returns. The server's meter
// stops it past its budget, and the module for good; the server and the
// app's other modules go on.
#![no_std]

use buildat_wasm_server as b;

#[no_mangle]
pub extern "C" fn init() {
	b::log("endless: spinning");
	let mut i: u32 = 0;
	loop {
		// Not a loop the compiler can drop
		i = unsafe { core::ptr::read_volatile(&i) }.wrapping_add(1);
	}
}
