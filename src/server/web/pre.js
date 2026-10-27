// The web server before main() ([WEB_LOCAL_SERVER]): the engine's resource
// directories, which a headless server reads nothing from but which
// Urho3D's start requires; and under node, the BUILDAT_* environment
// (Emscripten's getenv() reads its own ENV, not the process's), and its
// SIGTERM and SIGINT stopping the server as the page does, by
// Module._buildat_server_stop() (src/server/main.cpp)
Module.preRun = Module.preRun || [];
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
