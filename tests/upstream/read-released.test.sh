#!/usr/bin/env bash
#
# Tests for scripts/upstream/read-released.sh against a fake gh that behaves like
# the real one where it matters: `release download` refuses to overwrite an
# existing file unless --clobber is given.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/upstream/read-released.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
	"release list") printf '%s\n' "${FAKE_LATEST:-}" ;;
	"release download")
		clobber=0; out=""
		while [ $# -gt 0 ]; do
			case "$1" in --clobber) clobber=1 ;; --output) out="$2"; shift ;; esac
			shift
		done
		[ "${FAKE_NO_ASSET:-0}" = 0 ] || { echo "no assets match" >&2; exit 1; }
		if [ -e "$out" ] && [ "$clobber" = 0 ]; then echo "$out already exists (use --clobber)" >&2; exit 1; fi
		printf '%b' "${FAKE_COMPONENTS:-}" > "$out" ;;
	"release view")
		[ "${FAKE_VIEW_FAILS:-0}" = 0 ] || { echo "HTTP 502" >&2; exit 1; }
		[ "$3" = "${FAKE_LATEST:-}" ] || { echo "asked about $3" >&2; exit 1; }
		printf '%b' "${FAKE_ASSETS:-}" ;;
esac
GH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
# gh prints the tag name through --jq; the fake prints it directly.

out="$WORK/released"
FAKE_LATEST="" "$SCRIPT" "$out" >/dev/null 2>&1; rc=$?
check "no release yet: succeeds" 0 "$rc"
check "and leaves the file empty" 0 "$(wc -c < "$out")"

printf 'stale\n' > "$out"
FAKE_LATEST="v6.2.0+r2" FAKE_COMPONENTS='podman v6.2.0\nrecipe abc\n' "$SCRIPT" "$out" >/dev/null 2>&1; rc=$?
check "a release with components: succeeds even if the file already exists" 0 "$rc"
check "and holds the components of that release" "podman v6.2.0 recipe abc" "$(paste -sd' ' "$out")"

FAKE_LATEST="v6.2.0" FAKE_NO_ASSET=1 "$SCRIPT" "$out" >/dev/null 2>&1; rc=$?
check "a release whose components cannot be read fails" 1 "$rc"

FAKE_LATEST="v6.2.0" FAKE_COMPONENTS='recipe abc\n' "$SCRIPT" "$out" >/dev/null 2>&1; rc=$?
check "a components.txt without podman fails" 1 "$rc"

# --- the asset list, for whether the newest release carries a second signature -----
assets="$WORK/assets"
two='podman v6.2.0\nrecipe abc\n'
FAKE_LATEST="" "$SCRIPT" "$out" "$assets" >/dev/null 2>&1; rc=$?
check "no release yet, with an asset file: succeeds and leaves it empty" "0 0" "$rc $(wc -c < "$assets")"
printf 'stale.mldsa65.sig\n' > "$assets"
FAKE_LATEST="v6.2.0+r3" FAKE_COMPONENTS="$two" \
	FAKE_ASSETS='components.txt\npodman_6.2.0+r3_amd64.deb\npodman_6.2.0+r3_amd64.deb.mldsa65.sig\n' \
	"$SCRIPT" "$out" "$assets" >/dev/null 2>&1; rc=$?
check "a release: the asset file holds the names of its assets, and nothing older" \
	"0 components.txt podman_6.2.0+r3_amd64.deb podman_6.2.0+r3_amd64.deb.mldsa65.sig" "$rc $(paste -sd' ' "$assets")"
check "and the components are still written" "podman v6.2.0 recipe abc" "$(paste -sd' ' "$out")"
FAKE_LATEST="v6.2.0+r3" FAKE_COMPONENTS="$two" FAKE_VIEW_FAILS=1 "$SCRIPT" "$out" "$assets" 2>"$WORK/err" >/dev/null; rc=$?
check "an asset list that cannot be read fails, and says so" "1 1" "$rc $(grep -c 'cannot list the assets of release v6.2.0+r3' "$WORK/err")"
FAKE_LATEST="v6.2.0+r3" FAKE_COMPONENTS="$two" FAKE_ASSETS='' "$SCRIPT" "$out" "$assets" 2>"$WORK/err" >/dev/null; rc=$?
check "an empty asset list fails: it is not read as a release with no second signature" "1 1" \
	"$rc $(grep -c 'does not name components.txt' "$WORK/err")"
FAKE_LATEST="v6.2.0+r3" FAKE_COMPONENTS="$two" FAKE_VIEW_FAILS=1 "$SCRIPT" "$out" >/dev/null 2>&1; rc=$?
check "without an asset file, the assets are not asked for, as for the watchdog" 0 "$rc"

"$SCRIPT" >/dev/null 2>&1; check "no argument fails" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
