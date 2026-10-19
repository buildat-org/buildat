// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

// A handler's match returns from the calling function: an event()
// dispatches to one handler and does nothing after the list
// ([EVENT_DISPATCH]); work for every event goes in the caller of a
// function that holds only the list.
#define EVENT_DISPATCH_VOID(event_type, handler) \
	if(type == event_type){handler(); return; }
// The name's type looked up once a site: the name is a literal, and a type
// is never freed
#define EVENT_VOIDN(name, handler) { \
	static const interface::Event::Type event_type_ = \
			interface::Event::t(name); \
	EVENT_DISPATCH_VOID(event_type_, handler) }
#define EVENT_TYPEN(name, handler, param_type) { \
	static const interface::Event::Type event_type_ = \
			interface::Event::t(name); \
	if(type == event_type_){ \
		auto p0 = dynamic_cast<const param_type*>(p); \
		if(p0) handler(*p0); \
		else if(p == nullptr) throw Exception(ss_()+"Missing parameter to "+ \
				__PRETTY_FUNCTION__+"::" #handler " (parameter type: " \
				#param_type ")"); \
		else throw Exception(ss_()+"Invalid parameter to "+__PRETTY_FUNCTION__+ \
					  "::" #handler " (expected " #param_type ")"); \
		return; \
	} }

namespace interface
{
	// NOTE: Event has no copy constructor due to up_<Private> p; just pass it
	// by non-const value if it will be placed in a container by the receiver.
	struct Event
	{
		typedef size_t Type;
		struct Private {
			virtual ~Private(){}
		};
		Type type;
		sp_<const Private> p;

		Event():
			type(0){}
		Event(const Type &type):
			type(type){}
		Event(const Type &type, Private *p):
			type(type), p(p){}
		Event(const Type &type, up_<Private> p):
			type(type), p(std::move(p)){}
		Event(const ss_ &name):
			type(t(name)){}
		Event(const ss_ &name, up_<Private> p):
			type(t(name)), p(std::move(p)){}
		template<typename PrivateT>
				Event(const ss_ &name, PrivateT *p):
			type(t(name)), p(up_<Private>(p))
		{}

		static Type t(const ss_ &name); // Shorthand function
	};

	struct EventRegistry
	{
		// Allocates new type if needed
		virtual Event::Type type(const ss_ &name) = 0;
		// The type a name has, or 0 if it has none yet -- without making
		// one: a name from the network is not to become a type forever
		virtual Event::Type find(const ss_ &name) = 0;
		// Returns "" if type is not allocated to a name
		virtual ss_ name(const Event::Type &type) = 0;
	};

	EventRegistry* getGlobalEventRegistry();
}
// vim: set noet ts=4 sw=4:
