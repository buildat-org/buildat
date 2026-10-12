// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <sstream>

namespace interface
{
	// **The record rule** ([COMPAT_BREAK_07] 8b; doc/architecture.txt): a
	// cereal record is its major and minor version, then its fields as one
	// byte string. A newer minor only adds fields at the end, and a reader
	// skips the tail it does not know; another major is refused, not read
	// from the wrong offset. In a serialize():
	//
	//   Record<Archive> r(archive, "VoxelName", 1, 0);
	//   r.ar(v.block_name, ...);
	//   if(r.minor >= 1) r.ar(v.added_in_1);
	//   r.end();
	//
	// Writing, r.minor is the current minor; reading, the one written.
	struct RecordError: public Exception {
		RecordError(const ss_ &msg): Exception(msg){}
	};

	template<class Archive> struct Record;

	template<> struct Record<cereal::PortableBinaryOutputArchive>
	{
		cereal::PortableBinaryOutputArchive &outer;
		std::ostringstream os;
		cereal::PortableBinaryOutputArchive ar;
		uint8_t minor;
		Record(cereal::PortableBinaryOutputArchive &outer, const char *what,
				uint8_t major, uint8_t minor):
			outer(outer), os(std::ios::binary), ar(os), minor(minor)
		{
			outer(major, minor);
		}
		void end(){ outer(os.str()); }
	};

	template<> struct Record<cereal::PortableBinaryInputArchive>
	{
		uint8_t minor;
		ss_ body;
		std::istringstream is;
		cereal::PortableBinaryInputArchive ar;
		Record(cereal::PortableBinaryInputArchive &outer, const char *what,
				uint8_t major, uint8_t current_minor):
			minor(header(outer, what, major)), body(string(outer)),
			is(body, std::ios::binary), ar(is)
		{}
		void end(){}
		static uint8_t header(cereal::PortableBinaryInputArchive &outer,
				const char *what, uint8_t major)
		{
			uint8_t got_major = 0, got_minor = 0;
			outer(got_major, got_minor);
			if(got_major != major)
				throw RecordError(ss_()+"A "+what+" record of major version "+
						itos((int64_t)got_major)+"; this reads "+
						itos((int64_t)major));
			return got_minor;
		}
		static ss_ string(cereal::PortableBinaryInputArchive &outer)
		{
			ss_ s;
			outer(s);
			return s;
		}
	};
}
// vim: set noet ts=4 sw=4:
