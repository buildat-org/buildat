#!/bin/bash
# tier: quick
# cost: ~5s (2026-10-04)
# covers: src/server/confine.cpp src/server/rccpp.cpp
# [SECURITY_RUN_2] the box's compile reads: a module's C++ source is
# compiled by the server inside the Landlock box (confine.cpp). The box
# lets the compiler read the system (/usr /lib /bin /etc /opt /nix /proc
# /sys) and the app's own paths, and nothing else -- not /home, /root,
# /run, /var, /tmp. So a hostile app cannot make its compile read the
# user's files. This drives that: an app whose module #includes a file
# that exists outside the box must be refused by Landlock (EACCES,
# "Permission denied"), while a system path (/etc/hostname) is let
# through. A broken box would open the outside file and splice its bytes.
#
#   util/box_compile_reads.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/Build/bin/buildat_server"
[ -x "$b" ] || { echo "FAIL: no $b"; exit 1; }
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }

# A file that exists but is outside the box (/tmp is not in the allow-list
# and $t is not the module path). Its content is not valid C++, so if the
# box let the compiler open it the compile would error on the content
# rather than on not being allowed to read it.
secret="$t/secret_outside_the_box"
echo 'this is the user secret the box must not let the compiler read' > "$secret"

cp -r "$here/apps/sample_module_calls" "$t/app"
# Two #includes at the very top, before any real header: a system path the
# box allows, then the outside file it must deny.
{
	echo '#include "/etc/hostname"'
	echo "#include \"$secret\""
	cat "$t/app/test1/test1.cpp"
} > "$t/app/test1/test1.cpp.new"
mv "$t/app/test1/test1.cpp.new" "$t/app/test1/test1.cpp"

cd "$here/Build"
BUILDAT_UNCONFINED= timeout 120 "$b" --compile-only -u launcher=1 \
	-m "$t/app" -D "$t/user" > "$t/log" 2>&1
log=$(cat "$t/log")

# The outside file must be denied by Landlock, not opened
echo "$log" | grep -qF "$secret: Permission denied" ||
	fail "the sandbox did not deny the compiler reading $secret
$(echo "$log" | grep -aF "$secret")"
# And it must not have been opened and parsed (no diagnostic quoting its
# content or pointing a caret inside it)
echo "$log" | grep -qF 'user secret the box must not' &&
	fail "the compiler read the outside file's content"
# The system path is allowed: no denial for it (a broken allow-list that
# dropped /etc would show it here)
echo "$log" | grep -qE '/etc/hostname: (Permission denied|No such file)' &&
	fail "the sandbox denied a system path the compiler needs (/etc/hostname)"

echo "PASS: the sandbox denies the compiler the user's files, allows the system"
