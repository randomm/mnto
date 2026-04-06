#!/usr/bin/env bash
# Task planning functions for mnto
set -euo pipefail

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

# Generate plan from goal using apfel or external model
# Usage: generate_plan "<goal>"
generate_plan() {
	local goal="$1"

	if [[ "$PLAN_MODEL" == "apfel" ]]; then
		apfel -s "$SYS_PLAN" -- "$goal" 2>/dev/null || echo ""
	elif [[ "$PLAN_MODEL" == "curl" ]]; then
		# External model via curl to llama-server
		generate_plan_curl "$goal"
	else
		# Assume it's a command - validate before use
		if [[ ! "$PLAN_MODEL" =~ ^[a-zA-Z0-9_/-]+$ ]]; then
			echo "ERROR: Invalid PLAN_MODEL command" >&2
			echo ""
			return 1
		fi
		generate_plan_cmd "$goal" "$PLAN_MODEL"
	fi
}

# Generate plan via curl to external model (Strix Halo llama-server)
# Usage: generate_plan_curl "<goal>"
generate_plan_curl() {
	local goal="$1"
	local model_url="${PLAN_MODEL_URL:-http://127.0.0.1:8080}"

	# Validate HTTPS requirement for external URLs
	if [[ "$model_url" != "http://127.0.0.1"* ]] && [[ ! "$model_url" =~ ^https:// ]]; then
		echo "ERROR: PLAN_MODEL_URL must use HTTPS for external URLs" >&2
		echo ""
		return 1
	fi

	# Escape goal for JSON
	local escaped_goal
	escaped_goal="$(printf '%s' "$goal" | jq -Rs .)"

	# Build JSON request
	local json
	json="$(jq -n \
		--arg model "llama" \
		--arg system "$SYS_PLAN" \
		--argjson prompt "$escaped_goal" \
		'{
			model: $model,
			stream: false,
			system: $system,
			prompt: $prompt
		}')"

	local response
	if ! response="$(curl -s -X POST "$model_url/completion" \
		-H "Content-Type: application/json" \
		-d "$json" \
		--max-time 60 2>/dev/null)"; then
		echo ""
		return 1
	fi

	# Extract response content
	local plan
	plan="$(echo "$response" | jq -r '.content // .response // .choices[0].text // ""' 2>/dev/null)"

	if [[ -z "$plan" ]]; then
		echo "WARNING: External model returned empty response" >&2
	fi

	echo "$plan"
}

# Generate plan via custom command
# Usage: generate_plan_cmd "<goal>" "<cmd>"
generate_plan_cmd() {
	local goal="$1"
	local cmd="$2"

	# Pass goal via stdin to command (no eval - prevents command injection)
	printf '%s\n' "$goal" | "$cmd" 2>/dev/null || echo ""
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
