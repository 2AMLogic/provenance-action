#!/usr/bin/env bash
# Asserts render.sh against tests/vectors.json byte-for-byte, plus the
# validation failures. Needs bash and jq (both on ubuntu-latest).
set -euo pipefail
cd "$(dirname "$0")/.."
V=tests/vectors.json
SHA=0123456789abcdef0123456789abcdef01234567
pass=0 fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# render VAR=VALUE... : run render.sh in a clean env, outputs to $tmp/out
render() {
  : >"$tmp/gh_output"
  env -i PATH="$PATH" GITHUB_OUTPUT="$tmp/gh_output" "$@" ./render.sh >"$tmp/out" 2>"$tmp/err"
}
expect_eq() { # name expected actual
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1"; printf '  expected: %s\n  actual:   %s\n' "$2" "$3"; fi
}
expect_fail() { # name pattern VAR=VALUE...
  local name=$1 pat=$2; shift 2
  if render "$@"; then bad "$name (exit 0)"; return; fi
  if [[ -s $tmp/out || -s $tmp/gh_output ]]; then bad "$name (emitted output on failure)"; return; fi
  if grep -q -- "$pat" "$tmp/err"; then ok "$name"; else bad "$name (stderr: $(cat "$tmp/err"))"; fi
}

# --- D32 v1 vectors (same-repo story: key is the run's repository id) -------
n=$(jq '.d32.vectors | length' "$V")
for ((i = 0; i < n; i++)); do
  story=$(jq -r ".d32.vectors[$i].story" "$V")
  repo_id=$(jq -r ".d32.vectors[$i].repo_id" "$V")
  want=$(jq -r ".d32.vectors[$i].trace_id" "$V")
  repo=${story%#*}
  render PA_STORY="$story" PA_REPOSITORY="$repo" PA_REPOSITORY_ID="$repo_id" \
    PA_RUN_ID=7 PA_RUN_ATTEMPT=2 PA_SHA="$SHA" PA_BUILD_VERSION=1.2.3 || { bad "d32 $story: $(cat "$tmp/err")"; continue; }
  expect_eq "d32 trailers $story" \
"Loom-Story: $story
Loom-Trace-Id: $want
Loom-Build: 1.2.3 $SHA clean" "$(head -n 3 "$tmp/out")"
  expect_eq "d32 marker $story" \
"<!-- loom:provenance v1 build=1.2.3 $SHA clean prompts=none sweep=none story=$story trace=$want host=none base=$SHA run=$repo/actions/runs/7/2 -->" \
    "$(sed -n 4p "$tmp/out")"
  expect_eq "d32 trace-id output $story" "trace-id=$want" "$(grep '^trace-id=' "$tmp/gh_output")"
  # Cross-repo: the same story from another repo's run, keyed by story-repo-id.
  render PA_STORY="$story" PA_STORY_REPO_ID="$repo_id" PA_REPOSITORY=someone/else PA_REPOSITORY_ID=99 \
    PA_RUN_ID=7 PA_RUN_ATTEMPT=2 PA_SHA="$SHA" || { bad "d32 cross-repo $story: $(cat "$tmp/err")"; continue; }
  expect_eq "d32 cross-repo $story" "Loom-Trace-Id: $want" "$(sed -n 2p "$tmp/out")"
done

# --- CI run vectors (story none) ------------------------------------------
n=$(jq '.ci_run.vectors | length' "$V")
for ((i = 0; i < n; i++)); do
  repo=$(jq -r ".ci_run.vectors[$i].repo" "$V")
  run_id=$(jq -r ".ci_run.vectors[$i].run_id" "$V")
  attempt=$(jq -r ".ci_run.vectors[$i].run_attempt" "$V")
  want=$(jq -r ".ci_run.vectors[$i].trace_id" "$V")
  render PA_REPOSITORY="$repo" PA_RUN_ID="$run_id" PA_RUN_ATTEMPT="$attempt" PA_SHA="$SHA" \
    || { bad "ci_run $repo: $(cat "$tmp/err")"; continue; }
  expect_eq "ci_run stdout $repo/$run_id/$attempt" \
"Loom-Story: none
Loom-Trace-Id: $want
Loom-Build: unknown $SHA clean
<!-- loom:provenance v1 build=unknown $SHA clean prompts=none sweep=none story=none trace=$want host=none base=$SHA run=$repo/actions/runs/$run_id/$attempt -->" \
    "$(cat "$tmp/out")"
  expect_eq "ci_run GITHUB_OUTPUT $repo/$run_id/$attempt" \
"trailers<<PROVENANCE_EOF_$want
Loom-Story: none
Loom-Trace-Id: $want
Loom-Build: unknown $SHA clean
PROVENANCE_EOF_$want
marker=<!-- loom:provenance v1 build=unknown $SHA clean prompts=none sweep=none story=none trace=$want host=none base=$SHA run=$repo/actions/runs/$run_id/$attempt -->
trace-id=$want" "$(cat "$tmp/gh_output")"
done

# The run trace keys on the repo name exactly as GitHub reports it: case matters.
render PA_REPOSITORY=2amlogic/loom PA_RUN_ID=42 PA_RUN_ATTEMPT=1 PA_SHA="$SHA"
if [[ $(sed -n 2p "$tmp/out") != "Loom-Trace-Id: 3468ca8ebf11663d1c7bc17c8cdbbe5a" ]]; then ok "ci_run repo name is case-sensitive"; else bad "ci_run repo name is case-sensitive"; fi

# --- Context fallback, installs, base/host overrides, env export -----------
: >"$tmp/gh_env"
render GITHUB_REPOSITORY=2AMLogic/loom GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA="$SHA" \
  GITHUB_ENV="$tmp/gh_env" PA_EXPORT_ENV=true PA_BUILD_VERSION=0.19.400 \
  PA_INSTALLS="0.19.409 $SHA" PA_BASE=none PA_HOST=loom-worker-1
expect_eq "context fallback + installs marker" \
"<!-- loom:provenance v1 build=0.19.400 $SHA clean prompts=none sweep=none story=none trace=3468ca8ebf11663d1c7bc17c8cdbbe5a host=loom-worker-1 base=none run=2AMLogic/loom/actions/runs/42/1 installs=0.19.409 $SHA -->" \
  "$(sed -n 4p "$tmp/out")"
expect_eq "export-env writes PROVENANCE_*" \
"PROVENANCE_TRAILERS<<PROVENANCE_EOF_3468ca8ebf11663d1c7bc17c8cdbbe5a
Loom-Story: none
Loom-Trace-Id: 3468ca8ebf11663d1c7bc17c8cdbbe5a
Loom-Build: 0.19.400 $SHA clean
PROVENANCE_EOF_3468ca8ebf11663d1c7bc17c8cdbbe5a
PROVENANCE_MARKER=$(sed -n 4p "$tmp/out")
PROVENANCE_TRACE_ID=3468ca8ebf11663d1c7bc17c8cdbbe5a" "$(cat "$tmp/gh_env")"

# --- Validation failures ----------------------------------------------------
CTX=(PA_REPOSITORY=2AMLogic/loom PA_REPOSITORY_ID=1073994527 PA_RUN_ID=42 PA_RUN_ATTEMPT=1)
expect_fail "abbreviated sha"        "full 40-hex"      "${CTX[@]}" PA_SHA=0123456
expect_fail "uppercase sha"          "full 40-hex"      "${CTX[@]}" PA_SHA=0123456789ABCDEF0123456789ABCDEF01234567
expect_fail "missing sha"            "full 40-hex"      "${CTX[@]}"
expect_fail "missing repository"     "owner/repo"       PA_RUN_ID=42 PA_RUN_ATTEMPT=1 PA_SHA="$SHA"
expect_fail "missing run id"         "run id"           PA_REPOSITORY=2AMLogic/loom PA_RUN_ATTEMPT=1 PA_SHA="$SHA"
expect_fail "zero-padded attempt"    "run attempt"      PA_REPOSITORY=2AMLogic/loom PA_RUN_ID=42 PA_RUN_ATTEMPT=01 PA_SHA="$SHA"
expect_fail "build-version none"     "may not be 'none'" "${CTX[@]}" PA_SHA="$SHA" PA_BUILD_VERSION=none
expect_fail "build-version spaces"   "build-version"    "${CTX[@]}" PA_SHA="$SHA" PA_BUILD_VERSION="1 2"
expect_fail "build-version --"       "build-version"    "${CTX[@]}" PA_SHA="$SHA" PA_BUILD_VERSION=1--x
expect_fail "story unknown"          "'unknown' is not accepted" "${CTX[@]}" PA_SHA="$SHA" PA_STORY=unknown
expect_fail "story no number"        "owner/repo#n"     "${CTX[@]}" PA_SHA="$SHA" PA_STORY=2AMLogic/loom
expect_fail "story number zero"      "owner/repo#n"     "${CTX[@]}" PA_SHA="$SHA" PA_STORY='2AMLogic/loom#0'
expect_fail "story bare number"      "owner/repo#n"     "${CTX[@]}" PA_SHA="$SHA" PA_STORY='#12'
expect_fail "cross-repo without id"  "story-repo-id"    "${CTX[@]}" PA_SHA="$SHA" PA_STORY='2AMLogic/harness-ops#307'
expect_fail "cross-repo bad id"      "story-repo-id must" "${CTX[@]}" PA_SHA="$SHA" PA_STORY='2AMLogic/harness-ops#307' PA_STORY_REPO_ID=abc
expect_fail "same-repo id mismatch"  "contradicts"      "${CTX[@]}" PA_SHA="$SHA" PA_STORY='2AMLogic/loom#1' PA_STORY_REPO_ID=5
expect_fail "same-repo missing id"   "repository id"    PA_REPOSITORY=2AMLogic/loom PA_RUN_ID=42 PA_RUN_ATTEMPT=1 PA_SHA="$SHA" PA_STORY='2AMLogic/loom#1'
expect_fail "story-repo-id w/o story" "story is 'none'" "${CTX[@]}" PA_SHA="$SHA" PA_STORY_REPO_ID=5
expect_fail "installs short sha"     "installs commit"  "${CTX[@]}" PA_SHA="$SHA" PA_INSTALLS="0.19.409 abc1234"
expect_fail "installs one part"      "installs must"    "${CTX[@]}" PA_SHA="$SHA" PA_INSTALLS="0.19.409"
expect_fail "base short sha"         "base must"        "${CTX[@]}" PA_SHA="$SHA" PA_BASE=abc1234
expect_fail "bad host"               "host must"        "${CTX[@]}" PA_SHA="$SHA" PA_HOST='a b'
expect_fail "bad export-env"         "export-env"       "${CTX[@]}" PA_SHA="$SHA" PA_EXPORT_ENV=yes

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
