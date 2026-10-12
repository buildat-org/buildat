// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "core/version.h"
#include "interface/aitta.h"
#include "interface/record.h"
#include <cereal/types/vector.hpp>

namespace interface
{
	// **The hello** ([COMPAT_BREAK_07] 8a): the first packet each way,
	// core:hello (packet type 2, known to both ends without a definition).
	// A server and a client play together when their protocol ranges
	// overlap; otherwise the server says network:goodbye with the reason
	// and the client shows it.
	//
	// **One protocol number per minor release** (0.7 is 1): a patch only
	// adds, behind a feature name, and a minor may raise PROTOCOL_MIN. It
	// covers everything on the wire, Magic's replicated attributes too: a
	// change to them is a new number.
	static const uint32_t PROTOCOL_MIN = 1;
	static const uint32_t PROTOCOL_MAX = 1;

	// What was added since the minor, by name; served Lua's buildat.has()
	static inline sv_<ss_> protocol_features()
	{
		return {};
	}

	struct Hello
	{
		uint32_t protocol_min = 0;
		uint32_t protocol_max = 0;
		ss_ version; // the engine's, BUILDAT_VERSION
		uint32_t api = 0; // the engine API, served Lua's buildat.api
		sv_<ss_> features;

		static Hello own()
		{
			Hello h;
			h.protocol_min = PROTOCOL_MIN;
			h.protocol_max = PROTOCOL_MAX;
			h.version = BUILDAT_VERSION;
			h.api = aitta::ENGINE_API;
			h.features = protocol_features();
			return h;
		}
	};

	template<class Archive>
			void serialize(Archive &archive, Hello &v)
	{
		Record<Archive> r(archive, "hello", 1, 0);
		r.ar(v.protocol_min, v.protocol_max, v.version, v.api, v.features);
		r.end();
	}

	static inline ss_ hello_data(const Hello &h)
	{
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(h);
		}
		return os.str();
	}

	// Throws on a hello that cannot be read
	static inline Hello hello_of(const ss_ &data)
	{
		Hello h;
		std::istringstream is(data, std::ios::binary);
		try {
			cereal::PortableBinaryInputArchive ar(is);
			ar(h);
		} catch(cereal::Exception &e){
			throw RecordError(ss_()+"An unreadable hello: "+e.what());
		}
		return h;
	}

	// Empty when this end plays with theirs; otherwise why not, for a
	// player: theirs is "the server" or "the client"
	static inline ss_ hello_refusal(const Hello &h, const ss_ &theirs)
	{
		if(h.protocol_max < PROTOCOL_MIN)
			return "The "+theirs+" runs Buildat "+h.version.substr(0, 40)+
					", which is older than this one ("+BUILDAT_VERSION+
					") plays with";
		if(h.protocol_min > PROTOCOL_MAX)
			return "The "+theirs+" runs Buildat "+h.version.substr(0, 40)+
					", which is newer than this one ("+BUILDAT_VERSION+
					") plays with";
		return "";
	}
}
// vim: set noet ts=4 sw=4:
