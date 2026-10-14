// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// A zip reader over the raw deflate compress.h already has: the central
// directory at the end of the file names every entry, its method, its
// sizes and where its local header is; the local header's own name and
// extra field are skipped by their lengths and the entry's bytes follow.
// Enough for a ContentDB release or an exported world; not a zip library.
#include "interface/zip.h"
#include "interface/compress.h"
#include "interface/fs.h"
#include "core/log.h"
#include <fstream>
#include <sstream>
#include <cstring>
#include <zlib.h>
#define MODULE "zip"

namespace interface {

static uint32_t u16(const ss_ &d, size_t at)
{
	return (uint8_t)d[at] | ((uint8_t)d[at + 1] << 8);
}
static uint32_t u32(const ss_ &d, size_t at)
{
	return u16(d, at) | (u16(d, at + 2) << 16);
}

struct RawEntry {
	ZipEntry entry;
	uint32_t method = 0;
	uint32_t compressed_size = 0;
	uint32_t local_header_at = 0;
};

static ss_ read_file(const ss_ &path)
{
	std::ifstream f(path, std::ios::binary);
	if(!f.good())
		throw Exception("zip: cannot open "+path);
	std::stringstream ss;
	ss << f.rdbuf();
	return ss.str();
}

// The central directory, found from the end-of-central-directory record
// (signature 0x06054b50, at most 65535 bytes of comment after it)
static sv_<RawEntry> read_directory(const ss_ &d)
{
	if(d.size() < 22)
		throw Exception("zip: too short to be an archive");
	size_t eocd = ss_::npos;
	const size_t lowest = d.size() > 22 + 65535 ? d.size() - 22 - 65535 : 0;
	for(size_t i = d.size() - 22; ; i--){
		if(u32(d, i) == 0x06054b50){
			eocd = i;
			break;
		}
		if(i == lowest)
			break;
	}
	if(eocd == ss_::npos)
		throw Exception("zip: no end of central directory");
	const size_t n = u16(d, eocd + 10);
	size_t at = u32(d, eocd + 16);
	if(n == 0xffff || at == 0xffffffffu)
		throw Exception("zip: zip64 is not read");
	sv_<RawEntry> out;
	for(size_t i = 0; i < n; i++){
		if(at + 46 > d.size() || u32(d, at) != 0x02014b50)
			throw Exception("zip: central directory entry out of place");
		RawEntry e;
		const uint32_t flags = u16(d, at + 8);
		e.method = u16(d, at + 10);
		e.compressed_size = u32(d, at + 20);
		e.entry.size = u32(d, at + 24);
		const size_t name_len = u16(d, at + 28);
		const size_t extra_len = u16(d, at + 30);
		const size_t comment_len = u16(d, at + 32);
		e.local_header_at = u32(d, at + 42);
		if(at + 46 + name_len > d.size())
			throw Exception("zip: entry name runs past the end");
		e.entry.name = d.substr(at + 46, name_len);
		if(flags & 1)
			throw Exception("zip: "+e.entry.name+" is encrypted");
		if(e.method != 0 && e.method != 8)
			throw Exception("zip: "+e.entry.name+" uses method "+
					itos(e.method)+", not stored or deflate");
		out.push_back(e);
		at += 46 + name_len + extra_len + comment_len;
	}
	return out;
}

static ss_ entry_data(const ss_ &d, const RawEntry &e)
{
	const size_t h = e.local_header_at;
	if(h + 30 > d.size() || u32(d, h) != 0x04034b50)
		throw Exception("zip: "+e.entry.name+": local header out of place");
	const size_t start = h + 30 + u16(d, h + 26) + u16(d, h + 28);
	if(start + e.compressed_size > d.size())
		throw Exception("zip: "+e.entry.name+" runs past the end");
	const ss_ raw = d.substr(start, e.compressed_size);
	if(e.method == 0){
		if(raw.size() != e.entry.size)
			throw Exception("zip: "+e.entry.name+" is stored as "+
					itos(raw.size())+" bytes and says "+itos(e.entry.size));
		return raw;
	}
	std::istringstream is(raw, std::ios::binary);
	std::ostringstream os(std::ios::binary);
	// No more than the entry says it is: a few kilobytes of deflate made
	// gigabytes before the size below was compared ([SECURITY_RUN_1])
	decompress_deflate_raw(is, os, e.entry.size);
	ss_ out = os.str();
	if(out.size() != e.entry.size)
		throw Exception("zip: "+e.entry.name+" inflated to "+
				itos(out.size())+" bytes, not "+itos(e.entry.size));
	return out;
}

// A name that could not leave the directory it is put under: relative,
// '/'-separated, no "..", no drive letter, no NUL
static bool name_is_safe(const ss_ &name)
{
	if(name.empty() || name[0] == '/' || name[0] == '\\')
		return false;
	if(name.size() >= 2 && name[1] == ':')
		return false;
	if(name.find('\0') != ss_::npos || name.find('\\') != ss_::npos)
		return false;
	// Windows: a colon names a stream of a file (or a drive), and a
	// trailing dot or space is dropped from a segment, so ".. /" is ".."
	if(name.find(':') != ss_::npos)
		return false;
	size_t i = 0;
	while(i <= name.size()){
		size_t j = name.find('/', i);
		if(j == ss_::npos)
			j = name.size();
		const ss_ seg = name.substr(i, j - i);
		if(seg == ".." || (!seg.empty() &&
				(seg.back() == '.' || seg.back() == ' ')))
			return false;
		i = j + 1;
	}
	return true;
}

static void self_check(const ss_ &base);

sv_<ZipEntry> zip_list(const ss_ &zip_path)
{
	sv_<ZipEntry> out;
	for(const RawEntry &e : read_directory(read_file(zip_path)))
		out.push_back(e.entry);
	return out;
}

size_t zip_extract(const ss_ &zip_path, const ss_ &into_dir,
		uint64_t max_total)
{
	static bool checked = false;
	if(!checked){
		checked = true;
		// Beside the directory being extracted to, whose parent the caller
		// can write: a boxed server's working directory is not its own
		// (2026-10-03). Not in it: on Windows the check's files were left
		// there when deleting them raced whatever had them open, and the
		// archive then had three top-level entries instead of its one --
		// the game nested a level down, "no game called mineclone2"
		// ([CONTENTDB_FRESH], 0.6.0 on the box).
		fs::create_directories(into_dir);
		self_check(into_dir+".zip_self_check");
	}
	const ss_ d = read_file(zip_path);
	const sv_<RawEntry> entries = read_directory(d);
	// Every name checked before one byte is written, so a bad archive
	// leaves nothing half done
	// And what they come to, which a disk is filled with otherwise: 2 GiB
	// by default, past any game ContentDB has
	uint64_t total = 0;
	for(const RawEntry &e : entries){
		if(!name_is_safe(e.entry.name))
			throw Exception("zip: "+e.entry.name+" would leave the folder it "
					"unpacks to");
		total += e.entry.size;
	}
	if(total > max_total)
		throw Exception("zip: "+itos((int64_t)total)+" bytes unpacked is "
				"more than the "+itos((int64_t)max_total)+" there is room for");
	size_t files = 0;
	for(const RawEntry &e : entries){
		const ss_ path = into_dir+"/"+e.entry.name;
		if(!e.entry.name.empty() && e.entry.name.back() == '/'){
			fs::create_directories(path);
			continue;
		}
		fs::create_directories(fs::strip_file_name(path));
		const ss_ data = entry_data(d, e);
		std::ofstream f(path, std::ios::binary | std::ios::trunc);
		f.write(data.data(), data.size());
		if(!f.good())
			throw Exception("zip: could not write "+path);
		files++;
	}
	return files;
}

// One archive written by hand -- a directory, a stored file, a deflated
// file -- listed and extracted, and a name with ".." refused before
// anything lands
static void append_u16(ss_ &s, uint32_t v)
{
	s += (char)(v & 0xff); s += (char)((v >> 8) & 0xff);
}
static void append_u32(ss_ &s, uint32_t v)
{
	append_u16(s, v & 0xffff); append_u16(s, v >> 16);
}
void zip_write(const ss_ &zip_path, const sv_<std::pair<ss_, ss_>> &files)
{
	std::ofstream out(zip_path, std::ios::binary | std::ios::trunc);
	if(!out.good())
		throw Exception("zip: cannot write "+zip_path);
	ss_ dir;
	uint64_t at = 0;
	sv_<char> buf(1 << 20);
	for(const auto &f : files){
		std::ifstream in(f.second, std::ios::binary);
		if(!in.good())
			throw Exception("zip: cannot read "+f.second);
		in.seekg(0, std::ios::end);
		const uint64_t size = (uint64_t)in.tellg();
		in.seekg(0);
		if(size >= 0xffffffffu || at + size + 30 + f.first.size() >= 0xffffffffu)
			throw Exception("zip: "+f.second+" takes the archive past 4 GiB");
		// The CRC goes in the header before the data: a first read for it
		uLong crc = crc32(0, Z_NULL, 0);
		for(uint64_t left = size; left > 0; ){
			const size_t n = (size_t)std::min<uint64_t>(left, buf.size());
			in.read(buf.data(), n);
			if((size_t)in.gcount() != n)
				throw Exception("zip: "+f.second+" changed while read");
			crc = crc32(crc, (const Bytef*)buf.data(), n);
			left -= n;
		}
		ss_ local;
		append_u32(local, 0x04034b50); append_u16(local, 20);
		append_u16(local, 0); append_u16(local, 0);
		append_u32(local, 0); append_u32(local, crc);
		append_u32(local, size); append_u32(local, size);
		append_u16(local, f.first.size()); append_u16(local, 0);
		local += f.first;
		out.write(local.data(), local.size());
		in.clear();
		in.seekg(0);
		for(uint64_t left = size; left > 0; ){
			const size_t n = (size_t)std::min<uint64_t>(left, buf.size());
			in.read(buf.data(), n);
			if((size_t)in.gcount() != n)
				throw Exception("zip: "+f.second+" changed while read");
			out.write(buf.data(), n);
			left -= n;
		}
		ss_ c;
		append_u32(c, 0x02014b50); append_u16(c, 20); append_u16(c, 20);
		append_u16(c, 0); append_u16(c, 0);
		append_u32(c, 0); append_u32(c, crc);
		append_u32(c, size); append_u32(c, size);
		append_u16(c, f.first.size()); append_u16(c, 0); append_u16(c, 0);
		append_u16(c, 0); append_u16(c, 0); append_u32(c, 0);
		append_u32(c, at);
		dir += c + f.first;
		at += local.size() + size;
	}
	if(files.size() >= 0xffff || at + dir.size() >= 0xffffffffu)
		throw Exception("zip: more than an archive without zip64 holds");
	ss_ eocd;
	append_u32(eocd, 0x06054b50); append_u16(eocd, 0); append_u16(eocd, 0);
	append_u16(eocd, files.size()); append_u16(eocd, files.size());
	append_u32(eocd, dir.size()); append_u32(eocd, at);
	append_u16(eocd, 0);
	out.write(dir.data(), dir.size());
	out.write(eocd.data(), eocd.size());
	if(!out.good())
		throw Exception("zip: could not write "+zip_path);
}

static ss_ make_zip(const sv_<std::pair<ss_, ss_>> &files, bool deflate)
{
	ss_ body, dir;
	size_t n = 0;
	for(const auto &f : files){
		ss_ raw = f.second;
		if(deflate && !raw.empty()){
			std::ostringstream os(std::ios::binary);
			compress_deflate_raw(raw, os);
			raw = os.str();
		}
		const uint32_t method = (deflate && !f.second.empty()) ? 8 : 0;
		const uint32_t at = body.size();
		ss_ local;
		append_u32(local, 0x04034b50); append_u16(local, 20);
		append_u16(local, 0); append_u16(local, method);
		append_u32(local, 0); append_u32(local, 0);
		append_u32(local, raw.size()); append_u32(local, f.second.size());
		append_u16(local, f.first.size()); append_u16(local, 0);
		body += local + f.first + raw;
		ss_ c;
		append_u32(c, 0x02014b50); append_u16(c, 20); append_u16(c, 20);
		append_u16(c, 0); append_u16(c, method);
		append_u32(c, 0); append_u32(c, 0);
		append_u32(c, raw.size()); append_u32(c, f.second.size());
		append_u16(c, f.first.size()); append_u16(c, 0); append_u16(c, 0);
		append_u16(c, 0); append_u16(c, 0); append_u32(c, 0);
		append_u32(c, at);
		dir += c + f.first;
		n++;
	}
	ss_ eocd;
	append_u32(eocd, 0x06054b50); append_u16(eocd, 0); append_u16(eocd, 0);
	append_u16(eocd, n); append_u16(eocd, n);
	append_u32(eocd, dir.size()); append_u32(eocd, body.size());
	append_u16(eocd, 0);
	return body + dir + eocd;
}

static void self_check(const ss_ &base)
{
	const ss_ dir = base+".tmp";
	const ss_ zip = dir+".zip";
	sv_<std::pair<ss_, ss_>> files = {
		{"game/", ""},
		{"game/game.conf", "name = Test\n"},
		{"game/mods/a/init.lua", ss_(3000, 'x') + "\nprint(1)\n"},
	};
	for(int deflate = 0; deflate < 2; deflate++){
		{
			std::ofstream f(zip, std::ios::binary | std::ios::trunc);
			const ss_ d = make_zip(files, deflate != 0);
			f.write(d.data(), d.size());
		}
		sv_<ZipEntry> list = zip_list(zip);
		if(list.size() != 3 || list[2].name != "game/mods/a/init.lua" ||
				list[2].size != files[2].second.size())
			throw Exception("zip self_check: the listing is not the archive");
		if(zip_extract(zip, dir) != 2)
			throw Exception("zip self_check: two files should come out");
		if(read_file(dir+"/game/mods/a/init.lua") != files[2].second ||
				read_file(dir+"/game/game.conf") != files[1].second)
			throw Exception("zip self_check: a file came out changed");
	}
	// zip_write's archive reads back the same
	{
		const ss_ a = dir+".a", b = dir+".b";
		std::ofstream(a, std::ios::binary) << ss_(70000, 'q');
		std::ofstream(b, std::ios::binary) << "gameid = x\n";
		zip_write(zip, {{"w/save.sqlite", a}, {"w/world.mt", b}});
		if(zip_extract(zip, dir) != 2 ||
				read_file(dir+"/w/save.sqlite") != ss_(70000, 'q') ||
				read_file(dir+"/w/world.mt") != "gameid = x\n")
			throw Exception("zip self_check: zip_write's archive is not "
					"what went in");
		fs::remove_all(a);
		fs::remove_all(b);
	}
	{
		std::ofstream f(zip, std::ios::binary | std::ios::trunc);
		const ss_ d = make_zip({{"../escape.txt", "no"}}, false);
		f.write(d.data(), d.size());
	}
	bool refused = false;
	try {
		zip_extract(zip, dir);
	} catch(Exception &e){
		refused = true;
	}
	if(refused == false || fs::path_exists(fs::strip_file_name(dir)+"/escape.txt"))
		throw Exception("zip self_check: a name with .. must be refused");
	// What Windows makes ".." of, and a stream of a file; an absolute
	// name and a backslash (a separator on Windows) each leave the dir
	for(const char *bad : {".. /escape.txt", "a/... /x", "a:b.txt",
			"/abs.txt", "\\abs.txt", "a\\b.txt"}){
		if(name_is_safe(bad))
			throw Exception(ss_()+"zip self_check: \""+bad+"\" must be "
					"refused");
	}
	// An entry that says it is ten bytes and inflates to a hundred
	// kilobytes stops at ten
	{
		ss_ d = make_zip({{"bomb.txt", ss_(100000, 'z')}}, true);
		auto put_u32 = [&](size_t at, uint32_t v){
			for(int k = 0; k < 4; k++)
				d[at + k] = (char)((v >> (8 * k)) & 0xff);
		};
		put_u32(22, 10); // the local header's uncompressed size
		put_u32(d.find("PK\x01\x02") + 24, 10); // the directory's
		std::ofstream f(zip, std::ios::binary | std::ios::trunc);
		f.write(d.data(), d.size());
	}
	refused = false;
	try {
		zip_extract(zip, dir);
	} catch(Exception &e){
		refused = true;
	}
	if(!refused)
		throw Exception("zip self_check: an entry past its own size must be "
				"refused");
	fs::remove_all(dir);
	fs::remove_all(zip);
}

} // namespace interface
// vim: set noet ts=4 sw=4:
