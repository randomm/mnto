#!/usr/bin/env bash
# Workflow executor for mnto — DAG-based dependency-aware task execution
set -euo pipefail

# Dependency guard — must source blackboard.bash, backend.bash, planner.bash, and context.bash first
if [[ "${_BLACKBOARD_SOURCED:-}" != "1" ]] || [[ "${_BACKEND_SOURCED:-}" != "1" ]] || [[ "${_PLANNER_SOURCED:-}" != "1" ]] || [[ "${_CONTEXT_SOURCED:-}" != "1" ]]; then
	echo "ERROR: workflow.bash requires blackboard.bash, backend.bash, planner.bash, and context.bash to be sourced first" >&2
	# shellcheck disable=SC2317
	return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC2317
declare -r _WORKFLOW_SOURCED=1

# Harness options (can be overridden)
DRY_RUN="${DRY_RUN:-false}"
VIPUNE_ENABLED="${VIPUNE_ENABLED:-false}"

# Structured error logging — write JSON error objects for operational visibility.
# Production pattern: 65% of enterprise failures from schema drift are caught earlier
# with structured logging.
# Usage: _log_error <tid> <stage> <message>
_log_error() {
	local tid="$1"
	local stage="$2"
	local message="$3"
	local bb_dir="$BB_DIR/$tid"
	local log_file="$bb_dir/errors.jsonl"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	# Append structured error (JSONL format)
	printf '{"ts":"%s","tid":"%s","stage":"%s","msg":"%s"}\n' \
		"$timestamp" "$tid" "$stage" "$message" >>"$log_file" 2>/dev/null || true
}

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
		retries=$((retries + 1))
		set_status "$tid" "$subtask_id" "c" "$retries"
		return 0
	fi
}

# Assemble context for subtask draft
# Usage: assemble_context <tid> <subtask_id>
# Reads: .mnto/bb/{tid}/p (plan), .mnto/bb/{tid}/g (goal), .mnto/bb/{tid}/{dep_id}/f (dep outputs)
#        .mnto/bb/{tid}/{subtask_id}/c (critique, optional)
# Writes: .mnto/bb/{tid}/{subtask_id}/ctx
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

	# Read dependency outputs instead of just prev_final
	local dep_outputs=""
	dep_outputs="$(get_dep_outputs "$tid" "$subtask_id")"
	if [[ ${#dep_outputs} -gt 200 ]]; then
		dep_outputs="${dep_outputs:0:200}..."
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
		if [[ -n "$dep_outputs" ]]; then
			echo "DEP_OUTPUTS:"
			echo "$dep_outputs"
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

# Generate draft for subtask using apfel
# Usage: draft_subtask <tid> <subtask_id>
# Reads: .mnto/bb/{tid}/{subtask_id}/ctx
# Writes: .mnto/bb/{tid}/{subtask_id}/d
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

	# Safety: ensure context doesn't start with - (would be interpreted as apfel flag)
	if [[ "$ctx" == -* ]]; then
		ctx=$'\n'"$ctx"
	fi

	# Dry-run mode: show context without calling infer
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "=== DRY RUN: Would send to infer ===" >&2
		echo "System: $SYS_DRAFT" >&2
		echo "--- Context ---" >&2
		echo "$ctx" >&2
		echo "--- End Context ---" >&2
		return 0
	fi

	# Call infer proposer with SYS_DRAFT system prompt
	local draft_exit=0
	infer proposer "$SYS_DRAFT" "$ctx" "$draft_file" 2>/dev/null || draft_exit=$?
	if ((draft_exit != 0)); then
		if ((draft_exit == 3)); then
			_log_error "$tid" "draft" "guardrail blocked subtask $subtask_id"
			echo "ERROR: guardrail blocked drafting for subtask $subtask_id" >&2
			return 1
		elif ((draft_exit == 4)); then
			_log_error "$tid" "draft" "context overflow subtask $subtask_id"
			echo "ERROR: context overflow during drafting for subtask $subtask_id" >&2
			return 1
		else
			_log_error "$tid" "draft" "inference failed subtask $subtask_id exit=$draft_exit"
			echo "ERROR: inference failed for subtask $subtask_id (exit code $draft_exit)" >&2
			return 1
		fi
	fi

	# Update status to draft state (preserve retry count for retry loop)
	local retries
	retries="$(get_retries "$tid" "$subtask_id")"
	set_status "$tid" "$subtask_id" "d" "$retries"
}

# Verify subtask draft using apfel
# Usage: verify_subtask <tid> <subtask_id>
# Reads: .mnto/bb/{tid}/{subtask_id}/d (draft)
# Writes: .mnto/bb/{tid}/{subtask_id}/c (critique on FAIL), or promotes to .mnto/bb/{tid}/{subtask_id}/f on PASS
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
	local reason=""

	if [[ ! -f "$draft_file" ]]; then
		echo "ERROR: Draft file not found: $draft_file" >&2
		return 1
	fi

	local draft
	draft="$(cat "$draft_file")"

	# Quick bash pre-check: fail fast on empty or trivially bad drafts
	# without wasting an LLM verification call.
	# 10 chars is below any meaningful sentence fragment; catches empty output,
	# single-word responses, and inference errors that produce minimal text.
	local min_draft_len="${MNTO_MIN_DRAFT_LEN:-10}"
	local draft_len=${#draft}
	if ((draft_len < min_draft_len)); then
		echo "Draft too short (${draft_len} chars)" >"$critique_file"
		local retries
		retries="$(get_retries "$tid" "$subtask_id")"
		set_status "$tid" "$subtask_id" "c" "$retries"
		print_status "RETRY" "Subtask $subtask_id: draft too short"
		return 1
	fi

	# Read plan line for this subtask (spec)
	local spec
	spec="$(read_plan_line "$tid" "$subtask_id")" || true

	# Assemble verify context: draft + spec
	local vctx="DRAFT:
$draft

SPEC:
$spec"

	# Safety: ensure context doesn't start with - (would be interpreted as apfel flag)
	if [[ "$vctx" == -* ]]; then
		vctx=$'\n'"$vctx"
	fi

	# Call infer verifier with SYS_VERIFY
	local result
	local verify_exit=0
	result="$(infer verifier "$SYS_VERIFY" "$vctx" 2>/dev/null)" || verify_exit=$?
	if ((verify_exit != 0)); then
		if ((verify_exit == 3)); then
			_log_error "$tid" "verify" "guardrail blocked subtask $subtask_id"
			echo "ERROR: guardrail blocked verification for subtask $subtask_id" >&2
			return 1
		elif ((verify_exit == 4)); then
			_log_error "$tid" "verify" "context overflow subtask $subtask_id"
			echo "ERROR: context overflow during verification for subtask $subtask_id" >&2
			return 1
		else
			_log_error "$tid" "verify" "inference failed subtask $subtask_id exit=$verify_exit"
			echo "ERROR: inference failed for subtask $subtask_id (exit code $verify_exit)" >&2
			return 1
		fi
	fi

	# Parse result with confidence scoring (RECONCILE-inspired).
	# Expected format: "PASS 8" or "FAIL 3: reason" (verdict + confidence 1-10).
	# Strip markdown, scan all lines for verdict.
	local stripped
	stripped="$(echo "$result" | sed 's/\*\*//g; s/`//g')"

	# Extract verdict line: PASS [N] or FAIL [N]: reason
	local verdict_line
	verdict_line="$(echo "$stripped" | grep -E '^(PASS|FAIL)' | head -1)" || true

	local verdict="" confidence=5
	if [[ "$verdict_line" =~ ^(PASS|FAIL)[[:space:]]*([0-9]+)? ]]; then
		verdict="${BASH_REMATCH[1]}"
		[[ -n "${BASH_REMATCH[2]}" ]] && confidence="${BASH_REMATCH[2]}"
	fi

	if [[ -z "$verdict" ]]; then
		# No clear verdict — treat as low-confidence fail
		echo "Verifier returned no PASS or FAIL verdict" >"$critique_file"
		local retries
		retries="$(get_retries "$tid" "$subtask_id")"
		set_status "$tid" "$subtask_id" "c" "$retries"
		print_status "RETRY" "Subtask $subtask_id: no verdict from verifier"
		return 1
	elif [[ "$verdict" == "PASS" ]]; then
		# Promote draft to final
		mv "$draft_file" "$final_file"
		local retries
		retries="$(get_retries "$tid" "$subtask_id")"
		set_status "$tid" "$subtask_id" "f" "$retries"
		print_status "PASS" "Subtask $subtask_id verified (confidence: $confidence)"
		return 0
	else
		# FAIL verdict — check confidence. Low-confidence FAILs (< 4) are
		# likely pedantic; accept draft as soft pass to avoid wasted retries.
		if ((confidence < 4)); then
			mv "$draft_file" "$final_file"
			echo "" >>"$final_file"
			echo "<!-- memento: soft-pass (low-confidence fail: $confidence) -->" >>"$final_file"
			local retries
			retries="$(get_retries "$tid" "$subtask_id")"
			set_status "$tid" "$subtask_id" "f" "$retries"
			print_status "PASS" "Subtask $subtask_id: low-confidence FAIL ($confidence), accepting"
			return 0
		fi

		# High-confidence FAIL — extract reason and retry
		local reason=""
		if [[ "$verdict_line" =~ FAIL[[:space:]]*[0-9]*:[[:space:]]*(.+)$ ]]; then
			reason="${BASH_REMATCH[1]}"
		else
			reason="${verdict_line}"
		fi
		[[ -z "$reason" || "$reason" =~ ^[[:space:]]+$ ]] && reason="No reason provided"

		echo "$reason" >"$critique_file"
		local retries
		retries="$(get_retries "$tid" "$subtask_id")"
		set_status "$tid" "$subtask_id" "c" "$retries"
		print_status "RETRY" "Subtask $subtask_id (confidence: $confidence): $reason"
		return 1
	fi
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

	# Verify loop with echo chamber detection.
	# Research (RECONCILE): same-model agents reinforce incorrect beliefs.
	# If we see 2 consecutive similar critiques, accept the draft rather
	# than burning more retries on the same echo chamber.
	local prev_critique=""
	while true; do
		if verify_subtask "$tid" "$subtask_id"; then
			# PASS - subtask complete
			return 0
		else
			# Check for echo chamber: if current critique is similar to previous,
			# the verifier is stuck in a loop. Accept and move on.
			local bb_dir="$BB_DIR/$tid"
			local critique_file="$bb_dir/$subtask_id/c"
			if [[ -f "$critique_file" ]] && [[ -n "$prev_critique" ]]; then
				local curr_critique
				curr_critique="$(cat "$critique_file")"
				# Simple similarity: first 80 chars match (same complaint repeated)
				if [[ "${curr_critique:0:80}" == "${prev_critique:0:80}" ]]; then
					print_status "INFO" "Subtask $subtask_id: echo chamber detected, accepting draft"
					local draft_file="$bb_dir/$subtask_id/d"
					local final_file="$bb_dir/$subtask_id/f"
					if [[ -f "$draft_file" ]]; then
						mv "$draft_file" "$final_file"
						echo "" >>"$final_file"
						echo "<!-- memento: unverified (echo chamber) -->" >>"$final_file"
					fi
					local retries
					retries="$(get_retries "$tid" "$subtask_id")"
					set_status "$tid" "$subtask_id" "f" "$retries"
					return 0
				fi
				prev_critique="$curr_critique"
			elif [[ -f "$critique_file" ]]; then
				prev_critique="$(cat "$critique_file")"
			fi

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

# Write terminal node outputs to out file
# Terminal nodes = subtasks that never appear in any other subtask's deps
# Usage: _write_terminal_outputs <tid>
_write_terminal_outputs() {
	local tid="$1"
	local bb_dir="$BB_DIR/$tid"
	local plan_file="$bb_dir/p"
	local out_file="$bb_dir/out"

	if [[ ! -f "$plan_file" ]]; then
		echo "ERROR: Plan file not found: $plan_file" >&2
		return 1
	fi

	# Collect all subtask IDs from plan
	local -a all_subtasks=()
	while IFS=' ' read -r subtask_id rest; do
		[[ -z "$subtask_id" ]] && continue
		all_subtasks+=("$subtask_id")
	done <"$plan_file"

	# Find terminal nodes (subtasks not in any dep list)
	declare -A appears_as_dep
	for st in "${all_subtasks[@]}"; do
		appears_as_dep[$st]=0
	done

	local status_file="$bb_dir/s"
	while IFS=' ' read -r id state retries deps; do
		[[ -z "$deps" ]] && continue
		for dep in $(echo "$deps" | tr ',' ' '); do
			appears_as_dep[$dep]=1
		done
	done <"$status_file"

	# Terminal nodes are those with appears_as_dep=0
	local -a terminals=()
	for st in "${all_subtasks[@]}"; do
		if [[ "${appears_as_dep[$st]:-}" == "0" ]]; then
			terminals+=("$st")
		fi
	done

	# Write terminal outputs in plan order
	local tmp_out
	tmp_out="$(mktemp "${out_file}.XXXXXX")" || return 1

	for st in "${all_subtasks[@]}"; do
		# Check if this is a terminal
		local is_terminal=false
		for t in "${terminals[@]}"; do
			if [[ "$t" == "$st" ]]; then
				is_terminal=true
				break
			fi
		done
		if "$is_terminal"; then
			local final_file="$bb_dir/$st/f"
			if [[ -f "$final_file" ]]; then
				if [[ -s "$tmp_out" ]]; then
					printf '\n---\n\n' >>"$tmp_out"
				fi
				cat "$final_file" >>"$tmp_out"
			fi
		fi
	done

	mv "$tmp_out" "$out_file"
}

# Run the workflow using Kahn's algorithm for DAG execution
# Usage: run_workflow <tid>
# Returns: 0 on success, 1 on failure
run_workflow() {
	local tid="$1"

	if ! validate_id "$tid"; then
		return 1
	fi

	local bb_dir="$BB_DIR/$tid"
	local plan_file="$bb_dir/p"
	local status_file="$bb_dir/s"

	if [[ ! -f "$plan_file" ]]; then
		echo "ERROR: Plan file not found: $plan_file" >&2
		return 1
	fi

	print_status "INFO" "Starting workflow for task $tid"

	# Build in-degree map and dependency graph from status file
	declare -A in_degree
	declare -A dep_list
	local -a all_subtasks=()

	while IFS=' ' read -r id state retries deps; do
		[[ -z "$id" ]] && continue
		all_subtasks+=("$id")
		dep_list[$id]="${deps:-}"
		# Count unmet deps (initially all deps are unmet because no task is final yet)
		local count=0
		if [[ -n "$deps" ]]; then
			for dep in $(echo "$deps" | tr ',' ' '); do
				count=$((count + 1))
			done
		fi
		in_degree[$id]=$count
	done <"$status_file"

	# Build reverse dependency map: for each dep, which tasks depend on it
	declare -A dependents
	for subtask in "${all_subtasks[@]}"; do
		local deps="${dep_list[$subtask]:-}"
		if [[ -n "$deps" ]]; then
			for dep in $(echo "$deps" | tr ',' ' '); do
				dependents[$dep]="${dependents[$dep]:-}${dependents[$dep]:+,}$subtask"
			done
		fi
	done

	# Find initial ready tasks (in_degree == 0)
	local -a ready_queue=()
	for subtask in "${all_subtasks[@]}"; do
		if [[ "${in_degree[$subtask]:-}" == "0" ]]; then
			ready_queue+=("$subtask")
		fi
	done

	# Circuit breaker state
	local max_consecutive_failures="${MNTO_CIRCUIT_BREAKER:-3}"
	local consecutive_failures=0
	local total_subtasks=0
	local completed_subtasks=0
	local failed_subtasks=0

	print_status "INFO" "Ready queue initial: ${ready_queue[*]:-}"

	# Process ready queue using Kahn's algorithm
	while [[ ${#ready_queue[@]} -gt 0 ]]; do
		# Pop from ready queue (shift)
		local current="${ready_queue[0]}"
		ready_queue=("${ready_queue[@]:1}")

		if [[ -z "$current" ]]; then
			continue
		fi

		total_subtasks=$((total_subtasks + 1))
		print_status "INFO" "Processing subtask $current"

		if process_subtask "$tid" "$current"; then
			completed_subtasks=$((completed_subtasks + 1))
			consecutive_failures=0

			# Session checkpoint: record last successfully processed subtask
			echo "$current" >"$bb_dir/checkpoint"

			# Decrement in-degree of all dependents; enqueue if now ready
			local dep_deps="${dependents[$current]:-}"
			if [[ -n "$dep_deps" ]]; then
				for dependent in $(echo "$dep_deps" | tr ',' ' '); do
					in_degree[$dependent]=$((in_degree[$dependent] - 1))
					if [[ "${in_degree[$dependent]}" == "0" ]]; then
						ready_queue+=("$dependent")
						print_status "INFO" "Subtask $dependent is now ready"
					fi
				done
			fi
		else
			failed_subtasks=$((failed_subtasks + 1))
			consecutive_failures=$((consecutive_failures + 1))

			# Circuit breaker: abort on consecutive failures
			if ((consecutive_failures >= max_consecutive_failures)); then
				print_status "FAIL" "Circuit breaker: $consecutive_failures consecutive failures, aborting"
				_log_error "$tid" "circuit_breaker" "Aborted after $consecutive_failures consecutive failures ($failed_subtasks/$total_subtasks total)"
				return 1
			fi

			# Circuit breaker: abort if >50% failure rate (after at least 3 subtasks)
			if ((total_subtasks >= 3)) && ((failed_subtasks * 2 > total_subtasks)); then
				print_status "FAIL" "Circuit breaker: >50% failure rate ($failed_subtasks/$total_subtasks), aborting"
				_log_error "$tid" "circuit_breaker" "Aborted: $failed_subtasks/$total_subtasks failures exceed 50% threshold"
				return 1
			fi
		fi
	done

	# All subtasks processed — write terminal outputs to out file
	_write_terminal_outputs "$tid"

	print_status "PASS" "Task $tid completed (workflow)"
	return 0
}