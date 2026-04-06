#!/usr/bin/env bash
# Blackboard operations for mnto
set -euo pipefail

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

# Validate plan format before parsing (security)
validate_plan_format() {
	local plan="$1"
	if [[ -z "$plan" ]]; then
		echo "ERROR: Empty plan" >&2
		return 1
	fi

	# Filter empty lines and check minimum count (3 lines required per SYS_PLAN)
	local non_empty_lines=0
	while IFS= read -r line; do
		if [[ -z "$line" ]]; then
			continue
		fi
		((non_empty_lines++)) || true
		if [[ ! "$line" =~ ^[a-zA-Z0-9]{3} ]]; then
			echo "ERROR: Invalid plan format: $line" >&2
			return 1
		fi
	done <<<"$plan"
	if ((non_empty_lines < 3)); then
		echo "ERROR: Plan must have at least 3 sections (got $non_empty_lines)" >&2
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

	# Write plan file
	echo "$plan" >"$plan_file"

	# Validate plan format before parsing
	if ! validate_plan_format "$plan"; then
		rm -rf "$bb_dir"
		return 1
	fi

	# Initialize status file with waiting state
	while IFS=' ' read -r id rest; do
		if [[ -z "$id" ]]; then
			continue
		fi
		echo "$id - 0"
		mkdir -p "$bb_dir/$id"
	done <"$plan_file" >"$status_file"
}
