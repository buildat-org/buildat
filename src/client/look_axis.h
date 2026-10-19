// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// The look command's aiming, one axis of it and its limits; included by
// app.cpp ([FILE_SPLITS_1019]: moved out as it was).

// The look command. How far off the camera may be left, how far it is allowed
// to be asked to turn in one frame, how much of a turn counts as having moved
// at all, how many frames of not moving mean the game does not do mouse look,
// and how many frames of trying mean it is not going to arrive. The first
// guess is only what the first step is taken with; the second step onwards
// uses what the first one actually did.
static const float LOOK_TOLERANCE_DEG = 0.4f;
static const float LOOK_MAX_STEP_DEG = 60.0f;
static const float LOOK_MOVED_DEG = 0.002f;
static const float LOOK_FIRST_GUESS_DEG_PER_PX = 0.15f;
static const int LOOK_FLIP_FRAMES = 4;
static const int LOOK_STILL_FRAMES = 30;
static const int LOOK_MAX_FRAMES = 300;
// And how an axis that is never going to arrive is told from one that is
// still on its way: how much closer it has to get to count as getting
// closer, and how many frames it may fail to. A pitch clamp answers every
// push away from it and none towards it, so the sign flipping above
// oscillates against one forever -- what settles it is that the error stops
// shrinking.
static const float LOOK_PROGRESS_DEG = 0.05f;
static const int LOOK_NO_PROGRESS_FRAMES = 30;

// One axis of the aiming loop: what it has learned about how a pixel of mouse
// movement turns this game's camera, and whether the camera has stopped
// answering it. Learning the sign from what a push actually did is what lets
// this work on a game whose mouse look runs the other way; a push that changes
// nothing, tried in both directions, is an axis against a limit of its own.
struct LookAxis
{
	float deg_per_px = LOOK_FIRST_GUESS_DEG_PER_PX;
	int pushed = 0;
	int stall = 0;
	int flips = 0;
	// How close this axis has been to where it is wanted, and for how many
	// frames it has not got closer: that is what says a clamped axis has
	// arrived as far as it ever will. The flips alone cannot -- a push away
	// from a limit moves, which clears them.
	float best_err = 1e9f;
	int no_progress = 0;
	bool stuck = false;
	bool moved_ever = false;

	// A new look command on the same client: what the axis has learned about
	// the game is still true, so only what is about this one command is
	// cleared. The second aim of a run then costs no frames finding the sign
	// again.
	void restart()
	{
		pushed = 0;
		stall = 0;
		flips = 0;
		best_err = 1e9f;
		no_progress = 0;
		stuck = false;
	}

	// Called once a frame with how far this axis still has to go
	void progress(float err)
	{
		const float e = fabsf(err);
		if(e < best_err - LOOK_PROGRESS_DEG){
			best_err = e;
			no_progress = 0;
			return;
		}
		if(++no_progress >= LOOK_NO_PROGRESS_FRAMES)
			stuck = true;
	}

	void observe(float delta)
	{
		if(pushed == 0)
			return;
		if(fabsf(delta) > LOOK_MOVED_DEG){
			deg_per_px = delta / (float)pushed;
			stall = 0;
			flips = 0;
			moved_ever = true;
			return;
		}
		// Not at once: a push takes a frame or two to come back around
		// through SDL and the game's own update
		if(++stall < LOOK_FLIP_FRAMES)
			return;
		stall = 0;
		deg_per_px = -deg_per_px;
		if(++flips >= 2)
			stuck = true;
	}
};
// vim: set noet ts=4 sw=4:
