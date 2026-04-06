#!/usr/bin/env bash
# Draft-verify harness for mnto
set -euo pipefail

# Source dependencies
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/blackboard.bash"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/planner.bash"

# Assemble context for subtask draft
# Usage: assemble_context <tid> <subtask_id>
# Reads: .bb/{tid}/p (plan), .bb/{tid}/g (goal), .bb/{tid}/{prev_id}/f (previous final, optional)
#        .bb/{tid}/{subtask_id}/c (critique, optional)
# Writes: .bb/{tid}/{subtask_id}/ctx
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

	# Read goal
	local goal=""
	if [[ -f "$bb_dir/g" ]]; then
		goal="$(cat "$bb_dir/g")"
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

	# Concatenate: goal + plan line + previous output + critique
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
		return 0
	else
		# Extract reason from "FAIL: reason"
		local reason="${result#FAIL: }"
		echo "$reason" >"$critique_file"
		local retries
		retries="$(get_retries "$tid" "$subtask_id")"
		set_status "$tid" "$subtask_id" "c" "$retries"
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
			sections+=("$(cat "$final_file")")
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

	# Process each subtask in order
	while IFS=' ' read -r subtask_id rest; do
		if [[ -z "$subtask_id" ]]; then
			continue
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
				# PASS - move to next subtask
				break
			else
				# FAIL - handle retry
				if ! handle_retry "$tid" "$subtask_id" 3; then
					# No retries left - accept unverified
					break
				fi
				# Retry with new draft
				if ! draft_subtask "$tid" "$subtask_id"; then
					echo "ERROR: Failed to redraft $subtask_id after retry" >&2
					return 1
				fi
			fi
		done
	done <"$plan_file"

	# Stitch all final drafts
	if ! stitch_task "$tid"; then
		echo "ERROR: Failed to stitch task $tid" >&2
		return 1
	fi

	return 0
}
