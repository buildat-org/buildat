// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	// A zip archive read by its central directory ([CONTENTDB]): the two
	// methods a zip's entries are stored with -- stored, and the raw
	// deflate decompress_deflate_raw() reads. Anything else (encryption,
	// zip64, other methods) throws with the entry's name.
	struct ZipEntry {
		ss_ name; // as in the archive, '/' separated; a directory ends in '/'
		uint64_t size = 0; // uncompressed
	};
	sv_<ZipEntry> zip_list(const ss_ &zip_path);

	// Every entry under into_dir, directories made as needed. An entry
	// whose path would land outside into_dir ("../", an absolute path, a
	// drive letter) throws before anything is written. Returns the number
	// of files written.
	// max_total: what the entries may come to unpacked, all told; more
	// throws before anything is written (an entry is held to its own size
	// as it is written)
	size_t zip_extract(const ss_ &zip_path, const ss_ &into_dir,
			uint64_t max_total = (uint64_t)2 * 1024 * 1024 * 1024);

	// [WORLD_TRIM_MOVE] An archive of files on disk, {name in the archive,
	// path}, each stored as it is and copied a block at a time: what is
	// zipped here is a save, whose store is compressed already.
	// simplified: no zip64, so under 4 GiB a file and all told; past it
	// throws
	void zip_write(const ss_ &zip_path,
			const sv_<std::pair<ss_, ss_>> &files);
}
// vim: set noet ts=4 sw=4:
