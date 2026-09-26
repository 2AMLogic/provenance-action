#!/usr/bin/env bash
# Asserts render.sh against tests/vectors.json byte-for-byte, plus the
# validation, injection, hasher and build-state failures. Needs bash (3.2+),
# jq, git, and sha256sum or shasum. render.sh is driven directly through the
# environment (PA_* inputs, GITHUB_* context), which is the script's
# interface, not the action's.
set -euo pipefail
cd "$(dirname "$0")/.."
V=tests/vectors.json
SHA=0123456789abcdef0123456789abcdef01234567
pass=0 fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

printf 'render.sh runs under bash %s\n\n' "$(env bash -c 'echo "$BASH_VERSION"')"

ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# RPATH is the PATH render.sh sees; tests narrow it to control the tools.
RPATH=$PATH

# render VAR=VALUE... : run render.sh in a clean env; stdout, stderr,
# GITHUB_OUTPUT and GITHUB_ENV go to $tmp/{out,err,gh_output,gh_env}.
render() {
  : >"$tmp/gh_output"; : >"$tmp/gh_env"
  env -i PATH="$RPATH" GITHUB_OUTPUT="$tmp/gh_output" GITHUB_ENV="$tmp/gh_env" "$@" \
    ./render.sh >"$tmp/out" 2>"$tmp/err"
}
expect_eq() { # name expected actual
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1"; printf '  expected: %s\n  actual:   %s\n' "$2" "$3"; fi
}
expect_fail() { # name pattern VAR=VALUE...
  local name=$1 pat=$2; shift 2
  if render "$@"; then bad "$name (exit 0)"; return; fi
  if [[ -s $tmp/out || -s $tmp/gh_output || -s $tmp/gh_env ]]; then bad "$name (emitted output on failure)"; return; fi
  if grep -q -- "$pat" "$tmp/err"; then ok "$name"; else bad "$name (want '$pat', stderr: $(cat "$tmp/err"))"; fi
}
# check_gh_output name trailers marker trace : $tmp/gh_output with a random
# PROVENANCE_EOF_<32 hex> heredoc delimiter.
check_gh_output() {
  local name=$1 first delim
  first=$(head -n 1 "$tmp/gh_output")
  if [[ ! $first =~ ^trailers\<\<(PROVENANCE_EOF_[0-9a-f]{32})$ ]]; then
    bad "$name (delimiter line: $first)"; return
  fi
  delim=${BASH_REMATCH[1]}
  expect_eq "$name" "trailers<<$delim
$2
$delim
marker=$3
trace-id=$4" "$(cat "$tmp/gh_output")"
}
# mkbin DIR TOOL... : DIR holding symlinks to the named tools only.
mkbin() {
  local dir=$1 t; shift
  mkdir -p "$dir"
  for t in "$@"; do ln -sf "$(command -v "$t")" "$dir/$t"; done
}

# --- D32 v1 vectors (same-repo story: key is the run's repository id) -------
run_vectors() { # label
  local label=$1 n i story repo_id want repo run_id attempt
  n=$(jq '.d32.vectors | length' "$V")
  for ((i = 0; i < n; i++)); do
    story=$(jq -r ".d32.vectors[$i].story" "$V")
    repo_id=$(jq -r ".d32.vectors[$i].repo_id" "$V")
    want=$(jq -r ".d32.vectors[$i].trace_id" "$V")
    repo=${story%#*}
    render PA_STORY="$story" GITHUB_REPOSITORY="$repo" GITHUB_REPOSITORY_ID="$repo_id" \
      GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=2 GITHUB_SHA="$SHA" PA_BUILD_VERSION=1.2.3 \
      || { bad "$label d32 $story: $(cat "$tmp/err")"; continue; }
    expect_eq "$label d32 trailers $story" \
"Loom-Story: $story
Loom-Trace-Id: $want
Loom-Build: 1.2.3 $SHA unknown" "$(head -n 3 "$tmp/out")"
    expect_eq "$label d32 marker $story" \
"<!-- loom:provenance v1 build=1.2.3 $SHA unknown prompts=none sweep=none story=$story trace=$want host=none base=$SHA run=$repo/actions/runs/7/2 -->" \
      "$(sed -n 4p "$tmp/out")"
    expect_eq "$label d32 trace-id output $story" "trace-id=$want" "$(grep '^trace-id=' "$tmp/gh_output")"
    # Cross-repo: the same story from another repo's run, keyed by story-repo-id.
    render PA_STORY="$story" PA_STORY_REPO_ID="$repo_id" GITHUB_REPOSITORY=someone/else GITHUB_REPOSITORY_ID=99 \
      GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=2 GITHUB_SHA="$SHA" || { bad "$label d32 cross-repo $story: $(cat "$tmp/err")"; continue; }
    expect_eq "$label d32 cross-repo $story" "Loom-Trace-Id: $want" "$(sed -n 2p "$tmp/out")"
  done

  # --- CI run vectors (story none) ------------------------------------------
  n=$(jq '.ci_run.vectors | length' "$V")
  for ((i = 0; i < n; i++)); do
    repo=$(jq -r ".ci_run.vectors[$i].repo" "$V")
    run_id=$(jq -r ".ci_run.vectors[$i].run_id" "$V")
    attempt=$(jq -r ".ci_run.vectors[$i].run_attempt" "$V")
    want=$(jq -r ".ci_run.vectors[$i].trace_id" "$V")
    render GITHUB_REPOSITORY="$repo" GITHUB_RUN_ID="$run_id" GITHUB_RUN_ATTEMPT="$attempt" GITHUB_SHA="$SHA" \
      || { bad "$label ci_run $repo: $(cat "$tmp/err")"; continue; }
    local trailers="Loom-Story: none
Loom-Trace-Id: $want
Loom-Build: unknown $SHA unknown"
    local marker="<!-- loom:provenance v1 build=unknown $SHA unknown prompts=none sweep=none story=none trace=$want host=none base=$SHA run=$repo/actions/runs/$run_id/$attempt -->"
    expect_eq "$label ci_run stdout $repo/$run_id/$attempt" "$trailers
$marker" "$(cat "$tmp/out")"
    check_gh_output "$label ci_run GITHUB_OUTPUT $repo/$run_id/$attempt" "$trailers" "$marker" "$want"
  done
}

run_vectors default

# The same vectors with shasum as the only hasher (the macOS path).
if command -v shasum >/dev/null 2>&1; then
  mkbin "$tmp/bin-shasum" bash tr od shasum
  RPATH=$tmp/bin-shasum run_vectors shasum-only
  RPATH=$PATH
else
  bad "shasum is not installed; the shasum branch is untested"
fi

# The run trace keys on the repo name exactly as GitHub reports it: case matters.
render GITHUB_REPOSITORY=2amlogic/loom GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA="$SHA"
if [[ $(sed -n 2p "$tmp/out") != "Loom-Trace-Id: 3468ca8ebf11663d1c7bc17c8cdbbe5a" ]]; then ok "ci_run repo name is case-sensitive"; else bad "ci_run repo name is case-sensitive"; fi

# --- Installs, base/host, env export ----------------------------------------
render GITHUB_REPOSITORY=2AMLogic/loom GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA="$SHA" \
  PA_EXPORT_ENV=true PA_BUILD_VERSION=0.19.400 \
  PA_INSTALLS="0.19.409 $SHA" PA_BASE=none PA_HOST=example-host
expect_eq "installs marker, base/host" \
"<!-- loom:provenance v1 build=0.19.400 $SHA unknown prompts=none sweep=none story=none trace=3468ca8ebf11663d1c7bc17c8cdbbe5a host=example-host base=none run=2AMLogic/loom/actions/runs/42/1 installs=0.19.409 $SHA -->" \
  "$(sed -n 4p "$tmp/out")"
delim=$(sed -n 's/^trailers<<//p' "$tmp/gh_output")
expect_eq "export-env writes PROVENANCE_* with the same random delimiter" \
"PROVENANCE_TRAILERS<<$delim
Loom-Story: none
Loom-Trace-Id: 3468ca8ebf11663d1c7bc17c8cdbbe5a
Loom-Build: 0.19.400 $SHA unknown
$delim
PROVENANCE_MARKER=$(sed -n 4p "$tmp/out")
PROVENANCE_TRACE_ID=3468ca8ebf11663d1c7bc17c8cdbbe5a" "$(cat "$tmp/gh_env")"
d1=$delim
render GITHUB_REPOSITORY=2AMLogic/loom GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA="$SHA"
d2=$(sed -n 's/^trailers<<//p' "$tmp/gh_output")
if [[ $d1 =~ ^PROVENANCE_EOF_[0-9a-f]{32}$ && $d1 != "$d2" ]]; then ok "delimiter is random per run"; else bad "delimiter is random per run ($d1 / $d2)"; fi

# --- Build state: clean | dirty | unknown ------------------------------------
ws=$tmp/ws
mkdir -p "$ws"
git -C "$ws" init -q
printf 'a\n' >"$ws/f"
git -C "$ws" add f
git -C "$ws" -c user.name=test -c user.email=test@example.invalid commit -q -m init
wsha=$(git -C "$ws" rev-parse HEAD)
WCTX=(GITHUB_REPOSITORY=2AMLogic/loom GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA="$wsha" GITHUB_WORKSPACE="$ws")
build_line() { sed -n 3p "$tmp/out"; }
render "${WCTX[@]}"; expect_eq "build clean: HEAD is GITHUB_SHA, no diff" "Loom-Build: unknown $wsha clean" "$(build_line)"
case $(sed -n 4p "$tmp/out") in *" build=unknown $wsha clean prompts="*) ok "marker carries clean" ;; *) bad "marker carries clean" ;; esac
printf 'b\n' >>"$ws/f"
render "${WCTX[@]}"; expect_eq "build dirty: tracked file modified" "Loom-Build: unknown $wsha dirty" "$(build_line)"
git -C "$ws" checkout -q -- f
printf 'x\n' >"$ws/untracked"
render "${WCTX[@]}"; expect_eq "build clean: untracked files are not considered" "Loom-Build: unknown $wsha clean" "$(build_line)"
render "${WCTX[@]}" GITHUB_SHA="$SHA"; expect_eq "build unknown: HEAD is not GITHUB_SHA" "Loom-Build: unknown $SHA unknown" "$(build_line)"
mkdir -p "$tmp/notgit"
render "${WCTX[@]}" GITHUB_WORKSPACE="$tmp/notgit"; expect_eq "build unknown: workspace is not a git checkout" "Loom-Build: unknown $wsha unknown" "$(build_line)"
render "${WCTX[@]}" GITHUB_WORKSPACE="$tmp/missing"; expect_eq "build unknown: workspace missing" "Loom-Build: unknown $wsha unknown" "$(build_line)"
mkbin "$tmp/bin-nogit" bash tr od
if command -v sha256sum >/dev/null 2>&1; then mkbin "$tmp/bin-nogit" sha256sum; else mkbin "$tmp/bin-nogit" shasum; fi
RPATH=$tmp/bin-nogit render "${WCTX[@]}"; expect_eq "build unknown: git not installed" "Loom-Build: unknown $wsha unknown" "$(build_line)"

# --- Hasher failures and the all-zero digest -------------------------------
CTX=(GITHUB_REPOSITORY=2AMLogic/loom GITHUB_REPOSITORY_ID=1073994527 GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA="$SHA")
mkstub() { # dir body : dir with a stub sha256sum plus bash, tr, od, cat
  mkbin "$1" bash tr od cat
  printf '#!/bin/sh\n%s\n' "$2" >"$1/sha256sum"
  chmod +x "$1/sha256sum"
}
Z=0000000000000000000000000000000000000000000000000000000000000000
mkstub "$tmp/bin-zero" "cat >/dev/null; echo '$Z  -'"
mkstub "$tmp/bin-exit" "cat >/dev/null; exit 3"
mkstub "$tmp/bin-short" "cat >/dev/null; echo 'abc  -'"
mkstub "$tmp/bin-empty" "cat >/dev/null"
mkbin "$tmp/bin-nohash" bash tr od

RPATH=$tmp/bin-zero render "${CTX[@]}" || bad "all-zero story=none: $(cat "$tmp/err")"
expect_eq "all-zero digest, story=none: last digit becomes 1" "Loom-Trace-Id: 00000000000000000000000000000001" "$(sed -n 2p "$tmp/out")"
RPATH=$tmp/bin-zero  expect_fail "all-zero digest, same-repo story refused" "all-zero trace id; refusing" "${CTX[@]}" PA_STORY='2AMLogic/loom#1'
RPATH=$tmp/bin-zero  expect_fail "all-zero digest, cross-repo story refused" "all-zero trace id; refusing" "${CTX[@]}" PA_STORY='o/r#1' PA_STORY_REPO_ID=5
RPATH=$tmp/bin-nohash expect_fail "no hasher, story=none"        "neither sha256sum nor shasum" "${CTX[@]}"
RPATH=$tmp/bin-nohash expect_fail "no hasher, story"             "neither sha256sum nor shasum" "${CTX[@]}" PA_STORY='o/r#1' PA_STORY_REPO_ID=5
RPATH=$tmp/bin-exit  expect_fail "hasher exits non-zero, story=none" "hash tool 'sha256sum' failed" "${CTX[@]}"
RPATH=$tmp/bin-exit  expect_fail "hasher exits non-zero, story"  "hash tool 'sha256sum' failed" "${CTX[@]}" PA_STORY='2AMLogic/loom#1'
RPATH=$tmp/bin-short expect_fail "hasher malformed digest"       "malformed digest" "${CTX[@]}"
RPATH=$tmp/bin-empty expect_fail "hasher empty digest"           "malformed digest" "${CTX[@]}" PA_STORY='2AMLogic/loom#1'
RPATH=$PATH

# --- Validation failures ----------------------------------------------------
NOSHA=(GITHUB_REPOSITORY=2AMLogic/loom GITHUB_REPOSITORY_ID=1073994527 GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1)
expect_fail "abbreviated sha"        "GITHUB_SHA must"   "${NOSHA[@]}" GITHUB_SHA=0123456
expect_fail "uppercase sha"          "GITHUB_SHA must"   "${NOSHA[@]}" GITHUB_SHA=0123456789ABCDEF0123456789ABCDEF01234567
expect_fail "missing sha"            "GITHUB_SHA must"   "${NOSHA[@]}"
expect_fail "missing repository"     "GITHUB_REPOSITORY must" GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA="$SHA"
expect_fail "missing run id"         "GITHUB_RUN_ID must" GITHUB_REPOSITORY=2AMLogic/loom GITHUB_RUN_ATTEMPT=1 GITHUB_SHA="$SHA"
expect_fail "zero-padded attempt"    "GITHUB_RUN_ATTEMPT must" GITHUB_REPOSITORY=2AMLogic/loom GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=01 GITHUB_SHA="$SHA"
expect_fail "attempt over u32"       "GITHUB_RUN_ATTEMPT must" GITHUB_REPOSITORY=2AMLogic/loom GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=4294967296 GITHUB_SHA="$SHA"
expect_fail "attempt 11 digits"      "GITHUB_RUN_ATTEMPT must" GITHUB_REPOSITORY=2AMLogic/loom GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=99999999999 GITHUB_SHA="$SHA"
render GITHUB_REPOSITORY=2AMLogic/loom GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=4294967295 GITHUB_SHA="$SHA" && ok "attempt u32 max accepted" || bad "attempt u32 max accepted: $(cat "$tmp/err")"
expect_fail "build-version none"     "may not be 'none'" "${CTX[@]}" PA_BUILD_VERSION=none
expect_fail "build-version spaces"   "build-version"    "${CTX[@]}" PA_BUILD_VERSION="1 2"
expect_fail "build-version --"       "build-version"    "${CTX[@]}" PA_BUILD_VERSION=1--x
expect_fail "story unknown"          "'unknown' is not accepted" "${CTX[@]}" PA_STORY=unknown
expect_fail "story no number"        "owner/repo#n"     "${CTX[@]}" PA_STORY=2AMLogic/loom
expect_fail "story number zero"      "owner/repo#n"     "${CTX[@]}" PA_STORY='2AMLogic/loom#0'
expect_fail "story bare number"      "owner/repo#n"     "${CTX[@]}" PA_STORY='#12'
expect_fail "cross-repo without id"  "pass its numeric id as story-repo-id" "${CTX[@]}" PA_STORY='2AMLogic/harness-ops#307'
expect_fail "cross-repo bad id"      "story-repo-id must" "${CTX[@]}" PA_STORY='2AMLogic/harness-ops#307' PA_STORY_REPO_ID=abc
expect_fail "same-repo id mismatch"  "contradicts"      "${CTX[@]}" PA_STORY='2AMLogic/loom#1' PA_STORY_REPO_ID=5
expect_fail "same-repo missing id"   "GITHUB_REPOSITORY_ID must" GITHUB_REPOSITORY=2AMLogic/loom GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA="$SHA" PA_STORY='2AMLogic/loom#1'
expect_fail "story-repo-id w/o story" "story is 'none'" "${CTX[@]}" PA_STORY_REPO_ID=5
expect_fail "installs short sha"     "installs commit"  "${CTX[@]}" PA_INSTALLS="0.19.409 abc1234"
expect_fail "installs one part"      "installs must"    "${CTX[@]}" PA_INSTALLS="0.19.409"
expect_fail "base short sha"         "base must"        "${CTX[@]}" PA_BASE=abc1234
expect_fail "bad host"               "host must"        "${CTX[@]}" PA_HOST='a b'
expect_fail "bad export-env"         "export-env must"  "${CTX[@]}" PA_EXPORT_ENV=yes

# Error file hook (the workflow self-test reads it to check the reason).
render "${CTX[@]}" PA_BUILD_VERSION=none PROVENANCE_ACTION_ERROR_FILE="$tmp/errfile" || true
if grep -q "may not be 'none'" "$tmp/errfile" 2>/dev/null; then ok "error file gets the message"; else bad "error file gets the message"; fi

# --- Output injection: every input and context variable ---------------------
# Each payload is appended to an otherwise valid value. The last payload puts
# a heredoc-delimiter-shaped line into the value.
PAYLOADS=($'\ninjected' $'\rinjected' '-->' '>' '$(id)' $'\nPROVENANCE_EOF_00000000000000000000000000000000\nLoom-Story: evil')
PNAMES=(newline CR '-->' '>' '$(...)' 'delimiter line')
FIELDS=(
  "PA_STORY|2AMLogic/loom#1|story must"
  "PA_STORY_REPO_ID|5|story-repo-id must"
  "PA_BUILD_VERSION|1.0.0|build-version must"
  "PA_INSTALLS#version|0.19.409|installs"
  "PA_INSTALLS#commit|$SHA|installs"
  "PA_BASE|$SHA|base must"
  "PA_HOST|example-host|host must"
  "PA_EXPORT_ENV|true|export-env must"
  "GITHUB_REPOSITORY|2AMLogic/loom|GITHUB_REPOSITORY must"
  "GITHUB_REPOSITORY_ID|1073994527|GITHUB_REPOSITORY_ID must"
  "GITHUB_RUN_ID|42|GITHUB_RUN_ID must"
  "GITHUB_RUN_ATTEMPT|1|GITHUB_RUN_ATTEMPT must"
  "GITHUB_SHA|$SHA|GITHUB_SHA must"
)
for f in "${FIELDS[@]}"; do
  var=${f%%|*} rest=${f#*|}; valid=${rest%%|*} pat=${rest#*|}
  for ((k = 0; k < ${#PAYLOADS[@]}; k++)); do
    v=$valid${PAYLOADS[$k]}
    case $var in
      PA_STORY_REPO_ID) extra=(PA_STORY='2AMLogic/harness-ops#307' "$var=$v") ;;
      GITHUB_REPOSITORY_ID) extra=(PA_STORY='2AMLogic/loom#1' "$var=$v") ;;
      "PA_INSTALLS#version") extra=("PA_INSTALLS=$v $SHA") ;;
      "PA_INSTALLS#commit") extra=("PA_INSTALLS=0.19.409 $v") ;;
      *) extra=("$var=$v") ;;
    esac
    expect_fail "injection ${PNAMES[$k]} in $var" "$pat" "${CTX[@]}" "${extra[@]}"
  done
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
