#!/usr/bin/env bash
# Stitch step: combine final subtask outputs into unified document
set -euo pipefail

# Dependency guard — must source blackboard.bash, backend.bash, and planner.bash first
if [[ "${_BLACKBOARD_SOURCED:-}" != "1" ]] || [[ "${_BACKEND_SOURCED:-}" != "1" ]] || [[ "${_PLANNER_SOURCED:-}" != "1" ]]; then
	echo "ERROR: stitcher.bash requires blackboard.bash, backend.bash, and planner.bash to be sourced first" >&2
	# shellcheck disable=SC2317
	return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC2317
declare -r _STITCHER_SOURCED=1

# Stitch all final drafts into final output
# Usage: stitch_task <tid>
# Reads: .mnto/bb/{tid}/p (plan), .mnto/bb/{tid}/{subtask_id}/f (final drafts)
# Writes: .mnto/bb/{tid}/out (final output)
# Returns: 0 on success
# Options: DRY_RUN=true shows context without calling apfel
stitch_task() {
	local tid="$1"

	if ! validate_id "$tid"; then
		return 1
	fi

	# shellcheck disable=SC2153 # BB_DIR is defined in mnto at runtime
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

	# Write sections directly to temp file (avoid O(n²) buffer concatenation)
	local tmp_out
	tmp_out="$(mktemp "${out_file}.XXXXXX")" || return 1

	for ((i = 0; i < ${#sections[@]}; i++)); do
		if ((i > 0)); then
			printf '\n---\n\n' >>"$tmp_out"
		fi
		printf '%s\n' "${sections[i]}" >>"$tmp_out"
	done

	# Read back for apfel processing if needed
	local total_len
	total_len="$(wc -c <"$tmp_out")"

	# Decide: apfel combine vs direct use
	local result=""

	# Dry-run mode: skip apfel call
	if [[ "$DRY_RUN" == "true" ]]; then
		print_status "INFO" "DRY RUN: Skipping stitch, would combine ${#sections[@]} sections"
		mv "$tmp_out" "$out_file"
		return 0
	fi

	if ((total_len < 3000)); then
		# Use infer to combine
		local buffer
		buffer="$(cat "$tmp_out")"

		if ! result="$(infer stitcher "$SYS_STITCH" "$buffer" 2>/dev/null)"; then
			local exit_code=$?
			if ((exit_code == 3)); then
				echo "WARNING: guardrail blocked stitching, using direct concatenation" >&2
			elif ((exit_code == 4)); then
				echo "WARNING: context overflow during stitching, using direct concatenation" >&2
			else
				echo "WARNING: inference failed during stitching (exit code $exit_code), using direct concatenation" >&2
			fi
			# Fallback to direct concatenation
			result="$buffer"
		fi
		echo "$result" >"$tmp_out"
	else
		# Direct concatenation - already in tmp_out
		:
	fi

	mv "$tmp_out" "$out_file"
}
