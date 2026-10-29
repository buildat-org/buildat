// The web server before main() ([WEB_LOCAL_SERVER]): the engine's resource
// directories, which a headless server reads nothing from but which
// Urho3D's start requires; and under node, the BUILDAT_* environment
// (Emscripten's getenv() reads its own ENV, not the process's), and its
// SIGTERM and SIGINT stopping the server as the page does, by
// Module._buildat_server_stop() (src/server/main.cpp)
Module.preRun = Module.preRun || [];

// [WEBKIT_HC_SILENT] In a page, Emscripten's threads tell each other of
// work in their mailboxes by postMessage, not by Atomics.waitAsync: with
// it, in WebKit, the server's worker sometimes sat idle with work in its
// mailbox that no notify reached it for, and the threads waiting on the
// calls proxied there (a log line, a file) with it -- the server silent,
// one checkMailbox() from outside away from going on. Removed here,
// before the runtime, in the server's worker and in every thread's, in
// every browser: one path for all of them
if(typeof process !== 'object' && typeof Atomics === 'object')
	delete Atomics.waitAsync;

Module.preRun.push(function(){
	FS.mkdirTree('/urho/bin/CoreData');
	FS.mkdirTree('/urho/bin/Data');
	if(typeof process === 'object' && process.env){
		for(var k in process.env)
			if(k.indexOf('BUILDAT_') === 0)
				ENV[k] = process.env[k];
		// Asked twice, the shutdown is not getting anywhere: out, as natively
		var asked = false;
		['SIGTERM', 'SIGINT'].forEach(function(sig){
			process.on(sig, function(){
				if(asked)
					process.exit(1);
				asked = true;
				Module._buildat_server_stop();
			});
		});
	}
});

// **In a page** (src/client/web/index.html, ?local=<app>): this script is
// the page's worker, and its threads' (ENVIRONMENT_IS_PTHREAD, which this
// leaves alone). Its messages from the page, the only ones a dedicated
// worker gets: {op: 0, d: bytes}, {op: 1} (the client opened the stream),
// {op: 2} (closed it), {op: 'sync'} and {op: 'stop'}. To the page: {d:
// bytes}, {closed: 1} (the server dropped the client), {log: line} and,
// last, {exit: status}. The app's storage, /user, is kept in IndexedDB:
// read before main(), written every 5 s, when the page asks and at the
// end, as one instant's files (see below): what a crash leaves, which
// sqlite's WAL recovers. No event marks a finished save to wait for
// (core:save is the operator's save_now; voxelworld checkpoints on its own
// clock).
// simplified: two tabs of the same app write over each other's /user
if(ENVIRONMENT_IS_WORKER && !ENVIRONMENT_IS_PTHREAD &&
		typeof process !== 'object'){
	Module.arguments = ['--unconfined', '-l', '3', '-m', Module.buildatApp,
		'-S', '/buildat', '-U', '/urho', '-D', '/user', '-C', '/cache',
		// A local game: the page's player is in at once (hillclimb)
		'-u', 'launcher=1'];
	Module.print = function(t){ postMessage({log: t}); };
	// [WEB_LOCAL_AITTA] ?package=1 (local/_aitta/, the engine's server for
	// Aitta's packages): the app is the one the page sends, {op: 'files',
	// root, files: [[path under root, bytes], ...], wasm: [[name, bytes],
	// ...]}, written before main() runs it from root, the .wasm into /wasm
	var package_ = /[?&]package=1(&|$)/.test(self.location.search);
	// [WEB_LOCAL_AITTA_CPP] ?server=<shift> as well: the package's own
	// server .wasm (Aitta linked the engine's objects with its C++
	// modules), sent as {server: bytes} with the files, is run in place of
	// local/_aitta's own, by this script, whose imports Aitta checked it
	// takes no more of (post.js moves the EM_ASM addresses). Its /user is
	// its own app's directory only: the C++ reaches every file the server
	// can, so no other app's saves are in reach (the rest of /user is
	// memory, gone with the page).
	var own_server = package_ &&
			/[?&]server=-?[0-9]{1,9}(&|$)/.test(self.location.search);
	var instantiate = null;
	if(own_server)
		Module.instantiateWasm = function(imports, receive){
			instantiate = function(){
				instantiate = null;
				if(!(sent.server instanceof Uint8Array))
					return abort('no server .wasm was sent');
				WebAssembly.instantiate(sent.server, imports).then(function(r){
					receive(r.instance, r.module);
				}, function(e){
					abort('the package\'s server .wasm: ' + e);
				});
			};
			if(sent)
				instantiate();
			return {};
		};
	// [WEB_LOCAL_PLAYER_NAME] ?name=: the page's player's name, which
	// builtin/accounts' web stand-in gives the page's client
	var local_name = /[?&]name=([A-Za-z0-9_\-]{1,20})(&|$)/.exec(self.location.search);
	var sent = null, waiting = false;
	var put_files = function(){
		sent.files.forEach(function(f){
			var p = sent.root + '/' + f[0];
			FS.mkdirTree(p.substring(0, p.lastIndexOf('/')));
			FS.writeFile(p, f[1]);
		});
		FS.mkdirTree('/wasm');
		sent.wasm.forEach(function(f){ FS.writeFile('/wasm/' + f[0], f[1]); });
		// The array main() is given: changed in place
		var a = Module.arguments;
		a[a.indexOf('-m') + 1] = sent.root;
	};
	Module.printErr = Module.print;
	var syncing = false, again = false, after = [];
	var save = function(done){
		if(done)
			after.push(done);
		if(syncing){
			again = true;
			return;
		}
		syncing = true;
		again = false;
		FS.syncfs(false, function(err){
			syncing = false;
			if(err)
				postMessage({log: 'IndexedDB write: ' + err});
			if(again)
				return save();
			var a = after;
			after = [];
			a.forEach(function(f){ f(); });
		});
	};
	Module.preRun.push(function(){
		if(local_name)
			ENV.BUILDAT_LOCAL_NAME = local_name[1];
		// IDBFS's own write lists the files, waits for IndexedDB's list and
		// only then reads them, and a write between was half a save. Here
		// the listing and the reads are in one turn of this thread, where
		// the server's threads' file calls run (proxied), so none comes
		// between. The same in src/client/web/index.html.
		var idb = FS.filesystems.IDBFS, syncfs = idb.syncfs;
		idb.syncfs = function(m, populate, done){
			if(populate)
				return syncfs(m, populate, done);
			idb.getRemoteSet(m, function(err, remote){
				if(err)
					return done(err);
				idb.getLocalSet(m, function(err, local){
					if(err)
						return done(err);
					idb.reconcile(local, remote, done);
				});
			});
		};
		if(package_ && sent)
			put_files();
		else if(package_){
			waiting = true;
			addRunDependency('files');
		}
		var app = own_server && /^\/installed\/([A-Za-z0-9_]+)\/([A-Za-z0-9_]+)\//.exec(sent.root + '/');
		if(own_server && !app)
			return abort('not a package\'s root: ' + sent.root);
		var user = app ? '/user/apps/' + app[1] + '.' + app[2] : '/user';
		FS.mkdirTree(user);
		FS.mount(FS.filesystems.IDBFS, {}, user);
		addRunDependency('idbfs');
		FS.syncfs(true, function(err){
			if(err)
				postMessage({log: 'IndexedDB read: ' + err});
			removeRunDependency('idbfs');
		});
		setInterval(save, 5000);
	});
	// [WEB_NESTED_WORKER_HANG] The server's threads are the page's own
	// workers: Firefox's new Worker() in a worker sometimes never returns,
	// and the thread, and all that waits on it, with it. A thread's worker
	// here is a MessagePort, whose other end the page gives the worker it
	// makes ({thread: port, id}; {thread_end: id} terminates it). The
	// thread's side is below.
	// simplified: replaces Emscripten 3.1.60's PThread.allocateUnusedWorker,
	// whose callers use only postMessage, onmessage, onerror (the page's
	// worker's errors are the page's here) and terminate; on an upgrade
	// check that is still so, or drop this if the hang is gone
	Module.preRun.push(function(){
		if(typeof PThread !== 'object' ||
				typeof PThread.allocateUnusedWorker !== 'function' ||
				!Array.isArray(PThread.unusedWorkers))
			return abort('src/server/web/pre.js: not Emscripten 3.1.60\'s ' +
					'PThread, the page cannot make the server\'s threads');
		var next_thread = 0;
		PThread.allocateUnusedWorker = function(){
			var c = new MessageChannel(), id = ++next_thread;
			postMessage({thread: c.port2, id: id}, [c.port2]);
			c.port1.terminate = function(){
				c.port1.close();
				postMessage({thread_end: id});
			};
			PThread.unusedWorkers.push(c.port1);
		};
	});
	var ready = false, held = [];
	var take = function(m){
		if(m.op === 'stop')
			return Module._buildat_server_stop();
		if(m.op === 'sync')
			return save();
		var d = m.d || new Uint8Array(0);
		var p = Module._malloc(d.length + 1);
		HEAPU8.set(d, p);
		Module._buildat_stream_in(m.op, p, d.length);
		Module._free(p);
	};
	self.addEventListener('message', function(e){
		if(package_ && !sent && e.data && e.data.op === 'files'){
			sent = e.data;
			if(instantiate)
				instantiate();
			if(waiting){
				put_files();
				removeRunDependency('files');
			}
			return;
		}
		if(ready)
			take(e.data);
		else
			held.push(e.data);
	});
	Module.onRuntimeInitialized = function(){
		ready = true;
		held.forEach(take);
		held = [];
	};
	// Called by network_web.cpp when it has something for the page
	Module.buildatStreamOut = function(){
		for(;;){
			var n = Module._buildat_stream_take();
			if(n > 0){
				var p = Module._buildat_stream_taken();
				var d = HEAPU8.slice(p, p + n);
				postMessage({d: d}, [d.buffer]);
			} else if(n < 0){
				postMessage({closed: 1});
			} else {
				break;
			}
		}
	};
	Module.onExit = function(status){
		save(function(){ postMessage({exit: status}); });
	};
	Module.onAbort = function(what){
		postMessage({exit: 'aborted: ' + what});
	};
}

// [WEB_NESTED_WORKER_HANG] A thread's worker made by the page (above): its
// first message is the port to the server's worker, by which its messages
// go and come from there on, the ones coming given to Emscripten's handler
// as the worker's own
if(ENVIRONMENT_IS_PTHREAD && typeof process !== 'object'){
	var thread_port = null;
	self.addEventListener('message', function(e){
		if(thread_port || !(e.data && e.data.buildat_port))
			return;
		e.stopImmediatePropagation();
		thread_port = e.data.buildat_port;
		thread_port.onmessage = function(e){
			self.dispatchEvent(new MessageEvent('message', {data: e.data}));
		};
	});
	self.postMessage = function(m, t){ thread_port.postMessage(m, t); };
}
