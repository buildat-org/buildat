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
	// cereal record is its major and minor version (a byte each), the
	// length of its fields as a varint (seven bits a byte, low first, the
	// top bit set on all but the last) and then the fields themselves, in
	// the outer archive's byte order ([RECORD_FRAMING_COST]). A newer minor
	// only adds fields at the end, and a reader skips the tail it does not
	// know; another major is refused, not read from the wrong offset, and
	// so is a length that does not match what the fields took. In a
	// serialize():
	//
	//   Record<Archive> r(archive, "VoxelName", 1, 0);
	//   r.ar(v.block_name, ...);
	//   if(r.minor >= 1) r.ar(v.added_in_1);
	//   r.end();
	//
	// Writing, r.minor is the current minor; reading, the one written.
	// Reading, the fields come straight off the outer stream, which must
	// be a string stream; end() skips a newer minor's tail.
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
		void end()
		{
			// The inner archive's first byte is its byte order flag, which
			// is the outer's
			const ss_ body = os.str();
			uint8_t buf[10];
			size_t n = 0;
			uint64_t len = body.size() - 1;
			do {
				buf[n] = len & 0x7f;
				len >>= 7;
				if(len) buf[n] |= 0x80;
				n++;
			} while(len);
			outer.saveBinary(buf, n);
			outer.saveBinary(body.data() + 1, body.size() - 1);
		}
	};

	template<> struct Record<cereal::PortableBinaryInputArchive>
	{
		cereal::PortableBinaryInputArchive &ar;
		std::stringbuf *sb;
		const char *what;
		uint8_t minor;
		uint8_t current_minor;
		uint64_t len;
		// What was left in the stream after the length
		std::streamsize start;
		Record(cereal::PortableBinaryInputArchive &outer, const char *what,
				uint8_t major, uint8_t current_minor):
			ar(outer), sb(buf(outer, what)), what(what),
			minor(header(sb, what, major)), current_minor(current_minor),
			len(length(sb, what)), start(sb->in_avail())
		{
			if(len > (uint64_t)start)
				throw RecordError(ss_()+"A "+what+" record's length "+
						itos((int64_t)len)+" is past the "+
						itos((int64_t)start)+" bytes left");
		}
		// What is left of the fields unread
		uint64_t left()
		{
			const uint64_t used = start - sb->in_avail();
			if(used > len)
				throw RecordError(ss_()+"A "+what+" record's fields took "+
						itos((int64_t)used)+" bytes; its length says "+
						itos((int64_t)len));
			return len - used;
		}
		void end()
		{
			const uint64_t l = left();
			if(l == 0)
				return;
			if(minor <= current_minor)
				throw RecordError(ss_()+"A "+what+" record of minor version "+
						itos((int64_t)minor)+" has "+itos((int64_t)l)+
						" bytes left unread");
			sb->pubseekoff(l, std::ios::cur, std::ios::in);
		}
		// simplified: a string stream only, which is every reader's; a file
		// stream's in_avail() is not what is left. Another stream would
		// read the record into a string first.
		static std::stringbuf* buf(cereal::PortableBinaryInputArchive &outer,
				const char *what)
		{
			std::stringbuf *sb = outer.stringbuf();
			if(!sb)
				throw RecordError(ss_()+"A "+what+" record read from a "
						"stream that is not a string stream");
			return sb;
		}
		static uint8_t byte(std::stringbuf *sb, const char *what)
		{
			const int c = sb->sbumpc();
			if(c == std::char_traits<char>::eof())
				throw RecordError(ss_()+"A "+what+" record cut short");
			return (uint8_t)c;
		}
		static uint8_t header(std::stringbuf *sb, const char *what,
				uint8_t major)
		{
			const uint8_t got_major = byte(sb, what);
			const uint8_t got_minor = byte(sb, what);
			if(got_major != major)
				throw RecordError(ss_()+"A "+what+" record of major version "+
						itos((int64_t)got_major)+"; this reads "+
						itos((int64_t)major));
			return got_minor;
		}
		static uint64_t length(std::stringbuf *sb, const char *what)
		{
			uint64_t len = 0;
			for(int shift = 0; shift < 64; shift += 7){
				const uint8_t b = byte(sb, what);
				if(shift == 63 && b > 1)
					break;
				len |= (uint64_t)(b & 0x7f) << shift;
				if(!(b & 0x80))
					return len;
			}
			throw RecordError(ss_()+"A "+what+" record's length is not a "
					"varint of 64 bits");
		}
	};
}
// vim: set noet ts=4 sw=4:
