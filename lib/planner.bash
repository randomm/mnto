#!/usr/bin/env bash
# Task planning functions for mnto
set -euo pipefail

# Idempotency guard — prevent double-sourcing
[[ -n "${_PLANNER_SOURCED:-}" ]] && return 0
declare -r _PLANNER_SOURCED=1

# System prompts for apfel
readonly SYS_PLAN="Decompose the goal into 3-8 sections. Output one line per section:
{id} {label}: {description}, {word limit}
IDs: lowercase alphanumeric, 3 chars. No other output."

# shellcheck disable=SC2034
readonly SYS_DRAFT="Write the section described in TASK. Follow the word limit.
Use context from PREV for continuity. If CRIT is present,
address the issues raised. Output only the section text.
No headers unless the task requires them. No meta-commentary."

# shellcheck disable=SC2034
readonly SYS_VERIFY="Check if DRAFT satisfies SPEC. Output PASS if acceptable.
Output FAIL: {one-line reason} if not. Be strict but fair.
Only fail for: missing required content, exceeding word limit
by >50%, incoherent text. Do not fail for style preferences."

# shellcheck disable=SC2034
readonly SYS_STITCH="Combine the sections below into a single coherent document.
Add brief transitions between sections if needed. Fix any
inconsistencies. Do not add new content. Output only the
final document."

# Default planner is apfel
PLAN_MODEL="${PLAN_MODEL:-apfel}"

# Generate plan from goal using apfel
# Usage: generate_plan "<goal>"
generate_plan() {
	local goal="$1"

	if [[ "$PLAN_MODEL" == "apfel" ]]; then
		# Safety: ensure goal doesn't start with - (would be interpreted as apfel flag)
		if [[ "$goal" == -* ]]; then
			goal=$'\n'"$goal"
		fi
		local raw_output
		raw_output="$(apfel -q -s "$SYS_PLAN" "$goal")"
		local exit_code=$?

		# Handle apfel exit codes
		if ((exit_code == 3)); then
			echo "ERROR: apfel guardrail blocked the request" >&2
			echo ""
			return 3
		elif ((exit_code == 4)); then
			echo "ERROR: apfel context overflow" >&2
			echo ""
			return 4
		elif ((exit_code != 0)); then
			echo "ERROR: apfel failed with exit code $exit_code" >&2
			echo ""
			return 1
		fi

		# Normalize output and return
		local normalized
		normalized="$(echo "$raw_output" | normalize_plan_output)"
		echo "$normalized"
	else
		# Future extension point: external model support via PLAN_MODEL
		echo "ERROR: PLAN_MODEL must be 'apfel' for now" >&2
		echo ""
		return 1
	fi
}

# Inject vipune search results into context
# Usage: vipune_search "<query>"
# Returns: search results or empty string if vipune not available
vipune_search() {
	local query="$1"

	if ! command -v vipune >/dev/null 2>&1; then
		echo ""
		return 0
	fi

	local results
	results="$(vipune search "$query" 2>/dev/null)" || {
		echo ""
		return 0
	}

	if [[ -z "$results" ]]; then
		echo ""
		return 0
	fi

	printf '\n\n=== VIPUNE SEARCH RESULTS ===\n%s\n============================\n' "$results"
}
