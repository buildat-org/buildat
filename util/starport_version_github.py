#!/usr/bin/env python3
# [VERSION_CHECK]: Starport's version adapter for GitHub releases, the one
# the official instance uses. Copy it to <user>/apps/starport/version_adapter
# (executable); Starport runs it at the start and hourly and carries what it
# prints in /api/v1/list. It prints the newest release by its tag's number --
# the releases are listed, as GitHub's "latest" skips prereleases, and the
# older ones are prereleases:
#   {"version": "0.6.90", "url": <its page>,
#    "platforms": {"linux": {"url": ...}, "win64": {"url": ...}}}
# A platform's url is its archive (the Windows installer when there is
# one). GITHUB_REPO names another repository (owner/name).
import json, os, re, sys, urllib.request

repo = os.environ.get("GITHUB_REPO", "buildat-org/buildat")
req = urllib.request.Request(
		"https://api.github.com/repos/%s/releases?per_page=30" % repo,
		headers={"Accept": "application/vnd.github+json",
			"User-Agent": "buildat-starport"})
with urllib.request.urlopen(req, timeout=30) as r:
	releases = json.load(r)

def number(tag):
	m = re.match(r"v?(\d+(?:\.\d+)*)", tag or "")
	return m and m.group(1)

best = None
for rel in releases:
	v = number(rel.get("tag_name"))
	if rel.get("draft") or not v:
		continue
	if best is None or [int(x) for x in v.split(".")] > \
			[int(x) for x in best[0].split(".")]:
		best = (v, rel)
if best is None:
	sys.exit("no release with a version tag in " + repo)
v, rel = best
assets = {a["name"]: a["browser_download_url"] for a in rel.get("assets", [])}

def asset(*suffixes):
	for s in suffixes:
		for name, url in assets.items():
			if name.endswith(s):
				return {"url": url}

platforms = {"linux": asset("-linux-x86_64-portable.tar.gz"),
	"win64": asset("-win64-setup.exe", "-win64.zip")}
print(json.dumps({"version": v, "url": rel["html_url"],
	"platforms": {k: p for k, p in platforms.items() if p}}))
