#!/usr/bin/env bash
#
# Tests for the plan step of .github/workflows/release.yml, read from the workflow and
# run here under the shell GitHub uses. What it hands the rest of the run is decided
# there and nowhere else: whether the newest release carries the second signature,
# which the signing step then refuses to drop. read-released.sh and plan-release.sh
# are the real scripts; latest-stable.sh and recipe-id.sh are fakes that answer
# fixed tags, and git and gh answer from the case instead of the network.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# shellcheck source=tests/lib/workflow-step.sh
. "$HERE/tests/lib/workflow-step.sh"

P="$WORK/plan"
if step release.yml plan "name=Decide whether a new release is needed" "$P"; then
	check "the plan step's run block has no expression in it" 0 "$(grep -c '\${{' "$P/run.sh")"
	WS="$P/ws"
	mkdir -p "$WS/scripts/upstream" "$WS/scripts/build" "$P/bin"
	cp "$HERE/scripts/upstream/read-released.sh" "$HERE/scripts/upstream/plan-release.sh" "$WS/scripts/upstream/"
	cat > "$WS/scripts/upstream/latest-stable.sh" <<'SH'
#!/bin/sh
case "$1" in
	*/podman.git) echo v6.2.0 ;;
	*/netavark.git) echo v2.1.0 ;;
	*/aardvark-dns.git) echo v2.1.3 ;;
esac
SH
	printf '#!/bin/sh\necho r1\n' > "$WS/scripts/build/recipe-id.sh"
	# git ls-remote: the tags of this repository from $TAGS, and the commit of an
	# upstream tag, which a component named in $LIGHTWEIGHT does not have.
	cat > "$P/bin/git" <<'GIT'
#!/usr/bin/env bash
[ "$1" = ls-remote ] || exit 1
if [ "$2" = --tags ]; then
	for t in ${TAGS:-}; do printf '0123abcd\trefs/tags/%s\n' "$t"; done
	exit 0
fi
c="${2##*/}"; c="${c%.git}"
case " ${LIGHTWEIGHT:-} " in *" $c "*) exit 0 ;; esac
printf 'c0ffee-%s\t%s\n' "$c" "$3"
GIT
	# gh: the newest release is $LATEST, its components.txt is $COMPONENTS and its
	# assets are $ASSETS; ASSETS_FAIL makes listing them fail.
	cat > "$P/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
	"release list") printf '%s\n' "${LATEST:-}" ;;
	"release download")
		while [ $# -gt 0 ]; do [ "$1" = --output ] && { printf '%b' "$COMPONENTS" > "$2"; exit 0; }; shift; done
		exit 1 ;;
	"release view") [ -z "${ASSETS_FAIL:-}" ] || exit 1; printf '%b' "${ASSETS:-}" ;;
	*) exit 1 ;;
esac
GH
	chmod +x "$P/bin/git" "$P/bin/gh"
	plan() { # [VAR=value]...: runs the step; sets $rc, $out and $P/out
		rm -rf "$P/rt"; mkdir "$P/rt"; : > "$P/out"
		run_step "$P" "$WS" PATH="$P/bin:$PATH" RUNNER_TEMP="$P/rt" GITHUB_OUTPUT="$P/out" \
			GH_TOKEN=a-token GH_REPO=owner/repo "$@"
	}
	said() { sed -n "s/^$1=//p" "$P/out" | paste -sd' '; }
	old='podman v6.1.0\nnetavark v2.1.0\naardvark-dns v2.1.3\nrecipe r1\n'
	ed='components.txt\npodman_6.1.0_amd64.deb\npodman_6.1.0_amd64.deb.sig\n'

	plan
	check "no release yet: a first release, and the newest carries no second signature" \
		"0 true v6.2.0 false" "$rc $(said build) $(said tag) $(said previous_mldsa)"
	plan LATEST=v6.1.0 TAGS=v6.1.0 COMPONENTS="$old" ASSETS="$ed"
	check "the newest release signed with Ed25519 alone: previous_mldsa=false" "0 false" "$rc $(said previous_mldsa)"
	plan LATEST=v6.1.0 TAGS=v6.1.0 COMPONENTS="$old" ASSETS="${ed}podman_6.1.0_amd64.deb.mldsa65.sig\n"
	check "the newest release signed twice: previous_mldsa=true" "0 true" "$rc $(said previous_mldsa)"
	check "and the rest of the plan is unchanged" "true v6.2.0 v6.2.0 c0ffee-podman" "$(said build) $(said tag) $(said podman) $(said podman_sha)"
	plan LATEST=v6.1.0 TAGS=v6.1.0 COMPONENTS="$old" ASSETS_FAIL=1
	check "an asset list that cannot be read stops the plan, and says nothing about the signature" "1 " \
		"$rc $(said previous_mldsa)"
	check "and it says which list" 1 "$(says 'cannot list the assets of release v6.1.0')"
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the plan step"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
