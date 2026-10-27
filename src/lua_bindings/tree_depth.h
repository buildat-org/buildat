// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include <algorithm>

// How deep a Node or UIElement tree may be ([SANDBOX_TREE_DEPTH],
// [REPLICATE_TREE_DEPTH]): the engine recurses over a tree on the native
// stack (Clone, GetWorldPosition, Remove). client/core/urho3d/
// safe_classes.lua has the same number for what a script makes.
#define MAX_TREE_DEPTH 1024

namespace lua_bindings
{
	// How many levels t is below its root, counted up to limit + 1. A walk
	// up the parents.
	template<typename T>
	int tree_depth(T *t, int limit)
	{
		int depth = 0;
		for(T *p = t->GetParent(); p && depth <= limit; p = p->GetParent())
			depth++;
		return depth;
	}

	// How many levels there are under t, counted up to limit + 1: what t
	// moved under another adds to its depth. The recursion stops past
	// limit, so it is at most limit + 1 frames deep whatever the tree.
	template<typename T>
	int tree_height(T *t, int limit)
	{
		int h = 0;
		if(limit < 0)
			return 0;
		for(const auto &c : t->GetChildren()){
			h = std::max(h, 1 + tree_height(c.Get(), limit - 1));
			if(h > limit)
				break;
		}
		return h;
	}
}
// vim: set noet ts=4 sw=4:
