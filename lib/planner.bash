#!/usr/bin/env bash
# Task planning functions for mnto
set -euo pipefail

# Idempotency guard — prevent double-sourcing
[[ -n "${_PLANNER_SOURCED:-}" ]] && return 0
declare -r _PLANNER_SOURCED=1

# System prompts for apfel
readonly SYS_PLAN="Decompose the goal into 3-8 sections. Output EXACTLY in this format — one line per section:

abc overview: Brief description, 100 words
def install: How to install, 150 words
ghi usage: How to use it, 200 words

Rules:
- Each line: 3-char lowercase ID, then label, then colon, then description, then comma, then word count and 'words'
- NO markdown, NO headers, NO code fences, NO bullet points, NO extra text
- Output ONLY the plan lines — nothing before or after"

# System prompt for restructuring apfel output (two-pass fallback)
readonly SYS_RESTRUCTURE="You are a section formatter. Given the following text, restructure it into exactly this format — one line per section:

abc label: description, NNN words

Each line MUST start with a 3-char lowercase ID (like abc, def, ghi). After the ID: a label word, then a colon, then a brief description, then a comma, then a word count and the word 'words'. Output ONLY the plan lines — nothing else."

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
readonly SYS_STITCH="Merge the sections below into a single coherent document. \
Remove all duplicate and redundant content — keep each section's unique key \
points only. Add brief transitions where needed. Do not add new content. \
Output only the merged document."

# Generate plan from goal using infer planner
# Usage: generate_plan "<goal>"
generate_plan() {
	local goal="$1"

	# Call infer planner with SYS_PLAN
	local exit_code=0
	local raw_output

	raw_output="$(infer planner "$SYS_PLAN" "$goal" 2>/dev/null)" || exit_code=$?

	# Handle infer exit codes
	if ((exit_code == 3)); then
		echo "ERROR: guardrail blocked the request" >&2
		echo ""
		return 3
	elif ((exit_code == 4)); then
		echo "ERROR: context overflow" >&2
		echo ""
		return 4
	elif ((exit_code != 0)); then
		echo "ERROR: inference failed with exit code $exit_code" >&2
		echo ""
		return 1
	fi

	local normalized
	normalized="$(echo "$raw_output" | normalize_plan_output)"

	# Check if we got enough valid lines
	local line_count
	line_count="$(echo "$normalized" | grep -c '.' || true)"

	if ((line_count >= 3)); then
		# Add missing word counts and return
		local filled
		filled="$(fill_missing_word_counts "$normalized")"
		echo "$filled"
		return 0
	fi

	# Pass 2: Two-pass fallback — ask infer planner to restructure its own output
	echo "WARNING: Initial plan normalization produced ${line_count} lines, attempting restructure" >&2

	local restructure_exit_code=0
	local restructured
	restructured="$(infer planner "$SYS_RESTRUCTURE" "$raw_output" 2>/dev/null)" || restructure_exit_code=$?

	if ((restructure_exit_code == 3)); then
		echo "ERROR: guardrail blocked restructure" >&2
		echo ""
		return 3
	elif ((restructure_exit_code == 4)); then
		echo "ERROR: context overflow during restructure" >&2
		echo ""
		return 4
	elif ((restructure_exit_code != 0)); then
		echo "ERROR: inference failed restructure with exit code $restructure_exit_code" >&2
		echo ""
		return 1
	fi

	normalized="$(echo "$restructured" | normalize_plan_output)"

	line_count="$(echo "$normalized" | grep -c '.' || true)"
	if ((line_count >= 3)); then
		local filled
		filled="$(fill_missing_word_counts "$normalized")"
		echo "$filled"
		return 0
	fi

	echo "ERROR: Could not generate valid plan after two attempts" >&2
	echo ""
	return 1
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
