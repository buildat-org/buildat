// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [KIT_AGENTS_OAUTH] accounts.cpp's OAuth pieces that are not the Module's:
// the records, the checks of what a client sends, and the /authorize page.
// Included by accounts.cpp inside namespace accounts, after its own
// includes (interface/web_brand.h, by network/api.h); the flow is there
// ("OAuth for agents").
#pragma once

// How long each thing lasts: a page's sign-in, a code, an access token; a
// refresh token is KEEP_US from its last use, as a kept login is
static const int64_t OAUTH_REQUEST_US = 600LL * 1000000;
static const int64_t OAUTH_CODE_US = 120LL * 1000000;
static const int64_t OAUTH_ACCESS_US = 3600LL * 1000000;
// Registered clients: at most OAUTH_CLIENTS, the oldest never used in a
// sign-in going for a new one past that; OAUTH_REGISTERS an hour from one
// network -- the tool's server's, which every user of a hosted tool
// (claude.ai's) shares; one never used goes after a day, one used KEEP_US
// after its last use
static const size_t OAUTH_CLIENTS = 1000;
static const int OAUTH_REGISTERS = 100;
static const int64_t OAUTH_UNUSED_US = 24LL * 3600 * 1000000;
// Pages waiting for their sign-in and codes waiting to be taken, in
// memory: OAUTH_PENDING of each, past it the oldest going
// (oauth_make_room()); a network (address_bin()) opens OAUTH_PAGES pages
// in their 10 minutes and makes OAUTH_CODES codes in their 2, so one
// network's flood has a share of the cap and refuses only itself
static const size_t OAUTH_PENDING = 1000;
static const int OAUTH_PAGES = 30, OAUTH_CODES = 30;
// Wrong passwords or codes on one page before it ends, and refused /token
// calls a minute from one network
static const int OAUTH_PAGE_TRIES = 5, OAUTH_TOKEN_FAILS = 30;
// The protected resource: Kit's MCP endpoint, the one thing an agent token
// reaches (api.h)
static const char *OAUTH_RESOURCE_PATH = "/api/v1/mcp";

// **A client of RFC 7591's open registration**, stored as
// oauth_client/<id>: its name (untrusted, shown escaped), its redirect URIs,
// the sha256 of its secret ("" for a public client, token_endpoint_auth_method
// "none"), when it was made and last used in a sign-in
struct OAuthClient
{
	ss_ name, auth, secret;
	sv_<ss_> redirects;
	int64_t made_us = 0, used_us = 0;
	template<class Archive>
	void serialize(Archive &archive){
		interface::Record<Archive> r(archive, "OAuthClient", 1, 0);
		r.ar(name, auth, secret, redirects, made_us, used_us);
		r.end();
	}
};

static ss_ oauth_random_hex(size_t bytes)
{
	std::random_device rd;
	ss_ bits(bytes, '\0');
	for(char &c : bits)
		c = (char)(rd() & 0xff);
	return interface::sha256::hex(bits);
}

// base64 (RFC 4648), url's alphabet without padding or the standard one
static ss_ oauth_base64(const ss_ &in, bool url)
{
	const char *a = url ?
			"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" :
			"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	ss_ out;
	uint32_t buf = 0;
	int bits = 0;
	for(unsigned char c : in){
		buf = (buf << 8) | c;
		bits += 8;
		while(bits >= 6){
			out += a[(buf >> (bits - 6)) & 63];
			bits -= 6;
		}
	}
	if(bits > 0)
		out += a[(buf << (6 - bits)) & 63];
	while(!url && out.size() % 4)
		out += '=';
	return out;
}

// Standard base64 decoded, padding optional; "" for what is not
static ss_ oauth_unbase64(const ss_ &in)
{
	ss_ out;
	uint32_t buf = 0;
	int bits = 0;
	for(char c : in){
		if(c == '=')
			break;
		const int v = c >= 'A' && c <= 'Z' ? c - 'A' : c >= 'a' && c <= 'z' ?
				c - 'a' + 26 : c >= '0' && c <= '9' ? c - '0' + 52 :
				c == '+' ? 62 : c == '/' ? 63 : -1;
		if(v < 0)
			return "";
		buf = (buf << 6) | v;
		bits += 6;
		if(bits >= 8){
			bits -= 8;
			out += (char)((buf >> bits) & 0xff);
		}
	}
	return out;
}

static ss_ oauth_url_encode(const ss_ &s)
{
	static const char *hex = "0123456789ABCDEF";
	ss_ out;
	for(unsigned char c : s){
		if(isalnum(c) || c == '-' || c == '.' || c == '_' || c == '~')
			out += (char)c;
		else {
			out += '%';
			out += hex[c >> 4];
			out += hex[c & 15];
		}
	}
	return out;
}

// A sign-in's token apart: "<prefix><grant id, 32 hex>_<its secret, 64
// hex>", bao_ the access token and bar_ the refresh token
static bool oauth_split(const ss_ &t, const char *prefix, ss_ &gid,
		ss_ &secret)
{
	const size_t n = strlen(prefix);
	if(t.size() != n + 32 + 1 + 64 || t.compare(0, n, prefix) != 0 ||
			t[n + 32] != '_')
		return false;
	gid = t.substr(n, 32);
	secret = t.substr(n + 33);
	return interface::sha256::is_hex(gid, 32) &&
			interface::sha256::is_hex(secret, 64);
}

static ss_ oauth_sha(const ss_ &s)
{
	return interface::sha256::hex(interface::sha256::calculate(s));
}

// Equal, taking as long whatever matches
static bool oauth_same(const ss_ &a, const ss_ &b)
{
	unsigned char d = a.size() == b.size() ? 0 : 1;
	for(size_t i = 0; i < a.size() && i < b.size(); i++)
		d |= (unsigned char)(a[i] ^ b[i]);
	return d == 0;
}

// A URL's scheme and authority, lower case, as "https://host[:port]"; its
// host apart; "" for one that is not http(s)://host[:port][/...] with a
// host of letters, digits, dots and hyphens or an IPv6 address in brackets
static ss_ oauth_url_origin(const ss_ &u, ss_ *host = nullptr)
{
	ss_ l;
	for(char c : u.substr(0, u.find_first_of("/?#", u.find("://") + 3)))
		l += (char)tolower((unsigned char)c);
	const size_t s = l.find("://");
	if(s == ss_::npos || (l.substr(0, s) != "https" && l.substr(0, s) != "http"))
		return "";
	const ss_ auth = l.substr(s + 3);
	const bool v6 = !auth.empty() && auth[0] == '[';
	const size_t end = v6 ? auth.find(']') : auth.find(':');
	const ss_ h = auth.substr(0, end == ss_::npos ? auth.size() :
			end + (v6 ? 1 : 0));
	const ss_ port = auth.substr(h.size());
	if(h.empty() || h.size() > 255 || h.find_first_not_of(v6 ?
			"[]0123456789abcdef:." : "abcdefghijklmnopqrstuvwxyz0123456789.-") !=
			ss_::npos || (!port.empty() && (port[0] != ':' || port.size() < 2 ||
			port.size() > 6 || port.find_first_not_of("0123456789", 1) !=
			ss_::npos)))
		return "";
	if(host)
		*host = h;
	return l;
}

static bool oauth_loopback(const ss_ &host)
{
	if(host == "localhost" || host == "[::1]")
		return true;
	if(host.compare(0, 4, "127.") != 0)
		return false;
	return host.find_first_not_of("0123456789.") == ss_::npos;
}

// A host no page rebinds (DNS rebinding needs a name of the attacker's):
// "localhost", an IPv4 address, or an IPv6 one in brackets; lower case
static bool oauth_not_rebindable(const ss_ &host)
{
	return host == "localhost" || (!host.empty() && host[0] == '[') ||
			(!host.empty() && host.find_first_not_of("0123456789.") == ss_::npos);
}

// **Room for one more** in a map of pending pages or codes at its cap: the
// oldest goes (its until_us is when it was made plus the same time), not
// a refusal of everyone. One network's share is its RateTable's.
// simplified: a linear scan of at most `max`
template<class M>
static void oauth_make_room(M &m, size_t max)
{
	if(m.size() < max)
		return;
	auto oldest = m.begin();
	for(auto it = m.begin(); it != m.end(); ++it)
		if(it->second.until_us < oldest->second.until_us)
			oldest = it;
	m.erase(oldest);
}

// **What a redirect URI may be** (MCP's authorization spec, OAuth 2.1
// 1.5, 7.12): https, or http on a loopback address for a tool on the
// builder's own machine; no fragment, no user in it, no white space.
// "" when it may be one, else why not
static ss_ oauth_redirect_problem(const ss_ &u)
{
	if(u.empty() || u.size() > 512)
		return "a redirect URI of 1 to 512 bytes";
	for(unsigned char c : u)
		if(c <= 32 || c >= 127 || c == '#' || c == '\\' || c == '"' ||
				c == '<' || c == '>')
			return "a redirect URI has no fragment, space or quote";
	ss_ host;
	const ss_ o = oauth_url_origin(u, &host);
	if(o.empty() || u.find('@', 0) < u.find_first_of("/?", o.size()))
		return "a redirect URI is https://host[:port]/path";
	if(o.compare(0, 8, "https://") != 0 && !oauth_loopback(host))
		return "a redirect URI is https, or http on a loopback address "
				"(127.0.0.1, [::1], localhost)";
	return "";
}

// RFC 8707's resource as this server compares it: the scheme and the
// host in lower case, a trailing "/" off
static ss_ oauth_resource_norm(ss_ u)
{
	const ss_ o = oauth_url_origin(u);
	if(o.empty())
		return "";
	u = o+u.substr(o.size());
	while(u.size() > o.size() && u.back() == '/')
		u.pop_back();
	return u;
}

// PKCE (RFC 7636): a verifier or an S256 challenge, 43 to 128 of its
// letters, digits and "-._~"
static bool oauth_pkce_text(const ss_ &s)
{
	if(s.size() < 43 || s.size() > 128)
		return false;
	for(char c : s)
		if(!(isalnum((unsigned char)c) || c == '-' || c == '.' || c == '_' ||
				c == '~'))
			return false;
	return true;
}

