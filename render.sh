#!/usr/bin/env bash
# Render 2AMLogic provenance stamps (harness-ops D33, story traces D32 v1).
#
# Inputs come from the environment (action.yml maps the action inputs onto
# PA_*; each override falls back to the GitHub Actions context variable):
#   PA_STORY           owner/repo#n, or "none" (default "none")
#   PA_STORY_REPO_ID   numeric repo id of the story's repo; required only when
#                      the story is in a different repo than the run
#   PA_BUILD_VERSION   version of the emitting tool, or "unknown" (default)
#   PA_INSTALLS        optional "<version> <40-hex>" of a program this run installs
#   PA_BASE            base commit (40-hex) or "none"; default GITHUB_SHA
#   PA_HOST            fleet host.id, or "none" (default; a hosted runner is not a fleet host)
#   PA_EXPORT_ENV      "true" to also write PROVENANCE_* to $GITHUB_ENV
#   PA_REPOSITORY / PA_REPOSITORY_ID / PA_RUN_ID / PA_RUN_ATTEMPT / PA_SHA
#                      overrides for GITHUB_REPOSITORY / GITHUB_REPOSITORY_ID /
#                      GITHUB_RUN_ID / GITHUB_RUN_ATTEMPT / GITHUB_SHA
#
# Outputs: prints the three trailers and the marker to stdout, and appends
# `trailers`, `marker` and `trace-id` to $GITHUB_OUTPUT when it is set.
# Any invalid input exits non-zero with an "error:" line; nothing is emitted.
set -euo pipefail

die() { printf 'provenance-action: error: %s\n' "$*" >&2; exit 1; }

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  else
    die "neither sha256sum nor shasum is available"
  fi
}

# D32 v1: hex(sha256("loom-story/v1:github:<repo_id>:<number>")[0:16])
d32_trace() {
  local h
  h=$(printf '%s' "loom-story/v1:github:$1:$2" | sha256_hex)
  h=${h:0:32}
  # D32: an all-zero ID is refused, never substituted.
  [[ $h =~ ^0+$ ]] && die "D32 derivation produced an all-zero trace id; refusing"
  printf '%s' "$h"
}

# loom CI run trace: sha256 over NUL-terminated parts, first 32 hex;
# an all-zero result has its last digit replaced with 1 (loom derived_hex).
ci_run_trace() {
  local h
  h=$(printf '%s\0%s\0%s\0%s\0' "loom.ci.trace" "$1" "$2" "$3" | sha256_hex)
  h=${h:0:32}
  [[ $h =~ ^0+$ ]] && h="${h:0:31}1"
  printf '%s' "$h"
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
repo=${PA_REPOSITORY:-${GITHUB_REPOSITORY:-}}
repo_id=${PA_REPOSITORY_ID:-${GITHUB_REPOSITORY_ID:-}}
run_id=${PA_RUN_ID:-${GITHUB_RUN_ID:-}}
run_attempt=${PA_RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-}}
sha=${PA_SHA:-${GITHUB_SHA:-}}
base=${PA_BASE:-$sha}

case $export_env in
  true) [[ -n ${GITHUB_ENV:-} ]] || die "export-env is true but GITHUB_ENV is not set" ;;
  false) ;;
  *) die "export-env must be 'true' or 'false' (got '${export_env}')" ;;
esac

# --- Run context -----------------------------------------------------------
is_repo "$repo" || die "repository must be owner/repo (got '${repo}'); is GITHUB_REPOSITORY set?"
is_dec "$run_id" || die "run id must be a positive decimal integer (got '${run_id}')"
is_dec "$run_attempt" || die "run attempt must be a positive decimal integer (got '${run_attempt}')"
is_sha "$sha" || die "commit must be a full 40-hex lowercase SHA (got '${sha}'); abbreviated SHAs are never emitted"

# --- Build -----------------------------------------------------------------
[[ $build_version == none ]] && die "build-version may not be 'none' (use 'unknown' if it cannot be determined)"
is_version "$build_version" || die "build-version must match [A-Za-z0-9._+-]+ without '--' (got '${build_version}')"

# --- Host / base -----------------------------------------------------------
[[ $host == none || $host == unknown ]] || [[ $host =~ ^[A-Za-z0-9._-]+$ && $host != *--* ]] \
  || die "host must be a host.id, 'none' or 'unknown' (got '${host}')"
[[ $base == none || $base == unknown ]] || is_sha "$base" \
  || die "base must be a full 40-hex lowercase SHA, 'none' or 'unknown' (got '${base}')"

# --- Installs (optional) ---------------------------------------------------
if [[ -n $installs ]]; then
  [[ $installs =~ ^([^ ]+)\ ([^ ]+)$ ]] || die "installs must be '<version> <40-hex>' (got '${installs}')"
  iv=${BASH_REMATCH[1]} ic=${BASH_REMATCH[2]}
  [[ $iv != none ]] && is_version "$iv" || die "installs version must match [A-Za-z0-9._+-]+ or be 'unknown' (got '${iv}')"
  [[ $ic == unknown ]] || is_sha "$ic" || die "installs commit must be a full 40-hex lowercase SHA or 'unknown' (got '${ic}')"
fi

# --- Story and trace -------------------------------------------------------
if [[ $story == none ]]; then
  [[ -z $story_repo_id ]] || die "story-repo-id given but story is 'none'"
  trace=$(ci_run_trace "$repo" "$run_id" "$run_attempt")
elif [[ $story == unknown ]]; then
  die "story 'unknown' is not accepted: CI automation either works on a story (owner/repo#n) or has none ('none')"
else
  [[ $story =~ ^([A-Za-z0-9-]+/[A-Za-z0-9._-]+)#([1-9][0-9]*)$ ]] \
    || die "story must be owner/repo#n or 'none' (got '${story}')"
  story_repo=${BASH_REMATCH[1]} number=${BASH_REMATCH[2]}
  if [[ $(lower "$story_repo") == "$(lower "$repo")" ]]; then
    is_dec "$repo_id" || die "repository id must be a positive decimal integer (got '${repo_id}'); is GITHUB_REPOSITORY_ID set?"
    if [[ -n $story_repo_id && $story_repo_id != "$repo_id" ]]; then
      die "story-repo-id ${story_repo_id} contradicts this run's repository id ${repo_id}"
    fi
    key_id=$repo_id
  else
    [[ -n $story_repo_id ]] \
      || die "story ${story} is in another repository than ${repo}; pass its numeric id as story-repo-id (gh api repos/${story_repo} --jq .id). A repo name is never used as the key."
    is_dec "$story_repo_id" || die "story-repo-id must be a positive decimal integer (got '${story_repo_id}')"
    key_id=$story_repo_id
  fi
  trace=$(d32_trace "$key_id" "$number")
fi

# --- Render ----------------------------------------------------------------
trailers="Loom-Story: ${story}
Loom-Trace-Id: ${trace}
Loom-Build: ${build_version} ${sha} clean"

marker="<!-- loom:provenance v1 build=${build_version} ${sha} clean prompts=none sweep=none story=${story} trace=${trace} host=${host} base=${base} run=${repo}/actions/runs/${run_id}/${run_attempt}"
[[ -n $installs ]] && marker="${marker} installs=${installs}"
marker="${marker} -->"

printf '%s\n%s\n' "$trailers" "$marker"

delim="PROVENANCE_EOF_${trace}"
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
