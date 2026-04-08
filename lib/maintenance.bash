#!/usr/bin/env bash
# Task maintenance operations for mnto

# Dependency guard — must source blackboard.bash first
if [[ "${_BLACKBOARD_SOURCED:-}" != "1" ]]; then
	echo "ERROR: maintenance.bash requires blackboard.bash to be sourced first" >&2
	# shellcheck disable=SC2317
	return 1 2>/dev/null || exit 1
fi

set -euo pipefail

# Idempotency guard — prevent double-sourcing
[[ -n "${_MAINTENANCE_SOURCED:-}" ]] && return 0
declare -r _MAINTENANCE_SOURCED=1

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
