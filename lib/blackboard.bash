#!/usr/bin/env bash
# Blackboard operations for mnto
set -euo pipefail

# ANSI terminal colours (used in harness.bash via source)
# Declare these without readonly to allow multiple sourcing, only set if not already defined
# shellcheck disable=SC2034
: "${C_RESET:=\033[0m}"
# shellcheck disable=SC2034
: "${C_RED:=\033[0;31m}"
# shellcheck disable=SC2034
: "${C_GREEN:=\033[0;32m}"
# shellcheck disable=SC2034
: "${C_YELLOW:=\033[0;33m}"
# shellcheck disable=SC2034
: "${C_BLUE:=\033[0;34m}"

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
# More lenient validation that accepts imperfect apfel output
validate_plan_format() {
	local plan="$1"
	if [[ -z "$plan" ]]; then
		echo "ERROR: Empty plan" >&2
		return 1
	fi

	# Filter empty lines and check minimum count (3 lines required per SYS_PLAN)
	# Count lines starting with 3 alnum + space/colon
	local valid_lines
	valid_lines=$(echo "$plan" | grep -c -E '^[a-zA-Z0-9]{3}[ :]' || true)
	if ((valid_lines < 3)); then
		echo "ERROR: Plan must have at least 3 valid sections (found $valid_lines)" >&2
		return 1
	fi
	return 0
}

# Parse plan and create subtask structure
# Handles multi-line apfel output by normalizing to single-line format
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

	# Normalize multi-line plan to single-line format
	local current_id=""
	local current_content=""
	local norm_plan=""
	
	while IFS= read -r line || [[ -n "$line" ]]; do
		# Check if line starts with a section ID (3 alnum + space/colon)
		local first_three="${line:0:3}"
		local fourth_char="${line:3:1}"
		if [[ "$first_three" =~ ^[a-zA-Z0-9]{3}$ ]] && { [[ "$fourth_char" == " " ]] || [[ "$fourth_char" == ":" ]]; }; then
			# Save previous section if exists
			if [[ -n "$current_id" ]]; then
				# Normalize content: single line, no leading/trailing spaces
				current_content=$(echo "$current_content" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]\+/ /g')
				# Truncate to reasonable length
				if [[ ${#current_content} -gt 60 ]]; then
					current_content="${current_content:0:60}..."
				fi
				norm_plan+="$current_id $current_content"$'\n'
			fi
			
			# Start new section: extract first 3 chars as ID
			current_id="${line:0:3}"
			# Extract content after the ID (skip first 4 chars: "AAA:")
			current_content="${line:4}"
		else
			# Accumulate content for current if it's not just whitespace
			if [[ -n "$current_id" ]] && [[ -n "$line" ]]; then
				# Trim and add space separator
				local trimmed
				trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
				current_content+=" $trimmed"
			fi
		fi
	done <<<"$plan"
	
	# Save last section
	if [[ -n "$current_id" ]]; then
		current_content=$(echo "$current_content" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]\+/ /g')
		if [[ ${#current_content} -gt 60 ]]; then
			current_content="${current_content:0:60}..."
		fi
		norm_plan+="$current_id $current_content"$'\n'
	fi
	
	# Write normalized plan file (one line per section)
	printf '%s' "$norm_plan" >"$plan_file"

	# Initialize status file with waiting state
	while IFS=' ' read -r id rest; do
		if [[ -z "$id" ]]; then
			continue
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
