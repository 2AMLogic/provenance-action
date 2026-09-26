#!/usr/bin/env bash
# Render 2AMLogic provenance stamps (harness-ops D33, story traces D32 v1).
#
# Action inputs arrive as PA_* (action.yml maps them):
#   PA_STORY           owner/repo#n, or "none" (default "none")
#   PA_STORY_REPO_ID   numeric repo id of the story's repo; required only when
#                      the story is in a different repo than the run
#   PA_BUILD_VERSION   version of the emitting tool, or "unknown" (default)
#   PA_INSTALLS        optional "<version> <40-hex>" of a program this run installs
#   PA_BASE            base commit (40-hex), "none" or "unknown"; default GITHUB_SHA
#   PA_HOST            fleet host.id, or "none" (default; a hosted runner is not a fleet host)
#   PA_EXPORT_ENV      "true" to also write PROVENANCE_* to $GITHUB_ENV
#
# The run context is read from the Actions environment only, never from
# inputs: GITHUB_REPOSITORY, GITHUB_REPOSITORY_ID, GITHUB_RUN_ID,
# GITHUB_RUN_ATTEMPT, GITHUB_SHA, GITHUB_WORKSPACE.
#
# Build state (the third Loom-Build field): "clean" when git is available,
# GITHUB_WORKSPACE is a checkout whose HEAD is GITHUB_SHA and
# `git diff --quiet HEAD` succeeds there; "dirty" when HEAD is GITHUB_SHA but
# tracked files differ from it; "unknown" in every other case (no git, no
# workspace, HEAD is another commit, git errors). Untracked files are not
# considered.
#
# Outputs: prints the three trailers and the marker to stdout, and appends
# `trailers`, `marker` and `trace-id` to $GITHUB_OUTPUT when it is set.
# Any invalid input or tool failure exits non-zero with one "error:" line on
# stderr, and nothing is emitted. Rejected values are echoed only escaped.
set -euo pipefail

# esc VALUE: VALUE with every byte outside [A-Za-z0-9._#/+-] written as \xNN,
# so an error message never carries raw input (a newline followed by
# "::set-output" or "::add-mask::" would be a runner workflow command).
esc() {
  local hex h d out=
  hex=$(printf '%s' "$1" | od -An -v -tx1 2>/dev/null) || { printf '<unprintable>'; return; }
  for h in $hex; do
    d=$((16#$h))
    if ((d >= 48 && d <= 57 || d >= 65 && d <= 90 || d >= 97 && d <= 122)) \
      || ((d == 46 || d == 95 || d == 35 || d == 47 || d == 43 || d == 45)); then
      out="$out$(printf "\\x$h")"
    else
      out="$out\\x$h"
    fi
  done
  printf '%s' "$out"
}

# Every value interpolated into a die message goes through esc. As a second
# guard, CR and LF in the final message are escaped too, so stderr is always
# exactly one line starting with "provenance-action: error:".
die() {
  local msg="$*"
  msg=${msg//$'\n'/\\x0a}
  msg=${msg//$'\r'/\\x0d}
  printf 'provenance-action: error: %s\n' "$msg" >&2
  exit 1
}

# Pick the hasher once, at top level, so a missing tool is fatal here.
if command -v sha256sum >/dev/null 2>&1; then
  HASHER="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASHER="shasum -a 256"
else
  die "neither sha256sum nor shasum is available"
fi

# sha256 of the bytes printf renders from "$@", into the global HEX.
# Never called inside $(...): die must exit the script, and bash drops
# `set -e` in command substitutions, so every failure is checked explicitly.
HEX=
sha256_printf() {
  local out
  # HASHER is a fixed, word-split command; the format is a literal from the callers.
  # shellcheck disable=SC2086,SC2059
  if ! out=$(printf "$@" | $HASHER); then
    die "hash tool '${HASHER}' failed"
  fi
  out=${out%%[[:space:]]*}
  [[ $out =~ ^[0-9a-f]{64}$ ]] || die "hash tool '${HASHER}' returned a malformed digest"
  HEX=$out
}

# D32 v1: hex(sha256("loom-story/v1:github:<repo_id>:<number>")[0:16])
d32_trace() {
  sha256_printf '%s' "loom-story/v1:github:$1:$2"
  trace=${HEX:0:32}
  # D32: an all-zero ID is refused, never substituted.
  [[ $trace =~ ^0+$ ]] && die "D32 derivation produced an all-zero trace id; refusing"
  return 0
}

# loom CI run trace: sha256 over NUL-terminated parts, first 32 hex;
# an all-zero result has its last digit replaced with 1 (loom derived_hex).
ci_run_trace() {
  sha256_printf '%s\0%s\0%s\0%s\0' "loom.ci.trace" "$1" "$2" "$3"
  trace=${HEX:0:32}
  [[ $trace =~ ^0+$ ]] && trace="${trace:0:31}1"
  return 0
}

# clean | dirty | unknown for the workspace against GITHUB_SHA (see header).
measure_build_state() {
  local ws=${GITHUB_WORKSPACE:-} head rc
  [[ -n $ws && -d $ws ]] || { printf unknown; return; }
  command -v git >/dev/null 2>&1 || { printf unknown; return; }
  head=$(git -C "$ws" rev-parse --verify -q HEAD 2>/dev/null) || { printf unknown; return; }
  [[ $head == "$sha" ]] || { printf unknown; return; }
  rc=0
  git -C "$ws" diff --quiet HEAD -- 2>/dev/null || rc=$?
  case $rc in
    0) printf clean ;;
    1) printf dirty ;;
    *) printf unknown ;;
  esac
}

is_dec()     { [[ $1 =~ ^[1-9][0-9]*$ ]]; }
is_sha()     { [[ $1 =~ ^[0-9a-f]{40}$ ]]; }
is_repo()    { [[ $1 =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; }
is_version() { [[ $1 =~ ^[A-Za-z0-9._+-]+$ && $1 != *--* ]]; }
lower()      { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

story=${PA_STORY:-none}
story_repo_id=${PA_STORY_REPO_ID:-}
build_version=${PA_BUILD_VERSION:-unknown}
installs=${PA_INSTALLS:-}
host=${PA_HOST:-none}
export_env=${PA_EXPORT_ENV:-false}
repo=${GITHUB_REPOSITORY:-}
repo_id=${GITHUB_REPOSITORY_ID:-}
run_id=${GITHUB_RUN_ID:-}
run_attempt=${GITHUB_RUN_ATTEMPT:-}
sha=${GITHUB_SHA:-}
base=${PA_BASE:-$sha}

case $export_env in
  true) [[ -n ${GITHUB_ENV:-} ]] || die "export-env is true but GITHUB_ENV is not set" ;;
  false) ;;
  *) die "export-env must be 'true' or 'false' (got '$(esc "$export_env")')" ;;
esac

# --- Run context -----------------------------------------------------------
is_repo "$repo" || die "GITHUB_REPOSITORY must be owner/repo (got '$(esc "$repo")')"
is_dec "$run_id" || die "GITHUB_RUN_ID must be a positive decimal integer (got '$(esc "$run_id")')"
is_dec "$run_attempt" && ((${#run_attempt} <= 10)) && ((run_attempt <= 4294967295)) \
  || die "GITHUB_RUN_ATTEMPT must be a positive decimal integer that fits in 32 bits (got '$(esc "$run_attempt")')"
is_sha "$sha" || die "GITHUB_SHA must be a full 40-hex lowercase SHA (got '$(esc "$sha")'); abbreviated SHAs are never emitted"

# --- Build -----------------------------------------------------------------
[[ $build_version == none ]] && die "build-version may not be 'none' (use 'unknown' if it cannot be determined)"
is_version "$build_version" || die "build-version must match [A-Za-z0-9._+-]+ without '--' (got '$(esc "$build_version")')"

# --- Host / base -----------------------------------------------------------
[[ $host == none || $host == unknown ]] || [[ $host =~ ^[A-Za-z0-9._-]+$ && $host != *--* ]] \
  || die "host must be a host.id, 'none' or 'unknown' (got '$(esc "$host")')"
[[ $base == none || $base == unknown ]] || is_sha "$base" \
  || die "base must be a full 40-hex lowercase SHA, 'none' or 'unknown' (got '$(esc "$base")')"

# --- Installs (optional) ---------------------------------------------------
if [[ -n $installs ]]; then
  [[ $installs =~ ^([^[:space:]]+)\ ([^[:space:]]+)$ ]] || die "installs must be '<version> <40-hex>' (got '$(esc "$installs")')"
  iv=${BASH_REMATCH[1]} ic=${BASH_REMATCH[2]}
  [[ $iv != none ]] && is_version "$iv" || die "installs version must match [A-Za-z0-9._+-]+ or be 'unknown' (got '$(esc "$iv")')"
  [[ $ic == unknown ]] || is_sha "$ic" || die "installs commit must be a full 40-hex lowercase SHA or 'unknown' (got '$(esc "$ic")')"
fi

# --- Story and trace -------------------------------------------------------
trace=
if [[ $story == none ]]; then
  [[ -z $story_repo_id ]] || die "story-repo-id given but story is 'none'"
  ci_run_trace "$repo" "$run_id" "$run_attempt"
elif [[ $story == unknown ]]; then
  die "story 'unknown' is not accepted: CI automation either works on a story (owner/repo#n) or has none ('none')"
else
  [[ $story =~ ^([A-Za-z0-9-]+/[A-Za-z0-9._-]+)#([1-9][0-9]*)$ ]] \
    || die "story must be owner/repo#n or 'none' (got '$(esc "$story")')"
  story_repo=${BASH_REMATCH[1]} number=${BASH_REMATCH[2]}
  if [[ $(lower "$story_repo") == "$(lower "$repo")" ]]; then
    is_dec "$repo_id" || die "GITHUB_REPOSITORY_ID must be a positive decimal integer (got '$(esc "$repo_id")')"
    if [[ -n $story_repo_id && $story_repo_id != "$repo_id" ]]; then
      die "story-repo-id $(esc "$story_repo_id") contradicts this run's repository id $(esc "$repo_id")"
    fi
    key_id=$repo_id
  else
    [[ -n $story_repo_id ]] \
      || die "story $(esc "$story") is in another repository than $(esc "$repo"); pass its numeric id as story-repo-id (gh api repos/$(esc "$story_repo") --jq .id). A repo name is never used as the key."
    is_dec "$story_repo_id" || die "story-repo-id must be a positive decimal integer (got '$(esc "$story_repo_id")')"
    key_id=$story_repo_id
  fi
  d32_trace "$key_id" "$number"
fi
[[ $trace =~ ^[0-9a-f]{32}$ ]] || die "internal: trace id '$(esc "$trace")' is not 32 lowercase hex; refusing"

build_state=$(measure_build_state)
case $build_state in clean | dirty | unknown) ;; *) die "internal: build state '$(esc "$build_state")'" ;; esac

# --- Render ----------------------------------------------------------------
trailers="Loom-Story: ${story}
Loom-Trace-Id: ${trace}
Loom-Build: ${build_version} ${sha} ${build_state}"

marker="<!-- loom:provenance v1 build=${build_version} ${sha} ${build_state} prompts=none sweep=none story=${story} trace=${trace} host=${host} base=${base} run=${repo}/actions/runs/${run_id}/${run_attempt}"
[[ -n $installs ]] && marker="${marker} installs=${installs}"
marker="${marker} -->"

# Random heredoc delimiter (defence in depth: every field is validated above).
rnd=
if ! rnd=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null); then
  die "could not read /dev/urandom for the output delimiter"
fi
rnd=${rnd//[[:space:]]/}
[[ $rnd =~ ^[0-9a-f]{32}$ ]] || die "could not generate a random output delimiter"
delim="PROVENANCE_EOF_${rnd}"
case $'\n'"$trailers"$'\n' in *$'\n'"$delim"$'\n'*) die "output delimiter collision; refusing" ;; esac

printf '%s\n%s\n' "$trailers" "$marker"

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    printf 'trailers<<%s\n%s\n%s\n' "$delim" "$trailers" "$delim"
    printf 'marker=%s\n' "$marker"
    printf 'trace-id=%s\n' "$trace"
  } >>"$GITHUB_OUTPUT"
fi
if [[ $export_env == true ]]; then
  {
    printf 'PROVENANCE_TRAILERS<<%s\n%s\n%s\n' "$delim" "$trailers" "$delim"
    printf 'PROVENANCE_MARKER=%s\n' "$marker"
    printf 'PROVENANCE_TRACE_ID=%s\n' "$trace"
  } >>"$GITHUB_ENV"
fi
