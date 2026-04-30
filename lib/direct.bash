#!/usr/bin/env bash
# Direct single-shot inference for simple tasks that don't benefit from
# decomposition. Research shows single-agent systems outperform multi-agent
# on sequential reasoning tasks with matched budgets.
set -euo pipefail

# Dependency guard
if [[ "${_BLACKBOARD_SOURCED:-}" != "1" ]] || [[ "${_BACKEND_SOURCED:-}" != "1" ]] || [[ "${_PLANNER_SOURCED:-}" != "1" ]]; then
	echo "ERROR: direct.bash requires blackboard.bash, backend.bash, and planner.bash to be sourced first" >&2
	return 1 2>/dev/null || exit 1
fi

# Threshold for direct mode: goals shorter than this bypass the harness.
# Configurable via MNTO_DIRECT_THRESHOLD (default: 300 chars).
readonly DIRECT_THRESHOLD="${MNTO_DIRECT_THRESHOLD:-300}"

# Check if a goal is simple enough for direct single-shot inference.
# Usage: is_direct_task "$goal"
# Returns: 0 if direct mode should be used, 1 if harness should be used.
is_direct_task() {
	local goal="$1"
	local goal_len=${#goal}

	# Short goals don't benefit from decomposition
	if ((goal_len <= DIRECT_THRESHOLD)); then
		return 0
	fi

	return 1
}

# Determine if goal should use workflow executor.
# Returns: 0 (use workflow) or 1 (use direct/single-shot)
# Usage: should_use_workflow <goal>
should_use_workflow() {
	local goal="$1"

	# Explicit force flags
	[[ "${MNTO_FORCE_WORKFLOW:-}" == "true" ]] && return 0
	[[ "${MNTO_FORCE_DIRECT:-}" == "true" ]] && return 1

	# Token size heuristic (chars / 4 ≈ tokens)
	local threshold="${MNTO_WORKFLOW_THRESHOLD:-120000}"
	local estimated_chars="${#goal}"
	((estimated_chars > threshold)) && return 0

	# Sequential intent signals
	echo "$goal" | grep -qiE \
		'(then|after|followed by|depends on|step [0-9]|first.*then|review.*and)' &&
		return 0

	return 1
}

# Run a task in direct mode: single inference call, no plan/verify/stitch.
# Usage: run_direct <tid>
# Reads: .mnto/bb/{tid}/g (goal)
# Writes: .mnto/bb/{tid}/out (output)
run_direct() {
	local tid="$1"

	if ! validate_id "$tid"; then
		return 1
	fi

	local bb_dir="$BB_DIR/$tid"
	local goal_file="$bb_dir/g"
	local out_file="$bb_dir/out"

	if [[ ! -f "$goal_file" ]]; then
		echo "ERROR: Goal file not found: $goal_file" >&2
		return 1
	fi

	local goal
	goal="$(cat "$goal_file")"

	print_status "INFO" "Direct mode: single-shot inference for task $tid"

	local direct_exit=0
	local result
	result="$(infer proposer "$SYS_DRAFT" "$goal" 2>/dev/null)" || direct_exit=$?

	if ((direct_exit != 0)); then
		echo "ERROR: Direct inference failed (exit code $direct_exit)" >&2
		return 1
	fi

	echo "$result" >"$out_file"
	print_status "PASS" "Task $tid completed (direct mode)"
}
