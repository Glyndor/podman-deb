#!/usr/bin/env bash
#
# Write the components.txt of the newest published release to <out>. The plan
# compares it with what upstream has now, and a difference means "build".
#
# An empty file means this repository has no release yet. A release that exists
# but whose components cannot be read is an error, never an empty file: read as
# "nothing released" it makes every scheduled run build and publish another +rN,
# with nobody asking. That is what happened once: the file was created empty
# first and `gh release download` refuses to overwrite it, and the failure was
# swallowed.
#
# With <assets>, it also writes the names of that release's assets there, one per
# line, so the release can tell whether the newest one carries a second signature.
# The same rule holds: no release is an empty file, and a listing that cannot be
# read, or that does not even name components.txt, is an error. Read as "no
# assets" it would say the newest release carried no second signature, which is
# the answer that lets the next one leave without it.
#
# Needs gh and, as for gh itself, GH_TOKEN and GH_REPO (or a repository checkout).
#
# Usage: read-released.sh <out> [<assets>]

set -euo pipefail

out="${1:?out file}"
assets="${2:-}"

latest="$(gh release list --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName // empty')"
rm -f "$out"
[ -z "$assets" ] || rm -f "$assets"
if [ -z "$latest" ]; then
	: > "$out"
	[ -z "$assets" ] || : > "$assets"
	exit 0
fi

gh release download "$latest" --pattern components.txt --output "$out" --clobber \
	|| { echo "release $latest has no readable components.txt" >&2; exit 1; }
grep -q '^podman ' "$out" \
	|| { echo "components.txt of $latest names no podman version" >&2; exit 1; }

[ -n "$assets" ] || exit 0
gh release view "$latest" --json assets --jq '.assets[].name' > "$assets" \
	|| { echo "cannot list the assets of release $latest" >&2; exit 1; }
grep -qx 'components.txt' "$assets" \
	|| { echo "the asset list of release $latest does not name components.txt" >&2; exit 1; }
