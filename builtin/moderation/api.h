// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/json.h"
#include "interface/server.h"
#include "interface/module.h"
#include "storage/api.h"
#include "interface/sha256.h"
#include <functional>

// **Moderation** ([MODERATION_MODULE], from Starport's [STARPORT] 5 to 7):
// reports, their groups and weights, the queue, a moderator's decision, the
// audit log, the statements of reasons and the appeals, for any app. It
// knows nothing of what is moderated: a subject is an id the app gives, and
// the app is a Host whose callbacks say what a subject is and do the
// actions. Everything is in the app's save, in its stores "reports",
// "groups", "audit", "statements" and "appeals", each record JSON:
// - A report: {id, listing (the subject), reason, text, key, address, ts,
//   trusted, weight, group, state (open, held, upheld, rejected), held,
//   outcome, decided_at, ...the app's}. Its weight is the app's to give.
// - A group, the open reports of one subject and reason: {id, listing,
//   reason, reports, state (open, closed), opened, note, weight, auto,
//   decided, decided_by, decided_at, ...the app's}. Its weight is the sum of
//   its open reports' weights, the largest one per Host::bucket.
// - A statement, to the subject's owner: {id, ts, listing, listing_name,
//   action, reason, text, by, owner, appeal}; an appeal of one: {id,
//   statement, listing, by, acted_by, text, ts, state, outcome,
//   decided_by, answer}. Another moderator than the one who acted decides.
// The field is "listing" for any subject, as Starport's saves have it.
//
// The module holds no state: every call names its Host. The Host's
// callbacks run in this module's thread while the app waits in access(),
// so a callback that audits or states is handed the Interface to call
// directly; calling access() from one would be this module accessing
// itself.
namespace moderation
{
	struct Interface;

	struct Host
	{
		virtual storage::Save* save() = 0;
		// Who acts when nobody did, in the moderators' events: "Starport"
		virtual ss_ name() = 0;
		// {id, name, owner, players (how many it reaches)}, or undefined
		// when it has gone
		virtual json::Value subject(const ss_ &id) = 0;
		// The subjects a group is about
		virtual sv_<ss_> members(const json::Value &group) = 0;
		// How much a reason weighs in the queue's order
		virtual int severity(const ss_ &reason) = 0;
		// {hide, delist}: the weights past which a group's subjects are
		// hidden or delisted until a moderator looks; {} for never
		virtual json::Value thresholds(const json::Value &group) = 0;
		// Why a new report is held back (the reporter's standing), or ""
		virtual ss_ held(const json::Value &report) = 0;
		// Reports in one bucket count once in a group's weight: one per
		// network, say
		virtual ss_ bucket(const json::Value &report) = 0;
		// The automatic hide or delist of a subject; the subject after it,
		// or undefined for nothing done. The module audits and states it.
		virtual json::Value auto_act(const json::Value &group, const ss_ &id,
				const ss_ &want) = 0;
		// A moderator upheld a group: q is the request ({action, text,
		// days, ...}). Throws for a refusal, before anything is done.
		virtual void uphold(Interface *m, const ss_ &by,
				const json::Value &group, const json::Value &q) = 0;
		// A moderator dismissed a group: undo what was done automatically
		// to a subject; whether there was anything (it is audited as a
		// restore, else as a dismiss)
		virtual bool undo_auto(const ss_ &id, const json::Value &group) = 0;
		// An appeal decided "reverse"
		virtual void reverse(Interface *m, const ss_ &by,
				const json::Value &appeal, const ss_ &text) = 0;
		// A report decided: the reporter's record
		virtual void decided(const json::Value &report, bool upheld) = 0;
		// For the accounts and roles in `to`, by `by`
		virtual void event(const sv_<ss_> &to, const ss_ &by,
				const ss_ &text) = 0;
		// A statement made: mail it, where the app can
		virtual void notify(const json::Value &statement) = 0;
	};

	struct Interface
	{
		// A report, with its "group" set: put in the group, which is
		// opened with `fields` added where none is open. Its state is
		// "held" for spam (Host::held, or the same text as three others
		// today) where it has none.
		virtual void add_report(Host *h, json::Value report,
				const json::Value &fields) = 0;
		virtual json::Value open_group(Host *h, const ss_ &gid,
				const ss_ &subject, const ss_ &reason, const ss_ &note,
				const json::Value &fields) = 0;
		// `tell`: the moderators get an event of it
		virtual void audit(Host *h, const ss_ &by, const ss_ &subject,
				const ss_ &action, const ss_ &reason, const ss_ &text,
				bool automatic, bool tell = true) = 0;
		// To the owner of `subject` (Host::subject's): what was done, why,
		// how to appeal
		virtual void statement(Host *h, const json::Value &subject,
				const ss_ &action, const ss_ &reason, const ss_ &text,
				const ss_ &by) = 0;

		// The moderators' commands; a refusal throws
		// The open groups, the most urgent first
		virtual json::Value queue(Host *h) = 0;
		// The open groups' ids, from an index: their count without
		// queue()'s reading of each
		virtual sv_<ss_> open_groups(Host *h) = 0;
		// {group, reports (who reported left out), history}
		virtual json::Value group(Host *h, const ss_ &gid) = 0;
		// {group, decision (dismiss, uphold), ...the action's}
		virtual void decide(Host *h, const ss_ &by, const json::Value &q) = 0;
		// The latest 300 entries, newest first
		virtual json::Value audit_log(Host *h) = 0;
		// {statement, text} by its owner; the appeal's id
		virtual ss_ appeal(Host *h, const ss_ &by, const json::Value &q) = 0;
		// The open ones, each with its statement
		virtual json::Value appeals(Host *h) = 0;
		// {appeal, outcome (reverse, keep), text}
		virtual void decide_appeal(Host *h, const ss_ &by,
				const json::Value &q) = 0;
	};

	// **What both hosts answer alike** ([SECURITY_RUN_7], [REWORK_SWEEP_1019]
	// apps 5: Starport's and Aitta's copies had drifted). A reporter's key,
	// 64 hex digits, as a report keeps it: the sha256 of its bytes; legacy,
	// of its hex text, which Aitta's reports before 2026-10-20 carry.
	inline ss_ key_hash(const ss_ &key_hex, bool legacy = false)
	{
		using namespace interface::sha256;
		return hex(calculate(legacy ? key_hex : unhex(key_hex)));
	}

	// report_status: {key, receipts: [id...]} -> each of the key's reports'
	// {receipt, state, outcome}, at most a hundred looked up, from the
	// app's "reports" store; "" or what was wrong with the request. A
	// limit by address is the caller's.
	inline ss_ report_status(storage::Store *reports, const json::Value &b,
			json::Value &out)
	{
		const ss_ key = json::jstr(b, "key");
		if(!interface::sha256::is_hex(key, 64))
			return "key: 64 hex digits";
		const ss_ h = key_hash(key), old = key_hash(key, true);
		out = json::array();
		const json::Value &ids = b.get("receipts");
		for(unsigned i = 0; ids.is_array() && i < ids.size() && i < 100; i++){
			ss_ text;
			if(!ids.at(i).is_string() ||
					!reports->get(ids.at(i).as_string(), text))
				continue;
			const json::Value rep = json::load_string(text.c_str());
			const ss_ k = json::jstr(rep, "key");
			if(!rep.is_object() || k.empty() || (k != h && k != old))
				continue;
			json::Value o = json::object();
			o.set("receipt", json::jstr(rep, "id"));
			o.set("state", json::jstr(rep, "state"));
			o.set("outcome", json::jstr(rep, "outcome"));
			out.append(o);
		}
		return "";
	}

	// The moderators' commands both hosts have, by their names without
	// the host's prefix: queue, group, decide, audit, appeals,
	// decide_appeal. False for another; a host's own (Starport's group)
	// is answered before this is asked.
	inline bool moderator_command(Interface *m, Host *host,
			const ss_ &name, const ss_ &cmd, const json::Value &q,
			json::Value &out)
	{
		if(cmd == "queue")
			out = m->queue(host);
		else if(cmd == "group")
			out = m->group(host, json::jstr(q, "group"));
		else if(cmd == "decide"){
			m->decide(host, name, q);
			out = json::Value(true);
		} else if(cmd == "audit")
			out = m->audit_log(host);
		else if(cmd == "appeals")
			out = m->appeals(host);
		else if(cmd == "decide_appeal"){
			m->decide_appeal(host, name, q);
			out = json::Value(true);
		} else
			return false;
		return true;
	}

	inline bool access(interface::Server *server,
			std::function<void(moderation::Interface*)> cb)
	{
		return server->access_module("moderation", [&](interface::Module *module){
			cb((moderation::Interface*)module->check_interface());
		});
	}
}
// vim: set noet ts=4 sw=4:
