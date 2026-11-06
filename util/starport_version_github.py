#!/usr/bin/env python3
# [VERSION_CHECK]: Starport's version adapter for GitHub releases, the one
# the official instance uses. Copy it to <user>/apps/starport/version_adapter
# (executable); Starport runs it at the start and hourly and carries what it
# prints in /api/v1/list. It prints the newest stable release, and under
# "prerelease" the newest alpha ([ALPHA_BUILDS]), each by its tag's number:
#   {"version": "0.6.90", "url": <its page>,
#    "platforms": {"linux": {"url": ...}, "win64": {"url": ...}},
#    "prerelease": {"version": "0.7.0-alpha.3", "url": ..., "platforms": ...}}
# Stable is a tag v<major>.<minor>.<patch> not marked a prerelease, alpha a tag
# v<major>.<minor>.<patch>-alpha.<n>; the old v<version>-<hash> tags are
# neither. A platform's url is its archive (the Windows installer when there
# is one). GITHUB_REPO names another repository (owner/name); RELEASES_URL
# what is read instead of GitHub's list.
# simplified: the newest 100 releases, as a pruned alpha channel is five of
# them; 100 alphas in a row would read as "no stable release" and Starport
# keeps its last good answer. Walk the pages if pruning is ever dropped.
import json, os, re, sys, urllib.request

repo = os.environ.get("GITHUB_REPO", "buildat-org/buildat")
url = os.environ.get("RELEASES_URL",
		"https://api.github.com/repos/%s/releases?per_page=100" % repo)
req = urllib.request.Request(url,
		headers={"Accept": "application/vnd.github+json",
			"User-Agent": "buildat-starport"})
with urllib.request.urlopen(req, timeout=30) as r:
	releases = json.load(r)

def newest(pattern, take):
	best = None
	for rel in releases:
		m = re.fullmatch(pattern, rel.get("tag_name") or "")
		if rel.get("draft") or not m or not take(rel):
			continue
		key = [int(x) for x in m.groups()]
		if best is None or key > best[0]:
			best = (key, rel)
	return best and best[1]

def answer(rel):
	assets = {a["name"]: a["browser_download_url"]
			for a in rel.get("assets", [])}
	def asset(*suffixes):
		for s in suffixes:
			for name, url in assets.items():
				if name.endswith(s):
					return {"url": url}
	platforms = {"linux": asset("-linux-x86_64-portable.tar.gz"),
		"win64": asset("-win64-setup.exe", "-win64.zip")}
	return {"version": rel["tag_name"][1:], "url": rel["html_url"],
		"platforms": {k: p for k, p in platforms.items() if p}}

stable = newest(r"v(\d+)\.(\d+)\.(\d+)", lambda rel: not rel.get("prerelease"))
if stable is None:
	sys.exit("no stable release with a version tag in " + url)
out = answer(stable)
alpha = newest(r"v(\d+)\.(\d+)\.(\d+)-alpha\.(\d+)", lambda rel: True)
if alpha is not None:
	out["prerelease"] = answer(alpha)
print(json.dumps(out))
