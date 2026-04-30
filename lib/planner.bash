#!/usr/bin/env bash
# Task planning functions for mnto
set -euo pipefail

# Idempotency guard — prevent double-sourcing
[[ -n "${_PLANNER_SOURCED:-}" ]] && return 0
declare -r _PLANNER_SOURCED=1

# System prompts — tuned for small LLMs (1.2B-3B params).
# Uses positive framing, explicit ID sequence, and 5 diverse examples
# to maximize format compliance via pattern completion.
readonly SYS_PLAN="Write a plan. Each line: three-letter ID, space, label, colon, description, comma, word count, comma, deps.

Use these IDs in order: zab, zcd, zef, zij, zkl, zmn, zop, zqr

Example output for \"build a treehouse\":
zab planning: Choose a tree and gather materials, 100 words, deps:
zcd foundation: Build the base platform securely, 150 words, deps: zab
zef walls: Construct walls and add windows, 150 words, deps: zcd
zij roof: Add weatherproof roofing, 100 words, deps: zef
zkl finishing: Paint and add a rope ladder, 100 words, deps: zij

Write 3 to 8 lines. Only plan lines, nothing else."

# Two-pass fallback: reformat raw output into plan lines
readonly SYS_RESTRUCTURE="Rewrite the text below as a plan. Each line: three-letter ID, space, label, colon, description, comma, word count, comma, deps.

Use these IDs in order: zab, zcd, zef, zij, zkl, zmn, zop, zqr

Example line:
zab overview: Brief summary of the topic, 100 words, deps:
zcd details: Key information and steps, 150 words, deps: zab
zef conclusion: Summary and next steps, 100 words, deps: zcd

Write one line per section. Only plan lines, nothing else."

# Emergency fallback: minimal prompt for pure pattern completion
readonly SYS_PLAN_MINIMAL="Write a plan like this:
zab first: Description here, 100 words, deps:
zcd second: Description here, 100 words, deps: zab
zef third: Description here, 100 words, deps: zcd

Write 3 to 5 lines about the topic below."

# shellcheck disable=SC2034
readonly SYS_DRAFT="Write the section described in TASK. Follow the word limit.
Use context from PREV for continuity. If CRIT is present,
address the issues raised. Output only the section text.
No headers unless the task requires them. No meta-commentary."

# shellcheck disable=SC2034
# Confidence-aware verification: verdict + confidence score (1-10).
# Research (RECONCILE): confidence-weighted voting yields 6-11% accuracy gains.
readonly SYS_VERIFY="Check if DRAFT satisfies SPEC. Rate your confidence 1-10.

Output format: PASS 8 or FAIL 3: reason

Only fail for: missing required content, exceeding word limit by >50%, incoherent text.
Do not fail for style preferences. Be strict but fair."

# Fixed template fallback — guarantees the harness always runs even when
# the LLM cannot produce a valid dynamic plan.
readonly PLAN_TEMPLATE_GENERIC="zab introduction: Opening section that introduces the topic, 100 words, deps:
zcd body: Main content covering the key points in detail, 200 words, deps: zab
zef conclusion: Summary and closing thoughts, 100 words, deps: zcd"

# Try to normalize and validate a raw plan output.
# Usage: result="$(_try_normalize "$raw_output")"
# Returns the filled plan on stdout, or empty string. Exit 0 if valid.
_try_normalize() {
	local raw="$1"
	local normalized
	normalized="$(echo "$raw" | normalize_plan_output)" || true

	local line_count
	line_count="$(echo "$normalized" | grep -c '.' || true)"

	if ((line_count >= 3)); then
		fill_missing_word_counts "$normalized"
		return 0
	fi
	return 1
}

# Call infer planner and handle exit codes.
# Usage: raw="$(_plan_infer "$system_prompt" "$goal")"
# Returns raw output on stdout. Propagates guardrail/overflow exit codes.
_plan_infer() {
	local sys="$1"
	local goal="$2"
	local ec=0
	local out

	# MNTO_PLANNER_MODEL takes precedence over role-based model resolution
	# for planning inference only. Falls back to infer planner otherwise.
	if [[ -n "${MNTO_PLANNER_MODEL:-}" ]]; then
		local backend="$MNTO_PLANNER_MODEL"
		out="$(infer_with_backend "$backend" planner "$sys" "$goal" 2>/dev/null)" || ec=$?
	else
		out="$(infer planner "$sys" "$goal" 2>/dev/null)" || ec=$?
	fi

	if ((ec == 3)); then
		echo "ERROR: guardrail blocked the request" >&2
		return 3
	elif ((ec == 4)); then
		echo "ERROR: context overflow" >&2
		return 4
	elif ((ec != 0)); then
		echo "ERROR: inference failed with exit code $ec" >&2
		return 1
	fi
	echo "$out"
}

# Generate plan from goal using infer planner
# Strategy: multi-sample with same prompt (up to 3), then restructure
# fallback, then minimal prompt, then fixed template.
# Usage: generate_plan "<goal>"
generate_plan() {
	local goal="$1"

	# Truncate goal for planner to preserve output budget (especially on
	# apfel's 4096-token window). Drafters get the full goal via assemble_context.
	local planner_goal="${goal:0:512}"

	# --- Pass 1: Multi-sample with SYS_PLAN (up to 3 attempts) ---
	# Use higher temperature (0.7) for diversity across samples so each
	# attempt has a genuine chance of producing different output.
	local saved_temp="${MNTO_TEMP_STRUCTURED:-0.2}"
	export MNTO_TEMP_STRUCTURED=0.7

	local max_samples="${MNTO_PLAN_SAMPLES:-3}"
	local attempt=0
	local raw_output=""
	local result

	while ((attempt < max_samples)); do
		attempt=$((attempt + 1))

		raw_output="$(_plan_infer "$SYS_PLAN" "$planner_goal")" || {
			local ec=$?
			# Propagate guardrail/overflow, but retry on generic failure
			if ((ec == 3 || ec == 4)); then
				export MNTO_TEMP_STRUCTURED="$saved_temp"
				echo ""
				return "$ec"
			fi
			continue
		}

		if result="$(_try_normalize "$raw_output")"; then
			export MNTO_TEMP_STRUCTURED="$saved_temp"
			echo "$result"
			return 0
		fi
	done

	# Restore low temperature for deterministic fallback passes
	export MNTO_TEMP_STRUCTURED="$saved_temp"

	# --- Pass 2: Restructure fallback — reformat raw output from last attempt ---
	echo "WARNING: ${max_samples} plan samples failed, attempting restructure" >&2

	if [[ -n "$raw_output" ]]; then
		local restructured
		restructured="$(_plan_infer "$SYS_RESTRUCTURE" "$raw_output")" || true

		if [[ -n "$restructured" ]]; then
			if result="$(_try_normalize "$restructured")"; then
				echo "$result"
				return 0
			fi
		fi
	fi

	# --- Pass 3: Emergency minimal prompt ---
	echo "WARNING: Restructure failed, attempting minimal prompt" >&2

	local minimal
	minimal="$(_plan_infer "$SYS_PLAN_MINIMAL" "$planner_goal")" || true

	if [[ -n "$minimal" ]]; then
		if result="$(_try_normalize "$minimal")"; then
			echo "$result"
			return 0
		fi
	fi

	# --- Pass 4: Fixed template fallback ---
	echo "WARNING: All plan generation failed, using fixed template" >&2
	echo "$PLAN_TEMPLATE_GENERIC"
	return 0
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
