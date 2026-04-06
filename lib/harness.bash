#!/usr/bin/env bash
# Draft-verify harness for mnto
set -euo pipefail

# Source dependencies
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/blackboard.bash"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/planner.bash"

# Harness options (can be overridden)
DRY_RUN="${DRY_RUN:-false}"
VIPUNE_ENABLED="${VIPUNE_ENABLED:-false}"

# Print colored status message
# Usage: print_status "<state>" "<message>"
print_status() {
	local state="$1"
	local message="$2"
	case "$state" in
	PASS) printf '%s✓ PASS%s %s\n' "$C_GREEN" "$C_RESET" "$message" ;;
	RETRY) printf '%s⟳ RETRY%s %s\n' "$C_YELLOW" "$C_RESET" "$message" ;;
	FAIL) printf '%s✗ FAIL%s %s\n' "$C_RED" "$C_RESET" "$message" ;;
	INFO) printf '%s➤ INFO%s %s\n' "$C_BLUE" "$C_RESET" "$message" ;;
	*) printf '%s\n' "$message" ;;
	esac
}

# Assemble context for subtask draft
# Usage: assemble_context <tid> <subtask_id>
# Reads: .bb/{tid}/p (plan), .bb/{tid}/g (goal), .bb/{tid}/{prev_id}/f (previous final, optional)
#        .bb/{tid}/{subtask_id}/c (critique, optional)
# Writes: .bb/{tid}/{subtask_id}/ctx
# Options: VIPUNE_ENABLED=true adds vipune search results
assemble_context() {
	local tid="$1"
	local subtask_id="$2"

	if ! validate_id "$tid"; then
		return 1
	fi
	if ! validate_id "$subtask_id"; then
		return 1
	fi

	local bb_dir="$BB_DIR/$tid"
	local ctx_file="$bb_dir/$subtask_id/ctx"
	local tmp_ctx
	tmp_ctx="$(mktemp "${ctx_file}.XXXXXX")" || return 1

	# Read goal (truncate to 1024 bytes to prevent memory issues)
	local goal=""
	if [[ -f "$bb_dir/g" ]]; then
		goal="$(head -c 1024 "$bb_dir/g")"
	fi

	# Read plan line for this subtask
	local plan_line
	plan_line="$(read_plan_line "$tid" "$subtask_id")" || true

	# Read previous subtask's final output (if exists)
	local prev_output=""
	prev_output="$(prev_final "$tid" "$subtask_id")"
	if [[ "$prev_output" == "NULL" ]]; then
		prev_output=""
	fi

	# Read critique (if exists, for retry)
	local critique=""
	if [[ -f "$bb_dir/$subtask_id/c" ]]; then
		critique="$(cat "$bb_dir/$subtask_id/c")"
	fi

	# Build context sections
	{
		echo "GOAL:"
		echo "$goal"
		echo ""
		echo "TASK:"
		echo "$plan_line"
		echo ""
		if [[ -n "$prev_output" ]]; then
			echo "PREV:"
			echo "$prev_output"
			echo ""
		fi
		if [[ -n "$critique" ]]; then
			echo "CRIT:"
			echo "$critique"
			echo ""
		fi

		# Inject vipune results if enabled
		if [[ "$VIPUNE_ENABLED" == "true" ]]; then
			local vipune_results
			vipune_results="$(vipune_search "$goal")"
			if [[ -n "$vipune_results" ]]; then
				echo "$vipune_results"
			fi
		fi
	} >"$tmp_ctx"

	mv "$tmp_ctx" "$ctx_file"
}

# Verify subtask draft using apfel
# Usage: verify_subtask <tid> <subtask_id>
# Reads: .bb/{tid}/{subtask_id}/d (draft)
# Writes: .bb/{tid}/{subtask_id}/c (critique on FAIL), or promotes to .bb/{tid}/{subtask_id}/f on PASS
# Updates status: {subtask_id} c {retries} (FAIL) or {subtask_id} f {retries} (PASS)
# Returns: 0 on PASS, 1 on FAIL
verify_subtask() {
	local tid="$1"
	local subtask_id="$2"

	if ! validate_id "$tid"; then
		return 1
	fi
	if ! validate_id "$subtask_id"; then
		return 1
	fi

	local bb_dir="$BB_DIR/$tid"
	local draft_file="$bb_dir/$subtask_id/d"
	local critique_file="$bb_dir/$subtask_id/c"
	local final_file="$bb_dir/$subtask_id/f"

	if [[ ! -f "$draft_file" ]]; then
		echo "ERROR: Draft file not found: $draft_file" >&2
		return 1
	fi

	local draft
	draft="$(cat "$draft_file")"

	# Read plan line for this subtask (spec)
	local spec
	spec="$(read_plan_line "$tid" "$subtask_id")" || true

	# Assemble verify context: draft + spec
	local vctx="DRAFT:
$draft

SPEC:
$spec"

	# Call apfel with SYS_VERIFY
	local result
	if ! result="$(apfel -q -s "$SYS_VERIFY" -- "$vctx" 2>/dev/null)"; then
		echo "ERROR: apfel failed for subtask $subtask_id" >&2
		return 1
	fi

	# Parse result
	if [[ "$result" == PASS* ]]; then
		# Promote draft to final
		mv "$draft_file" "$final_file"
		local retries
		retries="$(get_retries "$tid" "$subtask_id")"
		set_status "$tid" "$subtask_id" "f" "$retries"
		print_status "PASS" "Subtask $subtask_id verified"
		return 0
	else
		# Extract reason from "FAIL: reason"
		local reason="${result#FAIL: }"
		echo "$reason" >"$critique_file"
		local retries
		retries="$(get_retries "$tid" "$subtask_id")"
		set_status "$tid" "$subtask_id" "c" "$retries"
		print_status "RETRY" "Subtask $subtask_id: $reason"
		return 1
	fi
}

# Get current retry count for subtask
# Usage: get_retries <tid> <subtask_id>
# Returns: retry count or 0 if not found
get_retries() {
	local tid="$1"
	local subtask_id="$2"
	local status_file="$BB_DIR/$tid/s"

	if [[ ! -f "$status_file" ]]; then
		echo "0"
		return
	fi

	while IFS=' ' read -r id _state retries; do
		if [[ "$id" == "$subtask_id" ]]; then
			echo "$retries"
			return
		fi
	done <"$status_file"

	echo "0"
}

# Handle retry logic after failed verification
# Usage: handle_retry <tid> <subtask_id> <max_retries>
# Returns: 0 if retry available, 1 if max retries exceeded
handle_retry() {
	local tid="$1"
	local subtask_id="$2"
	local max_retries="$3"

	if ! validate_id "$tid"; then
		return 1
	fi
	if ! validate_id "$subtask_id"; then
		return 1
	fi

	local bb_dir="$BB_DIR/$tid"
	local draft_file="$bb_dir/$subtask_id/d"
	local final_file="$bb_dir/$subtask_id/f"

	local retries
	retries="$(get_retries "$tid" "$subtask_id")"

	if ((retries >= max_retries)); then
		# Accept best draft with unverified comment
		if [[ -f "$draft_file" ]]; then
			mv "$draft_file" "$final_file"
			echo "" >>"$final_file"
			echo "<!-- memento: unverified -->" >>"$final_file"
		fi
		set_status "$tid" "$subtask_id" "f" "$retries"
		return 1
	else
		# Increment retry count
		((retries++)) || true
		set_status "$tid" "$subtask_id" "c" "$retries"
		return 0
	fi
}

# Generate draft for subtask using apfel
# Usage: draft_subtask <tid> <subtask_id>
# Reads: .bb/{tid}/{subtask_id}/ctx
# Writes: .bb/{tid}/{subtask_id}/d
# Updates status: {subtask_id} d 0
# Options: DRY_RUN=true shows context without calling apfel
draft_subtask() {
	local tid="$1"
	local subtask_id="$2"

	if ! validate_id "$tid"; then
		return 1
	fi
	if ! validate_id "$subtask_id"; then
		return 1
	fi

	local bb_dir="$BB_DIR/$tid"
	local ctx_file="$bb_dir/$subtask_id/ctx"
	local draft_file="$bb_dir/$subtask_id/d"

	if [[ ! -f "$ctx_file" ]]; then
		echo "ERROR: Context file not found: $ctx_file" >&2
		return 1
	fi

	local ctx
	ctx="$(cat "$ctx_file")"

	# Dry-run mode: show context without calling apfel
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "=== DRY RUN: Would send to apfel ===" >&2
		echo "System: $SYS_DRAFT" >&2
		echo "--- Context ---" >&2
		echo "$ctx" >&2
		echo "--- End Context ---" >&2
		return 0
	fi

	# Call apfel with SYS_DRAFT system prompt
	if ! apfel -q -s "$SYS_DRAFT" -- "$ctx" >"$draft_file" 2>/dev/null; then
		echo "ERROR: apfel failed for subtask $subtask_id" >&2
		return 1
	fi

	# Update status to draft state (preserve retry count for retry loop)
	local retries
	retries="$(get_retries "$tid" "$subtask_id")"
	set_status "$tid" "$subtask_id" "d" "$retries"
}

# Stitch all final drafts into final output
# Usage: stitch_task <tid>
# Reads: .bb/{tid}/p (plan), .bb/{tid}/{subtask_id}/f (final drafts)
# Writes: .bb/{tid}/out (final output)
# Returns: 0 on success
# Options: DRY_RUN=true shows context without calling apfel
stitch_task() {
	local tid="$1"

	if ! validate_id "$tid"; then
		return 1
	fi

	local bb_dir="$BB_DIR/$tid"
	local plan_file="$bb_dir/p"
	local out_file="$bb_dir/out"

	if [[ ! -f "$plan_file" ]]; then
		echo "ERROR: Plan file not found: $plan_file" >&2
		return 1
	fi

	# Collect all final drafts in order
	local -a sections=()
	while IFS=' ' read -r subtask_id rest; do
		if [[ -z "$subtask_id" ]]; then
			continue
		fi
		local final_file="$bb_dir/$subtask_id/f"
		if [[ -f "$final_file" ]]; then
			sections+=("$(<"$final_file")")
		fi
	done <"$plan_file"

	# Join sections with "---" separator
	local buffer=""
	for ((i = 0; i < ${#sections[@]}; i++)); do
		if ((i > 0)); then
			buffer="$buffer"$'\n'"---"$'\n'
		fi
		buffer="$buffer${sections[i]}"
	done

	# Decide: apfel combine vs direct concatenation
	local total_len=${#buffer}
	local result=""

	# Dry-run mode: skip apfel call
	if [[ "$DRY_RUN" == "true" ]]; then
		print_status "INFO" "DRY RUN: Skipping stitch, would combine ${#sections[@]} sections"
		printf '%s\n' "$buffer" >"$out_file"
		return 0
	fi

	if ((total_len < 3000)); then
		# Use apfel to combine
		if ! result="$(apfel -q -s "$SYS_STITCH" -- "$buffer" 2>/dev/null)"; then
			# Fallback to direct concatenation
			result="$buffer"
		fi
	else
		# Direct concatenation
		result="$buffer"
	fi

	printf '%s\n' "$result" >"$out_file"
}

# Process a single subtask through draft-verify loop
# Usage: process_subtask <tid> <subtask_id>
# Returns: 0 on success, 1 on failure (including max retries)
process_subtask() {
	local tid="$1"
	local subtask_id="$2"

	if ! validate_id "$tid"; then
		return 1
	fi
	if ! validate_id "$subtask_id"; then
		return 1
	fi

	# Assemble context for this subtask
	if ! assemble_context "$tid" "$subtask_id"; then
		echo "ERROR: Failed to assemble context for $subtask_id" >&2
		return 1
	fi

	# Initial draft
	if ! draft_subtask "$tid" "$subtask_id"; then
		echo "ERROR: Failed to draft $subtask_id" >&2
		return 1
	fi

	# Verify loop with retry
	while true; do
		if verify_subtask "$tid" "$subtask_id"; then
			# PASS - subtask complete
			return 0
		else
			# FAIL - handle retry
			if ! handle_retry "$tid" "$subtask_id" 3; then
				# No retries left - accept unverified draft, still considered success
				return 0
			fi
			# Retry with new draft
			if ! draft_subtask "$tid" "$subtask_id"; then
				echo "ERROR: Failed to redraft $subtask_id after retry" >&2
				return 1
			fi
		fi
	done
}

# Run the full draft-verify harness for a task
# Usage: run_harness <tid>
# Returns: 0 on success, 1 on failure
run_harness() {
	local tid="$1"

	if ! validate_id "$tid"; then
		return 1
	fi

	local bb_dir="$BB_DIR/$tid"
	local plan_file="$bb_dir/p"

	if [[ ! -f "$plan_file" ]]; then
		echo "ERROR: Plan file not found: $plan_file" >&2
		return 1
	fi

	print_status "INFO" "Starting harness for task $tid"

	# Process each subtask in order
	while IFS=' ' read -r subtask_id rest; do
		if [[ -z "$subtask_id" ]]; then
			continue
		fi

		print_status "INFO" "Processing subtask $subtask_id: $rest"

		if ! process_subtask "$tid" "$subtask_id"; then
			echo "ERROR: Failed to process subtask $subtask_id" >&2
			return 1
		fi
	done <"$plan_file"

	# Stitch all final drafts
	if ! stitch_task "$tid"; then
		echo "ERROR: Failed to stitch task $tid" >&2
		return 1
	fi

	print_status "PASS" "Task $tid completed"
	return 0
}
