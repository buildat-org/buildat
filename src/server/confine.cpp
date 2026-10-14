// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "server/confine.h"
#include "core/config.h"
#include "core/log.h"
#include "interface/fs.h"
#include "interface/aitta.h"
#include "core/json.h"
#include <cstdio>
#include <cstdlib>
#ifdef _WIN32
	#include <process.h>
	#define getpid _getpid
#else
	#include <unistd.h>
#endif
#define MODULE "confine"

namespace server {
void boxed_step(const char *what)
{
	const char *path = getenv("BUILDAT_BOXED_STEPS");
	if(!path || !*path)
		return;
	log_i(MODULE, "sandboxed step: %s (pid %i)", what, (int)getpid());
	FILE *f = fopen(path, "ab");
	if(!f)
		return;
	fprintf(f, "%s (pid %i)\n", what, (int)getpid());
	fclose(f);
}
}

#if !defined(__linux__) && !defined(_WIN32)

namespace server {
ss_ confine(core::Config &config, const ss_ &module_path, int *exit_code)
{
	return "this platform has no box yet";
}
}

#elif defined(_WIN32)
// confine_windows.cpp
#else

#include <linux/landlock.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <linux/audit.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include <stddef.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <dirent.h>
#include <fstream>
#include <vector>

// What older headers lack: the build box is older than the kernels the
// server runs on
#ifndef SYS_landlock_create_ruleset
	#define SYS_landlock_create_ruleset 444
	#define SYS_landlock_add_rule 445
	#define SYS_landlock_restrict_self 446
#endif
#ifndef LANDLOCK_ACCESS_FS_REFER
	#define LANDLOCK_ACCESS_FS_REFER (1ULL << 13)
#endif
#ifndef LANDLOCK_ACCESS_FS_TRUNCATE
	#define LANDLOCK_ACCESS_FS_TRUNCATE (1ULL << 14)
#endif
#ifndef LANDLOCK_ACCESS_FS_IOCTL_DEV
	#define LANDLOCK_ACCESS_FS_IOCTL_DEV (1ULL << 15)
#endif
#ifndef LANDLOCK_ACCESS_NET_BIND_TCP
	#define LANDLOCK_ACCESS_NET_BIND_TCP (1ULL << 0)
	#define LANDLOCK_ACCESS_NET_CONNECT_TCP (1ULL << 1)
	#define LANDLOCK_RULE_NET_PORT ((enum landlock_rule_type)2)
	struct landlock_net_port_attr {
		uint64_t allowed_access;
		uint64_t port;
	} __attribute__((packed));
#endif
#ifndef LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET
	#define LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET (1ULL << 0)
	#define LANDLOCK_SCOPE_SIGNAL (1ULL << 1)
#endif
#ifndef __NR_pidfd_open
	#define __NR_pidfd_open 434
#endif
#ifndef __NR_io_uring_setup
	#define __NR_io_uring_setup 425
	#define __NR_io_uring_enter 426
	#define __NR_io_uring_register 427
#endif

namespace server {

// The ruleset's attribute as the newest kernel knows it; an older kernel
// is handed the prefix it knows
struct RulesetAttr {
	uint64_t handled_access_fs;
	uint64_t handled_access_net;
	uint64_t scoped;
};

static const uint64_t FS_ABI1 =
		LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_WRITE_FILE |
		LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR |
		LANDLOCK_ACCESS_FS_REMOVE_DIR | LANDLOCK_ACCESS_FS_REMOVE_FILE |
		LANDLOCK_ACCESS_FS_MAKE_CHAR | LANDLOCK_ACCESS_FS_MAKE_DIR |
		LANDLOCK_ACCESS_FS_MAKE_REG | LANDLOCK_ACCESS_FS_MAKE_SOCK |
		LANDLOCK_ACCESS_FS_MAKE_FIFO | LANDLOCK_ACCESS_FS_MAKE_BLOCK |
		LANDLOCK_ACCESS_FS_MAKE_SYM;
// What a rule on a file, not a directory, may carry
static const uint64_t FS_FILE_RIGHTS =
		LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_WRITE_FILE |
		LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_TRUNCATE |
		LANDLOCK_ACCESS_FS_IOCTL_DEV;
static const uint64_t FS_READ =
		LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_READ_FILE |
		LANDLOCK_ACCESS_FS_READ_DIR;

static ss_ real(const ss_ &path)
{
	char buf[PATH_MAX];
	if(!realpath(path.c_str(), buf))
		return "";
	return buf;
}

static bool inside(const ss_ &path, const ss_ &dir)
{
	return path.size() > dir.size() && path.compare(0, dir.size(), dir) == 0 &&
			path[dir.size()] == '/';
}

struct Ruleset
{
	int fd = -1;
	uint64_t handled = 0;
	sv_<ss_> refused; // Paths a rule could not be made for

	void add(const ss_ &path, uint64_t access)
	{
		const ss_ p = real(path);
		if(p.empty())
			return; // Not there: nothing to allow
		int pfd = open(p.c_str(), O_PATH | O_CLOEXEC);
		if(pfd < 0){
			refused.push_back(p);
			return;
		}
		struct landlock_path_beneath_attr attr;
		attr.allowed_access = access & handled;
		attr.parent_fd = pfd;
		struct stat st;
		if(fstat(pfd, &st) == 0 && !S_ISDIR(st.st_mode))
			attr.allowed_access &= FS_FILE_RIGHTS;
		if(syscall(SYS_landlock_add_rule, fd, LANDLOCK_RULE_PATH_BENEATH,
				&attr, 0) != 0)
			refused.push_back(p+": "+strerror(errno));
		close(pfd);
	}

	// Read access to `dir` but not to what is in `holes` under it: Landlock
	// only adds, so a granted directory gives all of itself, and the
	// development tree keeps user/ and cache/ inside the install directory.
	// The directory's other entries are granted one by one instead.
	void add_around(const ss_ &dir, const sv_<ss_> &holes, uint64_t access)
	{
		const ss_ d = real(dir);
		if(d.empty())
			return;
		bool has_hole = false;
		for(const ss_ &h : holes){
			if(h == d)
				return;
			if(inside(h, d))
				has_hole = true;
		}
		if(!has_hole){
			add(d, access);
			return;
		}
		for(const interface::fs::Node &n : interface::fs::list_directory(d)){
			if(n.name == "." || n.name == "..")
				continue;
			// A link back to this directory or above it (`Build -> .`)
			// recursed without end ([SEC_RUN5_LEFTOVERS]); what it points
			// to is granted where it is
			const ss_ r = real(d+"/"+n.name);
			if(r == d || inside(d, r))
				continue;
			add_around(d+"/"+n.name, holes, access);
		}
	}
};

static int count_threads()
{
	int n = 0;
	DIR *d = opendir("/proc/self/task");
	if(!d)
		return -1;
	while(struct dirent *e = readdir(d))
		if(e->d_name[0] != '.')
			n++;
	closedir(d);
	return n;
}

// seccomp: no unix socket -- Landlock does not govern a named socket's
// connect(), and D-Bus, X11 and docker.sock are all one -- and no io_uring,
// which goes around both. And no signal to anything but this process
// ([SECURITY_RUN_1]): Landlock scopes signals only from ABI 6 (Linux 6.12),
// and before that a boxed server could kill any of the user's processes.
// kill, tgkill, the sigqueue pair and pidfd_open are let through for this
// pid alone, which a child (a mod's os.execute, the compiler) inherits as
// it is: it signals nothing outside either. tkill, which glibc does not
// use, is refused, and truncate by path (see below). The rest is
// Landlock's.
static ss_ install_seccomp()
{
#if defined(__x86_64__)
	const uint32_t arch = AUDIT_ARCH_X86_64;
#elif defined(__aarch64__)
	const uint32_t arch = AUDIT_ARCH_AARCH64;
#else
	return "seccomp: not written for this architecture";
#endif
	const uint32_t deny_unix = SECCOMP_RET_ERRNO | (EAFNOSUPPORT & SECCOMP_RET_DATA);
	const uint32_t deny_enosys = SECCOMP_RET_ERRNO | (ENOSYS & SECCOMP_RET_DATA);
	const uint32_t deny_perm = SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA);
	const uint32_t pid = (uint32_t)getpid();
	const uint32_t arg0_lo = offsetof(struct seccomp_data, args[0]);
	const uint32_t arg0_hi = arg0_lo + 4; // little-endian, both arches

	// Written with named targets and the offsets worked out after: a
	// hand-counted jump is how a filter goes to the wrong place
	enum Label { NONE = -1, L_ENOSYS, L_PERM, L_SOCKET, L_PIDCHECK, NUM_LABELS };
	struct Ins { struct sock_filter f; int jt, jf; };
	std::vector<Ins> prog;
	int at[NUM_LABELS];
	auto stmt = [&](uint16_t code, uint32_t k){
		prog.push_back({BPF_STMT(code, k), NONE, NONE});
	};
	// Equal goes to `jt`, else to `jf`; NONE is the next instruction
	auto jeq = [&](uint32_t k, int jt, int jf){
		prog.push_back({BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, k, 0, 0), jt, jf});
	};
	auto label = [&](Label l){ at[l] = (int)prog.size(); };

	stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
	prog.push_back({BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, arch, 1, 0), NONE, NONE});
	stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
	stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
#if defined(__x86_64__)
	// The x32 numbers are the same calls under other names
	prog.push_back({BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000, 0, 1),
			NONE, NONE});
	stmt(BPF_RET | BPF_K, deny_enosys);
#endif
	jeq(__NR_io_uring_setup, L_ENOSYS, NONE);
	jeq(__NR_io_uring_enter, L_ENOSYS, NONE);
	jeq(__NR_io_uring_register, L_ENOSYS, NONE);
	jeq(__NR_tkill, L_PERM, NONE);
	// truncate(2) by path: Landlock governs it from ABI 3 (Linux 6.2) only,
	// and nothing here needs it -- sqlite, the compiler and the linker
	// truncate what they have open, which the write rules cover
	jeq(__NR_truncate, L_PERM, NONE);
	jeq(__NR_socket, L_SOCKET, NONE);
	jeq(__NR_kill, L_PIDCHECK, NONE);
	jeq(__NR_tgkill, L_PIDCHECK, NONE);
	jeq(__NR_rt_sigqueueinfo, L_PIDCHECK, NONE);
	jeq(__NR_rt_tgsigqueueinfo, L_PIDCHECK, NONE);
	jeq(__NR_pidfd_open, L_PIDCHECK, NONE);
	stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
	// socket(domain, ...): the low word of the first argument
	label(L_SOCKET);
	stmt(BPF_LD | BPF_W | BPF_ABS, arg0_lo);
	prog.push_back({BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_UNIX, 0, 1),
			NONE, NONE});
	stmt(BPF_RET | BPF_K, deny_unix);
	stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
	// The first argument is this pid, all 64 bits of it: not 0 (the
	// group), not -1 (everyone), not another process
	label(L_PIDCHECK);
	stmt(BPF_LD | BPF_W | BPF_ABS, arg0_lo);
	jeq(pid, NONE, L_PERM);
	stmt(BPF_LD | BPF_W | BPF_ABS, arg0_hi);
	jeq(0, NONE, L_PERM);
	stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
	// Last: a classic BPF jump only goes forward
	label(L_ENOSYS);
	stmt(BPF_RET | BPF_K, deny_enosys);
	label(L_PERM);
	stmt(BPF_RET | BPF_K, deny_perm);

	std::vector<struct sock_filter> filter;
	for(size_t i = 0; i < prog.size(); i++){
		struct sock_filter f = prog[i].f;
		for(int which = 0; which < 2; which++){
			const int l = which == 0 ? prog[i].jt : prog[i].jf;
			if(l == NONE)
				continue;
			const int off = at[l] - (int)i - 1;
			if(off < 0 || off > 255)
				return "seccomp: a jump the filter cannot make";
			(which == 0 ? f.jt : f.jf) = (uint8_t)off;
		}
		filter.push_back(f);
	}
	struct sock_fprog fprog = {(unsigned short)filter.size(), filter.data()};
	if(prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &fprog) != 0)
		return ss_("seccomp: ")+strerror(errno);
	return "";
}

ss_ confine(core::Config &config, const ss_ &module_path, int *exit_code)
{
	// Landlock restricts the calling thread and what it starts; a thread
	// already running would stay outside
	const int threads = count_threads();
	if(threads != 1)
		return "the sandbox is made before any thread starts, and "+
				itos(threads)+" are running";

	const int abi = syscall(SYS_landlock_create_ruleset, nullptr, 0,
			LANDLOCK_CREATE_RULESET_VERSION);
	if(abi < 1)
		return ss_("Landlock is not available (")+strerror(errno)+"): the "
				"kernel is older than 5.13 or has it off in its lsm= list";

	const ss_ app = app_of(module_path);

	const ss_ user = real(config.get<ss_>("user_path"));
	const ss_ cache = real(config.get<ss_>("cache_path"));
	if(user.empty() || cache.empty())
		return "the user or the cache path does not resolve";
	const ss_ prebuilt = config.get<ss_>("rccpp_build_path");

	// **The app's own cache** (decided 2026-10-02: a cache shared between
	// apps is an escape between them -- app A writes a module object app
	// B loads). The shared rccpp_build stays as what was built before, read
	// only: a module whose hash matches there is loaded from it.
	const ss_ app_cache = cache+"/apps/"+app;
	const ss_ app_user = user+"/apps/"+app;
	const ss_ app_shared = user+"/shared/"+app;
	for(const ss_ &d : {app_cache+"/tmp", app_cache+"/rccpp_build", app_user,
			app_shared})
		interface::fs::create_directories(d);
	config.set("cache_path", app_cache);
	config.set("rccpp_build_path", app_cache+"/rccpp_build");
	config.set("rccpp_prebuilt_path", prebuilt);
	// The compiler's temporary files
	setenv("TMPDIR", (app_cache+"/tmp").c_str(), 1);

	RulesetAttr attr;
	attr.handled_access_fs = FS_ABI1;
	if(abi >= 2)
		attr.handled_access_fs |= LANDLOCK_ACCESS_FS_REFER;
	if(abi >= 3)
		attr.handled_access_fs |= LANDLOCK_ACCESS_FS_TRUNCATE;
	if(abi >= 5)
		attr.handled_access_fs |= LANDLOCK_ACCESS_FS_IOCTL_DEV;
	// **TCP by port** (user, 2026-10-03), from ABI 4: the services on
	// 127.0.0.1 are other running programs. Bind the server's own port
	// only; connect to the ports buildat itself implies -- HTTP and HTTPS
	// (Starports, ContentDB, blocklists), mail submission (a Starport's
	// codes), a buildat server's and a Starport's defaults -- and to the
	// ones the server's admin names outside the box (--connect-ports,
	// BUILDAT_CONNECT_PORTS: "8080,2525", or "any"), never to ones an app
	// names. simplified: by port and not by address, which is all Landlock
	// has; UDP is not covered at all.
	// Or the admin's file <user>/connect_ports, one line: the box cannot
	// write the user path's top level, so an app cannot give itself ports
	ss_ extra = config.get<ss_>("connect_ports");
	if(extra.empty()){
		std::ifstream f(user+"/connect_ports");
		std::getline(f, extra);
		while(!extra.empty() && isspace((unsigned char)extra.back()))
			extra.pop_back();
	}
	const bool connect_any = extra == "any";
	sv_<int> connect_ports = {80, 443, 465, 587, 29500, 29595};
	if(!connect_any){
		size_t at = 0;
		while(at < extra.size()){
			size_t comma = extra.find(',', at);
			if(comma == ss_::npos)
				comma = extra.size();
			const int p = atoi(extra.substr(at, comma - at).c_str());
			if(p > 0 && p < 65536)
				connect_ports.push_back(p);
			at = comma + 1;
		}
	}
	const int listen_port = atoi(config.get<ss_>("network_port").c_str());
	attr.handled_access_net = abi >= 4 ? (LANDLOCK_ACCESS_NET_BIND_TCP |
			(connect_any ? 0 : LANDLOCK_ACCESS_NET_CONNECT_TCP)) : 0;
	attr.scoped = abi >= 6 ? (LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET |
			LANDLOCK_SCOPE_SIGNAL) : 0;
	const size_t attr_size = abi >= 6 ? sizeof(RulesetAttr) :
			abi >= 4 ? offsetof(RulesetAttr, scoped) :
			offsetof(RulesetAttr, handled_access_net);
	Ruleset rs;
	rs.handled = attr.handled_access_fs;
	rs.fd = syscall(SYS_landlock_create_ruleset, &attr, attr_size, 0);
	if(rs.fd < 0)
		return ss_("Landlock: ")+strerror(errno);

	const uint64_t rw = rs.handled;
	// The system: programs, libraries, the compiler, certificates, the
	// resolver's files. Not /run, /home, /root, /mnt, /media, /var, /tmp.
	for(const char *p : {"/usr", "/lib", "/lib32", "/lib64", "/bin", "/sbin",
			"/etc", "/opt", "/nix", "/proc", "/sys"})
		rs.add(p, FS_READ);
	// /etc's links out of it, granted where they lead: resolv.conf is
	// /run/systemd/resolve/stub-resolv.conf under systemd-resolved, and
	// without it no name resolves
	for(const char *p : {"/etc/resolv.conf", "/etc/hosts",
			"/etc/nsswitch.conf", "/etc/localtime"})
		rs.add(p, FS_READ);
	for(const char *p : {"/dev/null", "/dev/zero", "/dev/full",
			"/dev/random", "/dev/urandom"})
		rs.add(p, rw);
	// The install: the share path, the executable's, the headers and
	// Urho3D's, with the user and cache paths cut out of them
	const sv_<ss_> holes = {user, cache};
	char exe[PATH_MAX];
	ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
	ss_ exe_dir = n > 0 ? interface::fs::strip_file_name(ss_(exe, n)) : "";
	for(const ss_ &p : {config.get<ss_>("share_path"), exe_dir,
			config.get<ss_>("interface_path"), config.get<ss_>("urho3d_path"),
			config.get<ss_>("web_client_path"), module_path,
			interface::fs::strip_file_name(
				config.get<ss_>("compiler_command"))})
		if(!p.empty())
			rs.add_around(p, holes, FS_READ);
	// The app's own, and what the other apps share, read only
	rs.add(app_user, rw);
	rs.add(app_shared, rw);
	rs.add(app_cache, rw);
	rs.add(user+"/shared", FS_READ);
	// A variant's base, which may be an installed package under the user
	// path ([LUANTI_APP_PACKAGES]); the loader refuses one not there
	{
		json::json_error_t e;
		ss_ why;
		const ss_ base = real(interface::aitta::find_base(json::load_file(
				(module_path+"/meta.json").c_str(), &e), module_path,
				config.get<ss_>("share_path"), config.get<ss_>("user_path"),
				&why));
		if(!base.empty())
			rs.add(base, FS_READ);
	}
	rs.add_around(prebuilt, {app_cache}, FS_READ);
	auto net_rule = [&](uint64_t access, int port){
		struct landlock_net_port_attr a;
		a.allowed_access = access;
		a.port = (uint64_t)port;
		if(syscall(SYS_landlock_add_rule, rs.fd, LANDLOCK_RULE_NET_PORT,
				&a, 0) != 0)
			rs.refused.push_back("port "+itos(port)+": "+strerror(errno));
	};
	if(attr.handled_access_net){
		net_rule(LANDLOCK_ACCESS_NET_BIND_TCP, listen_port);
		if(!connect_any)
			for(int p : connect_ports)
				net_rule(LANDLOCK_ACCESS_NET_CONNECT_TCP, p);
	}

	if(prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0){
		close(rs.fd);
		return ss_("no_new_privs: ")+strerror(errno);
	}
	if(syscall(SYS_landlock_restrict_self, rs.fd, 0) != 0){
		const ss_ why = strerror(errno);
		close(rs.fd);
		return "Landlock: "+why;
	}
	close(rs.fd);
	const ss_ seccomp = install_seccomp();
	if(!seccomp.empty())
		return seccomp;

	for(const ss_ &r : rs.refused)
		log_w(MODULE, "No rule for %s", cs(r));
	ss_ tcp;
	if(!attr.handled_access_net){
		tcp = "TCP is not limited before ABI 4";
	} else {
		tcp = "TCP bound to port "+itos(listen_port)+" only, connecting ";
		if(connect_any){
			tcp += "anywhere (connect_ports any)";
		} else {
			tcp += "to ports";
			for(int p : connect_ports)
				tcp += " "+itos(p);
		}
	}
	config.set("box", "Landlock ABI "+itos(abi)+(abi >= 6 ?
			" (files, abstract sockets, signals)" : " (files)")+
			", seccomp; "+tcp);
	log_i(MODULE, "The server is sandboxed: Landlock ABI %i (the filesystem%s), "
			"seccomp (no unix sockets, no io_uring); %s. "
			"%s and %s writable, %s/shared readable",
			abi, abi >= 6 ? ", abstract sockets and signals scoped" :
				"; signals and abstract sockets not scoped before ABI 6",
			cs(tcp), cs(app_user), cs(app_shared), cs(user));
	return "";
}

}
#endif
// vim: set noet ts=4 sw=4:
