// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// Starport's ID page, included by main.cpp inside namespace starport
// ([SPLITS]: moved out as it was).

// [WEB_ID_TRUST] **Starport's own page**, the only place a web page logs a
// Starport ID in (the API refuses an ID call from another origin):
//   /authorize?listing=<id>[&address=<host:port>][&origin=<o>]  a web client
//     opens this in a window to sign in to a server: the ID logs in, says
//     Allow, and the token goes to the window that opened this by
//     postMessage -- only to the listed server's own web client, or a page
//     of the setting web_clients ("origin"), which the API checks.
//   /authorize?site=<id>  [STARPORT_SITE_LOGIN] the same for a website an
//     operator registered: the token goes to the site's origin only.
//   /id  the ID's settings, (b): its sessions and recent logins with "log
//     out everywhere else", the e-mail, the password, TOTP and the age.
// One page for both; the session is kept in this origin's storage.
// simplified: no password reset here (the client has it); TOTP's key is
// shown as text, no QR code; the age is changed without the client's PIN,
// which a browser does not have.

// [HTML_BRAND]: id_page() puts the shared sheet between these two, the
// page's own rules after it, and the logo at LOGO
static const char *id_page_head = R"PAGE(<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Starport ID</title>
<style>)PAGE";
static const char *id_page_html = R"PAGE(
body{max-width:34em}input{width:100%;box-sizing:border-box;margin:.2em 0}
button{min-width:7em;margin:.4em .5em .2em 0}.hide{display:none}
li{margin:.2em 0}label{display:block}
input[type=radio],input[type=checkbox]{width:auto}.yn>label{display:inline;
margin-right:1.5em}
</style></head><body>
<header><span class="brand">LOGO<span id="title">Starport ID</span></span>
</header>
<p id="what"></p>
<p id="err" role="alert"></p><p id="ok" role="status"></p>
<form id="login" class="hide">
<label>ID <input id="name" autocomplete="username" required></label>
<label>Password <input id="password" type="password"
 autocomplete="current-password" required></label>
<label id="totpl" class="hide">TOTP code <input id="totp"
 autocomplete="one-time-code" inputmode="numeric"></label>
<button>Log in</button>
<button type="button" id="toreg">Make an ID...</button>
</form>
<form id="register" class="hide">
<label>ID <input id="rname" autocomplete="username" required></label>
<label>Password <input id="rpassword" type="password"
 autocomplete="new-password" required></label>
<fieldset class="yn"><legend>Are you 18 or over?</legend>
<label><input type="radio" name="radult" id="ryes" required> Yes</label>
<label><input type="radio" name="radult" id="rno"> No</label>
<div id="rminor" class="hide">
<label>Your birth year <input id="ryear" inputmode="numeric"></label>
<p>Kept only until you turn 18.</p>
<label><input id="rconsent" type="checkbox"> Under 13: I have a
 parent's consent</label></div></fieldset>
<div><button>Make the ID</button><button type="button"
 id="tologin">Back</button></div>
</form>
<form id="allow" class="hide">
<p>Signed in as <b class="me"></b>.</p>
<label id="fleetl" class="hide">Your name on this server
 <input id="fleet"></label>
<button autofocus>Allow</button><button type="button" id="cancel">Cancel</button>
<button type="button" class="logout">Log out</button>
</form>
<div id="settings" class="hide">
<p>Signed in as <b class="me"></b>. <button type="button"
 class="logout">Log out</button></p>
<fieldset><legend>Sessions</legend><ul id="sessions"></ul>
<button type="button" id="others">Log out everywhere else</button>
<p>The last logins:</p><ul id="recent"></ul></fieldset>
<fieldset id="totpbox"><legend>TOTP</legend>
<p id="totpstate"></p><div id="totpkey" class="hide"></div>
<label id="ccodel">Code <input id="ccode" inputmode="numeric"
 autocomplete="one-time-code"></label>
<button type="button" id="totpgo"></button></fieldset>
<fieldset><legend>Recovery e-mail</legend>
<input id="email" type="email" autocomplete="email">
<button type="button" id="setemail">Set</button>
<div id="confirmbox" class="hide"><label>Code from the mail
 <input id="ecode"></label>
<button type="button" id="confirmemail">Confirm</button></div></fieldset>
<fieldset><legend>Password</legend>
<label>Old <input id="old" type="password" autocomplete="current-password">
</label><label>New <input id="new" type="password"
 autocomplete="new-password"></label>
<button type="button" id="setpw">Change</button></fieldset>
<fieldset><legend>Age</legend><p id="band"></p>
<div class="yn">Are you 18 or over?<br>
<label><input type="radio" name="sadult" id="syes"> Yes</label>
<label><input type="radio" name="sadult" id="sno"> No</label>
<div id="sminor" class="hide">
<label>Your birth year <input id="syear" inputmode="numeric"></label>
<p>Kept only until you turn 18.</p>
<label><input id="sconsent" type="checkbox"> Under 13: I have a
 parent's consent</label></div></div>
<button type="button" id="setage">Save</button></fieldset>
<p>With TOTP on, a change of the e-mail, the password or TOTP takes a
code: put it in TOTP's Code first.</p>
</div>
<script>
"use strict";
const authorize = location.pathname == "/authorize";
const q = new URLSearchParams(location.search);
const want = {listing: q.get("listing") || "", address: q.get("address") || "",
	origin: q.get("origin") || "", web: true};
if(q.get("site")) want.site = q.get("site");
// The server has an account of its own by this ID's name there: another
const rename = q.get("rename") == "1";
if(rename) want.rename = true;
const $ = id => document.getElementById(id);
let session = null, me = null, secret = "";
try { session = localStorage.getItem("buildat_sp_session"); } catch(e){}
function keep(s){
	session = s;
	try {
		if(s) localStorage.setItem("buildat_sp_session", s);
		else localStorage.removeItem("buildat_sp_session");
	} catch(e){}
}
async function call(what, body){
	const r = await fetch("/api/v1/id/" + what, {method: "POST",
		headers: {"Content-Type": "text/plain"}, body: JSON.stringify(body)});
	const v = await r.json();
	if(!v.ok) throw new Error(v.error);
	return v.result;
}
function show(id){
	for(const f of ["login", "register", "allow", "settings"])
		$(f).classList.toggle("hide", f != id);
	$("err").textContent = "";
}
function fail(e){
	if(e.message == "session"){ keep(null); show("login"); }
	$("err").textContent = e.message == "totp" ?
		"Put a code from your authenticator in TOTP's Code" : e.message || e;
	$("ok").textContent = "";
}
function done(t){ $("ok").textContent = t; $("err").textContent = ""; }
function when(x){
	return new Date(x.created * 1000).toLocaleString() + ", " + x.how +
		(x.address ? ", from " + x.address : "");
}
function list(ul, xs){
	ul.replaceChildren(...xs.map(x => {
		const li = document.createElement("li");
		li.textContent = when(x) + (x.this ? " (this one)" : "");
		return li;
	}));
}
async function signed_in(){
	me = await call("me", {session});
	for(const e of document.querySelectorAll(".me")) e.textContent = me.name;
	if(authorize){
		show("allow");
		if(rename){
			$("fleetl").firstChild.textContent = "The name you have on this "
				+ "server is taken there by an account of its own. Pick "
				+ "another: ";
			$("fleetl").classList.remove("hide");
			$("fleet").required = true;
			$("fleet").focus();
		} else {
			// [PLAYTEST_1008]: Enter allows
			$("allow").querySelector("button").focus();
		}
		return;
	}
	const s = await call("sessions", {session});
	list($("sessions"), s.sessions);
	list($("recent"), s.recent.slice().reverse());
	$("email").value = me.email_pending || me.email;
	$("confirmbox").classList.toggle("hide", !me.email_pending);
	$("band").textContent = "Now: " + me.band;
	$("totpstate").textContent = me.totp ? "On." : "Off.";
	$("totpgo").textContent = me.totp ? "Turn off" : secret ? "Turn on" :
		"Turn on...";
	$("ccodel").classList.toggle("hide", !me.totp && !secret);
	show("settings");
}
async function start(){
	if(authorize){
		$("title").textContent = "Sign in with a Starport ID";
		if(want.site)
			$("fleetl").firstChild.textContent = "Your name on this site ";
		if(!window.opener){
			$("what").textContent = want.site ? "Open this from the site's "
				+ "page." : "Open this from a Buildat web client.";
			return;
		}
		try {
			const i = await call("authorize_info", want);
			const b = document.createElement("b");
			b.textContent = i.name || (i.site ? "a website" : "a server");
			$("what").append(b, " at " + i.origin + " asks who you are. "
				+ "Allowing signs you in there, by the name you have on it.");
		} catch(e){ return fail(e); }
	}
	if(session){
		try { return await signed_in(); }
		catch(e){ if(e.message != "session") return fail(e); keep(null); }
	}
	show("login");
}
const act = f => async ev => {
	if(ev) ev.preventDefault();
	try { await f(); } catch(e){ fail(e); }
};
$("login").onsubmit = async ev => {
	ev.preventDefault();
	try {
		const r = await call("login", {name: $("name").value,
			password: $("password").value, totp: $("totp").value});
		keep(r.session);
		await signed_in();
	} catch(e){
		if(e.message == "totp"){
			$("totpl").classList.remove("hide");
			$("totp").focus();
			return;
		}
		fail(e);
	}
};
$("toreg").onclick = () => show("register");
$("tologin").onclick = () => show("login");
// [SP_AGE_FORM] The age as the client asks it: "18 or over?", and only a
// No asks the birth year, which a Yes never sends
for(const p of ["r", "s"])
	for(const yn of ["yes", "no"])
		$(p + yn).onchange = () => {
			$(p + "minor").classList.toggle("hide", !$(p + "no").checked);
			$(p + "year").required = $(p + "no").checked;
		};
function age(p){
	if($(p + "yes").checked)
		return {adult: true};
	if(!$(p + "no").checked)
		throw new Error("say whether you are 18 or over");
	return {birth_year: +$(p + "year").value, consent: $(p + "consent").checked};
}
$("register").onsubmit = act(async () => {
	const r = await call("register", Object.assign({name: $("rname").value,
		password: $("rpassword").value}, age("r")));
	keep(r.session);
	await signed_in();
});
$("allow").onsubmit = act(async () => {
	const r = await call("token", Object.assign({session,
		name: $("fleet").value}, want));
	if(r.need_name){
		$("fleetl").classList.remove("hide");
		if(!$("fleet").value) $("fleet").value = r.suggest;
		$("fleet").focus();
		return;
	}
	window.opener.postMessage({buildat_starport_token: r.token,
		name: r.name, listing: r.listing, site: r.site}, r.origin);
	window.close();
});
$("cancel").onclick = () => window.close();
for(const b of document.querySelectorAll(".logout"))
	b.onclick = async () => {
		try { await call("logout", {session}); } catch(e){}
		keep(null);
		show("login");
	};
const code = () => $("ccode").value;
$("others").onclick = act(async () => {
	const n = await call("logout_others", {session});
	await signed_in();
	done("Logged out of " + n + " other sessions");
});
$("totpgo").onclick = act(async () => {
	if(me.totp){
		await call("totp", {session, cmd: "off", code: code()});
		await signed_in();
		return done("TOTP is off");
	}
	if(!secret){
		const r = await call("totp", {session, cmd: "begin"});
		secret = r.secret;
		$("totpkey").textContent = "Add this key to an authenticator app, "
			+ "then put the code it shows in Code: " + r.secret;
		$("totpkey").classList.remove("hide");
		return signed_in();
	}
	await call("totp", {session, cmd: "confirm", code: code()});
	secret = "";
	$("totpkey").classList.add("hide");
	await signed_in();
	done("TOTP is on");
});
$("setemail").onclick = act(async () => {
	const r = await call("email", {session, email: $("email").value,
		totp: code()});
	await signed_in();
	done(r == "sent" ? "A code went to the address" : "Set");
});
$("confirmemail").onclick = act(async () => {
	await call("confirm_email", {session, code: $("ecode").value});
	await signed_in();
	done("Confirmed");
});
$("setpw").onclick = act(async () => {
	await call("password", {session, old: $("old").value,
		new: $("new").value, totp: code()});
	$("old").value = $("new").value = "";
	done("Password changed");
});
$("setage").onclick = act(async () => {
	await call("age", Object.assign({session}, age("s")));
	await signed_in();
	done("Saved");
});
start();
</script></body></html>
)PAGE";

static ss_ id_page()
{
	ss_ h = id_page_html;
	h.replace(h.find("LOGO"), 4, interface::web_brand::logo);
	return id_page_head+ss_(interface::web_brand::css)+h;
}
