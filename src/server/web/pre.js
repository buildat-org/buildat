// The web server before main() ([WEB_LOCAL_SERVER]): the engine's resource
// directories, which a headless server reads nothing from but which
// Urho3D's start requires; and under node, the BUILDAT_* environment
// (Emscripten's getenv() reads its own ENV, not the process's)
Module.preRun = Module.preRun || [];
Module.preRun.push(function(){
	FS.mkdirTree('/urho/bin/CoreData');
	FS.mkdirTree('/urho/bin/Data');
	if(typeof process === 'object' && process.env){
		for(var k in process.env)
			if(k.indexOf('BUILDAT_') === 0)
				ENV[k] = process.env[k];
	}
});
