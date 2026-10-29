// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// A scripted run's driver: the command sequence started, stepped a frame
// at a time, failed and finished, with the look and the click; included
// by app.cpp inside struct CApp ([FILE_SPLITS_1019]: moved out as it was).

	// A scripted run's command sequence parsed
	void start_command_seq()
	{
		if(g_client_config.get<bool>("command_seq_enabled")){
			ss_ text = g_client_config.get<ss_>("command_seq");
			ss_ err;
			if(!client::command_seq::parse(text, &m_commands, &err))
				throw AppStartupError("command sequence: "+err);
			m_command_seq_stdin =
					g_client_config.get<bool>("command_seq_stdin");
			m_command_seq_active = true;
			m_logical_w = m_options.graphics.window_w;
			m_logical_h = m_options.graphics.window_h;
			apply_ui_scale();
			apply_preferred_viewports();
			// Urho3D toggles fullscreen on alt+enter. A driven run injects
			// plenty of enters, and SDL's modifier state can have alt in it
			// from an alt+tab the window never saw the release of, which
			// then puts the window into fullscreen in the middle of a
			// sequence -- and a screen mode change loses what was uploaded
			// to the GPU by hand, so the world comes back black.
			GetSubsystem<magic::Input>()->SetToggleFullscreen(false);
			// **The first injected mouse motion of a run was swallowed**
			// and a scripted look started one command late: whatever
			// takes it, it takes what arrives in that first frame, so
			// the absorbing motion has to be a frame earlier than any
			// real one rather than pushed beside it. That is what
			// absorb_mouse_move_suppression() is for, and it had never
			// been called at all (2026-09-23).
			client::command_seq::absorb_mouse_move_suppression(
					GetSubsystem<magic::Input>());
			client::command_seq::inhibit_real_input(true);
			client::command_seq::show_window(GetSubsystem<magic::Graphics>(),
					GetSubsystem<magic::Input>());
			if(m_command_seq_stdin)
				log_i(MODULE, "Command sequence: reading stdin,"
						" will exit at end of input");
			else
				log_i(MODULE, "Command sequence: %zu commands,"
						" will exit when done", m_commands.size());
		}
	}

	void command_seq_fail(const ss_ &err)
	{
		log_e(MODULE, "Command sequence failed: %s", cs(err));
		m_command_seq_failed = true;
		m_command_seq_active = false;
		client::command_seq::inhibit_real_input(false);
		client::command_seq::release_held_keys();
		client::command_seq::release_forced_focus(
				GetSubsystem<magic::Input>());
		shutdown();
	}

	void command_seq_finish()
	{
		if(m_command_seq_failed)
			return;
		if(!m_command_seq_extra_frame){
			m_command_seq_extra_frame = true;
			return;
		}
		log_i(MODULE, "Command sequence complete");
		m_command_seq_active = false;
		client::command_seq::inhibit_real_input(false);
		client::command_seq::release_held_keys();
		client::command_seq::release_forced_focus(
				GetSubsystem<magic::Input>());
		shutdown();
	}

	// A scripted client never hides or captures the cursor: the Input
	// wrapper in client/core/urho3d/safe_classes.lua refuses those calls
	// while is_scripted(). Undoing a hide after the fact was what warped
	// the desktop cursor to the window's corner -- Urho's re-show restores
	// a position sampled while the cursor was hidden. See [SCRIPTED_CURSOR]
	// in doc/plan/miscellaneous_plan.md.

	// Where the camera of the first viewport points: yaw from +Z towards +X
	// and pitch upwards, both in degrees. False when there is no camera --
	// a game that has not made one yet, or a menu.
	bool camera_angles(float *yaw, float *pitch)
	{
		auto *renderer = GetSubsystem<magic::Renderer>();
		magic::Viewport *viewport = nullptr;
		// The game's viewports are on the offscreen texture under a render
		// scale or in logical mode, and the renderer then has none
		if(!m_preferred_viewports.empty())
			viewport = m_preferred_viewports[0];
		else if(renderer && renderer->GetNumViewports() >= 1)
			viewport = renderer->GetViewport(0);
		if(!viewport)
			return false;
		magic::Camera *camera = viewport->GetCamera();
		if(!camera || !camera->GetNode())
			return false;
		magic::Vector3 d = camera->GetNode()->GetWorldDirection();
		if(d.LengthSquared() < 1e-12f)
			return false;
		d.Normalize();
		*yaw = magic::Atan2(d.x_, d.z_);
		*pitch = magic::Asin(d.y_);
		return true;
	}

	static float wrap_degrees(float a)
	{
		while(a > 180.0f)
			a -= 360.0f;
		while(a < -180.0f)
			a += 360.0f;
		return a;
	}

	// How many pixels to ask for on one axis this frame. Never more than a
	// LOOK_MAX_STEP_DEG turn, because a game that smooths its mouse look
	// rings if it is asked to cross the sky at once, and never zero while
	// there is still an error to close, because a rounded-down step would
	// stall the loop short of the target.
	static int look_step_px(float err, float deg_per_px, float tolerance)
	{
		if(fabsf(err) <= tolerance)
			return 0;
		if(fabsf(deg_per_px) < 1e-6f)
			return err > 0.0f ? 1 : -1;
		float px = err / deg_per_px;
		float limit = LOOK_MAX_STEP_DEG / fabsf(deg_per_px);
		if(px > limit)
			px = limit;
		if(px < -limit)
			px = -limit;
		int i = (int)(px >= 0.0f ? px + 0.5f : px - 0.5f);
		if(i == 0)
			i = px >= 0.0f ? 1 : -1;
		return i;
	}

	// One frame of the look command. True when the camera has arrived; on
	// failure it calls command_seq_fail(), which shuts the client down.
	bool command_seq_look(const client::command_seq::Command &c)
	{
		float yaw = 0.0f, pitch = 0.0f;
		bool have = camera_angles(&yaw, &pitch);

		if(!m_look_running){
			m_look_running = true;
			m_look_frames = 0;
			m_look_no_camera_frames = 0;
			m_look_had_angles = false;
			m_look_x.restart();
			m_look_y.restart();
		}

		if(!have){
			// Nothing to steer by. A game that has not made its camera yet
			// gets a few frames; one that never does is not aimable.
			if(++m_look_no_camera_frames >= LOOK_STILL_FRAMES){
				m_look_running = false;
				command_seq_fail("look: there is no camera on viewport 0");
				return false;
			}
			m_look_had_angles = false;
			return false;
		}
		m_look_no_camera_frames = 0;

		// What the last frame's push did, which is the only thing here that
		// knows anything about the game running
		if(m_look_had_angles){
			m_look_x.observe(wrap_degrees(yaw - m_look_last_yaw));
			m_look_y.observe(pitch - m_look_last_pitch);
		}

		if(m_look_x.stuck && m_look_y.stuck &&
				!m_look_x.moved_ever && !m_look_y.moved_ever){
			m_look_running = false;
			command_seq_fail(ss_()+"look: the camera does not follow the "
					"mouse; it stayed at yaw "+ftos(yaw)+" pitch "+
					ftos(pitch)+" however it was pushed");
			return false;
		}

		// A game whose mouse look is coarse cannot be aimed finer than one
		// pixel of it, so the tolerance gives way to that rather than the
		// loop hunting for something it cannot hit
		float tol_x = fmaxf(LOOK_TOLERANCE_DEG,
				0.75f * fabsf(m_look_x.deg_per_px));
		float tol_y = fmaxf(LOOK_TOLERANCE_DEG,
				0.75f * fabsf(m_look_y.deg_per_px));
		float err_yaw = wrap_degrees((float)c.yaw - yaw);
		float err_pitch = (float)c.pitch - pitch;
		// Is each axis still getting closer? An axis against a limit is not,
		// however it is pushed, and that is what ends the command instead of
		// its frame budget.
		m_look_x.progress(err_yaw);
		m_look_y.progress(err_pitch);
		// An axis that has moved and then stopped answering in either
		// direction is against a limit the game keeps -- a pitch clamp, most
		// of the time -- and is as arrived as it is going to get
		bool done_x = fabsf(err_yaw) <= tol_x || m_look_x.stuck;
		bool done_y = fabsf(err_pitch) <= tol_y || m_look_y.stuck;
		if(done_x && done_y){
			m_look_running = false;
			if(fabsf(err_yaw) > tol_x || fabsf(err_pitch) > tol_y)
				log_w(MODULE, "look: the camera stops at yaw %.1f pitch %.1f; "
						"asked for yaw %.1f pitch %.1f",
						yaw, pitch, (float)c.yaw, (float)c.pitch);
			else
				log_v(MODULE, "look: arrived at yaw %.1f pitch %.1f in %i "
						"frames", yaw, pitch, m_look_frames);
			return true;
		}

		m_look_x.pushed = m_look_x.stuck ? 0 :
				look_step_px(err_yaw, m_look_x.deg_per_px, tol_x);
		m_look_y.pushed = m_look_y.stuck ? 0 :
				look_step_px(err_pitch, m_look_y.deg_per_px, tol_y);
		m_look_last_yaw = yaw;
		m_look_last_pitch = pitch;
		m_look_had_angles = true;

		log_v(MODULE, "look: at yaw %.2f pitch %.2f, pushing %i,%i at "
				"%.4f,%.4f deg/px", yaw, pitch,
				m_look_x.pushed, m_look_y.pushed,
				m_look_x.deg_per_px, m_look_y.deg_per_px);

		if(m_look_x.pushed != 0 || m_look_y.pushed != 0){
			ss_ err;
			if(!client::command_seq::inject_mouse_move(
					GetSubsystem<magic::Input>(),
					m_look_x.pushed, m_look_y.pushed, &err)){
				m_look_running = false;
				command_seq_fail(err);
				return false;
			}
		}

		if(++m_look_frames >= LOOK_MAX_FRAMES){
			m_look_running = false;
			command_seq_fail(ss_()+"look: the camera did not arrive in "+
					itos(LOOK_MAX_FRAMES)+" frames; it is at yaw "+
					ftos(yaw)+" pitch "+ftos(pitch)+" and was asked for yaw "+
					ftos((float)c.yaw)+" pitch "+ftos((float)c.pitch));
			return false;
		}
		return false;
	}

	// [SEQ_CLICK]: where `click` goes, in the pixels mouse_pos takes (the
	// scan's, ui_utils scan_pixels): the centre of the element of type
	// c.s, effectively visible, whose label matches c.param, and which
	// GetElementAt finds at that centre (it, a child of it, or, for an
	// element that takes no input, its parent) -- so nothing is over it.
	// Of several, the nearest the hint. None: *err lists every one of the
	// type and why it was left.
	bool command_seq_find_click(const client::command_seq::Command &c,
			int *out_x, int *out_y, ss_ *err)
	{
		magic::UI *ui = GetSubsystem<magic::UI>();
		magic::Graphics *g = GetSubsystem<magic::Graphics>();
		magic::UIElement *root = ui->GetRoot();
		int lw = logical_mode() ? m_logical_w : g->GetWidth();
		float k = (float)lw / (float)std::max(1, root->GetWidth());
		const ss_ &want = c.param;
		bool prefix = !want.empty() && want.back() == '*';
		ss_ want_s = prefix ? want.substr(0, want.size() - 1) : want;
		auto label_of = [](magic::UIElement *e) -> ss_ {
			if(auto *t = dynamic_cast<magic::Text*>(e))
				return t->GetText().CString();
			if(auto *l = dynamic_cast<magic::LineEdit*>(e))
				return l->GetText().CString();
			for(unsigned i = 0; i < e->GetNumChildren(); i++)
				if(auto *t = dynamic_cast<magic::Text*>(e->GetChild(i)))
					return t->GetText().CString();
			return "";
		};
		auto under = [](magic::UIElement *e, magic::UIElement *a){
			for(; e; e = e->GetParent())
				if(e == a)
					return true;
			return false;
		};
		magic::PODVector<magic::UIElement*> all;
		root->GetChildren(all, true);
		magic::PODVector<magic::UIElement*> modal;
		ui->GetRootModalElement()->GetChildren(modal, true);
		all += modal;
		ss_ why;
		magic::UIElement *best = nullptr;
		int64_t best_d = 0;
		int bx = 0, by = 0;
		for(magic::UIElement *e : all){
			if(ss_(e->GetTypeName().CString()) != c.s)
				continue;
			ss_ label = label_of(e);
			magic::IntVector2 ctr = e->GetScreenPosition() + e->GetSize() / 2;
			int x = (int)(ctr.x_ * k), y = (int)(ctr.y_ * k);
			ss_ rect = itos((int)(e->GetScreenPosition().x_ * k))+","+
					itos((int)(e->GetScreenPosition().y_ * k))+" size "+
					itos((int)(e->GetWidth() * k))+"x"+
					itos((int)(e->GetHeight() * k));
			ss_ left;
			if(prefix ? label.compare(0, want_s.size(), want_s) != 0 :
					label != want_s)
				left = "another label";
			else if(!e->IsVisibleEffective())
				left = "hidden";
			else {
				magic::UIElement *hit = ui->GetElementAt(ctr, true);
				if(!hit || !(under(hit, e) || (!e->IsEnabled() && under(e, hit))))
					left = ss_()+"covered by "+(hit ? ss_(
							hit->GetTypeName().CString())+" \""+label_of(hit)+
							"\" \""+hit->GetName().CString()+"\"" : "nothing that takes input");
			}
			why += "\n  "+c.s+" \""+label+"\" at "+rect+": "+
					(left.empty() ? "a candidate" : left);
			if(!left.empty())
				continue;
			int64_t dx = x - c.x, dy = y - c.y;
			int64_t d = c.n ? dx * dx + dy * dy : 0;
			if(best && d >= best_d)
				continue;
			best = e; best_d = d; bx = x; by = y;
		}
		if(!best){
			*err = "click: no visible, uncovered "+c.s+" \""+want+"\""+
					(why.empty() ? ss_("; none of that type") : why);
			return false;
		}
		log_v(MODULE, "click: %s at %i,%i%s", cs(c.s), bx, by, cs(why));
		*out_x = bx;
		*out_y = by;
		return true;
	}

	// [DRIVE_WAITS] What the client still has to do of its own, for idle:
	// "" when nothing. The mesh pool (the web's on this thread too), the
	// connection's (client::State::get_pending()), fetches not taken, and
	// whatever client Lua registered with buildat.idle_source()
	ss_ drive_pending()
	{
		ss_ r;
		auto add = [&](const ss_ &s){
			if(!s.empty())
				r += (r.empty() ? "" : ", ")+s;
		};
		if(size_t n = m_thread_pool->get_unfinished())
			add("pool tasks (meshes) "+itos((int)n));
		if(m_state)
			add(m_state->get_pending());
#ifdef __EMSCRIPTEN__
		int fetches = EM_ASM_INT({
			return Object.keys(Module['buildatHttp'] || {}).length; });
#else
		int fetches = (int)m_http_jobs.size();
#endif
		if(fetches)
			add("fetches "+itos(fetches));
		lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_idle_pending");
		if(lua_isnil(L, -1)){
			lua_pop(L, 1);
		} else {
			try {
				error_logging_pcall(L, 0, 1);
				add(lua_bindings::lua_tocppstring(L, -1));
				lua_pop(L, 1);
			} catch(std::exception &e){
				add(ss_("idle sources failed: ")+e.what());
			}
		}
		return r;
	}

	// A network:sync with the next number; the number, 0 with no server
	int64_t sync_send()
	{
		if(!m_state)
			return 0;
		m_state->send_packet("network:sync", itos(++m_sync_sent));
		return m_sync_sent;
	}

#ifdef __EMSCRIPTEN__
	// [DRIVE_WAITS] util/web_drive.js's frames, idle and sync steps, which
	// cannot run a command sequence ([SECURITY_RUN_1]): the frame count,
	// and when Module.buildatDriveAsk says so (1 idle, 2 sync) the pending
	// list in Module.buildatPending or a sync sent (Module.buildatSyncSent,
	// -1 with no server; the answered one in Module.buildatSynced)
	void web_drive_waits()
	{
		int ask = EM_ASM_INT({
			Module.buildatFrames = $0;
			var a = Module.buildatDriveAsk | 0;
			Module.buildatDriveAsk = 0;
			return a;
		}, (double)m_frame_count);
		if(ask & 1){
			const ss_ p = drive_pending();
			EM_ASM({ Module.buildatPending = UTF8ToString($0); }, p.c_str());
		}
		if(ask & 2){
			const int64_t n = sync_send();
			EM_ASM({ Module.buildatSyncSent = $0; }, n ? (double)n : -1.0);
		}
		if(m_state)
			EM_ASM({ Module.buildatSynced = $0; },
					(double)m_state->get_synced());
	}
#endif

	bool command_seq_exec(const client::command_seq::Command &c)
	{
		using client::command_seq::Type;
		magic::Input *input = GetSubsystem<magic::Input>();
		ss_ err;
		bool ok = true;
		switch(c.type){
		case Type::KeyDown:
			ok = client::command_seq::inject_key(input, c.s, true, false, &err);
			break;
		case Type::KeyUp:
			ok = client::command_seq::inject_key(input, c.s, false, false, &err);
			break;
		case Type::KeyPress:
			ok = client::command_seq::inject_key(input, c.s, true, true, &err);
			break;
		case Type::MousePos:
			ok = client::command_seq::inject_mouse_pos(input,
					logical_mode() ? (int)(m_logical_ox + c.x * m_logical_scale) : c.x,
					logical_mode() ? (int)(m_logical_oy + c.y * m_logical_scale) : c.y,
					&err);
			break;
		case Type::MouseMove:
			ok = client::command_seq::inject_mouse_move(input, c.x, c.y, &err);
			break;
		case Type::MouseDown:
			ok = client::command_seq::inject_mouse_button(
					input, c.x, true, false, &err);
			break;
		case Type::MouseUp:
			// **A hold nothing saw is not a hold** ([SEQ_HOLD_FRAME],
			// 2026-09-24): a client under llvmpipe in a container draws
			// about a frame a second, so the down and the up of a
			// 1.4-second hold landed in one SDL_PollEvent and the button
			// was never down on any frame a script could read. Whatever
			// polls GetMouseButtonDown -- the launcher room's dig and
			// its launch among them -- saw nothing at all. The up waits
			// for the frame that reads the down, bounded so a button
			// that never arrives ends the run instead of hanging it.
			if(client::command_seq::button_held_unseen(c.x)){
				if(++m_mouse_up_frames < 600)
					return false;
				log_w(MODULE, "mouse_up: the button was never read as "
						"down in 600 frames; letting go anyway");
			}
			m_mouse_up_frames = 0;
			ok = client::command_seq::inject_mouse_button(
					input, c.x, false, false, &err);
			break;
		case Type::MouseClick:
			ok = client::command_seq::inject_mouse_button(
					input, c.x, true, true, &err);
			break;
		case Type::Click:
			{
				int x, y;
				ok = command_seq_find_click(c, &x, &y, &err) &&
						client::command_seq::inject_mouse_pos(input,
						logical_mode() ? (int)(m_logical_ox + x * m_logical_scale) : x,
						logical_mode() ? (int)(m_logical_oy + y * m_logical_scale) : y,
						&err) &&
						client::command_seq::inject_mouse_button(
						input, SDL_BUTTON_LEFT, true, true, &err);
			}
			break;
		case Type::MouseWheel:
			ok = client::command_seq::inject_mouse_wheel(input, (int)c.n, &err);
			break;
		case Type::Tap:
		case Type::Finger:
			ok = client::command_seq::inject_finger(input, c.type == Type::Tap ?
					"tap" : c.param, (int)c.n,
					logical_mode() ? (int)(m_logical_ox + c.x * m_logical_scale) : c.x,
					logical_mode() ? (int)(m_logical_oy + c.y * m_logical_scale) : c.y,
					&err);
			break;
		case Type::Text:
			ok = client::command_seq::inject_text(input, c.s, &err);
			break;
		case Type::Event:
			{
				// Sent now, in the sequence's own frame; the receiver
				// answers in the log, which is what a test reads
				magic::VariantMap data;
				data["Param"] = magic::String(c.param.c_str());
				SendEvent(magic::StringHash(
						magic::String(("command_seq:"+c.s).c_str())), data);
			}
			break;
		case Type::Quit:
		case Type::Frames:
		case Type::Idle:
		case Type::Sync:
		case Type::Delay:
		case Type::Screenshot:
		case Type::Look:
		case Type::WaitLog:
		case Type::WaitLogAny:
		case Type::WaitLogAbsent:
		case Type::ExpectError:
			return true;
		}
		if(!ok)
			command_seq_fail(err);
		return ok;
	}

	// Whole lines that have arrived on standard input, parsed and appended.
	// A line that does not parse is reported and skipped rather than ending
	// the run: the other end is a person or a script that can try again.
	void command_seq_pump_stdin()
	{
		sv_<ss_> lines;
		bool eof = false;
		client::command_seq::read_stdin_lines(&lines, &eof);
		for(const ss_ &line : lines){
			ss_ err;
			sv_<client::command_seq::Command> parsed;
			if(!client::command_seq::parse(line, &parsed, &err)){
				log_w(MODULE, "command: %s", cs(err));
				continue;
			}
			for(const client::command_seq::Command &c : parsed)
				m_commands.push_back(c);
		}
		if(eof)
			m_command_seq_stdin_eof = true;
	}

	// **An unexpected error ends the run at once** ([CHECKS_EVENT_WAITS]):
	// an error line, or the connection dropping, fails a sequence read
	// from a file then and names the line, rather than at the next wait's
	// timeout. An error the drive declared with expect_error passes, once.
	// From the client's start to the start of its shutdown.
	bool command_seq_watch()
	{
		if(m_command_seq_stdin || m_shutdown_begun)
			return true;
		char buf[700];
		while(log_problem_after(&m_problems_seen, buf, sizeof buf)){
			const ss_ line = buf;
			const bool error = line.compare(0, 2, "E ") == 0;
			if(!error && line.find("Disconnected from server") == ss_::npos)
				continue;
			// The sequence's own failure line is not a new one
			if(line.find("Command sequence failed") != ss_::npos)
				continue;
			// A declared text covers each line with it from then on: a
			// provoked fault often logs the same error more than once
			bool expected = false;
			for(const ss_ &e : m_expected_errors)
				expected = expected || line.find(e) != ss_::npos;
			if(expected)
				continue;
			command_seq_fail("an error the drive did not expect: "+line);
			return false;
		}
		return true;
	}

	void command_seq_tick()
	{
		using client::command_seq::Type;
		if(!m_command_seq_active)
			return;
		// Declared before the watch looks: a drive's first lines can
		// expect an error of the client's start
		while(m_command_index < m_commands.size() &&
				m_commands[m_command_index].type == Type::ExpectError){
			log_i(MODULE, "command: %s", cs(client::command_seq::dump_command(
					m_commands[m_command_index])));
			m_expected_errors.push_back(m_commands[m_command_index].s);
			m_command_logged_index = (int)m_command_index;
			m_command_index++;
		}
		if(!command_seq_watch())
			return;
		client::command_seq::reassert_held_keys(GetSubsystem<magic::Input>());
		if(!m_pending_screenshot.empty())
			return;
		if(m_command_seq_stdin)
			command_seq_pump_stdin();
		int64_t now = get_timeofday_us();
		if(m_command_wait_until_us > now)
			return;

		while(m_command_index < m_commands.size()){
			const client::command_seq::Command &c =
					m_commands[m_command_index];
			if(m_command_logged_index != (int)m_command_index){
				m_command_logged_index = (int)m_command_index;
				log_i(MODULE, "command: %s",
						cs(client::command_seq::dump_command(c)));
			}
			if(c.type == Type::Delay){
				m_command_wait_until_us = now + c.n * 1000;
				m_command_index++;
				return;
			}
			if(c.type == Type::ExpectError){
				m_expected_errors.push_back(c.s);
				m_command_index++;
				continue;
			}
			if(c.type == Type::WaitLog || c.type == Type::WaitLogAny ||
					c.type == Type::WaitLogAbsent){
				if(m_wait_log_since < 0){
					// WaitLogAny looks back over the whole run; WaitLog
					// waits for the next line after it starts
					m_wait_log_since = c.type == Type::WaitLogAny ? 0 :
							log_line_count();
					m_wait_log_until_us = now + c.n * 1000;
					log_watch(c.s.c_str());
				}
				if(log_watch_seen() ||
						log_lines_since_contain(m_wait_log_since, c.s.c_str())){
					if(c.type == Type::WaitLogAbsent){
						m_wait_log_since = -1;
						command_seq_fail("wait_log_absent: \""+c.s+
								"\" was logged");
						return;
					}
					log_i(MODULE, "wait_log: \"%s\" seen", cs(c.s));
				} else if(now < m_wait_log_until_us){
					// **A wait says it is waiting**, every ten seconds:
					// a run that has stopped saying anything is how a
					// harness tells a stuck client from a patient one,
					// and a wait of two minutes was two minutes of
					// silence indistinguishable from a wedge
					// **Without the text it is waiting for**: the line
					// would otherwise be a line containing that text,
					// and the wait would see its own heartbeat and go
					// on (2026-09-24). The command's own line above
					// says what it waits for.
					if(now >= m_wait_log_said_us + 10000000){
						m_wait_log_said_us = now;
						log_i(MODULE, "wait_log: still waiting, %s s left",
								cs(itos((int)((m_wait_log_until_us - now) /
								1000000))));
					}
					return;
				} else if(c.type == Type::WaitLogAbsent){
					log_i(MODULE, "wait_log_absent: \"%s\" not seen in %s ms",
							cs(c.s), cs(itos(c.n)));
				} else if(!m_command_seq_stdin){
					// **A missed wait fails the run** ([CHECKS_EVENT_WAITS]):
					// going on had every later wait sit out its timeout
					m_wait_log_since = -1;
					command_seq_fail("wait_log: \""+c.s+"\" not seen in "+
							itos(c.n)+" ms");
					return;
				} else {
					log_w(MODULE, "wait_log: \"%s\" not seen in %s ms; on",
							cs(c.s), cs(itos(c.n)));
				}
				m_wait_log_since = -1;
				m_command_index++;
				continue;
			}
			// [DRIVE_WAITS]
			if(c.type == Type::Frames){
				if(m_frames_end < 0)
					m_frames_end = m_frame_count + c.n;
				if(m_frame_count < m_frames_end)
					return;
				m_frames_end = -1;
				m_command_index++;
				continue;
			}
			if(c.type == Type::Idle || c.type == Type::Sync){
				const bool idle = c.type == Type::Idle;
				const char *name = idle ? "idle" : "sync";
				if(m_drive_wait_until_us < 0){
					m_drive_wait_until_us = now + c.n * 1000;
					m_drive_wait_frame = m_frame_count;
					m_wait_log_said_us = now;
					if(!idle && !(m_sync_want = sync_send())){
						m_drive_wait_until_us = -1;
						command_seq_fail("sync: no server");
						return;
					}
				}
				// Idle from the next frame on: what the last command
				// injected is read in the frame after it
				ss_ left = idle ? (m_frame_count > m_drive_wait_frame ?
						drive_pending() : ss_("the frame after the last "
						"command")) : m_state->get_synced() >= m_sync_want ?
						ss_() : ss_("no answer");
				if(!left.empty() && now < m_drive_wait_until_us){
					if(now >= m_wait_log_said_us + 10000000){
						m_wait_log_said_us = now;
						log_i(MODULE, "%s: still waiting: %s", name, cs(left));
					}
					return;
				}
				m_drive_wait_until_us = -1;
				if(left.empty()){
					log_i(MODULE, "%s: %s", name, idle ?
							"nothing pending" : "answered");
				} else if(!m_command_seq_stdin){
					command_seq_fail(ss_(name)+": not in "+itos(c.n)+
							" ms: "+left);
					return;
				} else {
					log_w(MODULE, "%s: not in %s ms: %s; on", name,
							cs(itos(c.n)), cs(left));
				}
				m_command_index++;
				continue;
			}
			if(c.type == Type::Screenshot){
				m_pending_screenshot = c.s;
				m_command_index++;
				return;
			}
			if(c.type == Type::Look){
				// One step a frame, so that what the last one did can be
				// seen before the next one is decided
				if(!command_seq_look(c))
					return;
				m_command_index++;
				continue;
			}
			if(c.type == Type::Quit){
				m_command_index = m_commands.size();
				m_command_seq_stdin_eof = true;
				break;
			}
			if(!command_seq_exec(c))
				return;
			m_command_index++;
		}

		if(m_command_index >= m_commands.size() &&
				m_pending_screenshot.empty() &&
				m_command_wait_until_us <= now &&
				(!m_command_seq_stdin || m_command_seq_stdin_eof))
			command_seq_finish();
	}
// vim: set noet ts=4 sw=4:
