// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "accounts/api.h"
#include "network/api.h"
#include "storage/api.h"
#include "starport_announce/api.h"
#include "core/log.h"
#include "core/json.h"
#include "core/version.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/sha256.h"
#include "interface/sha1.h"
#include "interface/os.h"
#include "interface/http.h"
#include "interface/fs.h"
#include "interface/tcpsocket.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/utility.hpp>
#include <random>
#include <algorithm>
#include <set>
#include <sstream>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <ctime>
#include <cstdio>
#include <cstring>
#include <cerrno>

using json::jstr;

#define MODULE "accounts"

using interface::Event;
using storage::pack;
using storage::unpack;

namespace accounts {

static const int PBKDF2_ITERATIONS = 10000;
// Failed logins on one connection before it has to reconnect
static const int MAX_LOGIN_FAILURES = 5;
static const size_t MIN_PASSWORD = 6;

// PBKDF2-HMAC-SHA256 with one 32-byte block
static ss_ hmac_sha256(const ss_ &key_in, const ss_ &msg)
{
	ss_ key = key_in.size() > 64 ? interface::sha256::calculate(key_in) :
			key_in;
	key.resize(64, '\0');
	ss_ ipad(64, '\0'), opad(64, '\0');
	for(int i = 0; i < 64; i++){
		ipad[i] = key[i] ^ 0x36;
		opad[i] = key[i] ^ 0x5c;
	}
	return interface::sha256::calculate(opad +
			interface::sha256::calculate(ipad + msg));
}

static ss_ pbkdf2_sha256(const ss_ &password, const ss_ &salt, int iterations)
{
	ss_ u = hmac_sha256(password, salt + ss_("\0\0\0\1", 4));
	ss_ t = u;
	for(int i = 1; i < iterations; i++){
		u = hmac_sha256(password, u);
		for(size_t j = 0; j < t.size(); j++)
			t[j] ^= u[j];
	}
	return t;
}

// RFC 7914's PBKDF2-HMAC-SHA256 vectors. Run at every start: a wrong hash
// would lock everybody out, silently.
static void check_pbkdf2()
{
	const ss_ a = interface::sha256::hex(pbkdf2_sha256("password", "salt", 1));
	const ss_ b = interface::sha256::hex(pbkdf2_sha256("password", "salt", 2));
	if(a != "120fb6cffcf8b32c43e7225256c4f837"
			"a86548c92ccc35480805987cb70be17b" ||
			b != "ae4d0c95af6b46d32d0adff928f06dd0"
			"2a303f8ef3c251dfd6e2d85a95474c43")
		throw Exception("accounts: PBKDF2-HMAC-SHA256 self-check failed");
}

// **TOTP** ([STARPORT] 10a, RFC 6238): HMAC-SHA1, 30 s steps, 6 digits.
// For a server's own admins and moderators, and anyone who wants it; a
// Starport ID is an account of the Starport's server and has it the same.
static ss_ hmac_sha1(ss_ key, const ss_ &msg)
{
	if(key.size() > 64)
		key = interface::sha1::calculate(key);
	key.resize(64, '\0');
	ss_ ipad(64, '\0'), opad(64, '\0');
	for(int i = 0; i < 64; i++){
		ipad[i] = key[i] ^ 0x36;
		opad[i] = key[i] ^ 0x5c;
	}
	return interface::sha1::calculate(opad +
			interface::sha1::calculate(ipad + msg));
}

static ss_ hotp(const ss_ &secret, uint64_t counter, int digits = 6)
{
	ss_ msg(8, '\0');
	for(int i = 7; i >= 0; i--, counter >>= 8)
		msg[i] = (char)(counter & 0xff);
	const ss_ h = hmac_sha1(secret, msg);
	const int o = h[19] & 0x0f;
	uint32_t v = ((uint32_t)(h[o] & 0x7f) << 24) |
			((uint32_t)(unsigned char)h[o + 1] << 16) |
			((uint32_t)(unsigned char)h[o + 2] << 8) |
			(uint32_t)(unsigned char)h[o + 3];
	uint32_t mod = 1;
	for(int i = 0; i < digits; i++)
		mod *= 10;
	char buf[16];
	snprintf(buf, sizeof buf, "%0*u", digits, v % mod);
	return buf;
}

// What authenticator apps take: RFC 4648 base32, no padding
static ss_ base32(const ss_ &data)
{
	static const char *A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
	ss_ out;
	uint32_t buf = 0;
	int bits = 0;
	for(unsigned char c : data){
		buf = (buf << 8) | c;
		bits += 8;
		while(bits >= 5){
			out += A[(buf >> (bits - 5)) & 31];
			bits -= 5;
		}
	}
	if(bits > 0)
		out += A[(buf << (5 - bits)) & 31];
	return out;
}

// RFC 6238's SHA-1 vector at T = 59 s, and RFC 4648's base32. Run at every
// start, as the PBKDF2 one is: a wrong TOTP locks people out.
static void totp_self_check()
{
	if(hotp("12345678901234567890", 59 / 30, 8) != "94287082" ||
			base32("foobar") != "MZXW6YTBOI")
		throw Exception("accounts: TOTP self-check failed");
}

// [SERVER_STATS] An hour's row, or a day's folded from them: players by
// the minute (min, the sum for an average weighted by minutes, max), the
// joins, the accounts made, the distinct names, the peak tick gap and
// memory, and the minutes sampled -- none is a gap, not a zero
struct StatRow
{
	int64_t minutes = 0, pmin = 0, psum = 0, pmax = 0, joins = 0, made = 0,
			names = 0, gap_ms = 0, mem = 0;

	ss_ str() const {
		char b[200];
		snprintf(b, sizeof b, "%lld %lld %lld %lld %lld %lld %lld %lld %lld",
				(long long)minutes, (long long)pmin, (long long)psum,
				(long long)pmax, (long long)joins, (long long)made,
				(long long)names, (long long)gap_ms, (long long)mem);
		return b;
	}
	static StatRow parse(const ss_ &s){
		StatRow r;
		std::istringstream is(s);
		is >> r.minutes >> r.pmin >> r.psum >> r.pmax >> r.joins >> r.made >>
				r.names >> r.gap_ms >> r.mem;
		return r;
	}
	void sample(int64_t players, int64_t gap, int64_t memory){
		pmin = minutes ? std::min(pmin, players) : players;
		psum += players;
		pmax = std::max(pmax, players);
		gap_ms = std::max(gap_ms, gap);
		mem = std::max(mem, memory);
		minutes++;
	}
	// [unit, minutes, min, average, max, joins, made, names, gap, memory]
	json::Value json(int64_t unit) const {
		json::Value v = json::array();
		v.append(unit);
		v.append(minutes);
		v.append(pmin);
		v.append(json::Value(minutes ? (double)psum / minutes : 0.0));
		for(int64_t x : {pmax, joins, made, names, gap_ms, mem})
			v.append(x);
		return v;
	}
};

// A day from its hours: what they sum or bound; the names are the day's
// own count, which the hours' cannot add up to
static StatRow fold_hours(const sv_<StatRow> &hours, int64_t names)
{
	StatRow d;
	for(const StatRow &h : hours){
		if(h.minutes > 0){
			d.pmin = d.minutes ? std::min(d.pmin, h.pmin) : h.pmin;
			d.minutes += h.minutes;
		}
		d.psum += h.psum;
		d.pmax = std::max(d.pmax, h.pmax);
		d.joins += h.joins;
		d.made += h.made;
		d.gap_ms = std::max(d.gap_ms, h.gap_ms);
		d.mem = std::max(d.mem, h.mem);
	}
	d.names = names;
	return d;
}

// 24 made-up hours, one missing, the first half sampled at 4 players: the
// day's average is by minutes, not the hours' averages'
static void stats_self_check()
{
	sv_<StatRow> hours;
	for(int i = 0; i < 24; i++){
		if(i == 5)
			continue;
		StatRow h;
		const int n = i == 0 ? 30 : 60;
		for(int m = 0; m < n; m++)
			h.sample(i == 0 ? 4 : i == 10 && m == 7 ? 7 : 2, i == 3 ? 500 : 10,
					1000 + i);
		h.joins = 1;
		h.made = i == 20;
		hours.push_back(StatRow::parse(h.str()));
	}
	const StatRow d = fold_hours(hours, 3);
	if(d.minutes != 30 + 22 * 60 || d.psum != 30 * 4 + 22 * 60 * 2 + 5 ||
			d.pmin != 2 || d.pmax != 7 || d.joins != 23 || d.made != 1 ||
			d.names != 3 || d.gap_ms != 500 || d.mem != 1023)
		throw Exception("accounts: statistics self-check failed: "+d.str());
}

struct Account
{
	ss_ salt;
	ss_ hash;
	sv_<ss_> privs;

	template<class Archive>
	void serialize(Archive &archive){
		archive(salt, hash, privs);
	}
	bool has(const ss_ &priv) const {
		for(const ss_ &p : privs)
			if(p == priv)
				return true;
		return false;
	}
};

// Who may make an account, which only an admin changes
struct AccessSettings
{
	uint8_t open_registration = 0;

	template<class Archive>
	void serialize(Archive &archive){
		archive(open_registration);
	}
};

// A one-time invite: the admin who made it. privs is kept empty.
struct Invite
{
	sv_<ss_> privs;
	ss_ by;

	template<class Archive>
	void serialize(Archive &archive){
		archive(privs, by);
	}
};

// A name banned, the address it last joined from, and who banned it
struct Ban
{
	ss_ address;
	ss_ by;

	template<class Archive>
	void serialize(Archive &archive){
		archive(address, by);
	}
};

// Failed logins of one name or one address: a wait that doubles with each,
// up to a minute, and after FAIL_LOCK of them in the window a lock of the
// window's length
struct Failures
{
	int count = 0;
	int64_t first_us = 0;
	int64_t wait_until_us = 0;
};
static const int64_t FAIL_WINDOW_US = 600LL * 1000000;
// [TRUST_LADDER] Open registration's untrusted accounts: at most
// UNTRUSTED_A_NETWORK made in the last UNTRUSTED_US from one
// network::address_bin() and not trusted since, and UNTRUSTED_A_DAY made
// in a day on the whole server (an IPv6 /48 is 65536 /64s)
static const int UNTRUSTED_A_NETWORK = 5;
static const int UNTRUSTED_A_DAY = 50;
static const int64_t UNTRUSTED_US = 30LL * 24 * 3600 * 1000000;
static const int FAIL_LOCK = 10;
// [REWORK_FIXES] A failure table's ceiling: past it the expired entries are
// swept, and if it is still full the one whose wait ends first goes. A
// key's entry is otherwise erased only when the key comes back, and spread
// IPv6 /64s would grow it without bound. simplified: at the ceiling an
// attacker's spray can push out a real lockout's entry (the soonest-ending
// one); 100000 of them is ~10 MB.
static const size_t FAIL_KEYS_MAX = 100000;

// A code to type: no 0/O or 1/I to mistake for each other
static ss_ random_code(size_t n)
{
	static const char *alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
	std::random_device rd;
	ss_ s;
	for(size_t i = 0; i < n; i++)
		s += alphabet[rd() % 32];
	return s;
}

static ss_ upper(ss_ s)
{
	for(char &c : s)
		c = (char)toupper((unsigned char)c);
	return s;
}

// Luanti's rule for a player name, which every game here keeps
static bool valid_name(const ss_ &name)
{
	if(name.empty() || name.size() > 20)
		return false;
	for(char c : name)
		if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
			return false;
	return true;
}

// A name no new account takes: "client<digits>" is what an app calls a
// peer that has not logged in (apps/vanilla's player_name_of), and an
// account of that name was the same player to it ([SECURITY_RUN_1]).
// One already made keeps logging in.
static bool reserved_name(const ss_ &name)
{
	if(name.size() < 7 || upper(name.substr(0, 6)) != "CLIENT")
		return false;
	for(size_t i = 6; i < name.size(); i++)
		if(!isdigit((unsigned char)name[i]))
			return false;
	return true;
}

struct Hello
{
	uint8_t local = 0;      // no password asked
	// The join asks for the setup code (the server has no admin), or says
	// a new name needs an invite (registration is not open)
	uint8_t setup = 0;
	uint8_t open_registration = 0;
	// [STARPORT] 10c: a Starport ID logs in here
	uint8_t starport = 0;
	// [SERVER_ADMIN_PAGE]: the server has starport_announce, so an admin's
	// Server window has its Starport panels (never on a Starport)
	uint8_t announce = 0;
	// [SERVER_VERSION]: "0.6.75-ea7eb9e33", for the Server window
	ss_ version;
	template<class Archive>
	void serialize(Archive &archive){
		archive(local, setup, open_registration, starport, announce, version);
	}
};

struct LoginRequest
{
	ss_ name;
	ss_ password;
	ss_ code; // the setup code, or an invite code
	// [ACC_KEEP]: a token from a login that asked to be kept, in place of
	// the password; and whether this login asks for one
	ss_ token;
	uint8_t keep = 0;
	// [STARPORT] 10: the TOTP code, and a Starport ID's token for this
	// server in place of a name and a password
	ss_ totp;
	ss_ starport;
	// [ACCOUNT_CREATE]: this login is allowed to make the account if the name
	// does not exist; a plain login (0) refuses an unknown name instead
	uint8_t create = 0;
	template<class Archive>
	void serialize(Archive &archive){
		// A leading version byte: add version-gated fields below it rather
		// than breaking the wire format again (voxel_cereal.h pattern)
		uint8_t version = 1;
		archive(version);
		archive(name, password, code, token, keep, totp, starport, create);
	}
};

// accounts:totp: begin (a new secret, pending), confirm (its first code
// turns it on), off (a code turns it off)
struct TotpRequest
{
	ss_ cmd;
	ss_ code;
	template<class Archive>
	void serialize(Archive &archive){
		archive(cmd, code);
	}
};
struct TotpResult
{
	ss_ error;
	ss_ secret; // base32, while one is pending
	ss_ uri;    // otpauth://, for an app's own QR reader or a link
	uint8_t on = 0;
	template<class Archive>
	void serialize(Archive &archive){
		archive(error, secret, uri, on);
	}
};

// **A kept login** ([ACC_KEEP]), stored as token/<the token's sha256>: the
// account, when it ends, and the account's password hash then, so that a
// new password or a deleted account ends it too
struct KeptLogin
{
	ss_ name;
	int64_t expires_us = 0;
	ss_ hash;
	template<class Archive>
	void serialize(Archive &archive){
		archive(name, expires_us, hash);
	}
};
static const int64_t KEEP_US = 90LL * 24 * 3600 * 1000000;

// **A login waiting on its TOTP code** ([LOGIN_UNLOADED]), stored as
// totp_wait/<the token's sha256>: the password was right, and the token
// stands for it with a code for totp_wait_s, three codes at most. The
// client keeps it, so a tab the browser unloaded while its user was in
// the authenticator app comes back to the code.
struct TotpWait
{
	ss_ name;
	int64_t expires_us = 0;
	ss_ hash;
	int32_t tries = 0;
	template<class Archive>
	void serialize(Archive &archive){
		archive(name, expires_us, hash, tries);
	}
};

struct AdminRequest
{
	ss_ cmd;
	ss_ name;
	ss_ arg;
	uint8_t on = 0;
	template<class Archive>
	void serialize(Archive &archive){
		archive(cmd, name, arg, on);
	}
};

struct UserRow
{
	ss_ name;
	sv_<ss_> privs;
	uint8_t here = 0;
	// 10g: logs in only by its Starport ID (no password anyone knows), so
	// not while the Starport is away
	uint8_t id_only = 0;
	// [TRUST_LADDER]
	int32_t level = 0;
	// [FP_ABUSE] 5: what the apps keep for it, "" for nothing
	ss_ storage;
	template<class Archive>
	void serialize(Archive &archive){
		archive(name, privs, here, id_only, level, storage);
	}
};

struct UsersInfo
{
	sv_<UserRow> users;
	sv_<std::pair<ss_, Invite>> invites;
	AccessSettings access;
	// name, address
	sv_<std::pair<ss_, ss_>> bans;
	// 10g: Starport IDs off, anyone or approved; the IDs waiting
	ss_ starport_ids;
	sv_<ss_> approvals;
	// [TRUST_LADDER] The viewer's: a moderator's page has less on it
	int32_t level = 0;
	// [FP_ABUSE] 3: the storage budget in MB, and what all apps keep
	int32_t budget_mb = 0;
	ss_ storage;
	template<class Archive>
	void serialize(Archive &archive){
		archive(users, invites, access, bans, starport_ids, approvals, level,
				budget_mb, storage);
	}
};

static const int64_t DEFAULT_BUDGET_MB = 2048;

static ss_ size_text(uint64_t bytes)
{
	char buf[32];
	if(bytes >= 1024 * 1024)
		snprintf(buf, sizeof buf, "%.1f MB", bytes / (1024.0 * 1024.0));
	else
		snprintf(buf, sizeof buf, "%.0f kB", bytes / 1024.0);
	return buf;
}

struct Peer
{
	ss_ name; // empty until joined
	ss_ address;
	bool web = false;
	int failures = 0;
	int64_t since_s = 0; // [SERVER_STATS] time joined counted from
};

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;
	storage::Save *m_save = nullptr;
	storage::Store *m_store = nullptr;
	AccessSettings m_access;
	ss_ m_setup_code;
	bool m_launched = false;
	// The token the launcher started this server with (main.cpp takes it
	// out of the environment), and the peers that showed it: the
	// launcher's own client, which is this server's owner and admin.
	// Without a token -- a server started by hand with launcher=1, which
	// the tests do -- a loopback peer is local, as it was.
	ss_ m_owner_token;
	// [ACCOUNTS_LAN] "Open to LAN" from the Server window: whether it is,
	// and the name it is announced under (the app's, or set_lan_name()'s)
	bool m_lan_open = false;
	ss_ m_lan_name;
	bool m_lan_account = true;
	std::set<PeerId> m_owners;
	std::map<PeerId, Peer> m_peers;
	// [SERVER_STATS] The hour in progress, written at each minute's sample
	StatRow m_hour;
	int64_t m_hour_no = -1;
	std::set<ss_> m_hour_names;
	int64_t m_next_sample_us = 0;
	// A logged in account's wrong old passwords, by its name
	std::map<ss_, Failures> m_name_failures;
	// Failed logins, by network::address_bin()
	std::map<ss_, Failures> m_address_failures;
	// [SERVER_ADMIN_PAGE]: test mails' answers, from their threads, which
	// may outlive the module; sent to the admin who asked on a tick
	struct MailResults { std::mutex m; std::vector<std::pair<PeerId, ss_>> r; };
	std::shared_ptr<MailResults> m_mail_results =
			std::make_shared<MailResults>();

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		if(m_save){
			storage::access(m_server, [&](storage::Interface *istorage){
				istorage->close(m_save);
			});
		}
	}

	// The failure counter is what stops a password being guessed, so it
	// is checked at every start as the PBKDF2 and TOTP vectors are. It
	// drives note_failure/failure_wait with a clock of its own (both take
	// `now`), so it is deterministic and touches no real account.
	void rate_limit_self_check()
	{
		const int64_t s = 1000000; // one second in us
		std::map<ss_, Failures> m;
		// An unknown key waits for nothing
		if(failure_wait(m, "a", 0) != 0)
			throw Exception("accounts: rate-limit self-check: a fresh key");
		// The wait doubles to a minute, then FAIL_LOCK of them in the
		// window locks it for the window's length
		const int64_t want[] = {1, 2, 4, 8, 16, 32, 60, 60, 60, 600};
		for(int i = 0; i < FAIL_LOCK; i++){
			note_failure(m, "a", 0);
			if(failure_wait(m, "a", 0) != want[i] * s)
				throw Exception("accounts: rate-limit self-check: the wait "
						"after "+itos(i + 1)+" failures is "+
						itos((int)(failure_wait(m, "a", 0) / s))+" s, not "+
						itos((int)want[i]));
		}
		// Locked at FAIL_LOCK: still waiting just before the window ends,
		// cleared once both the window has passed and the wait is over
		if(failure_wait(m, "a", 599 * s) <= 0)
			throw Exception("accounts: rate-limit self-check: unlocked early");
		if(failure_wait(m, "a", 601 * s) != 0)
			throw Exception("accounts: rate-limit self-check: still locked "
					"after the window");
		// A failure outside the window starts the count over, not doubling
		// from where an old one left off
		// The blocks the failures are counted in
		const char *bins[][2] = {{"1.2.3.4", "1.2.3.0/24"},
				{"::ffff:10.6.0.9", "10.6.0.0/24"},
				{"2001:db8:0:1:a:b:c:d", "2001:db8:0:1::/64"},
				{"2001:DB8::1", "2001:db8:0:0::/64"},
				{"fe80::1%eth0", "fe80:0:0:0::/64"}};
		for(auto &b : bins)
			if(network::address_bin(b[0]) != b[1])
				throw Exception(ss_("accounts: rate-limit self-check: ")+
						b[0]+"'s block is "+network::address_bin(b[0]));
		std::map<ss_, Failures> m2;
		note_failure(m2, "b", 0);
		note_failure(m2, "b", 601 * s);
		if(failure_wait(m2, "b", 601 * s) != 1 * s)
			throw Exception("accounts: rate-limit self-check: the window did "
					"not reset the count");
		// The table stays under its ceiling, and expired keys are swept
		// when it is reached
		std::map<ss_, Failures> m3;
		for(size_t i = 0; i <= FAIL_KEYS_MAX; i++)
			note_failure(m3, itos((int)i), 0);
		if(m3.size() != FAIL_KEYS_MAX)
			throw Exception("accounts: rate-limit self-check: the table "
					"grew past its ceiling");
		note_failure(m3, "late", 700 * s);
		if(m3.size() != 1)
			throw Exception("accounts: rate-limit self-check: expired keys "
					"not swept at the ceiling");
	}

	void init()
	{
		check_pbkdf2();
		totp_self_check();
		stats_self_check();
		rate_limit_self_check();
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this, Event::t("core:tick"));
		for(const char *name : {"accounts:owner_token",
				"accounts:get_hello", "accounts:login",
				"accounts:admin", "accounts:passwd", "accounts:logout",
				"accounts:totp", "accounts:link_starport",
				"accounts:unlink_starport", "accounts:open_lan"})
			m_server->sub_event(this,
					Event::t(ss_("network:packet_received/")+name));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("network:packet_received/accounts:owner_token",
				on_owner_token, network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:get_hello",
				on_get_hello, network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:login", on_login,
				network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:admin", on_admin,
				network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:passwd", on_passwd,
				network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:logout", on_logout,
				network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:totp", on_totp,
				network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:link_starport",
				on_link_starport, network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:unlink_starport",
				on_unlink_starport, network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:open_lan",
				on_open_lan, network::Packet)
	}

	// One key of what the launcher asked for through the server's -u
	// ([LAUNCH_GRID]), read as a packet would be
	ss_ launch_param(const ss_ &key_name)
	{
		return interface::launch_param(
				m_server->get_config().get<ss_>("untrusted_launch"), key_name);
	}

	void on_start()
	{
		m_launched = launch_param("launcher") == "1";
		m_owner_token = m_server->get_config().get<ss_>("owner_token");
		// **Answers go ahead of a game's bulk** ([NET_CHANNELS]; user,
		// 2026-09-30: a new invite never showed, behind a world streaming to
		// a slow link). Each is the whole of what it says, so a newer one
		// replacing an unsent one loses nothing: the users list, what an
		// admin's request came to, a login's and a password's answers.
		network::access(m_server, [&](network::Interface *inetwork){
			for(const char *name : {"accounts:hello", "accounts:login_result",
					"accounts:users", "accounts:admin_result",
					"accounts:passwd_result", "accounts:totp_result",
					"accounts:link_result", "accounts:stats"})
				inetwork->declare(name,
						network::Interface::Channel::LatestOnly);
		});
		if(m_store)
			return;
		storage::access(m_server, [&](storage::Interface *istorage){
			m_save = istorage->open("_server");
			if(!m_save)
				m_save = istorage->create("_server");
		});
		if(!m_save){
			m_server->shutdown(1, "accounts: no server store");
			return;
		}
		m_store = m_save->store("accounts");
		migrate_levels();
		migrate_links();
		load_access();
	}

	void send(PeerId peer, const ss_ &name, const ss_ &data)
	{
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, name, data);
		});
	}

	// Peers

	void on_client_connected(const network::NewClient &client)
	{
		Peer peer;
		peer.address = client.info.address;
		peer.web = client.info.web;
		m_peers[client.info.id] = peer;
	}

	void on_client_disconnected(const network::OldClient &client)
	{
		m_owners.erase(client.info.id);
		auto it = m_peers.find(client.info.id);
		if(it == m_peers.end())
			return;
		const bool joined = !it->second.name.empty();
		if(joined)
			add_time_joined(it->second);
		m_peers.erase(it);
		if(joined)
			send_users_to_staff();
	}

	// The interface

	ss_ name_of(PeerId peer)
	{
		auto it = m_peers.find(peer);
		return it == m_peers.end() ? "" : it->second.name;
	}

	PeerId find_peer(const ss_ &name)
	{
		for(auto &pair : m_peers)
			if(!name.empty() && pair.second.name == name)
				return pair.first;
		return 0;
	}

	sv_<PeerId> find_peers(const ss_ &name)
	{
		sv_<PeerId> out;
		for(auto &pair : m_peers)
			if(!name.empty() && pair.second.name == name)
				out.push_back(pair.first);
		return out;
	}

	bool m_multiple_logins = false;
	void set_multiple_logins(bool on)
	{
		m_multiple_logins = on;
	}

	ss_ address_of(PeerId peer)
	{
		auto it = m_peers.find(peer);
		return it == m_peers.end() ? "" : it->second.address;
	}

	bool is_admin(const ss_ &name)
	{
		Account account;
		return !name.empty() && get_account(name, account) &&
				account.has("admin");
	}

	bool exists(const ss_ &name)
	{
		Account account;
		return !name.empty() && get_account(name, account);
	}

	bool check_kept(const ss_ &name, const ss_ &token)
	{
		KeptLogin kept;
		Account account;
		ss_ data;
		if(token.empty() || token.size() > 100)
			return false;
		const ss_ key = "token/"+interface::sha256::hex(
				interface::sha256::calculate(token));
		const int64_t now = interface::os::wall_us();
		if(!(m_store->get(key, data) && unpack(data, kept) &&
				kept.name == name && kept.expires_us >= now &&
				get_account(name, account) && kept.hash == account.hash))
			return false;
		// [TRUST_LADDER]: KEEP_US from each use, written once a day at most
		if(kept.expires_us < now + KEEP_US - 86400LL * 1000000){
			kept.expires_us = now + KEEP_US;
			m_store->set(key, pack(kept));
		}
		return true;
	}

	// [TRUST_LADDER] Why open registration takes no new account from the
	// network `bin` now, or "". Forgets the untrusted/ records past
	// UNTRUSTED_US or of an account trusted since; one of a deleted
	// account counts on until then, so a deletion makes no room.
	ss_ untrusted_quota(const ss_ &bin)
	{
		const int64_t now = interface::os::wall_us();
		int in_bin = 0, today = 0;
		for(const ss_ &key : m_store->list("untrusted/")){
			ss_ v;
			m_store->get(key, v);
			const size_t sp = v.find(' ');
			const int64_t made = sp == ss_::npos ? 0 :
					atoll(v.c_str() + sp + 1);
			const ss_ name = key.substr(10);
			if(made < now - UNTRUSTED_US || level(name) >= LV_MEMBER){
				m_store->remove(key);
				continue;
			}
			if(v.substr(0, sp) == bin)
				in_bin++;
			if(made > now - 86400LL * 1000000)
				today++;
		}
		if(in_bin >= UNTRUSTED_A_NETWORK)
			return "This network has "+itos(UNTRUSTED_A_NETWORK)+" new "
					"accounts waiting to be trusted: one more is made once a "
					+level_name(LV_HELPER)+" or a "+level_name(LV_MODERATOR)+
					" trusts one of them, or it has been active a few days";
		if(today >= UNTRUSTED_A_DAY)
			return "No more new accounts today; try tomorrow";
		return "";
	}

	int level(const ss_ &name)
	{
		Account account;
		ss_ v;
		if(name.empty() || !get_account(name, account))
			return LV_NEW;
		if(account.has("admin"))
			return LV_ADMIN;
		return m_store->get("level/"+name, v) ? atoi(v.c_str()) : LV_NEW;
	}

	ss_ set_level(const ss_ &name, int lv, const ss_ &by)
	{
		if(!exists(name))
			return "No such account";
		const int was = level(name);
		if(lv < LV_NEW || lv >= LV_ADMIN || was >= LV_ADMIN)
			return "A "+level_name(LV_ADMIN)+" is made in the Server window";
		if(!by.empty()){
			const int by_lv = level(by);
			if(by_lv < LV_MODERATOR || lv >= by_lv || was >= by_lv)
				return "One sets only levels below one's own, from "+
						level_name(LV_MODERATOR);
		}
		if(lv == LV_NEW)
			m_store->remove("level/"+name);
		else
			m_store->set("level/"+name, itos(lv));
		if(lv >= LV_MEMBER)
			m_store->remove("untrusted/"+name);
		if(!by.empty())
			log_i(MODULE, "%s set the level of %s to %i", cs(by), cs(name), lv);
		privs_changed(name);
		// A new moderator's Server window has the Accounts page
		if(lv >= LV_MODERATOR)
			for(PeerId peer : find_peers(name))
				send_users(peer);
		return "";
	}

	// [TRUST_LADDER] 0.6.73 saved the levels as privileges
	void migrate_levels()
	{
		for(const ss_ &key : m_store->list("auth/")){
			Account account;
			const ss_ name = key.substr(5);
			if(!get_account(name, account))
				continue;
			int lv = LV_NEW;
			sv_<ss_> privs;
			for(const ss_ &p : account.privs){
				const int l = p == "trusted" ? LV_MEMBER : p == "helper" ?
						LV_HELPER : p == "moderator" ? LV_MODERATOR : -1;
				if(l < 0)
					privs.push_back(p);
				lv = std::max(lv, l);
			}
			if(privs.size() == account.privs.size())
				continue;
			account.privs = privs;
			set_account(name, account);
			if(lv > level(name))
				m_store->set("level/"+name, itos(lv));
		}
	}

	// -- Starport ID links ([ID_CLAIM_ACCOUNT] 5): one per Starport an
	// account has an ID on, starport_of/<name>/<starport> ->
	// starport/<starport>/<sub>, which -> name

	// A link's Starport, from starport/<starport>/<sub>
	static ss_ link_starport(const ss_ &link)
	{
		const size_t a = link.find('/'), b = link.rfind('/');
		return a == ss_::npos || b <= a ? ss_() : link.substr(a + 1, b - a - 1);
	}

	sv_<ss_> links_of(const ss_ &name)
	{
		sv_<ss_> out;
		for(const ss_ &key : m_store->list("starport_of/"+name+"/")){
			ss_ link;
			if(m_store->get(key, link))
				out.push_back(link);
		}
		return out;
	}

	void unlink_all(const ss_ &name)
	{
		for(const ss_ &key : m_store->list("starport_of/"+name+"/")){
			ss_ link;
			if(m_store->get(key, link))
				m_store->remove(link);
			m_store->remove(key);
		}
	}

	// The ID linked to the account, in place of its older ID of the same
	// Starport: "" or what was replaced. The caller checked that the ID is
	// no other account's.
	ss_ link_id(const ss_ &name, const starport_announce::IdLogin &id)
	{
		const ss_ link = "starport/"+id.starport+"/"+id.sub;
		const ss_ key = "starport_of/"+name+"/"+id.starport;
		ss_ old, note;
		if(m_store->get(key, old) && old != link){
			m_store->remove(old);
			note = "Your older Starport ID of "+id.starport+" was replaced";
		} else if(links_of(name).empty() &&
				!m_store->get("own_password/"+name, old)){
			// An account of its own being linked: its password is known
			m_store->set("own_password/"+name, "");
		}
		m_store->set(link, name);
		m_store->set(key, link);
		log_i(MODULE, "%s linked a Starport ID of %s", cs(name),
				cs(id.starport));
		return note;
	}

	// The single starport_of/<name> of before, as its Starport's
	void migrate_links()
	{
		for(const ss_ &key : m_store->list("starport_of/")){
			const ss_ name = key.substr(12);
			ss_ link;
			if(name.find('/') != ss_::npos || !m_store->get(key, link))
				continue;
			m_store->set(key+"/"+link_starport(link), link);
			m_store->remove(key);
		}
	}

	sv_<ss_> account_names()
	{
		sv_<ss_> out;
		if(m_store)
			for(const ss_ &key : m_store->list("auth/"))
				out.push_back(key.substr(5));
		return out;
	}

	// The launcher's own client, which connects by TCP or the pipe and
	// never by a WebSocket: a WebSocket from 127.0.0.1 is whatever page
	// the user's browser has open, and the WebSocket upgrade takes any
	// Origin ([SECURITY_RUN_1])
	bool is_local(PeerId peer)
	{
		auto it = m_peers.find(peer);
		if(!m_launched || it == m_peers.end() || it->second.web)
			return false;
		if(!m_owner_token.empty())
			return m_owners.count(peer) != 0;
		return it->second.address == "127.0.0.1" ||
				it->second.address == "::1";
	}

	// Another user or program on this machine reaches 127.0.0.1 too, and
	// once the owner opens the game to the LAN everyone there does: what
	// makes a peer the owner is the token, compared in constant time
	void on_owner_token(const network::Packet &packet)
	{
		if(m_owner_token.empty() || !m_peers.count(packet.sender))
			return;
		const ss_ &got = packet.data;
		unsigned diff = got.size() ^ m_owner_token.size();
		for(size_t i = 0; i < m_owner_token.size(); i++)
			diff |= (unsigned char)m_owner_token[i] ^
					(unsigned char)(i < got.size() ? got[i] : 0);
		if(diff != 0){
			log_w(MODULE, "Peer %i sent a wrong owner token",
					(int)packet.sender);
			return;
		}
		m_owners.insert(packet.sender);
		log_i(MODULE, "Peer %i is this server's owner", (int)packet.sender);
	}

	bool launched()
	{
		return m_launched;
	}

	void kick(PeerId peer, const ss_ &why)
	{
		auto it = m_peers.find(peer);
		if(it == m_peers.end())
			return;
		log_i(MODULE, "%s kicked: %s", cs(it->second.name), cs(why));
		send(peer, "accounts:kicked", pack(why));
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->disconnect(peer);
		});
	}

	ss_ ban(const ss_ &name, const ss_ &by, int64_t until = 0,
			const ss_ &reason = "")
	{
		if(!m_store)
			return "No accounts yet";
		if(!valid_name(name))
			return "No such name";
		if(is_admin(name))
			return "An admin is not banned";
		Ban b;
		b.by = by;
		ss_ data;
		if(m_store->get("ban/"+name, data))
			unpack(data, b);
		// **An address only where anyone can make an account** (user,
		// 2026-09-30): there a banned player comes back under a new name.
		// On an invite-only server the account is enough, and an address
		// ban would keep out others behind the same one.
		// Each connection's address, where the name is here more than once
		const sv_<PeerId> peers = find_peers(name);
		if(!peers.empty() && m_access.open_registration)
			b.address = address_of(peers[0]);
		m_store->set("ban/"+name, pack(b));
		// Its end and reason apart from Ban, whose stored form stays as it
		// was ([HEARTH_MOD_TOOLS])
		if(until > 0 || !reason.empty())
			m_store->set("banterm/"+name, pack(std::make_pair(until, reason)));
		else
			m_store->remove("banterm/"+name);
		if(m_access.open_registration)
			for(PeerId p : peers)
				m_store->set("banaddr/"+network::address_key(address_of(p)),
						name);
		log_i(MODULE, "%s banned %s (%s)", cs(by), cs(name), cs(b.address));
		for(PeerId p : peers)
			kick(p, "banned by "+by+(reason.empty() ? ss_() : ": "+reason));
		send_users_to_staff();
		return "";
	}

	// A ban's end and reason as a refused join says them; false when it
	// has ended, then lifted
	bool ban_term(const ss_ &name, ss_ &why)
	{
		ss_ data;
		std::pair<int64_t, ss_> term(0, "");
		if(m_store->get("banterm/"+name, data))
			unpack(data, term);
		if(term.first > 0 && interface::os::wall_us() / 1000000 >= term.first){
			unban(name, "");
			return false;
		}
		if(term.first > 0){
			char buf[40];
			const struct tm tm_ = interface::os::utc_tm(term.first);
			strftime(buf, sizeof buf, " until %Y-%m-%d %H:%M UTC", &tm_);
			why += buf;
		}
		if(!term.second.empty())
			why += ": "+term.second;
		return true;
	}

	ss_ unban(const ss_ &name_or_address, const ss_ &only_by)
	{
		if(!m_store)
			return "No accounts yet";
		ss_ data;
		bool found = false;
		if(!only_by.empty()){
			// Whose ban it is, by the name it is under
			ss_ name = name_or_address;
			ss_ bd;
			if(!m_store->get("ban/"+name, bd) &&
					m_store->get("banaddr/"+name_or_address, data))
				name = data;
			Ban b;
			if(m_store->get("ban/"+name, bd) && unpack(bd, b) &&
					b.by != only_by)
				return "Banned by "+b.by+"; an admin lifts it";
		}
		if(m_store->get("ban/"+name_or_address, data)){
			Ban b;
			if(unpack(data, b) && !b.address.empty()){
				m_store->remove("banaddr/"+b.address);
				m_store->remove("banaddr/"+network::address_key(b.address));
			}
			m_store->remove("ban/"+name_or_address);
			m_store->remove("banterm/"+name_or_address);
			// Off the Starports at the next announce, too (10d)
			m_store->remove("ban_report/"+name_or_address);
			found = true;
		}
		// An address as it was saved, or by its key ([DUAL_STACK])
		ss_ banned_name;
		for(const ss_ &k : {"banaddr/"+name_or_address,
				"banaddr/"+network::address_key(name_or_address)}){
			ss_ n;
			if(m_store->get(k, n)){
				m_store->remove(k);
				banned_name = n;
			}
		}
		if(!banned_name.empty()){
			m_store->remove("ban/"+banned_name);
			m_store->remove("banterm/"+banned_name);
			m_store->remove("ban_report/"+banned_name);
			found = true;
		}
		if(!found)
			return "No ban of "+name_or_address;
		log_i(MODULE, "%s was unbanned", cs(name_or_address));
		send_users_to_staff();
		return "";
	}

	sv_<std::pair<ss_, ss_>> bans()
	{
		sv_<std::pair<ss_, ss_>> out;
		if(!m_store)
			return out;
		for(const ss_ &key : m_store->list("ban/")){
			ss_ data;
			Ban b;
			if(m_store->get(key, data) && unpack(data, b))
				out.push_back(std::make_pair(key.substr(4), b.address));
		}
		return out;
	}

	sv_<ss_> ban_list()
	{
		sv_<ss_> out;
		for(auto &b : bans())
			out.push_back(b.second.empty() ? b.first : b.first+"|"+b.second);
		return out;
	}

	// Why a name or an address may not join, or ""
	ss_ banned(const ss_ &name, const ss_ &address)
	{
		ss_ data, why = "You are banned from this server";
		if(m_store->get("ban/"+name, data) && ban_term(name, why))
			return why;
		// The exact address too: a ban saved before [DUAL_STACK]'s key
		why = "This address is banned from this server";
		if(m_access.open_registration && !address.empty() &&
				(m_store->get("banaddr/"+network::address_key(address), data) ||
				m_store->get("banaddr/"+address, data)) && ban_term(data, why))
			return why;
		return "";
	}

	// Accounts

	bool get_account(const ss_ &name, Account &account)
	{
		ss_ data;
		return m_store && m_store->get("auth/"+name, data) &&
				unpack(data, account);
	}

	void set_account(const ss_ &name, const Account &account)
	{
		// [FP_ABUSE] 5: when it was made, for the newest first
		ss_ x;
		if(!m_store->get("auth/"+name, x)){
			m_store->set("made/"+name, itos(interface::os::wall_us() / 1000000));
			stats_hour().made++;
		}
		m_store->set("auth/"+name, pack(account));
	}

	// [FP_ABUSE] The apps' storage by app, then by account
	std::map<ss_, std::map<ss_, uint64_t>> m_storage;

	void report_storage(const ss_ &app, const std::map<ss_, uint64_t> &bytes)
	{
		m_storage[app] = bytes;
	}

	uint64_t storage_budget()
	{
		ss_ v;
		const int64_t mb = m_store && m_store->get("storage_budget_mb", v) ?
				atoll(v.c_str()) : DEFAULT_BUDGET_MB;
		return (uint64_t)mb * 1024 * 1024;
	}

	// "1.2 MB (floorplanner 1.2 MB)", or "" when no app keeps anything
	ss_ storage_text(const ss_ &name)
	{
		uint64_t sum = 0;
		ss_ apps;
		for(auto &app : m_storage){
			auto it = name.empty() ? app.second.end() : app.second.find(name);
			uint64_t n = 0;
			if(name.empty())
				for(auto &b : app.second)
					n += b.second;
			else if(it != app.second.end())
				n = it->second;
			if(!n)
				continue;
			sum += n;
			apps += (apps.empty() ? "" : ", ")+app.first+" "+size_text(n);
		}
		return sum ? size_text(sum)+" ("+apps+")" : "";
	}

	// The account gone: what is kept of it here, and the apps told
	void account_deleted(const ss_ &name)
	{
		m_store->remove("made/"+name);
		m_store->remove("seen/"+name);
		for(auto &app : m_storage)
			app.second.erase(name);
		m_server->emit_event("accounts:deleted", new Login(0, name));
	}

	Account new_account(const ss_ &password, const sv_<ss_> &privs)
	{
		Account account;
		std::random_device rd;
		account.salt.resize(16);
		for(char &c : account.salt)
			c = (char)(rd() & 0xff);
		account.hash = pbkdf2_sha256(password, account.salt, PBKDF2_ITERATIONS);
		account.privs = privs;
		return account;
	}

	void save_access()
	{
		m_store->set("access/settings", pack(m_access));
	}

	void load_access()
	{
		ss_ data;
		if(!(m_store->get("access/settings", data) &&
				unpack(data, m_access))){
			// Registration open where the launcher started the server
			m_access = AccessSettings();
			m_access.open_registration = m_launched;
			save_access();
		}
		apply_first_admin();
		update_setup_code();
	}

	// [FIRST_ADMIN]: <user>/first_admin's line, for a server a script
	// makes. "name <name> <password>": that account, made or its password
	// set, is the admin; "code <code>": the setup code is the script's own
	// and not the log's, which a Starport ID's join takes too.
	// simplified: no Starport ID named outright -- its sub is per fleet
	// and the operator has it only after a join; the code covers it
	void apply_first_admin()
	{
		const ss_ line = m_server->get_config().get<ss_>("first_admin");
		if(line.empty())
			return;
		if(admin_count() > 0){
			log_w(MODULE, "first_admin ignored: the server has an admin");
			return;
		}
		std::istringstream is(line);
		ss_ kind, arg, rest;
		is >> kind >> arg;
		std::getline(is >> std::ws, rest);
		if(kind == "name" && valid_name(arg) && rest.size() >= MIN_PASSWORD &&
				rest.size() <= 100){
			set_account(arg, new_account(rest, {"admin"}));
			log_i(MODULE, "first_admin: %s is the admin", cs(arg));
		} else if(kind == "code" && arg.size() >= 8 && arg.size() <= 100 &&
				rest.empty()){
			m_setup_code = upper(arg);
			log_w(MODULE, "The server has no admin. The first to join with "
					"the setup code from first_admin becomes it.");
		} else {
			log_e(MODULE, "first_admin: expected \"name <name> <password of "
					"%i to 100 characters>\" or \"code <8 to 100 characters>\"",
					(int)MIN_PASSWORD);
		}
	}

	int admin_count()
	{
		int n = 0;
		for(const ss_ &key : m_store->list("auth/")){
			Account account;
			if(get_account(key.substr(5), account) && account.has("admin"))
				n++;
		}
		return n;
	}

	// A server with no admin is claimed with a code from its log: on a
	// public server the first to connect would otherwise be its admin
	void update_setup_code()
	{
		if(admin_count() > 0){
			m_setup_code.clear();
			return;
		}
		if(!m_setup_code.empty())
			return;
		m_setup_code = random_code(8);
		log_w(MODULE, "The server has no admin. The first to join with the "
				"setup code %s becomes it.", cs(m_setup_code));
	}

	// How long, in microseconds, before a login of this name or from this
	// address may be tried again
	int64_t failure_wait(std::map<ss_, Failures> &m, const ss_ &key, int64_t now)
	{
		auto it = m.find(key);
		if(it == m.end())
			return 0;
		if(now - it->second.first_us > FAIL_WINDOW_US &&
				now >= it->second.wait_until_us){
			m.erase(it);
			return 0;
		}
		return std::max((int64_t)0, it->second.wait_until_us - now);
	}

	void note_failure(std::map<ss_, Failures> &m, const ss_ &key, int64_t now)
	{
		if(m.size() >= FAIL_KEYS_MAX && !m.count(key)){
			for(auto it = m.begin(); it != m.end();){
				if(now - it->second.first_us > FAIL_WINDOW_US &&
						now >= it->second.wait_until_us)
					it = m.erase(it);
				else
					++it;
			}
			if(m.size() >= FAIL_KEYS_MAX)
				m.erase(std::min_element(m.begin(), m.end(),
						[](const std::pair<const ss_, Failures> &a,
						const std::pair<const ss_, Failures> &b){
					return a.second.wait_until_us < b.second.wait_until_us;
				}));
		}
		Failures &f = m[key];
		if(f.count == 0 || now - f.first_us > FAIL_WINDOW_US){
			f.count = 0;
			f.first_us = now;
		}
		f.count++;
		const int64_t wait = f.count >= FAIL_LOCK ? FAIL_WINDOW_US :
				std::min((int64_t)60, (int64_t)1 << (f.count - 1)) * 1000000;
		f.wait_until_us = now + wait;
	}

	// The join

	void send_hello(PeerId peer)
	{
		Hello h;
		h.local = is_local(peer);
		h.setup = !h.local && !m_setup_code.empty();
		h.open_registration = m_access.open_registration;
		h.version = ss_(BUILDAT_VERSION) + "-" + BUILDAT_GIT_HASH;
		starport_announce::access(m_server,
				[&](starport_announce::Interface *s){
			h.starport = s->accepts_ids() ? 1 : 0;
			h.announce = 1;
		});
		send(peer, "accounts:hello", pack(h));
	}

	void on_get_hello(const network::Packet &packet)
	{
		if(!m_peers.count(packet.sender))
			return;
		send_hello(packet.sender);
		// A window opened again after a reconnect says it is open
		if(m_lan_open && is_local(packet.sender))
			send(packet.sender, "accounts:lan", "1");
	}

	// "Open to LAN" ([SECURITY_RUN_1], the user's call; [ACCOUNTS_LAN]): a
	// launched server listens on 127.0.0.1 until its owner opens it from
	// the Server window; then on the machine's LAN address too, the same
	// port, and it is announced there ([LAN_DISCOVERY]). The answer,
	// accounts:lan, is "1" or why not. A server the launcher did not start
	// listens where its config says and has no owner to ask.
	// simplified: the address the default route leaves by, one of them;
	// a machine on two LANs is opened on that one. Every interface would
	// be getifaddrs(), which the box's seccomp may not allow.
	void on_open_lan(const network::Packet &packet)
	{
		if(!is_local(packet.sender)){
			log_w(MODULE, "Open to LAN refused to peer %i: not the owner",
					(int)packet.sender);
			return;
		}
		if(m_lan_open)
			return send(packet.sender, "accounts:lan", "1");
		ss_ error;
		const ss_ lan = interface::local_lan_address();
		if(lan.empty())
			error = "this machine is on no network";
		else
			network::access(m_server, [&](network::Interface *inetwork){
				m_lan_open = inetwork->listen_on(lan, &error);
				if(m_lan_open)
					inetwork->lan_announce(lan_name(), m_lan_account);
			});
		log_i(MODULE, "Open to LAN: %s", m_lan_open ?
				("listening at "+lan+" too").c_str() : cs(error));
		send(packet.sender, "accounts:lan", m_lan_open ? ss_("1") : error);
	}

	ss_ lan_name()
	{
		return m_lan_name.empty() ? m_server->get_app_id() : m_lan_name;
	}

	void set_lan_name(const ss_ &name, bool account)
	{
		m_lan_name = name;
		m_lan_account = account;
		if(m_lan_open)
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->lan_announce(lan_name(), m_lan_account);
			});
	}

	// simplified: the password arrives in the clear on a native client's
	// connection, because the transport is not encrypted yet ([TRANSPORT]);
	// the join dialog says so. The web client behind an https proxy has TLS.
	void on_login(const network::Packet &packet)
	{
		auto pit = m_peers.find(packet.sender);
		if(pit == m_peers.end() || !m_store)
			return;
		Peer &peer = pit->second;
		LoginRequest cred;
		// The error, or "", and the token of a login asked to be kept
		ss_ token;
		auto reply = [&](const ss_ &error){
			// The name joined as: a Starport ID's is the token's
			send(packet.sender, "accounts:login_result",
					pack(std::make_pair(std::make_pair(error, token),
					error.empty() ? cred.name : ss_())));
		};
		// The local user is on the machine the saves are on: a password
		// would keep out nobody the files themselves do not let in
		bool local = is_local(packet.sender);
		if(!peer.name.empty())
			return reply("Already joined");
		if(peer.failures >= MAX_LOGIN_FAILURES)
			return reply("Too many failed attempts; reconnect");
		if(!unpack(packet.data, cred))
			return reply("Malformed login");
		// [STARPORT] 10c: a Starport ID's token in place of a password; the
		// name is the one the player picked on the Starport for this
		// community, and the account is the one linked to the ID
		// [ID_CLAIM_ACCOUNT]: a name with the ID's token is the account's
		// own login (its password, or its TOTP wait's token) that links the
		// ID to it as it completes
		starport_announce::IdLogin id, claim_id;
		if(!cred.starport.empty()){
			ss_ why = "This server does not take Starport IDs";
			starport_announce::access(m_server,
					[&](starport_announce::Interface *s){
				why = s->verify_id_token(cred.starport, &id);
			});
			if(!why.empty()){
				log_i(MODULE, "Starport ID login from %s refused: %s",
						cs(peer.address), cs(why));
				return reply(why);
			}
			// 10g: an ID linked to an account logs in as that account,
			// whatever name it picked for the community
			ss_ linked;
			const bool has = m_store->get("starport/"+id.starport+"/"+id.sub,
					linked);
			if(!cred.name.empty()){
				if(has && linked != cred.name)
					return reply("That Starport ID is another account's here");
				claim_id = id;
				id = starport_announce::IdLogin();
			} else {
				cred.name = has ? linked : id.name;
				cred.password.clear();
				cred.token.clear();
			}
		}
		const ss_ &name = cred.name;
		const ss_ &password = cred.password;
		const ss_ code = upper(cred.code);
		if(!valid_name(name))
			return reply("A name is 1 to 20 letters, digits, _ or -");
		if(password.size() > 100 || code.size() > 100 || cred.token.size() > 100)
			return reply("The password is too long");
		if(find_peer(name) && !m_multiple_logins)
			return reply(name+" is already here");
		if(!local){
			const ss_ why = banned(name, peer.address);
			if(!why.empty()){
				log_i(MODULE, "Login of %s from %s refused: banned", cs(name),
						cs(peer.address));
				return reply(why);
			}
		}

		// An address's block that failed waits before it tries again. Not
		// the name: who a client says it is means nothing before it has
		// logged in, and a name's wait was anyone's to keep its owner out
		const int64_t now = interface::os::wall_us();
		// [LOGIN_UNLOADED]: a TOTP wait's record, and whether this login
		// was one
		ss_ wait_data;
		bool waited = false;
		// By the account's password (and code), not a kept login
		bool by_password = false;
		const ss_ bin = network::address_bin(peer.address);
		const int64_t wait = failure_wait(m_address_failures, bin, now);
		if(wait > 0 && !local){
			log_i(MODULE, "Login of %s from %s refused: waiting after failures",
					cs(name), cs(peer.address));
			return reply("Too many failed logins; try again in "+
					itos((int)((wait + 999999) / 1000000))+" s");
		}
		auto fail = [&](const ss_ &why){
			peer.failures++;
			note_failure(m_address_failures, bin, now);
			log_i(MODULE, "Login of %s from %s failed: %s", cs(name),
					cs(peer.address), cs(why));
			reply(why);
		};
		// A Starport ID's refusal that is no failure, logged as one is
		auto refused = [&](const ss_ &why){
			log_i(MODULE, "Starport ID login of %s from %s refused: %s",
					cs(name), cs(peer.address), cs(why));
			reply(why);
		};

		Account account;
		if(!id.sub.empty()){
			const ss_ link = "starport/"+id.starport+"/"+id.sub;
			ss_ linked;
			ss_ mode = "off";
			starport_announce::access(m_server,
					[&](starport_announce::Interface *s){
				mode = s->ids_mode();
			});
			if(m_store->get(link, linked)){
				if(!get_account(name, account))
					return refused("This Starport ID's account here is gone; "
							"ask an admin");
			} else {
				if(exists(name))
					return refused("The name "+name+" is taken on this server "
							"by an account of its own: pick another for "
							"this community on the Starport, or, if the "
							"account is yours, choose \"That's my account\" "
							"and log in with its password: your ID is linked "
							"to it");
				// No admin yet: as with a local account, only the setup
				// code makes a new one, and makes it the admin (10g)
				if(!m_setup_code.empty() && code != m_setup_code)
					return fail(code.empty() ? "This server has no admin "
							"yet: the first account needs the setup code from "
							"the server's log" : "Wrong setup code");
				// A password nobody knows: this account logs in by its ID
				account = new_account(random_code(32), {});
				set_account(name, account);
				m_store->set(link, name);
				m_store->set("starport_of/"+name+"/"+id.starport, link);
				// 10g: approved only, the new ID waits for an admin
				if(mode == "approved" && m_setup_code.empty())
					m_store->set("approval/"+name, "");
				log_i(MODULE, "New account %s for a Starport ID of %s%s",
						cs(name), cs(id.starport), mode == "approved" ?
						" (waiting for approval)" : "");
				send_users_to_staff();
			}
			ss_ pending;
			if(m_store->get("approval/"+name, pending))
				return refused("Your Starport ID waits for an admin of this "
						"server to let it in");
			// The first admin by ID, as by a local login (10g)
			if(!m_setup_code.empty() && !code.empty()){
				if(code != m_setup_code)
					return fail("Wrong setup code");
				account.privs = {"admin"};
				set_account(name, account);
				log_i(MODULE, "%s claimed the server with the setup code",
						cs(name));
			}
		} else if(!cred.token.empty() && m_store->get("totp_wait/"+
				interface::sha256::hex(interface::sha256::calculate(
				cred.token)), wait_data)){
			const ss_ key = "totp_wait/"+interface::sha256::hex(
					interface::sha256::calculate(cred.token));
			TotpWait tw;
			if(!unpack(wait_data, tw) || tw.name != name ||
					tw.expires_us < now || !get_account(name, account) ||
					tw.hash != account.hash){
				// Not counted: an old token is no guess
				m_store->remove(key);
				return reply("The wait for the code has ended: log in again");
			}
			// A client come back to its code page asks whether it waits
			if(cred.totp.empty())
				return reply("TOTP: enter the code from your "
						"authenticator app");
			if(!check_totp(name, cred.totp)){
				if(++tw.tries >= 3){
					m_store->remove(key);
					return fail("Three wrong codes: log in again");
				}
				m_store->set(key, pack(tw));
				return fail("TOTP: wrong code");
			}
			m_store->remove(key);
			waited = true;
			by_password = true;
		} else if(!cred.token.empty()){
			KeptLogin kept;
			ss_ data;
			const ss_ key = "token/"+interface::sha256::hex(
					interface::sha256::calculate(cred.token));
			if(!(m_store->get(key, data) && unpack(data, kept)) ||
					kept.name != name || kept.expires_us < now ||
					!get_account(name, account) || kept.hash != account.hash){
				m_store->remove(key);
				return fail("The saved login has ended: log in again");
			}
			// [TRUST_LADDER]: KEEP_US from each use
			kept.expires_us = now + KEEP_US;
			m_store->set(key, pack(kept));
		} else if(get_account(name, account)){
			if(!local && pbkdf2_sha256(password, account.salt,
					PBKDF2_ITERATIONS) != account.hash)
				return fail("Wrong password");
			if(!local && totp_on(name)){
				// Said so, not counted: the client asks for the code
				// With a token that stands for the password while the
				// code is fetched
				if(cred.totp.empty()){
					token = random_code(32);
					TotpWait tw;
					tw.name = name;
					tw.expires_us = now + 1000000LL * atoi(m_server->
							get_config().get<ss_>("totp_wait_s").c_str());
					tw.hash = account.hash;
					m_store->set("totp_wait/"+interface::sha256::hex(
							interface::sha256::calculate(token)), pack(tw));
					return reply("TOTP: enter the code from your "
							"authenticator app");
				}
				if(!check_totp(name, cred.totp))
					return fail("TOTP: wrong code");
			}
			by_password = true;
			// An account of a server that has no admin can claim it too
			if(!local && !m_setup_code.empty() && !code.empty()){
				if(code != m_setup_code)
					return fail("Wrong setup code");
				account.privs = {"admin"};
				set_account(name, account);
				log_i(MODULE, "%s claimed the server with the setup code",
						cs(name));
			}
		} else {
			// [ACCOUNT_CREATE]: a plain login does not make an account; a
			// mistyped name is refused as unknown. Local still auto-creates.
			if(!local && !cred.create)
				return reply("There is no account named \""+name+"\". Use "
						"\"Create a new account\" to make one.");
			if(reserved_name(name))
				return reply("\""+name+"\" is kept for a client that has "
						"not logged in; choose another name");
			sv_<ss_> privs;
			if(local){
				// The first admin of the launcher's server is its own user
				if(admin_count() == 0)
					privs = {"admin"};
			} else {
				if(password.size() < MIN_PASSWORD)
					return reply("A new account's password is at least "+
							itos((int)MIN_PASSWORD)+" characters");
				Invite invite;
				ss_ data;
				if(!m_setup_code.empty()){
					if(code != m_setup_code)
						return fail(code.empty() ?
								"This server has no admin yet: the first "
								"account needs the setup code from the "
								"server's log" : "Wrong setup code");
					privs = {"admin"};
					log_i(MODULE, "%s claimed the server with the setup code",
							cs(name));
				} else if(!code.empty()){
					if(!(m_store->get("invite/"+code, data) &&
							unpack(data, invite)))
						return fail("No such invite code");
					m_store->remove("invite/"+code);
					log_i(MODULE, "%s used an invite of %s", cs(name),
							cs(invite.by));
				} else if(!m_access.open_registration){
					return reply("New accounts need an invite code from an "
							"admin");
				} else {
					const ss_ why = untrusted_quota(network::address_bin(
							peer.address));
					if(!why.empty())
						return reply(why);
					m_store->set("untrusted/"+name, network::address_bin(
							peer.address)+" "+itos(interface::os::wall_us()));
				}
			}
			// A local account gets a password nobody knows, so its name
			// cannot be taken over from elsewhere with an empty one
			ss_ pw = password;
			if(local)
				pw = random_code(32);
			account = new_account(pw, privs);
			set_account(name, account);
			log_i(MODULE, "New account %s", cs(name));
		}
		// 10g: a blocklist's ban of the ID is a ban of its account here,
		// password and kept login too -- not of an admin's or a
		// moderator's, which a blocklist must not lock out
		if(id.sub.empty() && !local && !account.has("admin") &&
				level(name) < LV_MODERATOR && id_blocked(name)){
			log_i(MODULE, "Login of %s refused: its Starport ID is on a "
					"blocklist", cs(name));
			return reply("Banned by a blocklist this server follows");
		}
		// [SERVER_CAPS]: the operator's --max-players; an admin, a
		// moderator and the local user join over it, to do something
		// about it
		const int max_players = atoi(m_server->get_config().get<ss_>(
				"max_players").c_str());
		if(max_players > 0 && !local && !account.has("admin") &&
				level(name) < LV_MODERATOR){
			int joined = 0;
			for(auto &it : m_peers)
				joined += !it.second.name.empty();
			if(joined >= max_players){
				log_i(MODULE, "Login of %s refused: the server is full",
						cs(name));
				return reply("The server is full ("+itos(max_players)+
						" players)");
			}
		}
		ss_ link_note;
		if(!claim_id.sub.empty()){
			if(!by_password)
				return reply("Linking a Starport ID needs the account's "
						"password");
			link_note = link_id(name, claim_id);
		}
		update_setup_code();
		if(cred.keep && !local && (cred.token.empty() || waited)){
			token = random_code(32);
			KeptLogin kept;
			kept.name = name;
			kept.expires_us = now + KEEP_US;
			kept.hash = account.hash;
			m_store->set("token/"+interface::sha256::hex(
					interface::sha256::calculate(token)), pack(kept));
			log_i(MODULE, "%s is kept logged in", cs(name));
		}
		log_i(MODULE, "%s joined from %s", cs(name), cs(peer.address));
		peer.name = name;
		stats_joined(peer);
		reply("");
		send_links(packet.sender, name);
		if(!claim_id.sub.empty())
			send(packet.sender, "accounts:link_result", pack(link_note));
		m_server->emit_event("accounts:login", new Login(packet.sender, name));
		send_users_to_staff();
	}

	// The admin's

	void send_users(PeerId peer)
	{
		UsersInfo info;
		// [FP_ABUSE] 5: the newest accounts first (one made before
		// 0.6.75 has no time, and is last)
		std::map<ss_, int64_t> made;
		for(const ss_ &key : m_store->list("made/")){
			ss_ v;
			if(m_store->get(key, v))
				made[key.substr(5)] = atoll(v.c_str());
		}
		for(const ss_ &key : m_store->list("auth/")){
			UserRow row;
			row.name = key.substr(5);
			Account account;
			if(get_account(row.name, account))
				row.privs = account.privs;
			row.here = find_peer(row.name) != 0;
			ss_ x;
			row.id_only = !links_of(row.name).empty() &&
					!m_store->get("own_password/"+row.name, x);
			row.level = level(row.name);
			row.storage = storage_text(row.name);
			info.users.push_back(row);
		}
		std::stable_sort(info.users.begin(), info.users.end(),
				[&](const UserRow &a, const UserRow &b){
			return made[a.name] > made[b.name];
		});
		info.budget_mb = (int32_t)(storage_budget() / (1024 * 1024));
		info.storage = storage_text("");
		for(const ss_ &key : m_store->list("invite/")){
			Invite invite;
			ss_ data;
			if(m_store->get(key, data) && unpack(data, invite))
				info.invites.push_back(std::make_pair(key.substr(7), invite));
		}
		info.access = m_access;
		info.bans = bans();
		info.starport_ids = "off";
		starport_announce::access(m_server,
				[&](starport_announce::Interface *s){
			info.starport_ids = s->ids_mode();
		});
		for(const ss_ &key : m_store->list("approval/"))
			info.approvals.push_back(key.substr(9));
		info.level = level(name_of(peer));
		send(peer, "accounts:users", pack(info));
	}

	void send_users_to_staff()
	{
		if(!m_store)
			return;
		for(auto &pair : m_peers)
			if(level(pair.second.name) >= LV_MODERATOR)
				send_users(pair.first);
	}

	void privs_changed(const ss_ &name)
	{
		for(PeerId peer : find_peers(name))
			m_server->emit_event("accounts:privs", new Login(peer, name));
	}

	void on_admin(const network::Packet &packet)
	{
		AdminRequest r;
		auto pit = m_peers.find(packet.sender);
		if(!m_store || pit == m_peers.end() ||
				level(pit->second.name) < LV_MODERATOR || !unpack(packet.data, r))
			return;
		const ss_ by = pit->second.name;
		// [TRUST_LADDER] A moderator's: the Accounts page but for what
		// changes an account's login or the server
		const int by_lv = level(by);
		if(by_lv < LV_ADMIN && r.cmd != "list" && r.cmd != "kick" &&
				r.cmd != "ban" && r.cmd != "unban" && r.cmd != "invite" &&
				r.cmd != "uninvite" && r.cmd != "approve" &&
				r.cmd != "turn_away" && r.cmd != "level" && r.cmd != "stats")
			return send(packet.sender, "accounts:admin_result",
					pack(ss_("Only the "+level_name(LV_ADMIN)+" does that")));
		if((r.cmd == "kick" || r.cmd == "ban") && by_lv < LV_ADMIN &&
				level(r.name) >= by_lv)
			return send(packet.sender, "accounts:admin_result",
					pack(ss_("Only the "+level_name(LV_ADMIN)+" does that to a "+
					level_name(level(r.name)))));
		auto result = [&](const ss_ &text){
			send(packet.sender, "accounts:admin_result", pack(text));
		};
		Account account;
		const bool exists = !r.name.empty() && get_account(r.name, account);
		const PeerId target = exists ? find_peer(r.name) : 0;
		// Every connection of the name ([FP_TWO_CLIENTS])
		const sv_<PeerId> targets = exists ? find_peers(r.name) : sv_<PeerId>();
		if(r.cmd == "list"){
			return send_users(packet.sender);
		} else if(r.cmd == "priv"){
			if(!exists || r.arg != "admin")
				return result("No such account or privilege");
			if(!r.on && account.has("admin") && admin_count() <= 1)
				return result("The last admin keeps admin");
			{
				sv_<ss_> privs;
				for(const ss_ &p : account.privs)
					if(p != "admin")
						privs.push_back(p);
				if(r.on)
					privs.push_back("admin");
				account.privs = privs;
			}
			set_account(r.name, account);
			privs_changed(r.name);
			log_i(MODULE, "%s %s admin %s", cs(by), r.on ? "granted" : "revoked",
					cs(r.name));
			result(r.name+(r.on ? " is an admin" : " is no longer an admin"));
		} else if(r.cmd == "level"){
			// [TRUST_LADDER] arg: the number
			const ss_ why = set_level(r.name, atoi(r.arg.c_str()), by);
			if(!why.empty())
				return result(why);
			result(r.name+" is a "+level_name(level(r.name)));
		} else if(r.cmd == "kick"){
			if(!target)
				return result(r.name+" is not here");
			for(PeerId t : targets)
				kick(t, "kicked by "+by);
			result(r.name+" was kicked");
		} else if(r.cmd == "ban"){
			ss_ why = ban(r.name, by);
			// [STARPORT] 10d: the reason, and whether it goes to the
			// Starports (an account of a Starport ID only)
			if(why.empty() && r.on){
				const ss_ rep = report_ban(r.name, r.arg.substr(0, 40));
				why = rep.empty() ? "" : r.name+" was banned; "+rep;
			}
			result(why.empty() ? r.name+" was banned" : why);
		} else if(r.cmd == "unban"){
			if(by_lv < LV_ADMIN){
				ss_ data;
				Ban b;
				if(m_store->get("ban/"+r.name, data) && unpack(data, b) &&
						level(b.by) >= by_lv)
					return result("Banned by "+b.by+"; only the "+
							level_name(LV_ADMIN)+" lifts it");
			}
			const ss_ why = unban(r.name, "");
			result(why.empty() ? r.name+" was unbanned" : why);
		} else if(r.cmd == "password"){
			if(!exists)
				return result("No account "+r.name);
			if(r.arg.size() < MIN_PASSWORD || r.arg.size() > 100)
				return result("A password is "+itos((int)MIN_PASSWORD)+
						" to 100 characters");
			set_account(r.name, new_account(r.arg, account.privs));
			// A password someone knows: the account no longer logs in by
			// its Starport ID only (10g)
			m_store->set("own_password/"+r.name, "");
			for(PeerId t : targets)
				if(t != packet.sender)
					kick(t, "the password was reset by "+by);
			log_i(MODULE, "%s reset the password of %s", cs(by), cs(r.name));
			result("The password of "+r.name+" was reset");
		} else if(r.cmd == "delete"){
			if(!exists)
				return result("No account "+r.name);
			if(r.name == by)
				return result("An admin does not delete their own account");
			if(account.has("admin") && admin_count() <= 1)
				return result("The last admin is not deleted");
			for(PeerId t : targets)
				kick(t, "the account was deleted by "+by);
			m_store->remove("auth/"+r.name);
			// Its Starport IDs' links, and what waited for approval (10g)
			unlink_all(r.name);
			m_store->remove("approval/"+r.name);
			m_store->remove("ban_report/"+r.name);
			m_store->remove("own_password/"+r.name);
			m_store->remove("level/"+r.name);
			m_store->remove("totp/"+r.name);
			m_store->remove("totp_pending/"+r.name);
			log_i(MODULE, "%s deleted the account %s", cs(by), cs(r.name));
			account_deleted(r.name);
			result("The account "+r.name+" was deleted");
		} else if(r.cmd == "add"){
			if(!valid_name(r.name) || reserved_name(r.name))
				return result("A name is 1 to 20 letters, digits, _ or -, "
						"and not client<digits>");
			if(exists)
				return result("There is an account "+r.name+" already");
			if(r.arg.size() < MIN_PASSWORD || r.arg.size() > 100)
				return result("A password is "+itos((int)MIN_PASSWORD)+
						" to 100 characters");
			set_account(r.name, new_account(r.arg, {}));
			log_i(MODULE, "%s added the account %s", cs(by), cs(r.name));
			result("The account "+r.name+" was added");
		} else if(r.cmd == "invite"){
			Invite invite;
			invite.by = by;
			const ss_ code = random_code(10);
			m_store->set("invite/"+code, pack(invite));
			log_i(MODULE, "%s made an invite", cs(by));
			result("Invite code: "+code);
		} else if(r.cmd == "uninvite"){
			m_store->remove("invite/"+upper(r.name));
			result("The invite was deleted");
		} else if(r.cmd == "setting" && r.name == "starport_ids"){
			ss_ why = "This server has no Starport module";
			starport_announce::access(m_server,
					[&](starport_announce::Interface *s){
				// "anyone", or "anyone https://host": the address the
				// admin reached the server by, from the page
				const size_t sp = r.arg.find(' ');
				why = s->set_ids_mode(r.arg.substr(0, sp), sp == ss_::npos ?
						"" : r.arg.substr(sp + 1));
			});
			// Everyone: a joined client's My account links an ID by it
			for(auto &pair : m_peers)
				send_hello(pair.first);
			result(why);
		} else if(r.cmd == "approve" || r.cmd == "turn_away"){
			ss_ pending;
			if(!m_store->get("approval/"+r.name, pending))
				return result("No ID of "+r.name+" waits");
			m_store->remove("approval/"+r.name);
			if(r.cmd == "turn_away"){
				unlink_all(r.name);
				m_store->remove("auth/"+r.name);
			}
			log_i(MODULE, "%s: %s's Starport ID %s", cs(by), cs(r.name),
					r.cmd == "approve" ? "let in" : "turned away");
			result(r.cmd == "approve" ? r.name+" may join" :
					r.name+" was turned away");
		} else if(r.cmd == "stats"){
			return send(packet.sender, "accounts:stats", stats_json().stringify());
		} else if(r.cmd == "health"){
			// [SERVER_ADMIN_PAGE]: on=1 runs the box check too
			return send(packet.sender, "accounts:health",
					health_json(r.on).stringify());
		} else if(r.cmd == "smtp"){
			return result(set_smtp(r.arg, by));
		} else if(r.cmd == "test_mail"){
			return result(test_mail(packet.sender, r.arg, by));
		} else if(r.cmd == "announce_now"){
			ss_ why = "This server has no Starport module";
			starport_announce::access(m_server,
					[&](starport_announce::Interface *s){
				s->announce_soon();
				why = "Announcing to the Starports now";
			});
			return result(why);
		} else if(r.cmd == "setting" && r.name == "storage_budget"){
			// [FP_ABUSE] 3: MB, 0 and up
			const ss_ &a = r.arg;
			if(a.empty() || a.size() > 9 ||
					a.find_first_not_of("0123456789") != ss_::npos)
				return result("The budget is a number of MB");
			m_store->set("storage_budget_mb", a);
			log_i(MODULE, "%s set the storage budget to %s MB", cs(by), cs(a));
			send_users(packet.sender);
			return result("The storage budget is "+a+" MB");
		} else if(r.cmd == "setting"){
			if(r.name != "open_registration")
				return result("No such setting");
			m_access.open_registration = r.on;
			save_access();
			// A listing's access is derived from it (10g)
			starport_announce::access(m_server,
					[&](starport_announce::Interface *s){
				s->announce_soon();
			});
			log_i(MODULE, "%s set %s to %i", cs(by), cs(r.name), (int)r.on);
			for(auto &pair : m_peers)
				if(pair.second.name.empty())
					send_hello(pair.first);
			result("");
		} else {
			return;
		}
		send_users_to_staff();
	}

	// A user's own password: the old one and the new one
	void on_passwd(const network::Packet &packet)
	{
		std::pair<ss_, ss_> pw;
		auto it = m_peers.find(packet.sender);
		if(!m_store || it == m_peers.end() || it->second.name.empty() ||
				!unpack(packet.data, pw))
			return;
		const ss_ name = it->second.name;
		auto result = [&](const ss_ &text){
			send(packet.sender, "accounts:passwd_result", pack(text));
		};
		Account account;
		if(!get_account(name, account))
			return;
		const int64_t now = interface::os::wall_us();
		if(failure_wait(m_name_failures, name, now) > 0)
			return result("Too many failed attempts; wait and try again");
		if(pbkdf2_sha256(pw.first, account.salt, PBKDF2_ITERATIONS) !=
				account.hash){
			note_failure(m_name_failures, name, now);
			log_i(MODULE, "%s: a password change with a wrong password",
					cs(name));
			return result("The old password is wrong");
		}
		if(pw.second.size() < MIN_PASSWORD || pw.second.size() > 100)
			return result("A password is "+itos((int)MIN_PASSWORD)+
					" to 100 characters");
		set_account(name, new_account(pw.second, account.privs));
		m_store->set("own_password/"+name, "");
		log_i(MODULE, "%s changed their password", cs(name));
		result("");
	}

	// A kept login ended by its user ([ACC_KEEP]): the token, which must be
	// this peer's account's
	void on_logout(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		ss_ tok;
		if(!m_store || it == m_peers.end() || it->second.name.empty() ||
				!unpack(packet.data, tok))
			return;
		const ss_ key = "token/"+interface::sha256::hex(
				interface::sha256::calculate(tok));
		KeptLogin kept;
		ss_ data;
		if(m_store->get(key, data) && unpack(data, kept) &&
				kept.name == it->second.name){
			m_store->remove(key);
			log_i(MODULE, "%s logged out", cs(kept.name));
		}
	}

	// **Linking a Starport ID to one's own account** (10g): its logins land
	// on this account from then on, as a player moving between Starports
	// does. The data is the ID's token for this server.
	void on_link_starport(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		if(!m_store || it == m_peers.end() || it->second.name.empty())
			return;
		const ss_ name = it->second.name;
		auto result = [&](const ss_ &text){
			send(packet.sender, "accounts:link_result", pack(text));
		};
		starport_announce::IdLogin id;
		ss_ why = "This server does not take Starport IDs";
		starport_announce::access(m_server,
				[&](starport_announce::Interface *s){
			why = s->verify_id_token(packet.data, &id);
		});
		if(!why.empty())
			return result(why);
		const ss_ link = "starport/"+id.starport+"/"+id.sub;
		ss_ linked;
		if(m_store->get(link, linked))
			return result(linked == name ? "Already linked" :
					"That Starport ID is another account's here");
		const ss_ note = link_id(name, id);
		send_links(packet.sender, name);
		result(note);
	}

	// What Starports the account has IDs linked from, a line each, for its
	// My account
	void send_links(PeerId peer, const ss_ &name)
	{
		ss_ text;
		for(const ss_ &link : links_of(name))
			text += (text.empty() ? "" : "\n")+link_starport(link);
		send(peer, "accounts:links", pack(text));
	}

	// Unlinking one Starport's ID; the data is the Starport. Not an
	// account's last way in: one made by its ID has no password anyone
	// knows.
	void on_unlink_starport(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		if(!m_store || it == m_peers.end() || it->second.name.empty())
			return;
		const ss_ name = it->second.name;
		const ss_ key = "starport_of/"+name+"/"+packet.data;
		ss_ link, x;
		if(packet.data.empty() || packet.data.find('/') != ss_::npos ||
				!m_store->get(key, link))
			return send(packet.sender, "accounts:link_result",
					pack(ss_("No Starport ID of that Starport is linked")));
		if(links_of(name).size() == 1 && !m_store->get("own_password/"+name, x))
			return send(packet.sender, "accounts:link_result", pack(ss_(
					"This account logs in by its Starport ID only: "
					"set a password first")));
		m_store->remove(link);
		m_store->remove(key);
		log_i(MODULE, "%s unlinked a Starport ID of %s", cs(name),
				cs(packet.data));
		send_links(packet.sender, name);
		send(packet.sender, "accounts:link_result",
				pack("The Starport ID of "+packet.data+" is unlinked"));
	}

	// -- TOTP ([STARPORT] 10a)

	ss_ totp_secret(const ss_ &name, const char *kind = "totp/")
	{
		ss_ data;
		return m_store && m_store->get(kind+name, data) ? data : ss_();
	}

	bool totp_on(const ss_ &name)
	{
		return !totp_secret(name).empty();
	}

	// The step each name last used, so a code is good once
	std::map<ss_, uint64_t> m_totp_last;

	bool check_totp(const ss_ &name, const ss_ &code)
	{
		const ss_ secret = totp_secret(name);
		if(secret.empty() || code.size() != 6)
			return false;
		// Real time, not the calendar --sim-clock moves: the user's
		// authenticator knows no other
		const uint64_t now = (uint64_t)(interface::os::time_us() / 1000000) /
				30;
		// One step either way, for a clock a little off
		for(uint64_t c = now - 1; c <= now + 1; c++){
			if(hotp(secret, c) == code && c > m_totp_last[name]){
				m_totp_last[name] = c;
				return true;
			}
		}
		return false;
	}

	// A new secret, pending until its first code: base32
	ss_ totp_begin(const ss_ &name)
	{
		std::random_device rd;
		ss_ secret(20, '\0');
		for(char &c : secret)
			c = (char)(rd() & 0xff);
		m_store->set("totp_pending/"+name, secret);
		return base32(secret);
	}

	ss_ totp_confirm(const ss_ &name, const ss_ &code)
	{
		const ss_ secret = totp_secret(name, "totp_pending/");
		if(secret.empty())
			return "Nothing to confirm: begin again";
		m_store->set("totp/"+name, secret);
		if(!check_totp(name, code)){
			m_store->remove("totp/"+name);
			return "Wrong code: check the app's time and try again";
		}
		m_store->remove("totp_pending/"+name);
		// Kept logins made before it would log in without a code
		for(const ss_ &key : m_store->list("token/")){
			ss_ data;
			KeptLogin kept;
			if(m_store->get(key, data) && unpack(data, kept) &&
					kept.name == name)
				m_store->remove(key);
		}
		log_i(MODULE, "%s turned TOTP on", cs(name));
		return "";
	}

	ss_ totp_off(const ss_ &name, const ss_ &code)
	{
		if(!totp_on(name))
			return "";
		if(!check_totp(name, code))
			return "Wrong code";
		m_store->remove("totp/"+name);
		log_i(MODULE, "%s turned TOTP off", cs(name));
		return "";
	}

	ss_ totp_uri(const ss_ &name, const ss_ &secret_b32)
	{
		ss_ issuer = m_server->get_app_id();
		return "otpauth://totp/"+issuer+":"+name+"?secret="+secret_b32+
				"&issuer="+issuer;
	}

	void on_totp(const network::Packet &packet)
	{
		auto it = m_peers.find(packet.sender);
		TotpRequest req;
		if(!m_store || it == m_peers.end() || it->second.name.empty() ||
				!unpack(packet.data, req))
			return;
		const ss_ name = it->second.name;
		TotpResult r;
		if(req.cmd == "begin" && totp_on(name)){
			// A session (a kept login's, which skips the code) does not
			// swap the secret for one of its own: off first, by a code
			r.error = "TOTP is on: turn it off with a code first";
		} else if(req.cmd == "begin"){
			r.secret = totp_begin(name);
			r.uri = totp_uri(name, r.secret);
		} else if(req.cmd == "confirm"){
			r.error = totp_confirm(name, req.code);
			// Still pending: the key again, to try once more
			const ss_ pending = totp_secret(name, "totp_pending/");
			if(!r.error.empty() && !pending.empty()){
				r.secret = base32(pending);
				r.uri = totp_uri(name, r.secret);
			}
		} else if(req.cmd == "off"){
			r.error = totp_off(name, req.code);
		} else if(req.cmd != "status"){
			r.error = "No such TOTP command";
		}
		r.on = totp_on(name) ? 1 : 0;
		send(packet.sender, "accounts:totp_result", pack(r));
	}

	// -- What a Starport (apps/starport) asks of its own server's accounts
	// ([STARPORT] 10): a Starport ID is an account here

	// [STARPORT] 10d: a ban to report to the Starport the account's ID is
	// of; "" when it will be, else why not
	ss_ report_ban(const ss_ &name, const ss_ &reason)
	{
		if(links_of(name).empty())
			return "not reported: not a Starport ID's account";
		m_store->set("ban_report/"+name, reason.empty() ? ss_("other") :
				reason);
		return "";
	}

	bool id_blocked(const ss_ &name)
	{
		bool blocked = false;
		for(const ss_ &link : links_of(name)){
			const ss_ starport = link_starport(link);
			if(starport.empty())
				continue;
			starport_announce::access(m_server,
					[&](starport_announce::Interface *s){
				blocked = blocked || s->is_blocked(starport,
						link.substr(link.rfind('/') + 1));
			});
		}
		return blocked;
	}

	bool registration_open()
	{
		return m_access.open_registration != 0;
	}

	// [SERVER_ADMIN_PAGE] The server's mail and the admin's health page

	json::Value smtp()
	{
		ss_ data;
		json::json_error_t err;
		json::Value v = m_store && m_store->get("smtp", data) ?
				json::load_string(data.c_str(), &err) : json::Value();
		return v.is_object() ? v : json::object();
	}

	// One address, nothing in it that ends a header line or lists another
	static bool mail_address(const ss_ &a)
	{
		const size_t at = a.find('@');
		return a.size() <= 200 && at != ss_::npos && at != 0 &&
				at == a.rfind('@') && at + 1 != a.size() &&
				a.find_first_of(" \t\r\n<>,;\"()") == ss_::npos;
	}

	bool can_mail()
	{
		const json::Value v = smtp();
		return !jstr(v, "url").empty() && !jstr(v, "from").empty() &&
				interface::mail_supported();
	}

	void mail(const ss_ &to, const ss_ &subject, const ss_ &text,
			std::function<void(const ss_ &error)> done)
	{
		const json::Value v = smtp();
		const ss_ url = jstr(v, "url"), user = jstr(v, "user"),
				password = jstr(v, "password"), from = jstr(v, "from");
		if(url.empty() || from.empty()){
			if(done)
				done("this server has no mail server set (the Server "
						"window's Health page)");
			return;
		}
		char date[64];
		const struct tm tm = interface::os::utc_tm(
				interface::os::wall_us() / 1000000);
		// RFC 5322's names: strftime's %a and %b are the locale's
		static const char *days[] = {"Sun", "Mon", "Tue", "Wed", "Thu",
				"Fri", "Sat"};
		static const char *months[] = {"Jan", "Feb", "Mar", "Apr", "May",
				"Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
		snprintf(date, sizeof date, "%s, %02d %s %04d %02d:%02d:%02d +0000",
				days[tm.tm_wday], tm.tm_mday, months[tm.tm_mon],
				tm.tm_year + 1900, tm.tm_hour, tm.tm_min, tm.tm_sec);
		ss_ body, subj;
		for(char c : text){
			if(c == '\n')
				body += "\r\n";
			else if(c != '\r')
				body += c;
		}
		for(char c : subject)
			subj += c == '\r' || c == '\n' ? ' ' : c;
		const ss_ message = ss_("Date: ")+date+"\r\n"
				"From: "+from+"\r\n"
				"To: "+to+"\r\n"
				"Subject: "+subj+"\r\n"
				"Content-Type: text/plain; charset=utf-8\r\n"
				"\r\n"+body;
		std::thread([=](){
			ss_ error;
			try {
				interface::send_mail(url, user, password, from, to, message);
				log_i(MODULE, "Mailed %s: %s", cs(to), cs(subj));
			} catch(std::exception &e){
				error = e.what();
				log_w(MODULE, "Mail to %s: %s", cs(to), e.what());
			}
			if(done)
				done(error);
		}).detach();
	}

	bool offer_smtp(const ss_ &url, const ss_ &from, const ss_ &user,
			const ss_ &password)
	{
		if(!m_store)
			return false;
		if(url.empty() || !jstr(smtp(), "url").empty())
			return true;
		json::Value v = json::object();
		v.set("url", url);
		v.set("from", from);
		v.set("user", user);
		v.set("password", password);
		m_store->set("smtp", v.stringify());
		log_i(MODULE, "The mail server %s taken over as the server's",
				cs(url));
		return true;
	}

	// arg: {"url", "from", "user", "password"}; an empty password keeps
	// the one set, so that the page never has it
	ss_ set_smtp(const ss_ &arg, const ss_ &by)
	{
		json::json_error_t err;
		const json::Value in = json::load_string(arg.c_str(), &err);
		if(!in.is_object())
			return "Not a setting";
		json::Value v = smtp();
		const ss_ url = jstr(in, "url"), from = jstr(in, "from");
		if(!url.empty() && url.compare(0, 7, "smtp://") != 0 &&
				url.compare(0, 8, "smtps://") != 0)
			return "The server is smtp://host:587 or smtps://host:465";
		if(!from.empty() && !mail_address(from))
			return "The sender is one address";
		v.set("url", url);
		v.set("from", from);
		v.set("user", jstr(in, "user"));
		if(!jstr(in, "password").empty() || url.empty())
			v.set("password", url.empty() ? "" : jstr(in, "password"));
		m_store->set("smtp", v.stringify());
		log_i(MODULE, "%s set the mail server to %s", cs(by),
				url.empty() ? "none" : cs(url));
		return url.empty() ? "No mail server" : "The mail server was saved";
	}

	ss_ test_mail(PeerId peer, const ss_ &to, const ss_ &by)
	{
		if(!mail_address(to))
			return "Not an e-mail address";
		if(!interface::mail_supported())
			return "This server's libcurl cannot send mail (a minimal "
					"build): install a full one";
		std::shared_ptr<MailResults> results = m_mail_results;
		mail(to, m_server->get_app_id()+": a test mail",
				"A test mail from the server, sent by its admin "+by+".\n",
				[=](const ss_ &error){
			std::lock_guard<std::mutex> lock(results->m);
			results->r.push_back(std::make_pair(peer, error.empty() ?
					"Sent: the mail server took it for "+to :
					"Not sent: "+error));
		});
		return "Sending to "+to+"...";
	}

	void on_tick(const interface::TickEvent &)
	{
		stats_sample();
		std::vector<std::pair<PeerId, ss_>> r;
		{
			std::lock_guard<std::mutex> lock(m_mail_results->m);
			r.swap(m_mail_results->r);
		}
		for(auto &x : r){
			json::Value v = json::object();
			v.set("mail", x.second);
			if(m_peers.count(x.first))
				send(x.first, "accounts:health", v.stringify());
		}
	}

	// A write that must work, in the app's cache, and one that must not,
	// at the top of the user path: the box's half
	json::Value box_check()
	{
		json::Value v = json::object();
		const interface::ServerConfig &c = m_server->get_config();
		auto try_write = [](const ss_ &path) -> ss_ {
			FILE *f = fopen(path.c_str(), "wb");
			if(!f)
				return strerror(errno);
			const bool ok = fputs("sandbox check\n", f) >= 0;
			fclose(f);
			remove(path.c_str());
			return ok ? "" : "the write failed";
		};
		const ss_ in = c.get<ss_>("cache_path")+"/box_check.txt";
		const ss_ out = c.get<ss_>("user_path")+"/box_check.txt";
		const ss_ in_err = try_write(in), out_err = try_write(out);
		v.set("inside_ok", json::Value(in_err.empty()));
		v.set("inside", in_err.empty() ? "a file written in the app's cache" :
				"no file written in the app's cache: "+in_err);
		v.set("outside_refused", json::Value(!out_err.empty()));
		v.set("outside", out_err.empty() ? "a file written at the top of the "
				"user path: the sandbox is off" : "a file at the top of the user "
				"path refused ("+out_err+")");
		return v;
	}

	// **Statistics** ([SERVER_STATS]). stats/h/<unix hour> an hour's row,
	// eight days kept; stats/d/<unix day> a day's, folded from its hours
	// when it ends and kept for ever; stats/n/<unix day>/<name> the day's
	// names until then; stats/open_day the day the last sample was in.
	// seen/<name> "<last joined> <seconds joined>"; made/<name> is when.
	static int64_t now_s(){ return interface::os::wall_us() / 1000000; }

	StatRow stored_row(const ss_ &key)
	{
		ss_ v;
		return m_store->get(key, v) ? StatRow::parse(v) : StatRow();
	}

	std::pair<int64_t, int64_t> seen(const ss_ &name)
	{
		ss_ v;
		long long last = 0, total = 0;
		if(m_store->get("seen/"+name, v))
			sscanf(v.c_str(), "%lld %lld", &last, &total);
		return std::make_pair((int64_t)last, (int64_t)total);
	}

	void add_time_joined(Peer &peer)
	{
		const int64_t now = now_s();
		auto sn = seen(peer.name);
		sn.second += std::max<int64_t>(0, now - peer.since_s);
		peer.since_s = now;
		m_store->set("seen/"+peer.name, itos(sn.first)+" "+itos(sn.second));
	}

	// The hour in progress, rolled over to the current one: the old one
	// written, the time joined counted to its end, a day ended folded
	StatRow &stats_hour()
	{
		const int64_t h = now_s() / 3600;
		if(h == m_hour_no)
			return m_hour;
		if(m_hour_no >= 0){
			m_store->set("stats/h/"+itos(m_hour_no), m_hour.str());
			for(auto &it : m_peers)
				if(!it.second.name.empty())
					add_time_joined(it.second);
		}
		ss_ v;
		const int64_t day = h / 24;
		if(!m_store->get("stats/open_day", v) || atoll(v.c_str()) != day){
			if(!v.empty() && atoll(v.c_str()) < day)
				fold_day(atoll(v.c_str()));
			m_store->set("stats/open_day", itos(day));
		}
		for(const ss_ &key : m_store->list("stats/h/"))
			if(atoll(key.c_str() + 8) < h - 8 * 24)
				m_store->remove(key);
		m_hour_no = h;
		m_hour = stored_row("stats/h/"+itos(h));
		m_hour_names.clear();
		return m_hour;
	}

	// A day's hours, the one in progress among them as it is now
	StatRow day_row(int64_t day, bool clear_names)
	{
		sv_<StatRow> hours;
		for(int64_t h = day * 24; h < day * 24 + 24; h++)
			hours.push_back(h == m_hour_no ? m_hour :
					stored_row("stats/h/"+itos(h)));
		const ss_ prefix = "stats/n/"+itos(day)+"/";
		const sv_<ss_> names = m_store->list(prefix);
		if(clear_names)
			for(const ss_ &key : names)
				m_store->remove(key);
		return fold_hours(hours, names.size());
	}

	void fold_day(int64_t day)
	{
		m_store->set("stats/d/"+itos(day), day_row(day, true).str());
	}

	// Once a minute: the players joined, the network's peak tick gap over
	// the last minute and the memory
	void stats_sample()
	{
		const int64_t now = interface::os::wall_us();
		if(!m_store || now < m_next_sample_us)
			return;
		m_next_sample_us = now + 60 * 1000000;
		json::Value h;
		network::access(m_server, [&](network::Interface *inetwork){
			json::json_error_t err;
			h = json::load_string(inetwork->health_json().c_str(), &err);
		});
		int64_t players = 0;
		for(auto &it : m_peers)
			players += !it.second.name.empty();
		StatRow &r = stats_hour();
		r.sample(players, jint(h, "tick_gap_ms_max"), jint(h, "memory_bytes"));
		m_store->set("stats/h/"+itos(m_hour_no), r.str());
	}

	void stats_joined(Peer &peer)
	{
		StatRow &r = stats_hour();
		r.joins++;
		if(m_hour_names.insert(peer.name).second)
			r.names++;
		// The peak between samples too
		int64_t players = 0;
		for(auto &it : m_peers)
			players += !it.second.name.empty();
		r.pmax = std::max(r.pmax, players);
		m_store->set("stats/n/"+itos(m_hour_no / 24)+"/"+peer.name, "");
		peer.since_s = now_s();
		m_store->set("seen/"+peer.name, itos(peer.since_s)+" "+
				itos(seen(peer.name).second));
	}

	// The answer to a moderator's "stats": the last 168 hours and the one
	// in progress, the last 182 days and today so far, and the accounts
	json::Value stats_json()
	{
		const int64_t now = now_s();
		stats_hour();
		const int64_t day = m_hour_no / 24;
		json::Value v = json::object();
		json::Value hours = json::array(), days = json::array();
		for(int64_t h = m_hour_no - 168; h <= m_hour_no; h++){
			const StatRow r = h == m_hour_no ? m_hour :
					stored_row("stats/h/"+itos(h));
			if(r.minutes || r.joins || r.made)
				hours.append(r.json(h));
		}
		for(int64_t d = day - 182; d < day; d++){
			const StatRow r = stored_row("stats/d/"+itos(d));
			if(r.minutes || r.joins || r.made)
				days.append(r.json(d));
		}
		days.append(day_row(day, false).json(day));
		v.set("hour", m_hour_no);
		v.set("day", day);
		v.set("hours", hours);
		v.set("days", days);
		json::Value levels = json::object();
		std::map<ss_, int64_t> by_level;
		struct Row { ss_ name; int64_t made, last, total; };
		std::vector<Row> rows;
		int64_t made_30 = 0, idle_90 = 0;
		for(const ss_ &key : m_store->list("auth/")){
			const ss_ name = key.substr(5);
			by_level[level_name(is_admin(name) ? LV_ADMIN : level(name))]++;
			ss_ m;
			Row row{name, m_store->get("made/"+name, m) ? atoll(m.c_str()) : 0,
					seen(name).first, seen(name).second};
			for(auto &it : m_peers)
				if(it.second.name == name)
					row.total += std::max<int64_t>(0, now - it.second.since_s);
			made_30 += row.made >= now - 30 * 86400;
			idle_90 += std::max(row.last, row.made) < now - 90 * 86400;
			rows.push_back(row);
		}
		for(auto &it : by_level)
			levels.set(it.first, it.second);
		std::stable_sort(rows.begin(), rows.end(), [](const Row &a,
				const Row &b){ return a.total > b.total; });
		json::Value top = json::array();
		for(size_t i = 0; i < rows.size() && i < 10; i++){
			json::Value t = json::array();
			t.append(rows[i].name);
			t.append(rows[i].made);
			t.append(rows[i].last);
			t.append(rows[i].total);
			top.append(t);
		}
		v.set("levels", levels);
		v.set("accounts", (int64_t)rows.size());
		v.set("made_30", made_30);
		v.set("idle_90", idle_90);
		v.set("top", top);
		return v;
	}

	json::Value health_json(bool with_box)
	{
		json::Value v = json::object();
		network::access(m_server, [&](network::Interface *inetwork){
			json::json_error_t err;
			v.set("running", json::load_string(
					inetwork->health_json().c_str(), &err));
		});
		const interface::ServerConfig &c = m_server->get_config();
		const ss_ app_user = c.get<ss_>("user_path")+"/apps/"+
				m_server->get_app_id();
		v.set("disk_path", app_user);
		v.set("disk_used", (int64_t)interface::fs::directory_tree_size(app_user));
		v.set("disk_free", interface::os::free_bytes(app_user));
		// [SAVE_LIMIT] What the host lets the app write, and the parts
		storage::access(m_server, [&](storage::Interface *i){
			const storage::Usage u = i->usage();
			v.set("disk_limit", i->limit_bytes());
			v.set("disk_saves", u.saves);
			v.set("disk_shared", u.shared);
			v.set("disk_cache", u.cache);
		});
		v.set("box", c.get<ss_>("box"));
		if(with_box)
			v.set("box_check", box_check());
		char buf[1];
		const size_t n = log_problems(buf, 0);
		ss_ problems(n + 1, '\0');
		log_problems(&problems[0], problems.size());
		problems.resize(n);
		v.set("log", problems);
		v.set("approvals", (int64_t)m_store->list("approval/").size());
		const json::Value m = smtp();
		json::Value sm = json::object();
		sm.set("url", jstr(m, "url"));
		sm.set("from", jstr(m, "from"));
		sm.set("user", jstr(m, "user"));
		sm.set("password_set", json::Value(!jstr(m, "password").empty()));
		sm.set("supported", json::Value(interface::mail_supported()));
		v.set("smtp", sm);
		return v;
	}

	size_t linked_count(const ss_ &host)
	{
		return m_store ? m_store->list("starport/"+host+"/").size() : 0;
	}

	sv_<ss_> reported_bans()
	{
		sv_<ss_> out;
		if(!m_store)
			return out;
		for(const ss_ &key : m_store->list("ban_report/")){
			const ss_ name = key.substr(11);
			ss_ reason;
			if(!m_store->get(key, reason))
				continue;
			// To each Starport the account has an ID of
			for(const ss_ &link : links_of(name)){
				const ss_ starport = link_starport(link);
				if(!starport.empty())
					out.push_back(starport+"|"+link.substr(link.rfind('/') + 1)+
							"|"+reason);
			}
		}
		return out;
	}

	ss_ create_account(const ss_ &name, const ss_ &password)
	{
		if(!m_store)
			return "Not ready";
		if(!valid_name(name) || reserved_name(name))
			return "A name is 1 to 20 letters, digits, _ or -, and not "
					"client<digits>";
		if(exists(name))
			return "That name is taken";
		if(password.size() < MIN_PASSWORD || password.size() > 100)
			return "A password is "+itos((int)MIN_PASSWORD)+
					" to 100 characters";
		set_account(name, new_account(password, {}));
		log_i(MODULE, "New account %s (Starport ID)", cs(name));
		return "";
	}

	bool check_password(const ss_ &name, const ss_ &password)
	{
		Account account;
		return get_account(name, account) && password.size() <= 100 &&
				pbkdf2_sha256(password, account.salt, PBKDF2_ITERATIONS) ==
				account.hash;
	}

	ss_ set_password(const ss_ &name, const ss_ &password)
	{
		Account account;
		if(!get_account(name, account))
			return "No such account";
		if(password.size() < MIN_PASSWORD || password.size() > 100)
			return "A password is "+itos((int)MIN_PASSWORD)+
					" to 100 characters";
		set_account(name, new_account(password, account.privs));
		return "";
	}

	ss_ delete_account(const ss_ &name)
	{
		if(!exists(name))
			return "No such account";
		m_store->remove("auth/"+name);
		m_store->remove("totp/"+name);
		m_store->remove("totp_pending/"+name);
		m_store->remove("level/"+name);
		log_i(MODULE, "Account %s deleted", cs(name));
		account_deleted(name);
		return "";
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_accounts(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}

// vim: set noet ts=4 sw=4:
