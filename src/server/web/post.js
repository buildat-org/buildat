// [WEB_LOCAL_AITTA_CPP] The engine's server for packages (local/_aitta/)
// running a release's own server .wasm, which Aitta linked from the same
// objects with the release's C++ modules in it: its EM_ASM code is this
// file's, at addresses moved by the release's own data. ?server=<shift>
// (the page's, from Aitta's check of the release's .js) moves them here,
// in the server's worker and in each of its threads' (whose script is
// this one, by the same URL).
(function(){
	var m = typeof self === 'object' && self.location &&
			/[?&]server=(-?[0-9]{1,9})(&|$)/.exec(self.location.search);
	if(!m || !+m[1])
		return;
	var old = ASM_CONSTS;
	ASM_CONSTS = {};
	for(var k in old)
		ASM_CONSTS[+k + +m[1]] = old[k];
})();
