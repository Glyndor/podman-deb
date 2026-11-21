#!/usr/bin/env bash
#
# Tests for the controls of .github/workflows/release.yml that no script suite can
# see go: only main publishes, the second (ML-DSA-65) signature is required once its
# public key is committed, it is verified against that key and published, and the
# provenance attestation is made. The two steps that sign and publish are read from
# the workflow and run here, under the shell GitHub uses, with fakes for python and
# gh; the guard and the attestation are rules read from the workflow file, run once on
# the real file and once on a copy that breaks each of them.
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

# violations <rule> [workflow-dir]: prints one line per violation of a rule over
# release.yml. The directory is a parameter so a rule can run on a copy that breaks
# it. A rule that cannot run prints "rule failed", so a crash is never read as none.
violations() {
	python3 - "$1" "${2:-$HERE/.github/workflows}/release.yml" 2>&1 <<'PY' || echo "rule failed"
import re, sys, yaml

rule, path = sys.argv[1:3]
with open(path) as fh:
    jobs = yaml.safe_load(fh)["jobs"]
GUARD = "github.ref == 'refs/heads/main'"

if rule == "guard":
    # plan and publish always, and any other job that can write to the repository:
    # a dispatch from a branch must not tag or sign an unreviewed commit.
    needs = {"plan", "publish"}
    for name, cfg in jobs.items():
        perms = cfg.get("permissions") or {}
        if perms.get("contents") == "write" or perms.get("attestations") == "write":
            needs.add(name)
    for name in sorted(needs):
        if name not in jobs:
            print(f"job {name} is missing")
        elif str(jobs[name].get("if", "")).strip() != GUARD:
            print(f"job {name} does not carry the main-only guard")
elif rule == "attest":
    cfg = jobs["publish"]
    steps = cfg["steps"]
    perms = cfg.get("permissions") or {}
    for p in ("id-token", "attestations"):
        if perms.get(p) != "write":
            print(f"publish lacks {p}: write, which the attestation needs")
    hits = [i for i, s in enumerate(steps)
            if re.fullmatch(r"actions/attest-build-provenance@[0-9a-f]{40}", str(s.get("uses", "")))]
    if len(hits) != 1:
        print(f"{len(hits)} steps attest the build provenance, expected 1")
    else:
        i = hits[0]
        subject = str((steps[i].get("with") or {}).get("subject-path", ""))
        if not subject.endswith("/podman_*.deb"):
            print(f"the attestation subject is {subject!r}, not the .deb packages")
        signing = [n for n, s in enumerate(steps) if "GLYNDOR_RELEASE_ED25519_KEY" in str(s.get("env", ""))]
        create = [n for n, s in enumerate(steps) if s.get("name") == "Create the release"]
        if not signing or not create or not (signing[0] < i < create[0]):
            print("the attestation is not between signing and the release")
elif rule == "previous":
    # What the plan read about the newest release reaches the signing step as it was
    # read: a literal there would decide the downgrade rule for every run.
    want = "${{ steps.p.outputs.previous_mldsa }}"
    if str((jobs["plan"].get("outputs") or {}).get("previous_mldsa", "")) != want:
        print(f"plan does not hand on previous_mldsa as {want}")
    want = "${{ needs.plan.outputs.previous_mldsa }}"
    if str((jobs["publish"].get("env") or {}).get("PREVIOUS_MLDSA", "")) != want:
        print(f"publish does not take PREVIOUS_MLDSA from {want}")
PY
}

# sabotage <file> <old> <new> <dir>: a copy of the workflows in <dir> with <old>
# replaced by <new> exactly once. A replacement that changes nothing is reported, so
# a rule is never judged against a copy that still has the control in it.
sabotage() {
	rm -rf "$4"; mkdir -p "$4"; cp "$HERE"/.github/workflows/*.yml "$4/"
	python3 - "$4/$1" "$2" "$3" <<'PY' || echo "SABOTAGE INERT"
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
if text.count(old) != 1:
    sys.exit(f"{old!r} occurs {text.count(old)} times in {path}")
open(path, "w").write(text.replace(old, new))
PY
}

BAD="$WORK/bad"
GUARD_LINE="    if: github.ref == 'refs/heads/main'"

# --- only main publishes ----------------------------------------------------------
check "plan and publish carry the main-only guard" "" "$(violations guard)"
sabotage release.yml "$GUARD_LINE
    # ubuntu-latest" "    # ubuntu-latest" "$BAD" >/dev/null 2>&1
check "a plan without the guard is named" "job plan does not carry the main-only guard" "$(violations guard "$BAD")"
sabotage release.yml "    # from a branch.
$GUARD_LINE" "    # from a branch." "$BAD" >/dev/null 2>&1
check "a publish without the guard is named" "job publish does not carry the main-only guard" "$(violations guard "$BAD")"
sabotage release.yml "    # from a branch.
$GUARD_LINE" "    # from a branch.
    if: github.ref == 'refs/heads/develop'" "$BAD" >/dev/null 2>&1
check "a guard on another branch is named" "job publish does not carry the main-only guard" "$(violations guard "$BAD")"

# --- the provenance attestation ---------------------------------------------------
check "the packages are attested between signing and the release" "" "$(violations attest)"
sabotage release.yml "      - uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2
        with:
          subject-path: \${{ runner.temp }}/artifacts/podman_*.deb
" "" "$BAD" >/dev/null 2>&1
check "a release without the attestation step is named" "0 steps attest the build provenance, expected 1" "$(violations attest "$BAD")"
sabotage release.yml "subject-path: \${{ runner.temp }}/artifacts/podman_*.deb" "subject-path: \${{ runner.temp }}/artifacts/podman_*.deb.sig" "$BAD" >/dev/null 2>&1
check "an attestation of something other than the packages is named" \
	"the attestation subject is '\${{ runner.temp }}/artifacts/podman_*.deb.sig', not the .deb packages" "$(violations attest "$BAD")"
sabotage release.yml "      attestations: write
" "" "$BAD" >/dev/null 2>&1
check "a job that cannot write the attestation is named" "publish lacks attestations: write, which the attestation needs" "$(violations attest "$BAD")"

# --- what the plan read about the newest release reaches the signing step ---------
check "previous_mldsa goes from the plan to the signing step untouched" "" "$(violations previous)"
sabotage release.yml "PREVIOUS_MLDSA: \${{ needs.plan.outputs.previous_mldsa }}" "PREVIOUS_MLDSA: false" "$BAD" >/dev/null 2>&1
check "a literal in its place is named" "publish does not take PREVIOUS_MLDSA from \${{ needs.plan.outputs.previous_mldsa }}" \
	"$(violations previous "$BAD")"
sabotage release.yml "previous_mldsa: \${{ steps.p.outputs.previous_mldsa }}" "previous_mldsa: 'false'" "$BAD" >/dev/null 2>&1
check "and so is one in the plan's outputs" "plan does not hand on previous_mldsa as \${{ steps.p.outputs.previous_mldsa }}" \
	"$(violations previous "$BAD")"

# --- release.yml, publish: the step that signs, and the second signature ----------
# It is found by the secret it holds, and the other secret is given to it as the case
# needs. A python3 that makes a virtual environment whose python only writes down
# what it was asked stands in for the signing tools: this tests what the step asks of
# them, and the release-signing*.test.sh suites test what they do with it.
S="$WORK/sign"
if step release.yml publish secret=GLYNDOR_RELEASE_ED25519_KEY "$S"; then
	check "the signing step's run block has no expression in it" 0 "$(grep -c '\${{' "$S/run.sh")"
	mkdir -p "$S/bin"
	cat > "$S/venv-python" <<'PY'
#!/bin/sh
echo "$*" >> "$CALLS"
exit 0
PY
	cat > "$S/bin/python3" <<'PY'
#!/bin/sh
[ "$1 $2" = "-m venv" ] || exit 99
mkdir -p "$3/bin" && cp "$FAKE_PYTHON" "$3/bin/python" && chmod +x "$3/bin/python"
PY
	chmod +x "$S/venv-python" "$S/bin/python3"
	WS="$S/ws"
	ANCHOR="$WS/keyring/glyndor-release-mldsa65.b64"
	REL="$WS/.github/scripts/release"
	# The third argument is what the plan said about the newest release, false by default.
	sign() { # <anchor: empty|keyed|missing|indented|committed|cr|crlf|bom|tab|nul|high> <mldsa secret, may be empty> [previous]
		rm -rf "$S/art" "$S/rt" "$WS" "$S/calls" "$S/out"; mkdir -p "$S/art" "$WS/keyring"
		: > "$S/calls"; : > "$S/out"
		touch "$S/art/podman_6.2.0_arch1.deb" "$S/art/podman_6.2.0_arch2.deb"
		case "$1" in
			empty) printf '# Glyndor release ML-DSA-65 public keys.\n# Empty until the key exists.\n' > "$ANCHOR" ;;
			indented) printf '# Glyndor release ML-DSA-65 public keys.\n\n   # an indented comment\n  \n' > "$ANCHOR" ;;
			keyed) printf '# Glyndor release ML-DSA-65 public keys.\nAAAAAAAAAAAAAAAA\n' > "$ANCHOR" ;;
			missing) ;;
			committed) cp "$HERE/keyring/glyndor-release-mldsa65.b64" "$ANCHOR" ;;
			# What the verifier reads as a comment line and then a key line.
			cr) printf '# Glyndor release ML-DSA-65 public keys.\rAAAAAAAAAAAAAAAA\r' > "$ANCHOR" ;;
			crlf) printf '# Glyndor release ML-DSA-65 public keys.\r\nAAAAAAAAAAAAAAAA\r\n' > "$ANCHOR" ;;
			bom) printf '\357\273\277# Glyndor release ML-DSA-65 public keys.\n' > "$ANCHOR" ;;
			tab) printf '# Glyndor release ML-DSA-65 public keys.\n\t# a comment behind a tab\n' > "$ANCHOR" ;;
			# A NUL makes GNU grep read the file as binary, where its pattern matches
			# nothing, so a guard that matched lines let this one through.
			nul) printf '# Glyndor release ML-DSA-65 public keys.\000# behind a NUL\n' > "$ANCHOR" ;;
			high) printf '# Glyndor release ML-DSA-65 public keys.\n# \200 a byte past ASCII\n' > "$ANCHOR" ;;
		esac
		run_step "$S" "$S/art" PATH="$S/bin:$PATH" RUNNER_TEMP="$S/rt" GITHUB_WORKSPACE="$WS" \
			GITHUB_OUTPUT="$S/out" CALLS="$S/calls" FAKE_PYTHON="$S/venv-python" \
			GLYNDOR_RELEASE_ED25519_KEY=an-ed25519-seed GLYNDOR_RELEASE_MLDSA65_KEY="$2" PREVIOUS_MLDSA="${3-false}"
	}
	verify_line() { # <deb> [--require-mldsa]: the call the step must make for a package
		printf '%s/verify-sig.py %s %s.sig %s/keyring/glyndor-release-ed25519.b64 --mldsa-sig %s.mldsa65.sig --mldsa-keys %s%s' \
			"$REL" "$1" "$1" "$WS" "$1" "$ANCHOR" "${2:+ $2}"
	}
	calls() { grep -c -x -F -- "$1" "$S/calls"; }
	signed() { grep -c 'sign.py ' "$S/calls"; }

	for state in empty indented; do
		sign "$state" ""
		check "$state anchor, no secret: the packages go through" "0 true" "$rc $(grep -qx require_mldsa=false "$S/out" && echo true)"
		check "$state anchor, no secret: each package is verified against the anchor, with no requirement" \
			"1 1" "$(calls "$(verify_line podman_6.2.0_arch1.deb)") $(calls "$(verify_line podman_6.2.0_arch2.deb)")"
		check "$state anchor, no secret: each package is signed first" "2" "$(signed)"
	done
	sign keyed AAAA-a-seed
	check "a committed key and the secret: the packages go through" "0" "$rc"
	# The only install in the job that holds the signing keys: pinned by hash and binary
	# only, so no sdist builds and no tree is resolved beside the keys.
	check "and first the signing library is installed by hash, binary only, from sign-requirements.txt" "1 -m pip install" \
		"$(calls "-m pip install --quiet --require-hashes --only-binary=:all: -r $REL/sign-requirements.txt") $(head -n 1 "$S/calls" | cut -d' ' -f1-3)"
	check "and nothing else is installed" 1 "$(grep -c 'pip install' "$S/calls")"
	check "and each package is verified against the anchor with the second signature required" \
		"1 1" "$(calls "$(verify_line podman_6.2.0_arch1.deb --require-mldsa)") $(calls "$(verify_line podman_6.2.0_arch2.deb --require-mldsa)")"
	check "and the release is told it is required" 1 "$(grep -c -x require_mldsa=true "$S/out")"
	check "and nothing is verified that was not signed first" "sign verify sign verify" \
		"$(sed -n 's#^[^ ]*/\(sign\|verify-sig\)\.py .*#\1#p' "$S/calls" | sed 's/-sig//' | paste -sd' ')"
	sign keyed ""
	check "a committed key and no secret: refused" "1" "$rc"
	check "and it says the secret is what is missing" 1 "$(says 'holds a public key and GLYNDOR_RELEASE_MLDSA65_KEY is not configured')"
	check "and nothing is signed" 0 "$(signed)"
	sign empty a-seed
	check "a secret and no committed key: the second signature is still required of the verifier" \
		"0 1 1" "$rc $(calls "$(verify_line podman_6.2.0_arch1.deb --require-mldsa)") $(calls "$(verify_line podman_6.2.0_arch2.deb --require-mldsa)")"
	sign committed ""
	check "the anchor this repository commits, no secret: the packages go through" "0 2" "$rc $(signed)"
	# A carriage return is a line break to the verifier and not to this step, so a
	# key behind one would be a comment here and required of nobody.
	for state in cr crlf bom tab nul high; do
		sign "$state" ""
		check "an anchor with a byte outside printable ASCII and the line feed ($state), no secret: refused" "1" "$rc"
		check "$state: and it says which file and why" 1 "$(says 'holds a byte that is neither printable ASCII nor a line feed')"
		check "$state: and nothing is signed" 0 "$(signed)"
	done
	# --- once a release carries the second signature, the next one cannot drop it ---
	downgrade='the newest release carries an ML-DSA-65 signature and keyring/glyndor-release-mldsa65.b64 holds no key'
	for secret in "" a-seed; do
		sign empty "$secret" true
		check "the newest release signed twice, an emptied anchor, secret '${secret:-unset}': refused" "1" "$rc"
		check "and it says the anchor lost the key the last release was verified with" 1 "$(says "$downgrade")"
		check "and nothing is signed" 0 "$(signed)"
	done
	sign committed "" true
	check "the anchor as committed today, after a release signed twice: refused for the downgrade" "1 1" "$rc $(says "$downgrade")"
	sign keyed a-seed true
	check "the newest release signed twice, a key and the secret: the packages go through, both required" "0 1 1" \
		"$rc $(calls "$(verify_line podman_6.2.0_arch1.deb --require-mldsa)") $(grep -c -x require_mldsa=true "$S/out")"
	sign keyed "" true
	check "the newest release signed twice, a key and no secret: refused for the secret" "1 1 0" \
		"$rc $(says 'GLYNDOR_RELEASE_MLDSA65_KEY is not configured') $(says "$downgrade")"
	for previous in "" yes; do
		sign empty "" "$previous"
		check "a plan that says '${previous:-nothing}' about the newest release: refused, not read as no" "1 1 0" \
			"$rc $(says 'the plan did not say whether the newest release carries the second signature') $(signed)"
	done
	sign missing ""
	check "no anchor file at all: refused, not read as no key" "1" "$rc"
	check "and it says the anchor is missing" 1 "$(says 'is missing; refusing to publish')"
	check "and nothing is signed" 0 "$(signed)"
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the step that holds the signing key"
fi

# --- release.yml, publish: the step that creates the release ---------------------
R="$WORK/create"
if step release.yml publish "name=Create the release" "$R"; then
	check "the release step's run block has no expression in it" 0 "$(grep -c '\${{' "$R/run.sh")"
	mkdir -p "$R/bin"
	printf '#!/bin/sh\necho "$*" >> "$CALLS"\n' > "$R/bin/gh"
	chmod +x "$R/bin/gh"
	release() { # <REQUIRE_MLDSA, may be empty> <packages that have a second signature...>
		local require="$1"; shift
		rm -rf "$R/art" "$R/calls"; mkdir "$R/art"; : > "$R/calls"
		local i
		for i in 1 2; do : > "$R/art/podman_6.2.0_arch$i.deb"; : > "$R/art/podman_6.2.0_arch$i.deb.sig"; done
		for i in "$@"; do : > "$R/art/podman_6.2.0_arch$i.deb.mldsa65.sig"; done
		run_step "$R" "$R/art" PATH="$R/bin:$PATH" CALLS="$R/calls" TAG=v6.2.0+r2 GITHUB_SHA=abc123 \
			PODMAN=v6.2.0 NETAVARK=v2.1.0 AARDVARK=v2.1.3 RECIPE=r1 REQUIRE_MLDSA="$require" \
			GH_TOKEN=a-token GH_REPO=owner/repo
	}
	assets() { grep '^release create v6.2.0+r2 --target abc123 ' "$R/calls" | sed 's/.*before signing\. //'; }
	base="podman_6.2.0_arch1.deb podman_6.2.0_arch2.deb podman_6.2.0_arch1.deb.sig podman_6.2.0_arch2.deb.sig"

	release true 1 2
	check "a required second signature on every package: the release is created" "0 1" "$rc $(grep -c '^release create' "$R/calls")"
	check "and both second signatures are among its assets" \
		"$base podman_6.2.0_arch1.deb.mldsa65.sig podman_6.2.0_arch2.deb.mldsa65.sig components.txt" "$(assets)"
	check "and components.txt lists the four components the plan compares" "podman v6.2.0|netavark v2.1.0|aardvark-dns v2.1.3|recipe r1" \
		"$(paste -sd'|' "$R/art/components.txt")"
	release true 1
	check "a required second signature missing from one package: nothing is created" "1 0" "$rc $(grep -c '^release create' "$R/calls")"
	check "and it names the package" 1 "$(says 'podman_6.2.0_arch2.deb.mldsa65.sig is missing')"
	release true
	check "a required second signature missing from both: nothing is created" "1 0" "$rc $(grep -c '^release create' "$R/calls")"
	release false
	check "none required and none made: the release carries the assets it always has" "0 $base components.txt" "$rc $(assets)"
	release ""
	check "a step output that is empty requires nothing" "0 $base components.txt" "$rc $(assets)"
	release false 2
	check "none required but one made: it is published anyway" "0 $base podman_6.2.0_arch2.deb.mldsa65.sig components.txt" "$rc $(assets)"
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the step that creates the release"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
