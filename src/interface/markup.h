// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	namespace markup
	{
		// What a user wrote, as HTML for a page: CommonMark with GitHub's
		// tables, strikethrough, task lists and URL autolinks, and
		// ||spoilers||. Raw HTML is text, everything is escaped, and a
		// link or an image that is not http, https, mailto or relative is
		// its text alone. An image is a link to it, never loaded, but for
		// the Hearth's own ("/f/<id>...", relative), an <img>; "{.right}" or
		// "{.center}" right after it (or the link round it) is its class
		// ([HEARTH_POST_STYLE]). "#1234" is
		// a link to /t/1234 of class "ref", "@name" one to /u/name.
		ss_ to_html(const ss_ &md);
	}
}
// vim: set noet ts=4 sw=4:
