// A shim, not Luanti's: see README.txt.
//
// Luanti's settings, as much as a mapgen reads: it asks for its own noise
// parameters and flags, and what answers is the world's noises
// (luanti_mapgen::Params::noises) and nothing else -- the C++ defaults in
// the mapgen's own constructor are the rest. The other overrides are a
// later refinement; see "Mapgen stage 3" in doc/plan/luanti_module_plan.md.
#ifndef LUANTI_SHIM_SETTINGS_H
#define LUANTI_SHIM_SETTINGS_H
#include "irrlichttypes_bloated.h"
#include "util/string.h"
#include "exceptions.h"
#include "noise.h"
#include <string>
#include <map>
#include <optional>

class Settings
{
public:
	// The world's noises, by setting name (luanti_mapgen::Params::noises)
	std::map<std::string, NoiseParams> noises;
	bool getNoiseParams(const std::string &name, NoiseParams &np) const {
		auto it = noises.find(name);
		if(it == noises.end())
			return false;
		np = it->second;
		return true;
	}
	void setNoiseParams(const std::string &name, const NoiseParams &np){}

	std::string get(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	bool getNoEx(const std::string &name, std::string &val) const {
		return false;
	}
	bool getFlagStrNoEx(const std::string &name, u32 &val,
			const FlagDesc *flagdesc) const { return false; }
	s16 getS16(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	u16 getU16(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	s32 getS32(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	float getFloat(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	u64 getU64(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	bool getBool(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	bool getS16NoEx(const std::string &name, s16 &val) const { return false; }
	bool getU16NoEx(const std::string &name, u16 &val) const { return false; }
	bool getS32NoEx(const std::string &name, s32 &val) const { return false; }
	bool getFloatNoEx(const std::string &name, float &val) const {
		return false;
	}
	bool getU64NoEx(const std::string &name, u64 &val) const { return false; }
	bool getBoolNoEx(const std::string &name, bool &val) const {
		return false;
	}
	bool exists(const std::string &name) const { return false; }

	bool set(const std::string &name, const std::string &value){ return true; }
	bool setDefault(const std::string &name, const std::string &value){
		return true;
	}
	bool setS16(const std::string &name, s16 value){ return true; }
	bool setU16(const std::string &name, u16 value){ return true; }
	bool setS32(const std::string &name, s32 value){ return true; }
	bool setFloat(const std::string &name, float value){ return true; }
	bool setU64(const std::string &name, u64 value){ return true; }
	bool setBool(const std::string &name, bool value){ return true; }
	bool setFlagStr(const std::string &name, u32 flags,
			const FlagDesc *flagdesc, u32 flagmask = 0xffffffff){
		return true;
	}
	bool setV3F(const std::string &name, const v3f &value){ return true; }
	// Luanti's own answers an optional, which is what a mapgen checks
	bool getV3FNoEx(const std::string &name,
			std::optional<v3f> &value) const {
		return false;
	}
	// Luanti hands a flag table as a default, which is nothing to store
	bool setDefault(const std::string &name, const FlagDesc *flagdesc,
			u32 flags){ return true; }
	bool remove(const std::string &name){ return false; }
};

extern Settings *g_settings;

#endif
