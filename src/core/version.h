// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include <cstring>

// The VERSION file's number and the short git hash of the tree that was
// built ("-dirty" when it had uncommitted changes, "unknown" outside a
// checkout); see util/version.cmake ([VERSION])
extern const char *BUILDAT_VERSION;
extern const char *BUILDAT_GIT_HASH;
// [ALPHA_BUILDS] Whether a version is an alpha's: <major>.<minor>.<patch>-alpha.<n>.
// An old tag's hash suffix, or another pre-release, is not.
static inline bool buildat_version_is_alpha(const char *version)
{
	return strstr(version, "-alpha.") != nullptr;
}
