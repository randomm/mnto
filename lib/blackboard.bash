#!/usr/bin/env bash
# Blackboard operations for mnto
set -euo pipefail

# Idempotency guard — prevent double-sourcing
[[ -n "${_BLACKBOARD_SOURCED:-}" ]] && return 0
declare -r _BLACKBOARD_SOURCED=1

# ANSI terminal colours (used in harness.bash via source)
# shellcheck disable=SC2034
readonly C_RESET='\033[0m'
# shellcheck disable=SC2034
readonly C_RED='\033[0;31m'
# shellcheck disable=SC2034
readonly C_GREEN='\033[0;32m'
# shellcheck disable=SC2034
readonly C_YELLOW='\033[0;33m'
# shellcheck disable=SC2034
readonly C_BLUE='\033[0;34m'

# Validate task ID format (security)
validate_id() {
	local id="$1"
	if [[ ! "$id" =~ ^[a-zA-Z0-9]{3}$ ]]; then
		echo "ERROR: Invalid task ID format '$id'" >&2
		return 1
	fi
	return 0
}

# Generate 3-char base62 ID with collision detection
gen_id() {
	local chars="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
	local id=""
	local i
	while true; do
		id=""
		for ((i = 0; i < 3; i++)); do
			id+="${chars:$((RANDOM % 62)):1}"
		done
		# Collision check - regenerate if directory already exists
		# shellcheck disable=SC2153 # BB_DIR is defined in mnto at runtime
		if [[ ! -d "$BB_DIR/$id" ]]; then
			echo "$id"
			return 0
		fi
	done
}

# Return next waiting subtask for task
# Uses "NULL" sentinel when no waiting task found
next_task() {
	local tid="$1"
	if ! validate_id "$tid"; then
		echo "NULL"
		return 1
	fi
	local status_file="$BB_DIR/$tid/s"

	if [[ ! -f "$status_file" ]]; then
		echo "NULL"
		return 1
	fi

	while IFS=' ' read -r id state retries; do
		if [[ "$state" == "-" ]]; then
			echo "$id"
			return 0
		fi
	done <"$status_file"

	echo "NULL"
	return 1
}

# Update status file for subtask
# Usage: set_status <tid> <id> <state> <retries>
set_status() {
	local tid="$1"
	local id="$2"
	local state="$3"
	local retries="$4"
	if ! validate_id "$tid"; then
		return 1
	fi
	if ! validate_id "$id"; then
		return 1
	fi
	local status_file="$BB_DIR/$tid/s"
	local tmp_file
	if ! tmp_file="$(mktemp "${status_file}.XXXXXX")"; then
		echo "ERROR: Failed to create temp file" >&2
		return 1
	fi

	if [[ ! -f "$status_file" ]]; then
		rm -f "$tmp_file"
		return 1
	fi

	while IFS=' ' read -r cur_id cur_state cur_retries; do
		if [[ "$cur_id" == "$id" ]]; then
			echo "$id $state $retries"
		else
			echo "$cur_id $cur_state $cur_retries"
		fi
	done <"$status_file" >"$tmp_file"

	mv "$tmp_file" "$status_file"
}

# Return previous subtask's final output
# Uses "NULL" sentinel when no previous output found
# Usage: prev_final <tid> <id>
prev_final() {
	local tid="$1"
	local id="$2"
	if ! validate_id "$tid"; then
		echo "NULL"
		return 1
	fi
	local bb_dir="$BB_DIR/$tid"
	local plan_file="$bb_dir/p"

	if [[ ! -f "$plan_file" ]]; then
		echo "NULL"
		return 1
	fi

	local prev_id=""
	while IFS=' ' read -r sub_id rest; do
		if [[ "$sub_id" == "$id" ]]; then
			break
		fi
		prev_id="$sub_id"
	done <"$plan_file"

	if [[ -n "$prev_id" ]] && [[ -f "$bb_dir/$prev_id/f" ]]; then
		cat "$bb_dir/$prev_id/f"
	else
		echo "NULL"
	fi
}

# Read plan line for specific subtask
# Usage: read_plan_line <tid> <subtask_id>
# Returns: plan line for subtask, or empty string if not found
read_plan_line() {
	local tid="$1"
	local subtask_id="$2"

	if ! validate_id "$tid"; then
		return 1
	fi
	if ! validate_id "$subtask_id"; then
		return 1
	fi

	local plan_file="$BB_DIR/$tid/p"

	if [[ ! -f "$plan_file" ]]; then
		echo ""
		return 1
	fi

	while IFS=' ' read -r pid rest; do
		if [[ "$pid" == "$subtask_id" ]]; then
			echo "$pid $rest"
			return 0
		fi
	done <"$plan_file"

	echo ""
	return 1
}

# Normalize apfel output to extract plan lines
# Strips markdown fences, ANSI codes, numbered prefixes, and leading whitespace
# Usage: normalized_output="$(echo "$raw_output" | normalize_plan_output)"
normalize_plan_output() {
	local input
	input="$(cat)"

	echo "$input" | sed '/^```/d' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | sed 's/^[[:space:]]*//' | sed '/^$/d' | sed 's/^[0-9]\{1,2\}[.)][[:space:]]*//' | sed 's/^[*-][[:space:]]*//' | grep -E '^[a-zA-Z0-9]{3}[^a-zA-Z0-9]' || true
}

# Validate plan format before parsing (security)
validate_plan_format() {
	local plan="$1"
	if [[ -z "$plan" ]]; then
		echo "ERROR: Empty plan" >&2
		return 1
	fi

	# Count raw non-empty lines before normalization (for warning)
	local raw_count
	raw_count="$(echo "$plan" | grep -c '.' || true)"

	# Normalize the plan first to handle apfel's formatting
	plan="$(echo "$plan" | normalize_plan_output)"

	# Warn if normalization filtered lines
	local norm_count
	norm_count="$(echo "$plan" | grep -c '.' || true)"

	if ((raw_count > norm_count)); then
		echo "WARNING: $((raw_count - norm_count)) lines filtered during normalization" >&2
	fi

	local count=0
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		((count++))
		# Validate full format: "abc label: description, 100 words"
		if [[ ! "$line" =~ ^[a-zA-Z0-9]{3}[[:space:]]+[^:]+:[^,]+,[[:space:]]*[0-9]+[[:space:]]*words?$ ]]; then
			echo "ERROR: Invalid plan format on line $count: $line" >&2
			echo "  Expected: idN label: description, NNN words" >&2
			return 1
		fi
	done <<<"$plan"

	if ((count < 3)); then
		echo "ERROR: Plan needs at least 3 sections, got $count" >&2
		return 1
	fi

	return 0
}

# Parse plan and create subtask structure
# Usage: parse_plan <plan> <tid>
parse_plan() {
	local plan="$1"
	local tid="$2"
	if ! validate_id "$tid"; then
		return 1
	fi
	local bb_dir="$BB_DIR/$tid"
	local plan_file="$bb_dir/p"
	local status_file="$bb_dir/s"

	mkdir -p "$bb_dir"

	# Validate plan format before creating any files
	if ! validate_plan_format "$plan"; then
		return 1
	fi

	# Write plan file
	echo "$plan" >"$plan_file"

	# Initialize status file with waiting state
	while IFS=' ' read -r id rest; do
		if [[ -z "$id" ]]; then
			continue
		fi
		# Validate ID is exactly 3 alphanumeric chars before creating directory
		if [[ ! "$id" =~ ^[a-zA-Z0-9]{3}$ ]]; then
			echo "ERROR: Invalid task ID: $id (must be exactly 3 alphanumeric chars)" >&2
			return 1
		fi
		echo "$id - 0"
		mkdir -p "$bb_dir/$id"
	done <"$plan_file" >"$status_file"
}

# Count subtasks by state
# Usage: count_subtasks <tid>
# Returns: "waiting draft checkpoint fail final" counts
count_subtasks() {
	local tid="$1"
	if ! validate_id "$tid"; then
		echo "0 0 0 0 0"
		return 1
	fi
	local status_file="$BB_DIR/$tid/s"
	if [[ ! -f "$status_file" ]]; then
		echo "0 0 0 0 0"
		return 0
	fi

	local w=0 d=0 c=0 fail=0
	while IFS=' ' read -r _id state _retries; do
		case "$state" in
		-) ((w++)) ;;
		d) ((d++)) ;;
		c) ((c++)) ;;
		f) ((fail++)) ;;
		*) echo "WARNING: Unknown state '$state' in status file" >&2 ;;
		esac
	done <"$status_file"
	echo "$w $d $c $fail"
}

# Get overall task status
# Usage: get_task_status <tid>
# Returns: running, waiting, done, or unknown
get_task_status() {
	local tid="$1"
	if ! validate_id "$tid"; then
		echo "unknown"
		return 1
	fi
	local bb_dir="$BB_DIR/$tid"

	# Check if output exists (task completed)
	if [[ -f "$bb_dir/out" ]]; then
		echo "done"
		return 0
	fi

	# No output yet - derive status from subtask counts
	local counts
	counts="$(count_subtasks "$tid")"
	read -r w d c fail _ <<<"$counts"

	# If any waiting or in-progress (draft/checkpoint), task is running
	if ((w > 0 || d > 0 || c > 0)); then
		echo "running"
		return 0
	fi

	# No waiting/in-progress subtasks but no output yet
	if ((fail > 0)); then
		# Some failed but not stitched yet
		echo "waiting"
		return 0
	fi

	echo "unknown"
	return 0
}

# Get task goal snippet (first line, truncated)
# Usage: get_goal_snippet <tid>
# Returns: truncated goal text
get_goal_snippet() {
	local tid="$1"
	if ! validate_id "$tid"; then
		echo ""
		return 1
	fi
	local goal_file="$BB_DIR/$tid/g"
	if [[ ! -f "$goal_file" ]]; then
		echo ""
		return 0
	fi
	local goal
	goal="$(head -1 "$goal_file")"
	if [[ ${#goal} -gt 40 ]]; then
		echo "${goal:0:40}..."
	else
		echo "$goal"
	fi
}

# Check if task is safe to clean (not active/failed)
# Usage: is_task_safe_to_clean <task_dir>
# Returns: 0 if safe to clean, 1 if should skip
is_task_safe_to_clean() {
	local task_dir="$1"
	local tid
	tid="$(basename "$task_dir")"

	# Check if task has output file (completed)
	if [[ -f "$task_dir/out" ]]; then
		return 1
	fi

	# Check if any subtask is still in draft or waiting state (active)
	if [[ -f "$task_dir/s" ]]; then
		while IFS=' ' read -r _id state _retries; do
			case "$state" in
			d | - | f) return 1 ;; # draft, waiting, or failed = do not clean
			esac
		done <"$task_dir/s"
	fi

	return 0
}

# Clean tasks older than N days (skip active/failed tasks)
# Usage: clean_tasks <days> [dry_run]
clean_tasks() {
	local days="${1:-30}"
	local dry_run="${2:-false}"

	if [[ ! -d "$BB_DIR" ]]; then
		echo "No tasks found"
		return 0
	fi

	local cleaned=0
	while IFS= read -r task_dir; do
		[[ -z "$task_dir" ]] && continue

		if ! is_task_safe_to_clean "$task_dir"; then
			continue
		fi

		local tid
		tid="$(basename "$task_dir")"

		if [[ "$dry_run" == "true" ]]; then
			echo "Would clean: $tid"
		else
			rm -rf "$task_dir"
			echo "Cleaned: $tid"
		fi
		((cleaned++)) || true
	done < <(find "$BB_DIR" -maxdepth 1 -type d -mtime "+$days" 2>/dev/null)

	echo "Cleaned $cleaned tasks older than $days days"
}

# Prune completed tasks (have out file)
# Usage: prune_completed [dry_run]
prune_completed() {
	local dry_run="${1:-false}"

	if [[ ! -d "$BB_DIR" ]]; then
		echo "No tasks found"
		return 0
	fi

	local pruned=0
	for task_dir in "$BB_DIR"/*/; do
		[[ -d "$task_dir" ]] || continue

		# Only prune if out file exists (completed)
		if [[ -f "$task_dir/out" ]]; then
			local tid
			tid="$(basename "$task_dir")"

			if [[ "$dry_run" == "true" ]]; then
				echo "Would prune: $tid"
			else
				rm -rf "$task_dir"
				echo "Pruned: $tid"
			fi
			((pruned++)) || true
		fi
	done

	echo "Pruned $pruned completed tasks"
}