static void oauth_self_check()
{
	// RFC 7636's appendix B
	if(oauth_base64(interface::sha256::calculate(
			"dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), true) !=
			"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" ||
			oauth_base64("ab", false) != "YWI=" ||
			oauth_unbase64("YWI=") != "ab" || oauth_unbase64("Y W") != "")
		throw Exception("accounts: OAuth base64 self-check");
	const char *ok[] = {"https://claude.ai/api/mcp/auth_callback",
			"http://localhost:33418/callback", "http://127.0.0.1:5/x?y=1",
			"http://[::1]:8000/cb", "https://EXAMPLE.org"};
	const char *bad[] = {"http://example.org/cb", "https://a.org/cb#x",
			"https://u@a.org/cb", "cursor://anysphere/cb", "https:///x",
			"https://a.org:99999999/x", "http://127.0.0.1.evil.org/cb",
			"https://a b.org/", "javascript:alert(1)", ""};
	for(const char *u : ok)
		if(!oauth_redirect_problem(u).empty())
			throw Exception(ss_("accounts: OAuth redirect self-check: ")+u);
	for(const char *u : bad)
		if(oauth_redirect_problem(u).empty())
			throw Exception(ss_("accounts: OAuth redirect self-check: ")+u);
	if(oauth_resource_norm("HTTPS://WB.example.org/api/v1/mcp/") !=
			"https://wb.example.org/api/v1/mcp" ||
			oauth_resource_norm("wb.example.org/api/v1/mcp") != "")
		throw Exception("accounts: OAuth resource self-check");
	for(const char *h : {"localhost", "127.0.0.1", "10.1.2.3", "[::1]",
			"[2001:db8::1]"})
		if(!oauth_not_rebindable(h))
			throw Exception(ss_("accounts: OAuth host self-check: ")+h);
	for(const char *h : {"evil.example", "127.0.0.1.evil.example",
			"localhost.evil.example", "1e100", ""})
		if(oauth_not_rebindable(h))
			throw Exception(ss_("accounts: OAuth host self-check: ")+h);
	// At the cap the oldest goes, whatever its key
	struct P { int64_t until_us; };
	std::map<int, P> m;
	for(int i = 0; i < 4; i++)
		m[i] = P{i == 2 ? -1 : i};
	oauth_make_room(m, 5);
	const bool under = m.size() == 4;
	oauth_make_room(m, 4);
	if(!under || m.size() != 3 || m.count(2) || !m.count(0))
		throw Exception("accounts: OAuth oauth_make_room self-check");
}

// [KIT_AGENTS_OAUTH] **The /authorize page**: what asks, where it goes
// back to, and the sign-in -- a local account's name and password (then
// its TOTP code, where it has one), or a Starport ID through the
// Starport's own window ([WEB_ISOLATED_SIGNIN]: no opener, the answer by
// this origin's /starport_signin and a BroadcastChannel; the token taken
// from the Starport by the code, as the web client does, and posted here
// with the page's form) -- and Cancel. Where the server takes Starport IDs
// the page first asks which (user, 2026-11-15: "Server login" and
// "Starport ID login", only then the name and password). An admin then
// has a step of its own, the Host's actions' box ([KIT_AGENTS_OAUTH_ADMIN_BOX]),
// the text above it following the box. Plain forms; the script is that
// choice, the box's text and the Starport's part. Phone-sized first.
static const char *oauth_page_css =
	"body{max-width:34em}input{width:100%;box-sizing:border-box;margin:.2em 0}"
	"button{min-width:7em;margin:.6em .5em .2em 0;padding:.5em .8em}"
	"label{display:block;margin:.4em 0}h1{font-size:1.4em}"
	"form{margin:.4em 0}.wide{width:100%}.box input{width:auto;margin-right:.5em}";
static const char *oauth_page_script = R"JS("use strict";
(function(){
var hb = document.getElementById("host");
function rights(){
	document.getElementById("rights").textContent = hb.checked ?
		"all your rights, the Host's actions included" :
		"your builder rights (none of the Host's)";
}
if(hb){
	hb.onchange = rights;
	rights();
}
var c = document.getElementById("choose"), pf = document.getElementById("pw");
function pick(local){
	c.hidden = local;
	pf.hidden = !local;
	if(local) pf.querySelector("input").focus();
}
if(c && pf){
	document.getElementById("local").onclick = function(){ pick(true); };
	document.getElementById("back").onclick = function(){ pick(false); };
}
var b = document.querySelector("button.sp");
if(!b) return;
var f = b.form, state = null;
function say(id, t){
	document.getElementById("err").textContent = id == "err" ? t : "";
	document.getElementById("ok").textContent = id == "ok" ? t : "";
}
function take(d){
	if(!d || typeof d !== "object" || d.buildat_starport_signin !== 1 ||
			!state || d.state !== state)
		return;
	state = null;
	if(typeof d.code !== "string")
		return say("err", d.error == "cancelled" ?
			"Cancelled in the Starport's window" : "Not signed in: " + d.error);
	say("ok", "Signed in: connecting...");
	fetch(b.dataset.sp + "/api/v1/id/redeem", {method: "POST",
		headers: {"Content-Type": "text/plain"},
		body: JSON.stringify({code: d.code})})
	.then(function(r){ return r.json(); })
	.then(function(v){
		if(!v || !v.ok || !v.result || typeof v.result.token !== "string")
			throw new Error(v && v.error || "refused");
		f.elements.id_token.value = v.result.token;
		f.submit();
	}).catch(function(e){ say("err", "Not signed in: " + (e.message || e)); });
}
if(typeof BroadcastChannel === "function"){
	b.channel = new BroadcastChannel("buildat_starport");
	b.channel.onmessage = function(e){ take(e.data); };
}
window.addEventListener("storage", function(e){
	if(e.key !== "buildat_starport_signin" || !e.newValue) return;
	try { take(JSON.parse(e.newValue)); } catch(x){}
});
b.onclick = function(){
	var a = new Uint8Array(16);
	crypto.getRandomValues(a);
	state = Array.prototype.map.call(a, function(x){
		return (x + 256).toString(16).slice(1); }).join("");
	window.open(b.dataset.sp + "/authorize?listing=" +
		encodeURIComponent(b.dataset.listing) + "&origin=" +
		encodeURIComponent(location.origin) + "&state=" + state, "_blank",
		"noopener");
	say("ok", "Sign in in the Starport's window, and Allow there");
};
})();)JS";

struct OAuthPage
{
	ss_ client, redirect, server, rid, error;
	ss_ totp_name; // the password was right: its code asked for
	ss_ admin_name; // signed in, an admin: the Host's box
	bool off = false; // agent access is off: Deny only
	bool ended = false; // no sign-in waits: the text only
	bool by_password = false; // a password tried: its form, not the choice
	// The tool's redirect with its error, a link the user may follow
	// (never a redirect before the user acts: RFC 9700 4.11.2)
	ss_ back;
	// (the Starport's URL, its origin, this server's listing there)
	sv_<std::pair<ss_, std::pair<ss_, ss_>>> starports;
};

// The page, and its headers: never in a frame, no referrer to another
// origin, only its own script and style, its forms only here and to the
// redirect URI's origin (a browser holds the redirect after a form's POST
// to form-action), its fetch only to the Starports
static std::pair<ss_, ss_> oauth_page(const OAuthPage &p)
{
	using interface::web_brand::html;
	ss_ rhost;
	const ss_ rorigin = oauth_url_origin(p.redirect, &rhost);
	ss_ h = "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
			"<meta name=\"viewport\" content=\"width=device-width, "
			"initial-scale=1\"><title>Connect an agent | Buildat</title><style>"+
			ss_(interface::web_brand::css)+oauth_page_css+"</style></head><body>"
			"<header><span class=\"brand\">"+interface::web_brand::logo+
			"Buildat</span></header>\n";
	const ss_ who = p.client.empty() ? ss_("A tool") : "<b>"+html(p.client)+"</b>";
	if(!p.ended){
		h += "<h1>Connect "+(p.client.empty() ? ss_("an agent") : html(p.client))+
				"?</h1>\n<p>"+who+" asks to work on <b>"+html(p.server)+
				"</b> as your agent: with "+(p.admin_name.empty() ?
				ss_("your builder rights (after signing in, an admin may add "
				"the Host's)") : ss_("<span id=\"rights\">your builder rights "
				"(none of the Host's)</span>"))+", its edits going into the "
				"live round, logged as your agent's.</p>\n"
				"<p class=\"meta\">Allowing it sends you back to <b>"+
				html(rhost)+"</b>"+(oauth_loopback(rhost) ? ", a program on "
				"the device you opened this on" : "")+". It is listed on My "
				"account, Connect an agent..., where you revoke it.</p>\n";
	}
	h += "<p id=\"err\" role=\"alert\">"+html(p.error)+"</p><p id=\"ok\" "
			"role=\"status\"></p>\n";
	if(!p.back.empty() && !rhost.empty())
		h += "<p><a href=\""+html(p.back)+"\">Back to "+html(rhost)+
				"</a></p>\n";
	const ss_ rid = "<input type=\"hidden\" name=\"rid\" value=\""+html(p.rid)+
			"\">";
	const ss_ action = "<form method=\"post\" action=\"/api/v1/oauth/authorize\"";
	if(!p.ended && !p.off){
		// The choice first where a Starport ID signs in too (and back to it
		// from the name and password); a TOTP code's step has none
		const bool two = !p.starports.empty() && p.totp_name.empty() &&
				p.admin_name.empty();
		const bool choose = two && !p.by_password;
		if(two){
			h += "<div id=\"choose\""+ss_(choose ? "" : " hidden")+"><button "
					"type=\"button\" id=\"local\" class=\"wide\">Server login"
					"</button>\n";
			for(size_t i = 0; i < p.starports.size(); i++){
				ss_ sh;
				oauth_url_origin(p.starports[i].first, &sh);
				h += action+">"+rid+"<input type=\"hidden\" name=\"action\" "
						"value=\"allow\"><input type=\"hidden\" name=\"id_token\">"
						"<button type=\"button\" class=\"sp wide\" data-sp=\""+
						html(p.starports[i].second.first)+"\" data-listing=\""+
						html(p.starports[i].second.second)+"\">Starport ID login"+
						(p.starports.size() > 1 ? " ("+html(sh)+")" : ss_())+
						"</button></form>\n";
			}
			h += "</div>\n";
		}
		h += action+" id=\"pw\""+ss_(choose ? " hidden" : "")+">"+rid;
		if(!p.admin_name.empty())
			h += "<p>Signed in as <b>"+html(p.admin_name)+"</b>, an admin "
					"here.</p><label class=\"box\"><input type=\"checkbox\" "
					"name=\"host\" value=\"1\" id=\"host\">Also allow the Host's "
					"actions (games: list, copy, rename...)</label><p "
					"class=\"meta\">To change it later, connect the tool again."
					"</p>";
		else if(!p.totp_name.empty())
			h += "<p>Signed in as <b>"+html(p.totp_name)+"</b>.</p><label>The "
					"code from your authenticator app <input name=\"totp\" "
					"inputmode=\"numeric\" autocomplete=\"one-time-code\" "
					"required autofocus></label>";
		else
			h += "<label>Your name on this server <input name=\"name\" "
					"autocomplete=\"username\" autocapitalize=\"none\" required "
					"autofocus></label><label>Password <input name=\"password\" "
					"type=\"password\" autocomplete=\"current-password\" "
					"required></label>";
		h += "<button name=\"action\" value=\"allow\">Allow</button>";
		if(two)
			h += "<button type=\"button\" id=\"back\">Back</button>";
		h += "</form>\n";
	}
	if(!p.ended)
		h += action+">"+rid+"<button name=\"action\" value=\"deny\">Cancel"
				"</button></form>\n";
	h += "<script>"+ss_(oauth_page_script)+"</script></body></html>\n";
	ss_ connect;
	for(auto &s : p.starports)
		connect += " "+s.second.first;
	// An IPv6 address is no CSP host: any http one then
	const ss_ form = rorigin.empty() ? ss_() : rhost[0] == '[' ? " http:" :
			" "+rorigin;
	auto hash = [](const ss_ &s){
		return "'sha256-"+oauth_base64(interface::sha256::calculate(s), false)+
				"'";
	};
	const ss_ headers = "Content-Security-Policy: default-src 'none'; "
			"script-src "+hash(oauth_page_script)+"; style-src "+
			hash(ss_(interface::web_brand::css)+oauth_page_css)+"; img-src "
			"'self'; font-src 'self'; connect-src"+(connect.empty() ?
			ss_(" 'none'") : connect)+"; form-action 'self'"+form+
			"; frame-ancestors 'none'; base-uri 'none'\r\n"
			"X-Frame-Options: DENY\r\n"
			"Referrer-Policy: same-origin\r\n"
			"X-Content-Type-Options: nosniff\r\n"
			"Cache-Control: no-store\r\n";
	return std::make_pair(h, headers);
}

// vim: set noet ts=4 sw=4:
