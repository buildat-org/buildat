// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [PROCESS_SANDBOX] B, the server's box on Windows: an AppContainer per app
// and a job object. What the user's probe runs of 2026-10-03 showed is in
// doc/plan/miscellaneous_plan.md: loopback blocked both ways, a pipe in
// the container's own namespace working, the LAN reaching a boxed
// listener, the profile, Documents and the clipboard refused.
#ifdef _WIN32
#ifndef _WIN32_WINNT
	#define _WIN32_WINNT 0x0A00
#endif
#include "server/confine.h"
#include "core/config.h"
#include "core/log.h"
#include "interface/fs.h"
#include "ports/windows_minimal.h"
#include "interface/os.h"
#include <userenv.h>
#include <sddl.h>
#include <aclapi.h>
#undef interface
#include <algorithm>
#include <cstdlib>
#define MODULE "confine"

namespace server {

// The keys the parent settles and the child is handed, since the child
// cannot write the files detecting them writes ("write.test"), nor read
// the user path's top level (first_admin)
static const char *PATH_KEYS[] = {"share_path", "interface_path",
	"urho3d_path", "compiler_command", "user_path", "cache_path",
	"rccpp_build_path", "web_client_path", "root_path", "log_path",
	"first_admin", nullptr};

static std::wstring wide(const ss_ &s)
{
	if(s.empty())
		return L"";
	int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
	std::wstring w(n, L'\0');
	MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
	return w;
}

static ss_ error_text(DWORD e)
{
	char buf[300] = {0};
	FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
			nullptr, e, 0, buf, sizeof buf, nullptr);
	ss_ s = buf;
	while(!s.empty() && (s.back() == '\n' || s.back() == '\r'))
		s.pop_back();
	return itos((int)e)+" "+s;
}

// A path as Windows compares them: absolute, backslashes, lower case
static ss_ norm(const ss_ &path)
{
	char buf[MAX_PATH * 2];
	DWORD n = GetFullPathNameA(path.c_str(), sizeof buf, buf, nullptr);
	ss_ p = (n > 0 && n < sizeof buf) ? ss_(buf, n) : path;
	std::replace(p.begin(), p.end(), '/', '\\');
	while(p.size() > 3 && p.back() == '\\')
		p.pop_back();
	std::transform(p.begin(), p.end(), p.begin(), ::tolower);
	return p;
}

static bool inside(const ss_ &path, const ss_ &dir)
{
	return path.size() > dir.size() && path.compare(0, dir.size(), dir) == 0 &&
			path[dir.size()] == '\\';
}

static bool in_app_container()
{
	HANDLE token;
	if(!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
		return false;
	DWORD is_ac = 0, len = 0;
	BOOL ok = GetTokenInformation(token, TokenIsAppContainer, &is_ac,
			sizeof is_ac, &len);
	CloseHandle(token);
	return ok && is_ac;
}

static const DWORD READ_RIGHTS = FILE_GENERIC_READ | FILE_GENERIC_EXECUTE;
static const DWORD FULL_RIGHTS = FILE_ALL_ACCESS;
// A directory granted around: its names and nothing in it. msvcrt's stat()
// of a directory lists its parent, so without this gcc calls src/ under a
// root that holds user/ and cache/ "nonexistent" (2026-10-03).
static const DWORD LIST_RIGHTS = FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES |
		FILE_TRAVERSE | SYNCHRONIZE;

struct Grants
{
	PSID sid = nullptr;
	int made = 0;
	sv_<ss_> refused;

	// An inheritable ACE for the container on `path`, where one with these
	// rights is not there already: a start after the first touches nothing
	void grant(const ss_ &path, DWORD rights,
			DWORD inheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT)
	{
		const std::wstring w = wide(path);
		if(GetFileAttributesW(w.c_str()) == INVALID_FILE_ATTRIBUTES)
			return; // Not there: nothing to grant
		PACL dacl = nullptr;
		PSECURITY_DESCRIPTOR sd = nullptr;
		DWORD r = GetNamedSecurityInfoW(w.c_str(), SE_FILE_OBJECT,
				DACL_SECURITY_INFORMATION, nullptr, nullptr, &dacl, nullptr, &sd);
		if(r != ERROR_SUCCESS){
			refused.push_back(path+": "+error_text(r));
			return;
		}
		bool there = false;
		for(DWORD i = 0; dacl && i < dacl->AceCount && !there; i++){
			ACE_HEADER *h = nullptr;
			if(!GetAce(dacl, i, (LPVOID*)&h) || h->AceType != ACCESS_ALLOWED_ACE_TYPE)
				continue;
			ACCESS_ALLOWED_ACE *a = (ACCESS_ALLOWED_ACE*)h;
			if(EqualSid((PSID)&a->SidStart, sid) && (a->Mask & rights) == rights)
				there = true;
		}
		if(!there){
			EXPLICIT_ACCESSW ea = {};
			ea.grfAccessPermissions = rights;
			ea.grfAccessMode = GRANT_ACCESS;
			ea.grfInheritance = inheritance;
			ea.Trustee.TrusteeForm = TRUSTEE_IS_SID;
			ea.Trustee.TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP;
			ea.Trustee.ptstrName = (LPWSTR)sid;
			PACL new_dacl = nullptr;
			r = SetEntriesInAclW(1, &ea, dacl, &new_dacl);
			if(r == ERROR_SUCCESS)
				r = SetNamedSecurityInfoW((LPWSTR)w.c_str(), SE_FILE_OBJECT,
						DACL_SECURITY_INFORMATION, nullptr, nullptr, new_dacl,
						nullptr);
			if(r == ERROR_SUCCESS)
				made++;
			else
				refused.push_back(path+": "+error_text(r));
			if(new_dacl)
				LocalFree(new_dacl);
		}
		LocalFree(sd);
	}

	// Read on `dir` but not on what is in `holes` under it: a granted
	// directory gives all of itself, and the development tree and an
	// archive keep user/ and cache/ inside the install. Its other entries
	// are granted one by one instead (as on Linux).
	void grant_around(const ss_ &dir, const sv_<ss_> &holes, DWORD rights)
	{
		if(dir.empty())
			return;
		const ss_ d = norm(dir);
		bool has_hole = false;
		for(const ss_ &h : holes){
			if(h == d)
				return;
			if(inside(h, d))
				has_hole = true;
		}
		if(!has_hole){
			grant(d, rights);
			return;
		}
		grant(d, LIST_RIGHTS, NO_INHERITANCE);
		for(const interface::fs::Node &n : interface::fs::list_directory(d)){
			if(n.name == "." || n.name == "..")
				continue;
			grant_around(d+"\\"+n.name, holes, rights);
		}
	}
};

// The child's side: in its container, the paths as the parent settled
// them, the app's own cache
static ss_ confine_child(core::Config &config, const ss_ &module_path)
{
	boxed_step("confine_child");
	if(!in_app_container())
		return "started --boxed and not in an AppContainer";
	boxed_step("in its AppContainer");
	// What the compiler is pointed at, read from in here: the boxed
	// compile found no include directory (2026-10-03), and this says how
	// each looks to the box itself
	{
		const ss_ share = config.get<ss_>("share_path");
		for(const ss_ &p : {share, share+"/src", share+"/src/interface",
				share+"/builtin", ss_(module_path), share+"/compiler"}){
			const DWORD a = GetFileAttributesA(p.c_str());
			const DWORD ea = a == INVALID_FILE_ATTRIBUTES ? GetLastError() : 0;
			WIN32_FIND_DATAA fd;
			HANDLE h = FindFirstFileA((p+"\\*").c_str(), &fd);
			const DWORD el = h == INVALID_HANDLE_VALUE ? GetLastError() : 0;
			if(h != INVALID_HANDLE_VALUE)
				FindClose(h);
			const ss_ line = "seen from the sandbox: "+p+": attributes "+
					(ea ? "error "+itos((int)ea) : ss_("ok"))+", listing "+
					(el ? "error "+itos((int)el) : ss_("ok"));
			boxed_step(line.c_str());
		}
	}
	const ss_ app = app_of(module_path);
	const ss_ cache = config.get<ss_>("cache_path");
	const ss_ prebuilt = config.get<ss_>("rccpp_build_path");
	const ss_ app_cache = cache+"/apps/"+app;
	config.set("cache_path", app_cache);
	config.set("rccpp_build_path", app_cache+"/rccpp_build");
	config.set("rccpp_prebuilt_path", prebuilt);
	log_i(MODULE, "The server is sandboxed: AppContainer buildat.%s and a job "
			"object; %s/apps/%s and its shared directory writable",
			cs(app), cs(config.get<ss_>("user_path")), cs(app));
	return "";
}

// **On by default since its runs on Windows 10** (2026-10-03: box_test,
// a local floorplanner and vanilla world by the pipe, a LAN join).
// BUILDAT_WINDOWS_BOX=0 turns it off, for the client too
// (client/pipe_stream.cpp), and the server runs as before and says so.
bool windows_box_wanted()
{
	return !interface::os::windows_sandbox_off_by_env();
}

ss_ confine(core::Config &config, const ss_ &module_path, int *exit_code)
{
	if(config.get<bool>("boxed"))
		return confine_child(config, module_path);
	if(!windows_box_wanted()){
		log_w(MODULE, "Not sandboxed (BUILDAT_WINDOWS_SANDBOX=0): the app can "
				"reach every file you can");
		return "";
	}

	const ss_ app = app_of(module_path);
	const ss_ user = norm(config.get<ss_>("user_path"));
	const ss_ cache = norm(config.get<ss_>("cache_path"));
	const ss_ prebuilt = config.get<ss_>("rccpp_build_path");
	const ss_ app_cache = cache+"\\apps\\"+app;
	const ss_ app_user = user+"\\apps\\"+app;
	const ss_ app_shared = user+"\\shared\\"+app;
	for(const ss_ &d : {app_cache+"\\tmp", app_cache+"\\rccpp_build",
			app_user, app_shared})
		interface::fs::create_directories(d);

	// **The container is per app**, kept, so its SID is stable and one app
	// stays out of another's directories
	const std::wstring name = wide("buildat."+app);
	Grants g;
	HRESULT hr = CreateAppContainerProfile(name.c_str(), name.c_str(),
			L"A buildat server's sandbox", nullptr, 0, &g.sid);
	const bool new_box = hr != HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
	if(!new_box)
		hr = DeriveAppContainerSidFromAppContainerName(name.c_str(), &g.sid);
	if(FAILED(hr))
		return "the AppContainer could not be made (HRESULT "+
				itos((unsigned)hr)+"; Windows 8 or newer has them)";
	// [SEC_WIN_NET] A container has no port rules; the firewall's, per box,
	// are an administrator's to add, and a box exists only from here on
	if(new_box)
		log_w(MODULE, "A new sandbox, buildat.%s: it connects to any host "
				"and port until an administrator runs bin\\sandbox_firewall.ps1 "
				"again", cs(app));

	// The grants: the install, the compiler and the shared build read;
	// the app's three directories full; the shared directories read
	const sv_<ss_> holes = {user, cache};
	char exe[MAX_PATH];
	GetModuleFileNameA(nullptr, exe, sizeof exe);
	for(const ss_ &p : {config.get<ss_>("share_path"),
			interface::fs::strip_file_name(exe),
			config.get<ss_>("interface_path"), config.get<ss_>("urho3d_path"),
			config.get<ss_>("web_client_path"), module_path,
			interface::fs::strip_file_name(
				config.get<ss_>("compiler_command"))})
		g.grant_around(p, holes, READ_RIGHTS);
	g.grant_around(prebuilt, {norm(app_cache)}, READ_RIGHTS);
	g.grant(user+"\\shared", READ_RIGHTS);
	g.grant(app_user, FULL_RIGHTS);
	g.grant(app_shared, FULL_RIGHTS);
	g.grant(app_cache, FULL_RIGHTS);
	for(const ss_ &r : g.refused)
		log_w(MODULE, "No grant on %s", cs(r));
	if(g.made)
		log_i(MODULE, "Granted the sandbox %i director%s", g.made,
				g.made == 1 ? "y" : "ies");

	// **The job**: the child dies with its parent, and has no clipboard,
	// no other process's windows, atoms, desktop or system settings. No
	// process limit: the compiler starts processes. simplified: no memory
	// limit until a playtest asks for one.
	HANDLE job = CreateJobObjectW(nullptr, nullptr);
	JOBOBJECT_EXTENDED_LIMIT_INFORMATION li = {};
	li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
			JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
	JOBOBJECT_BASIC_UI_RESTRICTIONS ui = {};
	ui.UIRestrictionsClass = JOB_OBJECT_UILIMIT_HANDLES |
			JOB_OBJECT_UILIMIT_READCLIPBOARD | JOB_OBJECT_UILIMIT_WRITECLIPBOARD |
			JOB_OBJECT_UILIMIT_GLOBALATOMS | JOB_OBJECT_UILIMIT_DESKTOP |
			JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS | JOB_OBJECT_UILIMIT_EXITWINDOWS |
			JOB_OBJECT_UILIMIT_DISPLAYSETTINGS;
	if(!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation,
			&li, sizeof li) || !SetInformationJobObject(job,
			JobObjectBasicUIRestrictions, &ui, sizeof ui))
		return "the job object: "+error_text(GetLastError());

	// The capabilities the probes ran with
	WELL_KNOWN_SID_TYPE kinds[3] = {WinCapabilityInternetClientSid,
			WinCapabilityInternetClientServerSid,
			WinCapabilityPrivateNetworkClientServerSid};
	BYTE cap_sid[3][SECURITY_MAX_SID_SIZE];
	SID_AND_ATTRIBUTES caps[3];
	for(int i = 0; i < 3; i++){
		DWORD size = SECURITY_MAX_SID_SIZE;
		CreateWellKnownSid(kinds[i], nullptr, cap_sid[i], &size);
		caps[i].Sid = cap_sid[i];
		caps[i].Attributes = SE_GROUP_ENABLED;
	}
	SECURITY_CAPABILITIES sc = {};
	sc.AppContainerSid = g.sid;
	sc.Capabilities = caps;
	sc.CapabilityCount = 3;

	// What the child is handed: the settled paths, its temporary files'
	// place, and its output into a pipe this side reads into the log
	ss_ paths;
	for(int i = 0; PATH_KEYS[i]; i++)
		paths += ss_(PATH_KEYS[i])+"="+config.get<ss_>(PATH_KEYS[i])+"\n";
	SetEnvironmentVariableW(L"BUILDAT_BOXED_PATHS", wide(paths).c_str());
	// The child's start, step by step, where a buffer cannot hide it
	const ss_ steps = app_cache+"\\boxed_start.log";
	std::remove(steps.c_str());
	SetEnvironmentVariableW(L"BUILDAT_BOXED_STEPS", wide(steps).c_str());
	SetEnvironmentVariableW(L"TMP", wide(app_cache+"\\tmp").c_str());
	SetEnvironmentVariableW(L"TEMP", wide(app_cache+"\\tmp").c_str());
	SECURITY_ATTRIBUTES sa = {sizeof sa, nullptr, TRUE};
	HANDLE rd, wr;
	if(!CreatePipe(&rd, &wr, &sa, 0))
		return "a pipe: "+error_text(GetLastError());
	SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
	HANDLE nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ |
			FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, nullptr);

	STARTUPINFOEXW si = {};
	si.StartupInfo.cb = sizeof si;
	si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
	si.StartupInfo.hStdInput = nul;
	si.StartupInfo.hStdOutput = wr;
	si.StartupInfo.hStdError = wr;
	// Only these two handles go to the child, not every inheritable one
	HANDLE inherit[2] = {wr, nul};
	SIZE_T attr_size = 0;
	InitializeProcThreadAttributeList(nullptr, 2, 0, &attr_size);
	sv_<char> attr_buf(attr_size);
	si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)attr_buf.data();
	InitializeProcThreadAttributeList(si.lpAttributeList, 2, 0, &attr_size);
	UpdateProcThreadAttribute(si.lpAttributeList, 0,
			PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &sc, sizeof sc,
			nullptr, nullptr);
	UpdateProcThreadAttribute(si.lpAttributeList, 0,
			PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherit, sizeof inherit,
			nullptr, nullptr);
	std::wstring cmd = std::wstring(GetCommandLineW())+L" --boxed";
	PROCESS_INFORMATION pi = {};
	// Ctrl+C reaches the child on the console they share; this side waits
	SetConsoleCtrlHandler(nullptr, TRUE);
	BOOL ok = CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, TRUE,
			EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED, nullptr, nullptr,
			&si.StartupInfo, &pi);
	DeleteProcThreadAttributeList(si.lpAttributeList);
	CloseHandle(wr);
	CloseHandle(nul);
	if(!ok){
		CloseHandle(rd);
		return "starting the sandboxed server: "+error_text(GetLastError());
	}
	if(!AssignProcessToJobObject(job, pi.hProcess)){
		const ss_ why = error_text(GetLastError());
		TerminateProcess(pi.hProcess, 1);
		CloseHandle(rd);
		return "the job object: "+why;
	}
	ResumeThread(pi.hThread);
	CloseHandle(pi.hThread);
	log_i(MODULE, "Started the server in AppContainer buildat.%s, pid %i "
			"(this is %i); its start's steps go to %s", cs(app),
			(int)pi.dwProcessId, (int)GetCurrentProcessId(), cs(steps));

	char buf[4096];
	DWORD n;
	while(ReadFile(rd, buf, sizeof buf, &n, nullptr) && n > 0)
		log_raw(buf, n);
	CloseHandle(rd);
	WaitForSingleObject(pi.hProcess, INFINITE);
	DWORD code = 1;
	GetExitCodeProcess(pi.hProcess, &code);
	CloseHandle(pi.hProcess);
	// **Never a negative code**: the caller takes one as "no child", and
	// a child that died at its load (an NTSTATUS such as 0xC0000135 is
	// negative as an int) had the parent go on and run the app itself,
	// unboxed (2026-10-03, on the Windows box over SSH)
	if(code != 0)
		log_w(MODULE, "The sandboxed server exited with 0x%08lx", (unsigned long)code);
	// STATUS_DLL_INIT_FAILED: what the box dies with in session 0, where
	// an SSH login or a service runs and there is no desktop (2026-10-03)
	if(code == 0xC0000142)
		log_e(MODULE, "The sandbox could not start here: a server started with "
				"no desktop -- from a service or an SSH login -- cannot be "
				"sandboxed yet. Start it from a desktop session, or give "
				"--unconfined to run the app unsandboxed.");
	*exit_code = code == 0 ? 0 : (code < 256 ? (int)code : 1);
	return "";
}

}
#endif
// vim: set noet ts=4 sw=4:
