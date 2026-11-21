#!/usr/bin/env bash
#
# Tests that .github/scripts/release/sign-requirements.txt fixes every wheel the signing
# job installs. release.yml installs it with --require-hashes, which only holds when
# every requirement is one exact version with its sha256 hashes: pip refuses an
# unpinned line under that flag, but an option line (another index, a link to a URL,
# an editable install) changes where the bytes come from, and nothing reads them but
# this. The rule runs on the file as committed and on copies that break it one way each.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
REQ="$HERE/.github/scripts/release/sign-requirements.txt"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# loose <file>: one line per requirement that is not fixed to one version and its
# sha256 hashes, and per line that is not a requirement at all. A file that could
# not be read is a line too, never an empty answer.
loose() {
	python3 - "$1" <<'PY' 2>&1 || echo "rule failed"
import re, sys
text = open(sys.argv[1]).read()
# A requirement may continue over several lines with a backslash.
logical = re.sub(r"\\\n", " ", text).split("\n")
seen = 0
for line in logical:
    line = line.split(" #", 1)[0].strip()
    if not line or line.startswith("#"):
        continue
    seen += 1
    head, *opts = line.split()
    m = re.fullmatch(r"([A-Za-z0-9][A-Za-z0-9._-]*)==([0-9][A-Za-z0-9.+!-]*)", head)
    if not m:
        print(f"{head} is not one exact version")
        continue
    hashes = [o for o in opts if re.fullmatch(r"--hash=sha256:[0-9a-f]{64}", o)]
    others = [o for o in opts if o not in hashes]
    if not hashes:
        print(f"{m.group(1)} has no sha256 hash")
    for o in others:
        print(f"{m.group(1)} carries {o}, which is not a sha256 hash")
if not seen:
    print("no requirement in the file")
PY
}

check "every wheel the signing job installs is one exact version, pinned by sha256" "" "$(loose "$REQ")"
check "and the library that signs is among them" 1 "$(grep -c '^cryptography==' "$REQ")"

# One break per copy, the rest of the file as committed. A replacement that changes
# nothing is reported, so a rule is never judged against a copy that still holds.
bad() { # <old> <new>: writes $WORK/bad.txt with <old> replaced by <new> exactly once
	python3 - "$REQ" "$WORK/bad.txt" "$1" "$2" <<'PY' || echo "SABOTAGE INERT"
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
if t.count(old) != 1:
    sys.exit(f"{old!r} occurs {t.count(old)} times")
open(dst, "w").write(t.replace(old, new))
PY
}
pyc_hashes="$(sed -n '/^pycparser==/,$p' "$REQ")"
bad "cryptography==50.0.2" "cryptography>=50.0.2"
check "a version range is named" "cryptography>=50.0.2 is not one exact version" "$(loose "$WORK/bad.txt")"
bad "$pyc_hashes" "pycparser==3.12"
check "a requirement left without its hashes is named" "pycparser has no sha256 hash" "$(loose "$WORK/bad.txt")"
bad "--hash=sha256:a076f3f489b39b43" "--hash=md5:a076f3f489b39b43"
check "a hash that is not sha256 is named" "pycparser carries --hash=md5:a076f3f489b39b43ed13563a1dafe42447445bec2e294154ec5c57fcdda4c85e, which is not a sha256 hash" \
	"$(loose "$WORK/bad.txt")"
bad "cffi==2.1.1" "--extra-index-url https://example.test/simple
cffi==2.1.1"
check "an option line, such as another index, is named" "--extra-index-url is not one exact version" "$(loose "$WORK/bad.txt")"
bad "cryptography==50.0.2" "cryptography @ https://example.test/c.whl"
check "a link to a URL is named" "cryptography is not one exact version" "$(loose "$WORK/bad.txt")"
printf '# only a comment\n' > "$WORK/bad.txt"
check "a file with no requirement is a finding, not a pass" "no requirement in the file" "$(loose "$WORK/bad.txt")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
