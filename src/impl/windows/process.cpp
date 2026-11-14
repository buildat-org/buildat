#include "interface/process.h"
#include "core/log.h"
#include "ports/windows_minimal.h"
#include <shellapi.h>
#include <cstring>
#include <string>
#define MODULE "__process"

namespace interface {
namespace process {

static ss_ format_last_error()
{
	DWORD last_error = GetLastError();
	if(!last_error)
		return "No error";
	TCHAR buf[1000];
	FormatMessage(FORMAT_MESSAGE_FROM_SYSTEM, NULL, last_error,
			MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), buf, 1000-1, NULL);
	return buf;
};

ss_ get_environment_variable(const ss_ &name)
{
	char buf[10000];
	DWORD len = GetEnvironmentVariable(name.c_str(), buf, sizeof buf);
	return ss_(buf, len);
}

int shell_exec(const ss_ &command, const ExecOptions &opts)
{
	log_d(MODULE, "shell_exec(\"%s\")", cs(command));

	// http://stackoverflow.com/questions/334879/how-do-i-get-the-application-exit-code-from-a-windows-command-line/3119934#3119934

	STARTUPINFO si;
	PROCESS_INFORMATION pi;
	memset(&si, 0, sizeof(si));
	si.cb = sizeof(si);
	memset(&pi, 0, sizeof(pi));

	char command_c[50000];
	snprintf(command_c, 50000, "%s", cs(command));

	// The environment block is a null-terminated buffer of null-terminated
	// strings: the parent's, with opts.env set over it -- not opts.env
	// alone, which left the shipped compiler with no TEMP and its first
	// module build failing in C:\WINDOWS\ ([WIN_TMP], 2026-09-20).
	sm_<ss_, ss_> env;
	{
		LPCH parent = GetEnvironmentStrings();
		if(parent){
			for(const char *p = parent; *p; p += strlen(p) + 1){
				const char *eq = strchr(p + 1, '='); // a name may start with '='
				if(!eq)
					continue;
				env[ss_(p, eq - p)] = ss_(eq + 1);
			}
			FreeEnvironmentStrings(parent);
		}
	}
	for(auto &pair : opts.env)
		env[pair.first] = pair.second;
	sv_<char> env_block;
	for(auto &pair : env){
		const ss_ &name = pair.first;
		const ss_ &value = pair.second;
		env_block.insert(env_block.end(), name.c_str(), name.c_str() + name.size());
		env_block.push_back('=');
		env_block.insert(env_block.end(), value.c_str(), value.c_str() + value.size());
		env_block.push_back(0);
	}
	env_block.push_back(0);

	// The child's stdout and stderr into a file when asked, inherited
	HANDLE out = INVALID_HANDLE_VALUE;
	if(!opts.output_path.empty()){
		SECURITY_ATTRIBUTES sa;
		memset(&sa, 0, sizeof sa);
		sa.nLength = sizeof sa;
		sa.bInheritHandle = TRUE;
		out = CreateFileA(opts.output_path.c_str(), GENERIC_WRITE,
				FILE_SHARE_READ, &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
		if(out != INVALID_HANDLE_VALUE){
			si.dwFlags |= STARTF_USESTDHANDLES;
			si.hStdOutput = out;
			si.hStdError = out;
			si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
		}
	}
	BOOL created = CreateProcess(
			NULL, // Module name
			command_c, // Command line (non-const)
			NULL, // Process handle not inheritable
			NULL, // Thread handle not inheritable
			out != INVALID_HANDLE_VALUE, // Inherit handles for the output file
			0, // No creation flags
			env_block.data(), // Use a new environment block
			//NULL, // Use parent's environment block
			NULL, // Use parent's starting directory
			&si, // Pointer to STARTUPINFO structure
			&pi // Pointer to PROCESS_INFORMATION structure
	);
	if(out != INVALID_HANDLE_VALUE)
		CloseHandle(out);
	if(!created){
		log_w(MODULE, "Trying to run \"%s\": CreateProcess failed: %s",
				cs(command), cs(format_last_error()));
		return 1;
	}

	WaitForSingleObject(pi.hProcess, INFINITE);
	int exit_code = -1;
	if(!GetExitCodeProcess(pi.hProcess, (LPDWORD)&exit_code)){
		log_w(MODULE, "Trying to run \"%s\": GetExitCodeProcess failed: %s",
				cs(command), cs(format_last_error()));
		return 1;
	}
	CloseHandle(pi.hProcess);
	CloseHandle(pi.hThread);
	return exit_code;
}

// The rules the C runtimes parse a command line by (CommandLineToArgvW's):
// backslashes are literal, but for those before a quote, which are halved
ss_ quote_arg(const ss_ &arg)
{
	ss_ r = "\"";
	size_t backslashes = 0;
	for(char c : arg){
		if(c == '\\'){
			backslashes++;
			continue;
		}
		r.append(c == '"' ? backslashes * 2 + 1 : backslashes, '\\');
		backslashes = 0;
		r += c;
	}
	r.append(backslashes * 2, '\\');
	return r+"\"";
}

bool open_with_system(const ss_ &target)
{
	if(target.find_first_of("'\"") != ss_::npos)
		return false;
	int n = MultiByteToWideChar(CP_UTF8, 0, target.c_str(), -1, nullptr, 0);
	if(n <= 0)
		return false;
	std::wstring w(n, L'\0');
	MultiByteToWideChar(CP_UTF8, 0, target.c_str(), -1, &w[0], n);
	// Above 32 is success (the HINSTANCE is an old error code otherwise)
	INT_PTR r = (INT_PTR)ShellExecuteW(NULL, L"open", w.c_str(), NULL, NULL,
			SW_SHOWNORMAL);
	if(r <= 32){
		log_w(MODULE, "open_with_system(\"%s\"): ShellExecute failed (%d)",
				cs(target), (int)r);
		return false;
	}
	return true;
}

bool Handle::valid() const
{
	return impl != 0;
}

// The Job Object every child goes into: when the last handle to it
// closes -- this process exiting, however it exits -- the children are
// killed with it. Linux has PR_SET_PDEATHSIG for the same. Without it a
// client that died at its connect left its server running, holding the
// module DLLs the next server could not overwrite ([WIN8_START] 7).
static HANDLE children_job()
{
	static HANDLE job = NULL;
	if(job)
		return job;
	job = CreateJobObject(NULL, NULL);
	if(!job){
		log_w(MODULE, "CreateJobObject failed: %s", cs(format_last_error()));
		return NULL;
	}
	JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
	memset(&info, 0, sizeof info);
	info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
	if(!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
			&info, sizeof info))
		log_w(MODULE, "SetInformationJobObject failed: %s",
				cs(format_last_error()));
	return job;
}

Handle start(const ss_ &path, const sv_<ss_> &args, const ss_ &cwd)
{
	Handle h;
	ss_ cmd = "\"" + path + "\"";
	for(const ss_ &a : args)
		cmd += " \"" + a + "\"";

	STARTUPINFO si;
	PROCESS_INFORMATION pi;
	memset(&si, 0, sizeof(si));
	si.cb = sizeof(si);
	memset(&pi, 0, sizeof(pi));

	char command_c[50000];
	snprintf(command_c, 50000, "%s", cs(cmd));

	// No window of its own for the child ([WIN8_START] 19): a server the
	// client starts writes its log to a file, and a console window beside
	// the game was one more thing to watch and a synchronous sink
	if(!CreateProcess(
			path.c_str(),
			command_c,
			NULL, NULL, false, CREATE_NO_WINDOW,
			NULL, cwd.empty() ? NULL : cwd.c_str(), &si, &pi)){
		log_w(MODULE, "start(\"%s\"): CreateProcess failed: %s",
				cs(path), cs(format_last_error()));
		return h;
	}
	CloseHandle(pi.hThread);
	h.impl = (intptr_t)pi.hProcess;
	HANDLE job = children_job();
	if(job && !AssignProcessToJobObject(job, pi.hProcess))
		log_w(MODULE, "AssignProcessToJobObject failed: %s",
				cs(format_last_error()));
	log_i(MODULE, "Started process: %s", cs(path));
	return h;
}

void request_terminate(Handle &h)
{
	if(!h.valid())
		return;
	TerminateProcess((HANDLE)h.impl, 1);
}

void kill_force(Handle &h)
{
	if(!h.valid())
		return;
	HANDLE process = (HANDLE)h.impl;
	TerminateProcess(process, 1);
	WaitForSingleObject(process, INFINITE);
	CloseHandle(process);
	h.impl = 0;
}

void terminate(Handle &h)
{
	if(!h.valid())
		return;
	request_terminate(h);
	HANDLE process = (HANDLE)h.impl;
	WaitForSingleObject(process, 10000);
	kill_force(h);
}

// **Reap it if it has already gone** ([QUIT_STALL]): there are no
// zombies to reap here -- the handle itself signals when the process
// exits -- so this is is_running()'s answer with the handle cleared,
// which is what a caller stopping a server a frame at a time wants.
bool reap(Handle &h)
{
	if(!h.valid())
		return true;
	if(WaitForSingleObject((HANDLE)h.impl, 0) == WAIT_OBJECT_0){
		CloseHandle((HANDLE)h.impl);
		h.impl = 0;
		return true;
	}
	return false;
}

bool is_running(const Handle &h)
{
	if(!h.valid())
		return false;
	// The handle signals when the process has exited: asked first, so
	// that a child which exited with 259 (STILL_ACTIVE's value) is not
	// taken for a live one ([WIN8_START] 10)
	if(WaitForSingleObject((HANDLE)h.impl, 0) == WAIT_OBJECT_0)
		return false;
	DWORD code = 0;
	if(!GetExitCodeProcess((HANDLE)h.impl, &code))
		return false;
	return code == STILL_ACTIVE;
}

}
}
