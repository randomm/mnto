#!/usr/bin/env bash
# Task planning functions for mnto
set -euo pipefail

# System prompts for apfel
# Declare without readonly to allow multiple sourcing
# Format required by line validator: ^[a-zA-Z0-9]{3}[ :]
SYS_PLAN='You are a task decomposition planner. Read the user goal and ONLY output a plan with 3-8 sections.

FORMAT RULE (STRICT):
Each section must be one line following this exact pattern:
ABC label: description, N words

Where:
- ABC is exactly 3 lowercase letters or numbers (e.g. int, sec1, 02a)
- A space and colon : separates ID from label
- description briefly states what the section covers
- N is approximate word count

EXAMPLE:
int intro: Project overview and purpose, 50 words
ins install: Installation steps and requirements, 80 words
use usage: Basic usage examples, 120 words

CRITICAL:
- Output ONLY the section lines, no other text
- No introduction, no explanation, no headers, no numbers
- Do NOT write the actual document, just the plan
- Each line must start with exactly 3 alphanumeric characters plus a space and colon'

# shellcheck disable=SC2034
SYS_DRAFT='Write the section described in TASK. Follow the word limit.
Use context from PREV for continuity. If CRIT is present,
address the issues raised. Output only the section text.
No headers unless the task requires them. No meta-commentary.'

# shellcheck disable=SC2034
SYS_VERIFY='Check if DRAFT satisfies SPEC. Output PASS if acceptable.
Output FAIL: {one-line reason} if not. Be strict but fair.
Only fail for: missing required content, exceeding word limit
by >50 percent, incoherent text. Do not fail for style preferences.'

# shellcheck disable=SC2034
SYS_STITCH='Combine the sections below into a single coherent document.
Add brief transitions between sections if needed. Fix any
inconsistencies. Do not add new content. Output only the
final document.'

# Default planner is apfel
PLAN_MODEL="${PLAN_MODEL:-apfel}"

# Generate plan from goal using apfel
# Usage: generate_plan "<goal>"
generate_plan() {
	local goal="$1"

	if [[ "$PLAN_MODEL" == "apfel" ]]; then
		apfel -s "$SYS_PLAN" "$goal" 2>/dev/null || echo ""
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