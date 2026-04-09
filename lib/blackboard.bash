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
	if [[ ! "$id" =~ ^[a-z]{3}$ ]]; then
		echo "ERROR: Invalid task ID format '$id'" >&2
		return 1
	fi
	return 0
}

# Generate 3-char lowercase alphabetic ID with collision detection
gen_id() {
	local chars="abcdefghijklmnopqrstuvwxyz"
	local id=""
	local i
	while true; do
		id=""
		for ((i = 0; i < 3; i++)); do
			id+="${chars:$((RANDOM % 26)):1}"
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
# Handles: strict 3-char IDs, id1-style IDs, markdown headers
# Usage: normalized_output="$(echo "$raw_output" | normalize_plan_output)"
normalize_plan_output() {
	local input
	input="$(head -c 65536)"

	# Strip common markdown artifacts
	local clean
	clean="$(echo "$input" |
		sed '/^```/d' |
		sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' |
		sed 's/^[[:space:]]*//' |
		sed '/^[[:space:]]*$/d' |
		sed 's/^[0-9]\{1,2\}[.)][[:space:]]*//' |
		sed 's/^[*-][[:space:]]*//' ||
		true)"

	# Pass 1: Extract lines with strict 3-char alphabetic ID format
	local strict
	strict="$(echo "$clean" | grep -E '^[a-z]{3}[[:space:]]+' || true)"
	if [[ -n "$strict" ]]; then
		echo "$strict"
		return 0
	fi

	# Pass 2: Extract lines with label: description pattern (relaxed)
	# Handles: "id1 introduction: Welcome..." or "Introduction: Brief overview"
	local relaxed
	relaxed="$(echo "$clean" | grep -E '^[a-zA-Z0-9]+[[:space:]]+.*:' || true)"
	if [[ -n "$relaxed" ]]; then
		# Assign sequential 3-char IDs to each line
		local result=""
		local ids=("abc" "def" "ghi" "jkl" "mno" "pqr" "stu" "vwx")
		local counter=0
		while IFS= read -r line; do
			# Strip leading id1/id2/etc prefixes using bash substitution
			if [[ "$line" =~ ^[a-zA-Z]*[0-9]+[[:space:]]+ ]]; then
				local match="${BASH_REMATCH[0]}"
				line="${line#"$match"}"
			fi
			# Use next ID from rotation
			local id="${ids[$((counter % ${#ids[@]}))]}"
			result+="${id} ${line}"$'\n'
			counter=$((counter + 1))
		done <<<"$relaxed"
		# Remove trailing newline
		result="$(echo "$result" | sed '/^$/d')"
		echo "$result"
		return 0
	fi

	# Pass 3: Extract markdown headers as section titles
	local headers
	headers="$(echo "$input" | grep -E '^##[[:space:]]+[^#]' | sed 's/^##[[:space:]]*//' || true)"
	if [[ -n "$headers" ]]; then
		local result=""
		local ids=("abc" "def" "ghi" "jkl" "mno" "pqr" "stu" "vwx")
		local counter=0
		while IFS= read -r title; do
			local id="${ids[$((counter % ${#ids[@]}))]}"
			result+="${id} ${title}: ${title}, 100 words"$'\n'
			counter=$((counter + 1))
		done <<<"$headers"
		result="$(echo "$result" | sed '/^$/d')"
		echo "$result"
		return 0
	fi

	# All passes failed
	echo "WARNING: Could not normalize plan output" >&2
	return 1
}

# Validate plan format before parsing (security)
validate_plan_format() {
	local plan="$1"
	if [[ -z "$plan" ]]; then
		echo "ERROR: Empty plan" >&2
		return 1
	fi

	# Note: Plan should already be normalized before calling validate_plan_format.
	# generate_plan() handles normalization before this function is called.

	local count=0
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		count=$((count + 1))
		# Validate full format: "abc label: description, 100 words" (word count optional)
		if [[ ! "$line" =~ ^[a-z]{3}[[:space:]]+[^:]+:.+$ ]]; then
			echo "ERROR: Invalid plan format on line $count: $line" >&2
			echo "  Expected: abc label: description[, NNN words] (3 lowercase chars for ID)" >&2
			return 1
		fi
	done <<<"$plan"

	if ((count < 3)); then
		echo "ERROR: Plan needs at least 3 sections, got $count" >&2
		return 1
	fi

	return 0
}

# Fill in missing word counts with default value
# Usage: fill_missing_word_counts <plan>
fill_missing_word_counts() {
	local plan="$1"
	local line
	local result=""

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		# If line matches format but lacks word count, add default
		# Label must start with a letter and only contain letters/spaces
		if [[ "$line" =~ ^[a-z]{3}[[:space:]]+[[:alpha:]][[:alpha:][:space:]]*:.+ ]] && [[ ! "$line" =~ ,[[:space:]]*[0-9]+[[:space:]]*words[[:space:]]*$ ]]; then
			line="${line}, 100 words"
		fi
		result+="${line}"$'\n'
	done <<<"$plan"

	echo "$result"
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
		# Validate ID is exactly 3 lowercase alphabetic chars before creating directory
		if [[ ! "$id" =~ ^[a-z]{3}$ ]]; then
			echo "ERROR: Invalid subtask ID: $id (must be exactly 3 lowercase chars)" >&2
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
		-) w=$((w + 1)) ;;
		d) d=$((d + 1)) ;;
		c) c=$((c + 1)) ;;
		f) fail=$((fail + 1)) ;;
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
