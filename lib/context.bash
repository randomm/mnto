#!/usr/bin/env bash
# Context assembly for mnto workflow
set -euo pipefail

# Dependency guard
if [[ "${_BLACKBOARD_SOURCED:-}" != "1" ]]; then
	echo "ERROR: context.bash requires blackboard.bash to be sourced first" >&2
	# shellcheck disable=SC2317
	return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC2317
declare -r _CONTEXT_SOURCED=1

# Get outputs of declared dependencies for a subtask
# Usage: get_dep_outputs <tid> <subtask_id>
# Returns: formatted dep outputs, or empty if no deps
get_dep_outputs() {
	local tid="$1"
	local subtask_id="$2"
	local deps
	deps="$(get_task_deps "$tid" "$subtask_id")"

	[[ -z "$deps" ]] && return 0

	local output=""
	local dep
	for dep in $(echo "$deps" | tr ',' ' '); do
		# Validate dep ID before using as path component
		if ! validate_id "$dep" 2>/dev/null; then
			continue
		fi
		local dep_file="$BB_DIR/$tid/$dep/f"
		if [[ -f "$dep_file" ]]; then
			output+="--- $dep output ---"$'\n'
			output+="$(cat "$dep_file")"$'\n'
		fi
	done
	echo "$output"
}
