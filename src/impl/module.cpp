// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/module.h"
#include "interface/server.h"

namespace interface {

void* Module::check_interface()
{
	void *i = get_interface();
	if(!i)
		throw Exception(ss_()+"Module \""+m_module_name+"\" has no interface");
	return i;
}

void Module::add_handler(Server *server, const ss_ &name,
		std::function<void(const Event::Private*)> f)
{
	const Event::Type type = Event::t(name);
	if(m_handlers.count(type))
		throw Exception(ss_()+"Module \""+m_module_name+"\": a second "
				"handler for \""+name+"\"");
	m_handlers[type] = std::move(f);
	server->sub_event(this, type);
}

}
// vim: set noet ts=4 sw=4:
