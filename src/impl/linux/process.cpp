#include "interface/process.h"
#include <fcntl.h>
#include "core/log.h"
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>
#include <cstring>
#include <cstdlib>
#include <vector>
#ifdef __linux__
#include <sys/prctl.h>
#endif
#define MODULE "__process"

namespace interface {
namespace process {

ss_ get_environment_variable(const ss_ &name)
{
	const char *v = getenv(name.c_str());
	return v ? v : "";
}

int shell_exec(const ss_ &command, const ExecOptions &opts)
{
	log_d(MODULE, "shell_exec(\"%s\")", cs(command));
	int f = fork();
	if(f == 0){
		if(!opts.output_path.empty()){
			int fd = open(opts.output_path.c_str(),
					O_WRONLY | O_CREAT | O_TRUNC, 0644);
			if(fd >= 0){
				dup2(fd, 1);
				dup2(fd, 2);
				close(fd);
			}
		}
		execl("/bin/sh", "sh", "-c", command.c_str(), (const char*)nullptr);
		_exit(127);
	}
	int exit_status = 1;
	if(waitpid(f, &exit_status, 0) < 0)
		return 1;
	return exit_status;
}

bool open_with_system(const ss_ &target)
{
	if(target.find_first_of("'\"") != ss_::npos)
		return false;
#ifdef __APPLE__
	return shell_exec("open '"+target+"'") == 0;
#else
	// Not waited for, so only a missing xdg-open is seen as a failure
	return shell_exec("command -v xdg-open >/dev/null && "
			"{ xdg-open '"+target+"' >/dev/null 2>&1 & }") == 0;
#endif
}

bool Handle::valid() const
{
	return impl > 0;
}

Handle start(const ss_ &path, const sv_<ss_> &args, const ss_ &cwd)
{
	Handle h;
	pid_t pid = fork();
	if(pid < 0){
		log_w(MODULE, "fork failed: %s", strerror(errno));
		return h;
	}
	if(pid == 0){
		setpgid(0, 0);
#ifdef __linux__
		prctl(PR_SET_PDEATHSIG, SIGKILL);
		if(getppid() == 1)
			_exit(1);
#endif
		if(!cwd.empty() && chdir(cwd.c_str()) != 0)
			_exit(126);
		std::vector<char*> argv;
		argv.push_back(const_cast<char*>(path.c_str()));
		for(const ss_ &a : args)
			argv.push_back(const_cast<char*>(a.c_str()));
		argv.push_back(nullptr);
		execv(path.c_str(), argv.data());
		log_w(MODULE, "execv(\"%s\") failed: %s", cs(path), strerror(errno));
		_exit(127);
	}
	setpgid(pid, pid);
	h.impl = pid;
	ss_ shown = path;
	for(const ss_ &a : args)
		shown += " " + a;
	log_i(MODULE, "Started pid %i: %s%s", (int)pid, cs(shown),
			cwd.empty() ? "" : cs(" (in " + cwd + ")"));
	return h;
}

static void kill_tree(pid_t pid, int sig)
{
	kill(-pid, sig);
	kill(pid, sig);
}

static bool reap_dead(Handle &h)
{
	if(!h.valid())
		return true;
	pid_t pid = (pid_t)h.impl;
	int status = 0;
	pid_t r = waitpid(pid, &status, WNOHANG);
	if(r == pid || (r < 0 && errno == ECHILD && kill(pid, 0) != 0 &&
			errno == ESRCH)){
		h.impl = 0;
		return true;
	}
	return false;
}

void request_terminate(Handle &h)
{
	if(!h.valid())
		return;
	if(reap_dead(h))
		return;
	pid_t pid = (pid_t)h.impl;
	log_i(MODULE, "SIGTERM pid %i", (int)pid);
	kill_tree(pid, SIGTERM);
}

void kill_force(Handle &h)
{
	if(!h.valid())
		return;
	if(reap_dead(h))
		return;
	pid_t pid = (pid_t)h.impl;
	log_w(MODULE, "SIGKILL pid %i", (int)pid);
	kill_tree(pid, SIGKILL);
	waitpid(pid, nullptr, 0);
	h.impl = 0;
}

bool is_running(const Handle &h)
{
	if(!h.valid())
		return false;
	pid_t pid = (pid_t)h.impl;
	// Reaped here, or a child that has exited stays a zombie that
	// kill(pid, 0) still finds: a crashed local server read as running
	// for as long as the client lived ([START_PROGRESS])
	if(waitpid(pid, nullptr, WNOHANG) == pid)
		return false;
	if(kill(pid, 0) == 0)
		return true;
	return errno != ESRCH;
}

bool reap(Handle &h)
{
	if(!h.valid())
		return true;
	return reap_dead(h);
}

void terminate(Handle &h)
{
	if(!h.valid())
		return;
	request_terminate(h);
	for(int i = 0; i < 200; i++){
		if(!is_running(h) || reap_dead(h))
			return;
		usleep(50000);
	}
	kill_force(h);
}

}
}
