// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "server/confine.h"
#include "server/config.h"
#include "server/wasm_build.h"
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
ss_ confine_build(const sv_<ss_> &read_dirs, const ss_ &job_dir)
{
	return "this platform has no box for a build";
}
}

#elif defined(_WIN32)
// confine_windows.cpp; no box for a build there
namespace server {
ss_ confine_build(const sv_<ss_> &read_dirs, const ss_ &job_dir)
{
	return "this platform has no box for a build";
}
}
#else

#include <linux/landlock.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <linux/audit.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <sched.h>
#include <signal.h>
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
#include <map>
#include <algorithm>
#include <sys/resource.h>
#include "interface/process.h"

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
// no_sockets ([WEB_LOCAL_AITTA], a publish's build): no socket of any
// family, so nothing reaches a network, TCP or UDP or a name server
static ss_ install_seccomp(bool no_sockets = false)
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
	if(no_sockets)
		stmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EACCES & SECCOMP_RET_DATA));
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

ss_ confine_build(const sv_<ss_> &read_dirs, const ss_ &job_dir)
{
	if(count_threads() != 1)
		return "the build's box is made before any thread starts";
	const int abi = syscall(SYS_landlock_create_ruleset, nullptr, 0,
			LANDLOCK_CREATE_RULESET_VERSION);
	if(abi < 1)
		return ss_("Landlock is not available (")+strerror(errno)+")";
	RulesetAttr attr;
	attr.handled_access_fs = FS_ABI1;
	if(abi >= 2)
		attr.handled_access_fs |= LANDLOCK_ACCESS_FS_REFER;
	if(abi >= 3)
		attr.handled_access_fs |= LANDLOCK_ACCESS_FS_TRUNCATE;
	if(abi >= 5)
		attr.handled_access_fs |= LANDLOCK_ACCESS_FS_IOCTL_DEV;
	// No TCP port at all (and seccomp takes the sockets themselves)
	attr.handled_access_net = abi >= 4 ? (LANDLOCK_ACCESS_NET_BIND_TCP |
			LANDLOCK_ACCESS_NET_CONNECT_TCP) : 0;
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
	// What the build reads goes into a .wasm that Aitta publishes: the
	// programs and libraries, the toolchain, the engine's headers and
	// crates, and nothing of the user's -- not /etc (but the loader's
	// cache), /proc, /home, /tmp or the server's own files
	for(const char *p : {"/usr", "/lib", "/lib32", "/lib64", "/bin", "/sbin",
			"/etc/ld.so.cache"})
		rs.add(p, FS_READ);
	for(const ss_ &d : read_dirs)
		if(!d.empty())
			rs.add(d, FS_READ);
	for(const char *p : {"/dev/null", "/dev/zero", "/dev/random",
			"/dev/urandom"})
		rs.add(p, rs.handled);
	rs.add(job_dir, rs.handled);
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
	const ss_ seccomp = install_seccomp(true);
	if(!seccomp.empty())
		return seccomp;
	for(const ss_ &r : rs.refused)
		log_w(MODULE, "No rule for %s", cs(r));
	log_i(MODULE, "The build is sandboxed: Landlock ABI %i, %s writable, "
			"no sockets", abi, cs(job_dir));
	return "";
}

// [WEB_LOCAL_AITTA] A publish's build, each of its processes: the wall
// clock (this one's), and the CPU, address space, file size and no core
// (all). [AITTA_BUILD_MEM] 2 GiB: the most a process of the builds
// measured reserved was node's (emcc), 1.2 GiB; rustc 0.4 GiB
static const unsigned BUILD_WALL_S = 300;
static const rlim_t BUILD_CPU_S = 600;
static const rlim_t BUILD_MEM = (rlim_t)2 << 30;
static const rlim_t BUILD_FILE = (rlim_t)256 << 20;
// [AITTA_BUILD_NPROC] Its processes and threads at once (RLIMIT_NPROC).
// The kernel (5.14+) counts it per user namespace: only the build's own
// tasks, not the rest of Aitta's uid, and the build cannot raise it.
// [AITTA_BUILD_MEM] 64: the builds measured ran 21 at most (cargo and two
// rustc; emcc with BINARYEN_CORES=2, below).
// simplified: an older kernel counts the uid's tasks across the host, so
// there every build fails closed past this many
static const rlim_t BUILD_NPROC = 64;
// [AITTA_BUILD_MEM] All of a build's processes together: at most this
// much memory, BUILDAT_BUILD_MEMORY_MIB or 4 GiB (the builds measured
// peaked at 0.5 GiB resident). A memory cgroup holds it where the server
// has one delegated (make_build_cgroup()); else the build's PID 1
// measures its processes every 0.1 s and ends the build past it.
// simplified: the measuring lags: what the build's tasks touch in 0.1 s
// (some GiB on a fast host) goes past the total before it ends, and
// kernel memory (pipe buffers, page tables) is not counted; the hard
// ceiling is BUILD_NPROC x BUILD_MEM (128 GiB). The upgrade is the cgroup:
// run Aitta under a systemd unit with Delegate= (doc/aitta.txt)
static uint64_t build_memory()
{
	const char *e = getenv("BUILDAT_BUILD_MEMORY_MIB");
	const long long mib = e ? atoll(e) : 0;
	return (uint64_t)(mib > 0 ? mib : 4096) << 20;
}
// [WEB_LOCAL_AITTA_CPP] Its job directory: at most this many bytes
// (blocks used) and files. RLIMIT_FSIZE caps a file, not how many there
// are; the build's PID 1 measures the directory each second and ends the
// build past either.
static const uint64_t BUILD_DISK = (uint64_t)3 << 30;
static const uint64_t BUILD_FILES = 200000;

// The bytes (blocks) and entries under the directory fd, links not
// followed; stops counting past the caps
static void tree_use(int dir, uint64_t &bytes, uint64_t &files)
{
	DIR *d = fdopendir(dir);
	if(!d){
		close(dir);
		return;
	}
	while(struct dirent *e = readdir(d)){
		if(!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
			continue;
		struct stat st;
		if(fstatat(dirfd(d), e->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0)
			continue;
		files++;
		bytes += (uint64_t)st.st_blocks * 512;
		if(bytes > BUILD_DISK || files > BUILD_FILES)
			break;
		if(S_ISDIR(st.st_mode)){
			const int sub = openat(dirfd(d), e->d_name, O_RDONLY |
					O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
			if(sub >= 0)
				tree_use(sub, bytes, files);
		}
	}
	closedir(d);
}

// [AITTA_BUILD_MEM] The memory this process's descendants hold (every
// process of its PID namespace, whose init it is): resident anonymous and
// shared memory (a memfd's too), bytes. From the host's /proc: each
// process's status, which no ptrace check guards (a process made
// undumpable is counted too)
static uint64_t ns_memory()
{
	char link[32] = {};
	if(readlink("/proc/self", link, sizeof link - 1) <= 0)
		return 0;
	const long self = atol(link); // as the host's /proc numbers it
	DIR *d = opendir("/proc");
	if(!d)
		return 0;
	std::map<long, std::pair<long, uint64_t>> procs; // pid: parent, KiB
	while(struct dirent *e = readdir(d)){
		if(!isdigit((unsigned char)e->d_name[0]))
			continue;
		std::ifstream f(ss_("/proc/")+e->d_name+"/status");
		ss_ line;
		long parent = 0;
		uint64_t kib = 0;
		while(std::getline(f, line)){
			if(line.compare(0, 5, "PPid:") == 0)
				parent = atol(line.c_str() + 5);
			else if(line.compare(0, 8, "RssAnon:") == 0 ||
					line.compare(0, 9, "RssShmem:") == 0)
				kib += strtoull(line.c_str() + line.find(':') + 1, nullptr, 10);
		}
		procs[atol(e->d_name)] = {parent, kib};
	}
	closedir(d);
	uint64_t kib = 0;
	for(const auto &p : procs){
		long at = p.first;
		for(int depth = 0; depth < 1000 && procs.count(at) && at != self;
				depth++)
			at = procs[at].first;
		if(at == self)
			kib += p.second.second;
	}
	return kib << 10;
}

int build_wasm_job(const ss_ &job, const ss_ &interface_path, const ss_ &kit)
{
	// Nothing of Aitta's: an open file or socket it left without
	// close-on-exec (a descriptor goes past any box), its input, and its
	// environment (cleared below, once the toolchain is found)
	struct rlimit nofile = {1024, 1024};
	getrlimit(RLIMIT_NOFILE, &nofile);
	for(int fd = 3; fd < (int)std::min<rlim_t>(nofile.rlim_cur, 1 << 20); fd++)
		close(fd);
	if(!freopen("/dev/null", "r", stdin))
		return 2;
	// What it said, for Aitta's log; the parent reads out/ only
	if(!freopen((job+"/log").c_str(), "w", stdout))
		return 2;
	dup2(fileno(stdout), fileno(stderr));
	// [AITTA_BUILD_LEFTOVERS] Every process the build starts ends with it,
	// one in a session of its own or double-forked as well (a boxed Aitta
	// signals no other process, and it would not know them): the build
	// runs as PID 1 of a namespace of its own (in a user namespace, which
	// needs no privilege), and when it exits the kernel kills the rest.
	// Where the host allows no such namespace (user namespaces off, or
	// refused by AppArmor; BUILDAT_BUILD_NO_PIDNS=1 acts so), nothing is
	// built: a subreaper could not end them either, the box refusing
	// kill() of any process but Aitta itself.
	// [AITTA_BUILD_MEM] The build's PID 1 moves into the build's cgroup
	// where the server made one, and this one stays out to say why the
	// build ended: an OOM kills the whole cgroup (memory.oom.group)
	const char *cgroup = getenv("BUILDAT_BUILD_CGROUP");
	const bool in_cgroup = cgroup != nullptr;
	const uint64_t mem_total = build_memory();
	log_i("wasm", "the build's memory: at most %i MiB, %s",
			(int)(mem_total >> 20), in_cgroup ? cgroup :
			"measured every 0.1 s (no cgroup)");
	auto oom_kills = [&](){
		std::ifstream f(ss_(cgroup)+"/memory.events");
		ss_ k;
		int64_t n = 0, kills = 0;
		while(f >> k >> n)
			if(k == "oom_kill")
				kills = n;
		return kills;
	};
	const int64_t kills_before = in_cgroup ? oom_kills() : 0;
	const char *no_pidns = getenv("BUILDAT_BUILD_NO_PIDNS");
	if(no_pidns || unshare(CLONE_NEWUSER | CLONE_NEWPID) != 0){
		log_e("wasm", "the build is not made: no PID namespace for it (%s), "
				"so nothing would end what it leaves", no_pidns ?
				"BUILDAT_BUILD_NO_PIDNS" : strerror(errno));
		return 3;
	}
	fflush(stdout);
	const pid_t child = fork();
	if(child < 0)
		return 2;
	if(child > 0){
		// The build's exit status; its namespace is gone by then
		int status = 0;
		while(waitpid(child, &status, 0) < 0 && errno == EINTR){}
		if(in_cgroup && oom_kills() != kills_before)
			log_e("wasm", "the build: its processes went past %i MiB "
					"(its cgroup's OOM); ended", (int)(mem_total >> 20));
		return WIFEXITED(status) ? WEXITSTATUS(status) : 4;
	}
	if(in_cgroup){
		// The user namespace's overflow uid is still the owner's kuid
		const int fd = open((ss_(cgroup)+"/cgroup.procs").c_str(),
				O_WRONLY | O_CLOEXEC);
		const bool ok = fd >= 0 && write(fd, "0", 1) == 1;
		const ss_ why = strerror(errno);
		if(fd >= 0)
			close(fd);
		if(!ok){
			log_e("wasm", "the build is not made: it cannot enter its "
					"cgroup %s (%s)", cgroup, cs(why));
			return 3;
		}
	}
	// A namespace's PID 1 ignores a signal it has no handler for
	signal(SIGALRM, [](int){ _exit(4); });
	alarm(BUILD_WALL_S);
	const struct rlimit cpu = {BUILD_CPU_S, BUILD_CPU_S},
			mem = {BUILD_MEM, BUILD_MEM}, file = {BUILD_FILE, BUILD_FILE},
			core_size = {0, 0}, nproc = {BUILD_NPROC, BUILD_NPROC};
	if(setrlimit(RLIMIT_NPROC, &nproc) != 0)
		return 2;
	log_i("wasm", "the build's process cap: %i in its user namespace "
			"(RLIMIT_NPROC)", (int)BUILD_NPROC);
	setrlimit(RLIMIT_CPU, &cpu);
	setrlimit(RLIMIT_AS, &mem);
	setrlimit(RLIMIT_FSIZE, &file);
	setrlimit(RLIMIT_CORE, &core_size);
	server::Config config;
	if(!interface::fs::path_exists(interface_path+"/wasm_server_api.h")){
		log_e("wasm", "the build: no wasm_server_api.h in %s",
				cs(interface_path));
		return 2;
	}
	config.set("interface_path", interface_path);
	find_wasm_toolchain(config);
	// Rust: the toolchain's own cargo and rustc, not rustup's proxies,
	// which read the user's home (and may fetch a toolchain a crate's
	// rust-toolchain.toml names)
	ss_ rust_dir;
	const ss_ cargo = config.get<ss_>("wasm_cargo");
	if(!cargo.empty()){
		interface::process::ExecOptions o;
		o.output_path = job+"/sysroot";
		const ss_ rustc = interface::fs::strip_file_name(cargo)+"/rustc";
		if(rustc.find('\'') == ss_::npos && interface::process::shell_exec(
				"'"+rustc+"' --print sysroot", o) == 0){
			std::ifstream f(o.output_path);
			std::getline(f, rust_dir);
		}
		if(rust_dir.empty() || access((rust_dir+"/bin/cargo").c_str(), X_OK) != 0){
			log_w("wasm", "the build: no Rust toolchain behind %s", cs(cargo));
			rust_dir = "";
		}
		config.set("wasm_cargo", rust_dir.empty() ? "" : rust_dir+"/bin/cargo");
	}
	interface::fs::create_directories(job+"/tmp");
	interface::fs::create_directories(job+"/build/wasm");
	interface::fs::create_directories(job+"/out");
	// A build script reads the environment and may write it into the
	// .wasm: only what the build needs
	clearenv();
	if(!rust_dir.empty())
		setenv("RUSTC", (rust_dir+"/bin/rustc").c_str(), 1);
	setenv("PATH", ((rust_dir.empty() ? "" : rust_dir+"/bin:")+
			"/usr/bin:/bin").c_str(), 1);
	setenv("TMPDIR", (job+"/tmp").c_str(), 1);
	setenv("HOME", (job+"/tmp").c_str(), 1);
	// Two compiles at once, each under the memory limit
	setenv("CARGO_BUILD_JOBS", "2", 1);
	// [AITTA_BUILD_MEM] wasm-opt's threads as for two cores, not one a
	// core of the host's (each a task of BUILD_NPROC); glibc's heaps two
	// (a 64 MiB reservation a thread counts against BUILD_MEM)
	setenv("BINARYEN_CORES", "2", 1);
	setenv("MALLOC_ARENA_MAX", "2", 1);
	config.set("rccpp_build_path", job+"/build");
	config.set("rccpp_prebuilt_path", "");
	const ss_ cc = config.get<ss_>("wasm_cc"), ld = config.get<ss_>("wasm_ld");
	// [WEB_LOCAL_AITTA_CPP] The kit and its emsdk (python3 is the
	// system's, under /usr)
	const ss_ emsdk = kit.empty() ? "" : real(kit+"/emsdk");
	if(!kit.empty() && (kit.find('\'') != ss_::npos || job.find('\'') !=
			ss_::npos || emsdk.empty())){
		log_e("wasm", "the build: no kit with an emsdk at %s", cs(kit));
		return 2;
	}
	// The build itself in a child, in its box; this one, the namespace's
	// PID 1, outside that box (in Aitta's, which reads /proc), measures
	// the job directory each second and, without a cgroup, the build's
	// memory every 0.1 s, and ends everything past its caps (by exiting).
	// The box's Landlock domain keeps the build from tracing this one.
	fflush(stdout);
	const pid_t work = fork();
	if(work < 0)
		return 2;
	if(work > 0){
		for(int tick = 0;; tick++){
			int status = 0;
			const pid_t r = waitpid(work, &status, WNOHANG);
			if(r == work)
				return WIFEXITED(status) ? WEXITSTATUS(status) : 4;
			if(r < 0 && errno != EINTR)
				return 4;
			if(!in_cgroup){
				const uint64_t used = ns_memory();
				if(used > mem_total){
					log_e("wasm", "the build: its processes went past %i MiB "
							"(%i MiB); ended", (int)(mem_total >> 20),
							(int)(used >> 20));
					fflush(stdout);
					_exit(6);
				}
			}
			if(tick % 10 == 0){
				uint64_t bytes = 0, files = 0;
				const int d = open(job.c_str(), O_RDONLY | O_DIRECTORY |
						O_CLOEXEC);
				if(d >= 0)
					tree_use(d, bytes, files);
				if(bytes > BUILD_DISK || files > BUILD_FILES){
					log_e("wasm", "the build: its directory went past %i MiB "
							"or %i files; ended", (int)(BUILD_DISK >> 20),
							(int)BUILD_FILES);
					fflush(stdout);
					_exit(5);
				}
			}
			usleep(100000);
		}
	}
	const ss_ why = confine_build({interface_path, rust_dir,
			cc.empty() ? "" : interface::fs::strip_file_name(
				interface::fs::strip_file_name(cc)),
			ld.empty() ? "" : interface::fs::strip_file_name(
				interface::fs::strip_file_name(ld)), kit, emsdk}, job);
	if(!why.empty()){
		log_e("wasm", "the build is not made outside its box: %s", cs(why));
		return 3;
	}
	// The release's modules: its directories with a meta.json, by a plain
	// name; each server .wasm to out/<module>.server.wasm, each wasm/ to
	// out/<module>.wasm, the names the page's server looks for
	bool ok = true;
	const ss_ src = job+"/src";
	for(const auto &n : interface::fs::list_directory(src)){
		bool plain = n.is_directory && n.name.size() <= 64;
		for(char c : n.name)
			plain = plain && (isalnum((unsigned char)c) || c == '_');
		if(!plain || !interface::fs::path_exists(src+"/"+n.name+"/meta.json"))
			continue;
		json::json_error_t e;
		const json::Value m = json::load_file((src+"/"+n.name+"/meta.json").c_str(), &e);
		const ss_ source = json::jstr(m.get("server_wasm"), "source");
		sv_<std::pair<ss_, bool>> parts;
		if(!source.empty())
			parts.emplace_back(source, true);
		if(interface::fs::path_exists(src+"/"+n.name+"/wasm"))
			parts.emplace_back("wasm", false);
		for(const auto &part : parts){
			const ss_ built = build_module_wasm(config, n.name, src+"/"+n.name,
					part.first, part.second);
			const ss_ to = job+"/out/"+n.name+(part.second ? ".server" : "")+
					".wasm";
			if(built.empty() || !interface::fs::copy_file(built, to)){
				log_e("wasm", "the build: %s's %s/ failed", cs(n.name),
						cs(part.first));
				ok = false;
			}
		}
	}
	// [WEB_LOCAL_AITTA_CPP] The C++ modules, by the kit's fixed script:
	// the system's python3, the environment above and the kit's emsdk
	if(ok && !kit.empty()){
		fflush(stdout);
		ok = interface::process::shell_exec("/usr/bin/python3 -I '"+kit+
				"/build.py' build '"+kit+"' '"+job+"'") == 0;
		if(!ok)
			log_e("wasm", "the build: the C++ server failed");
	}
	return ok ? 0 : 1;
}
// [AITTA_BUILD_MEM] A cgroup for --build-wasm's builds, where the
// server's own is delegated to it (a systemd unit with Delegate=, see
// doc/aitta.txt): writable, with the memory and pids controllers, and
// this process alone in it (so a terminal's or a session's cgroup is left
// as it is). This process moves to <cgroup>/server, and <cgroup>/build
// gets memory.max (build_memory()), no swap, pids.max BUILD_NPROC and
// memory.oom.group (one OOM kill ends the whole build). Its path, or ""
// and why not
static ss_ make_build_cgroup(ss_ &why)
{
	ss_ line;
	{
		std::ifstream f("/proc/self/cgroup");
		std::getline(f, line);
	}
	if(line.compare(0, 3, "0::") != 0 || line.size() <= 4)
		return why = "not in a cgroup v2 of its own", "";
	const ss_ cg = "/sys/fs/cgroup"+line.substr(3);
	auto read = [](const ss_ &path){
		std::ifstream f(path);
		std::string r((std::istreambuf_iterator<char>(f)),
				std::istreambuf_iterator<char>());
		return " "+r;
	};
	auto write = [](const ss_ &path, const ss_ &what){
		const int fd = open(path.c_str(), O_WRONLY | O_CLOEXEC);
		const bool ok = fd >= 0 && ::write(fd, what.data(), what.size()) ==
				(ssize_t)what.size();
		if(fd >= 0)
			close(fd);
		return ok;
	};
	const ss_ controllers = read(cg+"/cgroup.controllers");
	if(controllers.find(" memory") == ss_::npos ||
			controllers.find(" pids") == ss_::npos)
		return why = "no memory and pids controllers in "+cg, "";
	if(access((cg+"/cgroup.subtree_control").c_str(), W_OK) != 0 ||
			access((cg+"/cgroup.procs").c_str(), W_OK) != 0)
		return why = cg+" is not delegated to it", "";
	if(read(cg+"/cgroup.procs") != " "+itos(getpid())+"\n")
		return why = "other processes share "+cg, "";
	const ss_ build = cg+"/build";
	for(const ss_ &d : {cg+"/server", build})
		if(mkdir(d.c_str(), 0755) != 0 && errno != EEXIST)
			return why = d+": "+strerror(errno), "";
	if(!write(cg+"/server/cgroup.procs", "0") ||
			!write(cg+"/cgroup.subtree_control", "+memory +pids"))
		return why = cg+": "+strerror(errno), "";
	if(!write(build+"/memory.max", itos((int64_t)build_memory())) ||
			!write(build+"/pids.max", itos((int64_t)BUILD_NPROC)) ||
			!write(build+"/memory.oom.group", "1"))
		return why = build+": "+strerror(errno), "";
	// Not there without swap accounting: then nothing to swap anyway
	write(build+"/memory.swap.max", "0");
	return build;
}

ss_ confine(core::Config &config, const ss_ &module_path, int *exit_code)
{
	// Landlock restricts the calling thread and what it starts; a thread
	// already running would stay outside
	const int threads = count_threads();
	if(threads != 1)
		return "the sandbox is made before any thread starts, and "+
				itos(threads)+" are running";
	// [AITTA_BUILD_MEM] Before the box, which reads /sys only; the build
	// moves itself in through BUILDAT_BUILD_CGROUP and the rule below
	ss_ no_cgroup;
	const ss_ build_cgroup = make_build_cgroup(no_cgroup);
	if(build_cgroup.empty()){
		unsetenv("BUILDAT_BUILD_CGROUP");
		log_v(MODULE, "No cgroup for a build: %s", cs(no_cgroup));
	} else {
		setenv("BUILDAT_BUILD_CGROUP", build_cgroup.c_str(), 1);
		log_i(MODULE, "A build's cgroup: %s (memory.max %i MiB, pids.max "
				"%i)", cs(build_cgroup), (int)(build_memory() >> 20),
				(int)BUILD_NPROC);
	}

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
				config.get<ss_>("compiler_command")),
			// [CLIENT_WASM] clang and the wasm linker, which may be emsdk's
			// or rustup's under the home directory: the directory above
			// bin/, where clang's own headers are
			interface::fs::strip_file_name(interface::fs::strip_file_name(
				config.get<ss_>("wasm_cc"))),
			interface::fs::strip_file_name(interface::fs::strip_file_name(
				config.get<ss_>("wasm_ld"))),
			// cargo (rustup's proxy, in ~/.cargo/bin) and the toolchains
			// it runs, for a module's Rust; its CARGO_HOME is the build's
			interface::fs::strip_file_name(interface::fs::strip_file_name(
				config.get<ss_>("wasm_cargo"))),
			config.get<ss_>("wasm_rustup")})
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
	if(!build_cgroup.empty())
		rs.add(build_cgroup+"/cgroup.procs", LANDLOCK_ACCESS_FS_WRITE_FILE);
	// [WEB_LOCAL_AITTA_CPP] An Aitta's kit for building C++ servers for
	// the page, and the emsdk it names: what its build reads, which runs
	// inside this box as well
	if(const char *kit = getenv("BUILDAT_AITTA_CPP_KIT")){
		rs.add_around(kit, holes, FS_READ);
		rs.add_around(ss_(kit)+"/emsdk", holes, FS_READ);
	}
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
