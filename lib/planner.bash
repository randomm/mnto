#!/usr/bin/env bash
# Task planning functions for mnto
set -euo pipefail

# System prompts for apfel
readonly SYS_PLAN="Decompose the goal into 3-8 sections. Output one line per section:
{id} {label}: {description}, {word limit}
IDs: lowercase alphanumeric, 3 chars. No other output."

# shellcheck disable=SC2034 # Used by harness
readonly SYS_DRAFT="Write the section described in TASK. Follow the word limit.
Use context from PREV for continuity. If CRIT is present,
address the issues raised. Output only the section text.
No headers unless the task requires them. No meta-commentary."

# shellcheck disable=SC2034 # Used by harness
readonly SYS_VERIFY="Check if DRAFT satisfies SPEC. Output PASS if acceptable.
Output FAIL: {one-line reason} if not. Be strict but fair.
Only fail for: missing required content, exceeding word limit
by >50%, incoherent text. Do not fail for style preferences."

# shellcheck disable=SC2034 # Used by harness
readonly SYS_STITCH="Combine the sections below into a single coherent document.
Add brief transitions between sections if needed. Fix any
inconsistencies. Do not add new content. Output only the
final document."

# Generate plan from goal using apfel
# Usage: generate_plan "<goal>"
generate_plan() {
	local goal="$1"
	apfel -s "$SYS_PLAN" -- "$goal" 2>/dev/null || echo ""
}
