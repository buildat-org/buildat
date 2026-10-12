// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/packet_stream.h"
#include "core/log.h"
#include <c55/os.h> // get_timeofday_us()
#define MODULE "__packet_stream"

namespace interface {

// What a few bytes actually were, for an error message about a stream that
// has stopped making sense
static ss_ hex_of(const char *p, size_t n)
{
	ss_ out;
	char buf[4];
	for(size_t i = 0; i < n; i++){
		snprintf(buf, sizeof buf, "%02x", (unsigned)(p[i] & 0xff));
		out += buf;
	}
	return out;
}

static void self_check();

bool PacketStream::in_flight(const InputBuffer &socket_buffer, ss_ *name,
		size_t *have, size_t *size)
{
	if(socket_buffer.size() >= HEADER_BYTES){
		const unsigned char *b = (const unsigned char*)socket_buffer.begin();
		const size_t type = b[0] | b[1]<<8;
		const size_t n = b[3] | b[4]<<8 | b[5]<<16 | (size_t)b[6]<<24;
		auto it = m_incoming_types.m_names.find(type);
		const ss_ tname = it != m_incoming_types.m_names.end() ? it->second : "";
		// A fragment's own 64 kB says little: its sequence is below
		if(socket_buffer.size() < HEADER_BYTES + n &&
				tname != "core:fragment"){
			*name = tname;
			*have = socket_buffer.size() - HEADER_BYTES;
			*size = n;
			return true;
		}
	}
	const Fragments *best = nullptr;
	for(const auto &pair : m_incoming_fragments)
		if(!best || pair.second.bytes > best->bytes)
			best = &pair.second;
	if(!best)
		return false;
	*name = best->name;
	*have = best->bytes;
	*size = best->count * FRAGMENT_BYTES;
	return true;
}

void PacketStream::input(InputBuffer &socket_buffer,
		std::function<void(const ss_&name, const ss_&data)> cb,
		int64_t budget_us)
{
	const int64_t started_us = budget_us > 0 ? get_timeofday_us() : 0;
	// Once, on the first stream that reads anything. A plain bool rather
	// than a function-local static because self_check() calls this.
	static bool checked = false;
	if(!checked){
		checked = true;
		self_check();
	}
	for(;;){
		if(socket_buffer.size() < HEADER_BYTES)
			return;
		const char *b = socket_buffer.begin();
		size_t type =
				(b[0] & 0xff)<<0 |
				(b[1] & 0xff)<<8;
		const unsigned flags = b[2] & 0xff;
		size_t size =
				(b[3] & 0xff)<<0 |
				(b[4] & 0xff)<<8 |
				(b[5] & 0xff)<<16 |
				(size_t)(b[6] & 0xff)<<24;
		// None is defined yet ([COMPAT_BREAK_07] 8f): one that is, is a
		// newer peer's, and what it changes cannot be read here
		if(flags != 0){
			throw UnknownPacketReceived("A packet with flags "+
					hex_of(b + 2, 1)+", which this does not know (at byte "+
					itos((int64_t)m_input_offset)+")");
		}
		//log_d(MODULE, "size=%zu", size);
		if(size > m_max_packet_bytes){
			throw UnknownPacketReceived("A packet of "+itos((int64_t)size)+
					" bytes, over the "+itos((int64_t)m_max_packet_bytes)+
					" this stream takes (at byte "+
					itos((int64_t)m_input_offset)+")");
		}
		if(socket_buffer.size() < HEADER_BYTES + size)
			return;
		char header[HEADER_BYTES];
		for(size_t i = 0; i < HEADER_BYTES; i++)
			header[i] = b[i];
		log_d(MODULE, "Received full packet; type=%zu, "
				"length=%zu+%zu", type, HEADER_BYTES, size);
		ss_ data(b + HEADER_BYTES, size);
		socket_buffer.at += HEADER_BYTES + size;
		const uint64_t packet_at = m_input_offset;
		m_input_offset += HEADER_BYTES + size;

		ss_ name;
		try {
			name = m_incoming_types.get_name(type);
		} catch(UnknownPacketReceived &e){
			// Where it was and what it looked like, because a bare type
			// number cannot say whether a definition went missing or the
			// stream is being read at the wrong offset -- and those two want
			// different fixes. The header is what was decoded as a type and
			// a length; a length in the megabytes is the giveaway.
			throw UnknownPacketReceived(ss_()+e.what()+" (at byte "+
					itos((int64_t)packet_at)+" of the stream, header "+
					hex_of(header, HEADER_BYTES)+", payload "+itos((int64_t)size)+
					" bytes: "+hex_of(data.c_str(),
					data.size() < 16 ? data.size() : 16)+")");
		}

		if(name == "core:define_packet_type"){
			if(data.size() < 6)
				continue;
			// Masked, because char is signed here: without it the first type
			// number past 127 reads as a negative one, the definition is
			// filed under a number nothing will ever arrive as, and the next
			// packet of that type is "Packet not known: 128". Types are
			// handed out from 100, so this is the twenty-ninth distinct
			// packet name of a session and not an edge case.
			PacketType type1 =
					(data[0] & 0xff)<<0 |
					(data[1] & 0xff)<<8;
			size_t name1_size =
					(data[2] & 0xff)<<0 |
					(data[3] & 0xff)<<8 |
					(data[4] & 0xff)<<16 |
					(size_t)(data[5] & 0xff)<<24;
			if(data.size() < 6 + name1_size)
				continue;
			ss_ name1(&data.c_str()[6], name1_size);
			log_d(MODULE, "<< core:define_packet_type %zu %s", type1, cs(name1));
			m_incoming_types.set(type1, name1);
			continue;
		}

		if(name == "core:fragment"){
			// [u32 id][u16 index][u16 count][u16 type][u8 flags][bytes]
			if(data.size() < 11)
				continue;
			const unsigned char *d = (const unsigned char*)data.c_str();
			uint32_t id = d[0] | d[1]<<8 | d[2]<<16 | (uint32_t)d[3]<<24;
			size_t index = d[4] | d[5]<<8;
			size_t count = d[6] | d[7]<<8;
			PacketType ptype = d[8] | d[9]<<8;
			if(d[10] != 0){
				throw UnknownPacketReceived("A fragment with flags "+
						hex_of(data.c_str() + 10, 1)+", which this does not "
						"know");
			}
			if(count == 0 || index >= count)
				continue;
			// The name first: an unknown one throws, and must not leave an
			// empty sequence behind
			const ss_ fname = m_incoming_types.get_name(ptype);
			Fragments &f = m_incoming_fragments[id];
			if(f.count == 0){
				f.name = fname;
				f.count = count;
				f.parts.resize(count);
			}
			if(f.count != count || !f.parts[index].empty())
				continue;
			f.bytes += data.size() - 11;
			// All the unfinished ones together: eight of them each under
			// the limit held eight times it ([SECURITY_RUN_5])
			size_t all = 0;
			for(const auto &pair : m_incoming_fragments)
				all += pair.second.bytes;
			if(all > m_max_packet_bytes){
				m_incoming_fragments.erase(id);
				throw UnknownPacketReceived("A fragmented "+fname+
						" over the "+itos((int64_t)m_max_packet_bytes)+
						" bytes this stream takes, with the fragments "
						"of the others unfinished");
			}
			f.parts[index] = data.substr(11);
			f.have++;
			if(f.have < f.count){
				// A sequence a sender's drop policy cut short never
				// completes; the ones older than a handful of newer ones
				// are let go
				while(m_incoming_fragments.size() > 8)
					m_incoming_fragments.erase(m_incoming_fragments.begin());
				continue;
			}
			ss_ whole;
			for(const ss_ &part : f.parts)
				whole += part;
			ss_ whole_name = f.name;
			m_incoming_fragments.erase(id);
			log_d(MODULE, "<< %s (%zu fragments)", cs(whole_name), count);
			cb(whole_name, whole);
			if(budget_us > 0 && get_timeofday_us() - started_us >= budget_us)
				return;
			continue;
		}

		log_d(MODULE, "<< %s", cs(name));
		cb(name, data);
		// And the budget, checked after a packet rather than before:
		// nothing is left half-read, and a single slow handler still gets
		// its turn -- what this stops is ten of them in one update.
		if(budget_us > 0 && get_timeofday_us() - started_us >= budget_us)
			return;
	}
}

void PacketStream::send_new_types(
		std::function<void(ss_ &&packet_data, bool droppable)> cb)
{
	// Send new packet types if needed
	log_d(MODULE, "m_outgoing_types.m_next_type=%zu"
			", m_highest_known_type=%zu",
			m_outgoing_types.m_next_type, m_highest_known_type);
	if(m_outgoing_types.m_next_type > m_highest_known_type + 1){
		PacketType highest_known_type_was = m_highest_known_type;
		m_highest_known_type = m_outgoing_types.m_next_type - 1;
		for(PacketType t1 = highest_known_type_was + 1;
		t1 < m_outgoing_types.m_next_type; t1++){
			ss_ name = m_outgoing_types.get_name(t1);
			log_d(MODULE, "Sending type %zu = %s", t1, cs(name));
			std::ostringstream os(std::ios::binary);
			os<<(char)((t1>>0) & 0xff);
			os<<(char)((t1>>8) & 0xff);
			os<<(char)((name.size()>>0) & 0xff);
			os<<(char)((name.size()>>8) & 0xff);
			os<<(char)((name.size()>>16) & 0xff);
			os<<(char)((name.size()>>24) & 0xff);
			os<<name;
			// Never droppable: m_highest_known_type has already been
			// advanced above, so this is the only time this definition is
			// written and a peer that does not get it cannot read that type
			// again
			output("core:define_packet_type", os.str(), cb, false);
		}
	}
}

void PacketStream::output(const ss_ &name, const ss_ &data,
		std::function<void(ss_ &&packet_data, bool droppable)> cb,
		bool droppable)
{
	PacketType type = m_outgoing_types.get(name);
	log_d(MODULE, "output(): name=\"%s\", data.size()=%zu",
			cs(name), data.size());

	send_new_types(cb);

	log_d(MODULE, ">> %s", cs(name));

	if(data.size() > FRAGMENT_BYTES && droppable && name != "core:fragment"){
		const uint32_t id = m_next_fragment_id++;
		const size_t count = (data.size() + FRAGMENT_BYTES - 1) / FRAGMENT_BYTES;
		for(size_t i = 0; i < count; i++){
			ss_ frag;
			frag += (char)((id>>0) & 0xff);
			frag += (char)((id>>8) & 0xff);
			frag += (char)((id>>16) & 0xff);
			frag += (char)((id>>24) & 0xff);
			frag += (char)((i>>0) & 0xff);
			frag += (char)((i>>8) & 0xff);
			frag += (char)((count>>0) & 0xff);
			frag += (char)((count>>8) & 0xff);
			frag += (char)((type>>0) & 0xff);
			frag += (char)((type>>8) & 0xff);
			frag += (char)0; // flags
			frag += data.substr(i * FRAGMENT_BYTES, FRAGMENT_BYTES);
			output("core:fragment", frag, cb, true);
		}
		return;
	}

	// Create actual packet including type and length
	std::ostringstream os(std::ios::binary);
	os<<(char)((type>>0) & 0xff);
	os<<(char)((type>>8) & 0xff);
	os<<(char)0; // flags
	os<<(char)((data.size()>>0) & 0xff);
	os<<(char)((data.size()>>8) & 0xff);
	os<<(char)((data.size()>>16) & 0xff);
	os<<(char)((data.size()>>24) & 0xff);
	os<<data;
	cb(os.str(), droppable);
}


// One round trip through the pair, which is what is worth checking here: a
// name never written before is defined on the wire ahead of the payload
// that uses it, the definition is the one that may never be dropped, the
// reader gets both back, and a type nobody defined comes back as an error
// that says where in the stream it was.
static void self_check()
{
	PacketStream w;
	sv_<std::pair<ss_, bool>> out;
	auto collect = [&](const ss_ &d, bool droppable){
		out.push_back(std::make_pair(d, droppable));
	};
	w.output("test:hello", "abc", collect);
	if(out.size() != 2)
		throw Exception("packet_stream self_check: a name never written "
				"before is its definition and then its payload");
	if(out[0].second || !out[1].second)
		throw Exception("packet_stream self_check: the definition is the "
				"undroppable one of the two");
	ss_ stream = out[0].first + out[1].first;
	out.clear();
	w.output("test:hello", "d", collect);
	if(out.size() != 1 || !out[0].second)
		throw Exception("packet_stream self_check: a name already written "
				"is one droppable packet");
	stream += out[0].first;

	PacketStream r;
	sv_<std::pair<ss_, ss_>> got;
	InputBuffer buf;
	buf.append(stream);
	r.input(buf, [&](const ss_ &name, const ss_ &data){
		got.push_back(std::make_pair(name, data));
	});
	if(got.size() != 2 || got[0].first != "test:hello" ||
			got[0].second != "abc" || got[1].second != "d")
		throw Exception("packet_stream self_check: what went in is not what "
				"came out");
	if(!buf.empty())
		throw Exception("packet_stream self_check: the reader left bytes "
				"behind");

	// Over the reader's limit, whole or in fragments, is refused before it is
	// buffered: a size off the wire was waited for up to 4 GB
	{
		PacketStream w3, r3;
		r3.m_max_packet_bytes = 100;
		ss_ s3;
		auto write3 = [&](const ss_ &d, bool droppable){ s3 += d; };
		w3.output("test:big", ss_(150, 'x'), write3, false);
		InputBuffer b3;
		b3.append(s3);
		bool refused = false;
		try {
			r3.input(b3, [&](const ss_&, const ss_&){});
		} catch(UnknownPacketReceived &e){
			refused = true;
		}
		if(!refused)
			throw Exception("packet_stream self_check: a packet over the "
					"limit was taken");
		PacketStream w4, r4;
		r4.m_max_packet_bytes = PacketStream::FRAGMENT_BYTES + 100;
		ss_ s4;
		auto write4 = [&](const ss_ &d, bool droppable){ s4 += d; };
		w4.output("test:frag", ss_(PacketStream::FRAGMENT_BYTES * 3, 'y'), write4, true);
		InputBuffer b4;
		b4.append(s4);
		refused = false;
		try {
			r4.input(b4, [&](const ss_&, const ss_&){});
		} catch(UnknownPacketReceived &e){
			refused = true;
		}
		if(!refused)
			throw Exception("packet_stream self_check: fragments over the "
					"limit were taken");
		// Two unfinished, each under the limit and over it together
		PacketStream w5, r5;
		r5.m_max_packet_bytes = PacketStream::FRAGMENT_BYTES * 3 + 100;
		sv_<ss_> a5, c5;
		w5.output("test:frag", ss_(PacketStream::FRAGMENT_BYTES * 3, 'a'),
				[&](const ss_ &d, bool){ a5.push_back(d); }, true);
		w5.output("test:frag", ss_(PacketStream::FRAGMENT_BYTES * 3, 'c'),
				[&](const ss_ &d, bool){ c5.push_back(d); }, true);
		InputBuffer b5;
		for(size_t i = 0; i + 1 < a5.size(); i++)
			b5.append(a5[i]);
		for(size_t i = 0; i + 1 < c5.size(); i++)
			b5.append(c5[i]);
		refused = false;
		try {
			r5.input(b5, [&](const ss_&, const ss_&){});
		} catch(UnknownPacketReceived &e){
			refused = true;
		}
		if(!refused)
			throw Exception("packet_stream self_check: unfinished fragments "
					"over the limit together were taken");
	}

	// Past 127, which is where a signed char used to turn the type number in
	// a definition negative: the definition went in under a number nothing
	// arrives as, and the payload after it was "Packet not known: 128".
	// Types are handed out from 100, so this is the twenty-ninth name of a
	// session.
	{
		PacketStream w2, r2;
		ss_ s2;
		auto write2 = [&](const ss_ &d, bool droppable){ s2 += d; };
		for(int i = 0; i < 40; i++)
			w2.output(ss_()+"test:n"+itos(i), itos(i), write2);
		sv_<ss_> got2;
		InputBuffer b2;
		b2.append(s2);
		try {
			r2.input(b2, [&](const ss_ &name, const ss_ &data){
				got2.push_back(name+"="+data);
			});
		} catch(UnknownPacketReceived &e){
			throw Exception(ss_()+"packet_stream self_check: a type past 127 "
					"did not survive the round trip: "+e.what());
		}
		if(got2.size() != 40 || got2[39] != "test:n39=39")
			throw Exception(ss_()+"packet_stream self_check: a type past 127 "
					"did not survive the round trip ("+
					itos((int64_t)got2.size())+" of 40 back)");
	}

	// Bulk: a payload over a fragment goes as fragments and comes back whole
	{
		PacketStream w3, r3;
		ss_ s3;
		size_t packets = 0;
		auto write3 = [&](const ss_ &d, bool droppable){ s3 += d; packets++; };
		ss_ big(PacketStream::FRAGMENT_BYTES * 2 + 5, 'x');
		big[PacketStream::FRAGMENT_BYTES] = 'y';
		w3.output("test:big", big, write3);
		if(packets != 1 + 3)
			throw Exception(ss_()+"packet_stream self_check: bulk is a "
					"definition and three fragments, not "+
					itos((int64_t)packets)+" packets");
		const size_t big_end = s3.size();
		w3.output("test:small", "s", write3);
		sv_<std::pair<ss_, ss_>> got3;
		InputBuffer b3;
		b3.append(s3);
		r3.input(b3, [&](const ss_ &name, const ss_ &data){
			got3.push_back(std::make_pair(name, data));
		});
		if(got3.size() != 2 || got3[0].first != "test:big" ||
				got3[0].second != big || got3[1].second != "s")
			throw Exception("packet_stream self_check: bulk did not come "
					"back whole");
		// [LOAD_IN_FLIGHT] Part of it read: the sequence, two fragments in;
		// a whole packet part-read: its own name and bytes; all of it: none
		PacketStream r4, w5, r5;
		InputBuffer b4, b5;
		ss_ name;
		size_t have = 0, size = 0;
		b4.append(s3.substr(0, big_end - 20));
		r4.input(b4, [&](const ss_&, const ss_&){});
		if(!r4.in_flight(b4, &name, &have, &size) || name != "test:big" ||
				have != PacketStream::FRAGMENT_BYTES * 2 ||
				size != PacketStream::FRAGMENT_BYTES * 3)
			throw Exception("packet_stream self_check: a sequence in "
					"flight was not said");
		ss_ s5;
		w5.output("test:whole", big, [&](const ss_ &d, bool){ s5 += d; },
				false);
		b5.append(s5.substr(0, s5.size() - 10));
		r5.input(b5, [&](const ss_&, const ss_&){});
		if(!r5.in_flight(b5, &name, &have, &size) || name != "test:whole" ||
				have != big.size() - 10 || size != big.size())
			throw Exception("packet_stream self_check: a packet in flight "
					"was not said");
		b5.append(s5.substr(s5.size() - 10));
		r5.input(b5, [&](const ss_&, const ss_&){});
		if(r5.in_flight(b5, &name, &have, &size))
			throw Exception("packet_stream self_check: a whole packet "
					"still in flight");
	}

	// A type nobody defined: what a stream read at the wrong offset looks
	// like, and the message has to say where rather than only which number
	InputBuffer bad;
	const char raw[] = {(char)200, 0, 0, 1, 0, 0, 0, (char)0x78};
	bad.append(raw, sizeof raw);
	try {
		r.input(bad, [&](const ss_ &name, const ss_ &data){});
		throw Exception("packet_stream self_check: an undefined type was "
				"read without complaint");
	} catch(UnknownPacketReceived &e){
		if(ss_(e.what()).find("at byte") == ss_::npos)
			throw Exception(ss_()+"packet_stream self_check: the complaint "
					"does not say where: "+e.what());
	}

	// A flag this does not know, on a type it does: refused, not read
	// ([COMPAT_BREAK_07] 8f)
	{
		PacketStream r6;
		InputBuffer b6;
		const char raw6[] = {2, 0, 4, 1, 0, 0, 0, (char)0x78};
		b6.append(raw6, sizeof raw6);
		bool refused = false;
		try {
			r6.input(b6, [&](const ss_&, const ss_&){});
		} catch(UnknownPacketReceived &e){
			refused = ss_(e.what()).find("flags") != ss_::npos;
		}
		if(!refused)
			throw Exception("packet_stream self_check: an unknown flag "
					"was not refused");
	}
}

}
// vim: set noet ts=4 sw=4:
