// A shim, not Luanti's: see README.txt.
//
// Luanti's settings, as much as a mapgen reads: it asks for its own noise
// parameters and flags, and what answers is the world's noises
// (luanti_mapgen::Params::noises) and its other settings as world.mt's
// strings (Params::settings, [HEIGHTMAP_REST]: the NoEx getters) -- the
// C++ defaults in the mapgen's own constructor are the rest.
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
	// The world's other settings, by name (luanti_mapgen::Params::settings)
	std::map<std::string, std::string> values;
	// A number of the setting's, false when there is none or it is no
	// number
	template<typename T>
	bool number(const std::string &name, T &val) const {
		auto it = values.find(name);
		if(it == values.end())
			return false;
		try {
			val = (T)std::stod(it->second);
		} catch(std::exception &e){
			return false;
		}
		return true;
	}

	std::string get(const std::string &name) const {
		throw SettingNotFoundException("Setting ["+name+"] not found.");
	}
	bool getNoEx(const std::string &name, std::string &val) const {
		auto it = values.find(name);
		if(it == values.end())
			return false;
		val = it->second;
		return true;
	}
	// The flags named over the ones val has, as Luanti's own reads them
	bool getFlagStrNoEx(const std::string &name, u32 &val,
			const FlagDesc *flagdesc) const {
		auto it = values.find(name);
		if(it == values.end() || !flagdesc)
			return false;
		u32 mask = 0;
		const u32 flags = readFlagString(it->second, flagdesc, &mask);
		val = (val & ~mask) | flags;
		return true;
	}
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
	bool getS16NoEx(const std::string &name, s16 &val) const {
		return number(name, val);
	}
	bool getU16NoEx(const std::string &name, u16 &val) const {
		return number(name, val);
	}
	bool getS32NoEx(const std::string &name, s32 &val) const {
		return number(name, val);
	}
	bool getFloatNoEx(const std::string &name, float &val) const {
		return number(name, val);
	}
	bool getU64NoEx(const std::string &name, u64 &val) const {
		return number(name, val);
	}
	bool getBoolNoEx(const std::string &name, bool &val) const {
		auto it = values.find(name);
		if(it == values.end())
			return false;
		val = it->second == "true" || it->second == "yes" ||
				it->second == "1";
		return true;
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
