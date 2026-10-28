// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// interface/http.h in the web client ([WEB_CLIENT]): there is no libcurl in
// a browser, and what uses HTTP (ContentDB, the server list) is the native
// launch menu's, which the web client does not have.
// simplified: an upgrade would be emscripten_fetch, if the web client ever
// needs HTTP.
#include "interface/http.h"

namespace interface
{
	ss_ http_get(const ss_ &url, ss_ *redirect,
			const std::atomic<bool> *cancel)
	{
		throw Exception("HTTP is not available in the web client");
	}

	ss_ http_post(const ss_ &url, const ss_ &body, const ss_ &content_type,
			ss_ *redirect, bool ipv4, const std::atomic<bool> *cancel)
	{
		throw Exception("HTTP is not available in the web client");
	}

	void send_mail(const ss_ &url, const ss_ &user, const ss_ &password,
			const ss_ &from, const ss_ &to, const ss_ &message)
	{
		throw Exception("Mail is not available in the web client");
	}

	bool mail_supported()
	{
		return false;
	}

	void http_download(const ss_ &url, const ss_ &path,
			std::function<bool(uint64_t got, uint64_t total)> progress)
	{
		throw Exception("HTTP is not available in the web client");
	}
}
// vim: set noet ts=4 sw=4:
