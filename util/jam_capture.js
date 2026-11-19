// [MUSIC_WEB_RING] util/jam_check.sh's capture, run in the page before its
// own scripts (web_drive's "init"): every node connected to an
// AudioContext's destination is also connected to a recorder (an
// AudioWorklet of that context), so what each context plays is captured
// on the audio thread whatever the page's thread does; nothing is played
// to a device more than the page would (the browser is muted anyway).
//   __cap.start(busy_ms) records from now, and makes each frame on the
//     page's thread busy_ms longer (0: no stall)
//   __cap.stop() -> {fps, stalls, stalled (the part of the time), recs:
//     [{rate, frames, rms}]}: the stall ended,
//     the loudest context's capture downloaded as music.wav (16 bits,
//     stereo)
(function(){
	var REC = "class R extends AudioWorkletProcessor {" +
		"constructor(){ super(); this.on = false; this.k = 0;" +
		" this.l = new Float32Array(16384); this.r = new Float32Array(16384);" +
		" var self = this; this.port.onmessage = function(e){" +
		"  self.on = e.data; if(!self.on){ self.flush(); self.port.postMessage('end'); } }; }" +
		"flush(){ if(this.k){ this.port.postMessage({l: this.l.slice(0, this.k)," +
		" r: this.r.slice(0, this.k)}); this.k = 0; } }" +
		"process(ins){ if(!this.on) return true; var i = ins[0];" +
		" var L = i && i.length ? i[0] : null, R = i && i.length > 1 ? i[1] : L;" +
		" for(var j = 0; j < 128; j++){ this.l[this.k] = L ? L[j] : 0;" +
		"  this.r[this.k] = R ? R[j] : 0; if(++this.k == 16384) this.flush(); }" +
		" return true; } }" +
		"registerProcessor('buildat-rec', R);";
	var url = URL.createObjectURL(new Blob([REC], {type: 'application/javascript'}));
	var orig = AudioNode.prototype.connect;
	var recs = [];
	function tap(ctx){
		if(!ctx.__rec){
			ctx.__rec = ctx.audioWorklet.addModule(url).then(function(){
				var n = new AudioWorkletNode(ctx, 'buildat-rec', {numberOfInputs: 1,
					numberOfOutputs: 1, outputChannelCount: [2], channelCount: 2,
					channelCountMode: 'explicit'});
				orig.call(n, ctx.destination);
				var rec = {ctx: ctx, node: n, chunks: [], ended: null};
				n.port.onmessage = function(e){
					if(e.data === 'end'){
						if(rec.ended) rec.ended();
					} else {
						rec.chunks.push(e.data);
					}
				};
				recs.push(rec);
				return n;
			});
		}
		return ctx.__rec;
	}
	AudioNode.prototype.connect = function(dest){
		var r = orig.apply(this, arguments);
		try {
			if(dest === this.context.destination && !this.__tapped){
				this.__tapped = true;
				var self = this;
				tap(this.context).then(function(n){ orig.call(self, n); });
			}
		} catch(e){
			console.log('jam capture: ' + e);
		}
		return r;
	};
	var frames = 0;
	(function f(){ frames++; requestAnimationFrame(f); })();
	var stall = null, f0 = 0, t0 = 0, stalls = 0, stalled = 0;
	function wav(rec){
		var n = 0;
		rec.chunks.forEach(function(c){ n += c.l.length; });
		var b = new DataView(new ArrayBuffer(44 + n * 4));
		var s = function(o, t){ for(var i = 0; i < t.length; i++) b.setUint8(o + i, t.charCodeAt(i)); };
		var rate = rec.ctx.sampleRate;
		s(0, 'RIFF'); b.setUint32(4, 36 + n * 4, true); s(8, 'WAVEfmt ');
		b.setUint32(16, 16, true); b.setUint16(20, 1, true); b.setUint16(22, 2, true);
		b.setUint32(24, rate, true); b.setUint32(28, rate * 4, true);
		b.setUint16(32, 4, true); b.setUint16(34, 16, true); s(36, 'data');
		b.setUint32(40, n * 4, true);
		var o = 44, sq = 0;
		rec.chunks.forEach(function(c){
			for(var i = 0; i < c.l.length; i++){
				var l = Math.max(-1, Math.min(1, c.l[i])), r = Math.max(-1, Math.min(1, c.r[i]));
				sq += l * l + r * r;
				b.setInt16(o, Math.round(l * 32767), true);
				b.setInt16(o + 2, Math.round(r * 32767), true);
				o += 4;
			}
		});
		return {blob: new Blob([b.buffer], {type: 'audio/wav'}), frames: n, rate: rate,
			rms: n ? Math.sqrt(sq / (2 * n)) : 0};
	}
	window.__cap = {
		start: function(busy){
			recs.forEach(function(r){ r.chunks = []; r.node.port.postMessage(true); });
			f0 = frames; t0 = performance.now();
			// each frame busy_ms longer
			stalls = 0;
			stalled = 0;
			stall = busy > 0;
			var go = function(){
				if(!stall)
					return;
				var t = performance.now();
				while(performance.now() - t < busy);
				stalls++;
				stalled += performance.now() - t;
				requestAnimationFrame(go);
			};
			requestAnimationFrame(go);
			return recs.length;
		},
		stop: function(){
			stall = false;
			var fps = (frames - f0) * 1000 / (performance.now() - t0);
			return Promise.all(recs.map(function(r){
				return new Promise(function(res){
					r.ended = res;
					r.node.port.postMessage(false);
				});
			})).then(function(){
				var out = [], loud = null;
				recs.forEach(function(r){
					var w = wav(r);
					if(!loud || w.rms > loud.rms)
						loud = w;
					out.push({rate: w.rate, frames: w.frames, rms: w.rms});
				});
				if(loud){
					var a = document.createElement('a');
					a.href = URL.createObjectURL(loud.blob);
					a.download = 'music.wav';
					document.body.appendChild(a);
					a.click();
				}
				return {fps: fps, stalls: stalls, stalled: stalled / (performance.now() - t0),
					recs: out};
			});
		},
	};
})();
