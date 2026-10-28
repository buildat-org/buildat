// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "interface/address.h"
#include "interface/http.h"
#include "core/log.h"
#include "core/version.h"
#include <curl/curl.h>
#ifdef _WIN32
	// curl.h brings windows.h in, and windows.h #defines interface, which
	// is the namespace below
	#undef interface
#endif
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#define MODULE "http"

namespace interface {

static void global_init_once()
{
	static std::once_flag once;
	std::call_once(once, [](){ curl_global_init(CURL_GLOBAL_DEFAULT); });
}

// A body read into memory is at most this, and the request at most
// STRING_TIMEOUT_S long: what answers a game's script, a Starport's
// challenge or a ContentDB listing is small and quick, and a server that
// streamed forever or a byte a minute held a thread and its memory
// ([SECURITY_RUN_1]). A download to a file has its own ceiling below.
static const size_t STRING_MAX = 64 * 1024 * 1024;
static const long STRING_TIMEOUT_S = 120;
static const curl_off_t DOWNLOAD_MAX = (curl_off_t)2 * 1024 * 1024 * 1024;

static size_t to_string(char *p, size_t size, size_t n, void *user)
{
	ss_ &s = *(ss_*)user;
	if(s.size() + size * n > STRING_MAX)
		return 0; // libcurl stops with a write error
	s.append(p, size * n);
	return size * n;
}
static size_t to_file(char *p, size_t size, size_t n, void *user)
{
	std::ofstream &f = *(std::ofstream*)user;
	f.write(p, size * n);
	return f.good() ? size * n : 0;
}

struct Progress {
	std::function<bool(uint64_t, uint64_t)> f;
};
static int on_progress(void *user, curl_off_t total, curl_off_t got,
		curl_off_t, curl_off_t)
{
	Progress &p = *(Progress*)user;
	if(p.f && !p.f((uint64_t)got, total > 0 ? (uint64_t)total : 0))
		return 1;
	return 0;
}

// libcurl calls it at least once a second, connecting or waiting too
static void set_cancel(CURL *c, Progress &p, const std::atomic<bool> *cancel)
{
	if(!cancel)
		return;
	p.f = [cancel](uint64_t, uint64_t){ return !cancel->load(); };
	curl_easy_setopt(c, CURLOPT_NOPROGRESS, 0L);
	curl_easy_setopt(c, CURLOPT_XFERINFOFUNCTION, on_progress);
	curl_easy_setopt(c, CURLOPT_XFERINFODATA, &p);
}

static void set_protocols(CURL *c, const char *list)
{
#if LIBCURL_VERSION_NUM >= 0x075500
	curl_easy_setopt(c, CURLOPT_PROTOCOLS_STR, list);
	curl_easy_setopt(c, CURLOPT_REDIR_PROTOCOLS_STR, list);
#else
	const long p = strstr(list, "smtp") ?
			(CURLPROTO_SMTP | CURLPROTO_SMTPS) :
			(CURLPROTO_HTTP | CURLPROTO_HTTPS);
	curl_easy_setopt(c, CURLOPT_PROTOCOLS, p);
	curl_easy_setopt(c, CURLOPT_REDIR_PROTOCOLS, p);
#endif
}

static CURL *easy(const ss_ &url, char *errbuf)
{
	global_init_once();
	CURL *c = curl_easy_init();
	if(!c)
		throw Exception("http: curl_easy_init failed");
	curl_easy_setopt(c, CURLOPT_URL, url.c_str());
	curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
	curl_easy_setopt(c, CURLOPT_MAXREDIRS, 8L);
	// http and https, asked for and redirected to: a URL comes from a
	// ContentDB listing or a game's script, and libcurl's own default
	// includes file:// ([SECURITY_RUN_1]). send_mail() says smtp.
	set_protocols(c, "http,https");
	curl_easy_setopt(c, CURLOPT_FAILONERROR, 1L);
	// **Who is calling** ([LICENSE_DUAL]'s second courtesy): ContentDB's
	// and the serverlist's bandwidth is donated, and an operator reading
	// a log should see a name and a version rather than libcurl's
	// default. A project URL belongs here the day there is a public one.
	static const ss_ user_agent = ss_("buildat/")+BUILDAT_VERSION;
	curl_easy_setopt(c, CURLOPT_USERAGENT, user_agent.c_str());
	curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 20L);
	curl_easy_setopt(c, CURLOPT_LOW_SPEED_LIMIT, 1L);
	curl_easy_setopt(c, CURLOPT_LOW_SPEED_TIME, 60L);
	curl_easy_setopt(c, CURLOPT_ERRORBUFFER, errbuf);
	// BUILDAT_CA_FILE: the CAs trusted in place of the system's, for a
	// check's own CA (util/web_play_check.sh); never in a deployment
	static const char *ca_file = getenv("BUILDAT_CA_FILE");
	if(ca_file){
		static std::once_flag said;
		std::call_once(said, [](){
			log_w(MODULE, "BUILDAT_CA_FILE: trusting %s instead of the "
					"system's CAs", ca_file);
		});
		curl_easy_setopt(c, CURLOPT_CAINFO, ca_file);
	}
	return c;
}

static void perform(CURL *c, const ss_ &url, const char *errbuf,
		ss_ *redirect = nullptr)
{
	if(redirect)
		curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 0L);
	const CURLcode r = curl_easy_perform(c);
	long status = 0, os_errno = 0, port = 0;
	curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);
	curl_easy_getinfo(c, CURLINFO_OS_ERRNO, &os_errno);
	curl_easy_getinfo(c, CURLINFO_PRIMARY_PORT, &port);
	if(redirect){
		char *to = nullptr;
		curl_easy_getinfo(c, CURLINFO_REDIRECT_URL, &to);
		*redirect = r == CURLE_OK && status >= 300 && status < 400 && to ?
				ss_(to) : ss_();
	}
	curl_easy_cleanup(c);
	// [PROCESS_SANDBOX]: a port the server's box refuses
	if(r == CURLE_COULDNT_CONNECT && os_errno == EACCES){
		// The URL's own: curl's primary port is -1 with no connection made
		interface::Url u;
		port = interface::parse_url(url, &u) ? atol(u.port.c_str()) : 0;
		log_w(MODULE, "%s: the server's sandbox refused port %li; its admin "
				"allows it with --connect-ports or BUILDAT_CONNECT_PORTS",
				cs(url), port);
	}
	if(r != CURLE_OK){
		throw Exception("http: "+url+": "+
				(errbuf[0] ? ss_(errbuf) : ss_(curl_easy_strerror(r)))+
				(status ? " (status "+itos(status)+")" : ss_()));
	}
}

ss_ http_get(const ss_ &url, ss_ *redirect, const std::atomic<bool> *cancel)
{
	char errbuf[CURL_ERROR_SIZE] = {0};
	CURL *c = easy(url, errbuf);
	ss_ body;
	curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, to_string);
	curl_easy_setopt(c, CURLOPT_WRITEDATA, &body);
	curl_easy_setopt(c, CURLOPT_TIMEOUT, STRING_TIMEOUT_S);
	Progress p;
	set_cancel(c, p, cancel);
	perform(c, url, errbuf, redirect);
	return redirect && !redirect->empty() ? ss_() : body;
}

ss_ http_post(const ss_ &url, const ss_ &body, const ss_ &content_type,
		ss_ *redirect, bool ipv4, const std::atomic<bool> *cancel)
{
	char errbuf[CURL_ERROR_SIZE] = {0};
	CURL *c = easy(url, errbuf);
	ss_ out;
	struct curl_slist *headers = curl_slist_append(nullptr,
			("Content-Type: "+content_type).c_str());
	curl_easy_setopt(c, CURLOPT_HTTPHEADER, headers);
	curl_easy_setopt(c, CURLOPT_POSTFIELDS, body.c_str());
	curl_easy_setopt(c, CURLOPT_POSTFIELDSIZE, (long)body.size());
	curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, to_string);
	curl_easy_setopt(c, CURLOPT_WRITEDATA, &out);
	curl_easy_setopt(c, CURLOPT_TIMEOUT, STRING_TIMEOUT_S);
	if(ipv4)
		curl_easy_setopt(c, CURLOPT_IPRESOLVE, CURL_IPRESOLVE_V4);
	Progress p;
	set_cancel(c, p, cancel);
	try {
		perform(c, url, errbuf, redirect);
	} catch(...){
		curl_slist_free_all(headers);
		throw;
	}
	curl_slist_free_all(headers);
	return redirect && !redirect->empty() ? ss_() : out;
}

struct ReadState {
	const ss_ *data;
	size_t at;
};
static size_t from_string(char *p, size_t size, size_t n, void *user)
{
	ReadState &r = *(ReadState*)user;
	const size_t len = std::min(size * n, r.data->size() - r.at);
	memcpy(p, r.data->data() + r.at, len);
	r.at += len;
	return len;
}

void send_mail(const ss_ &url, const ss_ &user, const ss_ &password,
		const ss_ &from, const ss_ &to, const ss_ &message)
{
	char errbuf[CURL_ERROR_SIZE] = {0};
	CURL *c = easy(url, errbuf);
	set_protocols(c, "smtp,smtps");
	if(!user.empty()){
		curl_easy_setopt(c, CURLOPT_USERNAME, user.c_str());
		curl_easy_setopt(c, CURLOPT_PASSWORD, password.c_str());
	}
	// TLS or no mail: with "try", whoever is between here and the mail
	// server strips STARTTLS and reads the reset codes and the password
	// ([SECURITY_RUN_1]). A relay on this machine is the exception, which
	// is where a mail server without TLS still makes sense.
	const bool local = url.find("://localhost") != ss_::npos ||
			url.find("://127.") != ss_::npos || url.find("://[::1]") != ss_::npos;
	curl_easy_setopt(c, CURLOPT_USE_SSL,
			(long)(local ? CURLUSESSL_TRY : CURLUSESSL_ALL));
	curl_easy_setopt(c, CURLOPT_MAIL_FROM, ("<"+from+">").c_str());
	struct curl_slist *rcpt = curl_slist_append(nullptr,
			("<"+to+">").c_str());
	curl_easy_setopt(c, CURLOPT_MAIL_RCPT, rcpt);
	ReadState r{&message, 0};
	curl_easy_setopt(c, CURLOPT_READFUNCTION, from_string);
	curl_easy_setopt(c, CURLOPT_READDATA, &r);
	curl_easy_setopt(c, CURLOPT_UPLOAD, 1L);
	try {
		perform(c, url, errbuf);
	} catch(...){
		curl_slist_free_all(rcpt);
		throw;
	}
	curl_slist_free_all(rcpt);
}

bool mail_supported()
{
	global_init_once();
	const curl_version_info_data *v = curl_version_info(CURLVERSION_NOW);
	for(const char * const *p = v->protocols; p && *p; p++){
		if(strcmp(*p, "smtp") == 0)
			return true;
	}
	return false;
}

void http_download(const ss_ &url, const ss_ &path,
		std::function<bool(uint64_t, uint64_t)> progress)
{
	char errbuf[CURL_ERROR_SIZE] = {0};
	std::ofstream f(path, std::ios::binary | std::ios::trunc);
	if(!f.good())
		throw Exception("http: cannot write "+path);
	CURL *c = easy(url, errbuf);
	Progress p{progress};
	curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, to_file);
	curl_easy_setopt(c, CURLOPT_WRITEDATA, &f);
	curl_easy_setopt(c, CURLOPT_MAXFILESIZE_LARGE, DOWNLOAD_MAX);
	curl_easy_setopt(c, CURLOPT_NOPROGRESS, 0L);
	curl_easy_setopt(c, CURLOPT_XFERINFOFUNCTION, on_progress);
	curl_easy_setopt(c, CURLOPT_XFERINFODATA, &p);
	perform(c, url, errbuf);
	f.close();
	if(!f.good())
		throw Exception("http: could not finish writing "+path);
}

} // namespace interface
// vim: set noet ts=4 sw=4:
