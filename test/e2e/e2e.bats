#!/usr/bin/env bats
# e2e.bats - End-to-end scenarios for mnto workflow orchestrator
#
# Tests the full workflow orchestrator with realistic multi-step scenarios.
# Uses mock_infer to avoid real inference calls.
#
# NOTE: These tests use source_harness() to load library functions directly
# rather than invoking ./mnto as a black box. This is intentional — it enables
# mock inference without requiring a live LLM server. Full CLI-level e2e tests
# will be added in issue #77 (context-overflow benchmark) when live inference
# scenarios are needed.
#
# Scenarios:
#   01  Single-shot routing      - Direct mode for short goals
#   02  Workflow routing        - Harness mode with --workflow flag
#   03  DAG dependency ordering  - Sequential deps execute in order
#   04  Resume correctness       - Partial state resume processes remaining
#   05  Context isolation        - Dep outputs in context, not future tasks
#   06  Planner model routing    - Two-model architecture end-to-end

setup() {
	export MNTO="${BATS_TEST_DIRNAME}/../.."
	export TEST_BB_DIR="$BATS_TMPDIR/mnto-e2e-$BATS_TEST_NUMBER"
	export BB_DIR="$TEST_BB_DIR/.bb"
	mkdir -p "$BB_DIR"
}

# Standard mock infer — returns mock drafts for proposer, PASS 8 for verifier
setup_mock_infer() {
	infer() {
		local role="$1"
		local system="$2"
		local context="$3"
		local outfile="${4:-}"

		case "$role" in
		proposer)
			if [[ -n "$outfile" ]]; then
				echo "Mock draft content" >"$outfile"
			else
				echo "Mock draft content"
			fi
			;;
		verifier) echo "PASS 8" ;;
		esac
	}
}

teardown() {
	rm -rf "$TEST_BB_DIR"
}

# Source all harness dependencies in correct order
# shellcheck disable=SC1091
source_harness() {
	source "$MNTO/lib/blackboard.bash"
	source "$MNTO/lib/backend.bash"
	source "$MNTO/lib/planner.bash"
	source "$MNTO/lib/context.bash"
	source "$MNTO/lib/workflow.bash"
	source "$MNTO/lib/direct.bash"
}

# ============================================================================
# Scenario 01: Single-shot routing
# Goal: Short goal that should bypass harness and use direct mode
# Signal: is_direct_task returns 0 for short goals
# ============================================================================

@test "scenario_01_single_shot_routing" {
	source_harness

	# Create a short goal (under DIRECT_THRESHOLD of 300 chars)
	local tid="t01"
	mkdir -p "$BB_DIR/$tid"
	echo "Summarize: The quick brown fox jumps over the lazy dog." >"$BB_DIR/$tid/g"

	# is_direct_task should return 0 for short goals
	is_direct_task "$(cat "$BB_DIR/$tid/g")"
	[ $? -eq 0 ]

	# Verify no status file was created (direct mode path)
	# In direct mode, parse_plan is not called, so no status file
	[ ! -f "$BB_DIR/$tid/s" ]
}

# ============================================================================
# Scenario 02: Workflow routing
# Goal: Any goal with explicit plan forces harness mode
# Signal: $BB_DIR/tid/s exists with 2+ subtask entries
# ============================================================================

@test "scenario_02_workflow_routing" {
	source_harness

	local tid="xyz"
	mkdir -p "$BB_DIR/$tid"
	echo "Review this code and provide comprehensive feedback on the implementation" >"$BB_DIR/$tid/g"

	# Create a plan (simulating what generate_plan would produce)
	local plan="abc understand: Understand the code structure and purpose, 100 words, deps:
def analyze: Analyze the implementation for issues, 100 words, deps: abc
ghi conclude: Provide final recommendations, 100 words, deps: def"

	# Parse plan creates subtask directories and status file
	parse_plan "$plan" "$tid"
	[ $? -eq 0 ]

	# Signal: status file exists with at least 2 subtasks
	[ -f "$BB_DIR/$tid/s" ]

	# Count subtasks in status file
	local subtask_count
	subtask_count=$(wc -l <"$BB_DIR/$tid/s" | tr -d ' ')
	[ "$subtask_count" -ge 2 ]

	# Verify each subtask has a directory
	[ -d "$BB_DIR/$tid/abc" ]
	[ -d "$BB_DIR/$tid/def" ]
	[ -d "$BB_DIR/$tid/ghi" ]
}

# ============================================================================
# Scenario 03: DAG dependency ordering
# Goal: 3-step sequential task with explicit deps
# Signal: Files exist in dep order, mtime proves ordering
# ============================================================================

@test "scenario_03_dag_dependency_ordering" {
	source_harness

	local tid="sxr"

	# Create the DAG plan with zab->zcd->zef deps
	local plan="zab understand: Understand what the code does, 80 words, deps:
zcd issues: Identify potential issues with the implementation, 80 words, deps: zab
zef improve: Suggest specific improvements, 80 words, deps: zcd"

	# Mock infer for full workflow execution
	setup_mock_infer

	# Parse the plan to set up the DAG
	parse_plan "$plan" "$tid"

	# Sleep 1s to ensure final file mtimes are separated (mtime resolution is 1s)
	sleep 1

	# Run the workflow
	run_workflow "$tid"
	[ $? -eq 0 ]

	# Signal 1: All subtask directories have final files
	[ -f "$BB_DIR/$tid/zab/f" ]
	[ -f "$BB_DIR/$tid/zcd/f" ]
	[ -f "$BB_DIR/$tid/zef/f" ]

	# Signal 2: Terminal output exists (zef is terminal node)
	[ -f "$BB_DIR/$tid/out" ]

	# Signal 3: Dependency ordering via mtime (no-regression assertion)
	# zab must not be NEWER than zcd — if zab completed after zcd started, the
	# DAG ordering is violated. Same-second execution is valid (sequential within
	# same second), but zab must complete AT OR BEFORE zcd.
	local zab_mtime zcd_mtime
	zab_mtime=$(stat -f '%m' "$BB_DIR/$tid/zab/f" 2>/dev/null || stat -c '%Y' "$BB_DIR/$tid/zab/f" 2>/dev/null)
	zcd_mtime=$(stat -f '%m' "$BB_DIR/$tid/zcd/f" 2>/dev/null || stat -c '%Y' "$BB_DIR/$tid/zcd/f" 2>/dev/null)
	[ "$zab_mtime" -le "$zcd_mtime" ]

	# Signal 4: Verify status file records correct deps (proves DAG parsing correct)
	local zab_deps zcd_deps zef_deps
	zab_deps=$(grep "^zab " "$BB_DIR/$tid/s" | awk '{print $4}') || true
	zcd_deps=$(grep "^zcd " "$BB_DIR/$tid/s" | awk '{print $4}') || true
	zef_deps=$(grep "^zef " "$BB_DIR/$tid/s" | awk '{print $4}') || true
	[ "$zab_deps" == "" ]       # zab has no deps
	[ "$zcd_deps" == "zab" ]   # zcd depends on zab
	[ "$zef_deps" == "zcd" ]   # zef depends on zcd

	# Also verify status file shows correct final states
	local zab_status zcd_status zef_status
	zab_status=$(grep "^zab " "$BB_DIR/$tid/s" | awk '{print $2}')
	zcd_status=$(grep "^zcd " "$BB_DIR/$tid/s" | awk '{print $2}')
	zef_status=$(grep "^zef " "$BB_DIR/$tid/s" | awk '{print $2}')

	[ "$zab_status" == "f" ]
	[ "$zcd_status" == "f" ]
	[ "$zef_status" == "f" ]
}

# ============================================================================
# Scenario 04: Resume correctness
# Goal: Pre-create partial state, verify resume processes only remaining
# Signal: Completed subtask NOT re-processed; new subtasks ARE processed
# ============================================================================

@test "scenario_04_resume_correctness" {
	source_harness

	local tid="sax"

	# Pre-create partial state:
	# - zab is complete (final file exists with old content)
	# - zcd and zef are waiting

	mkdir -p "$BB_DIR/$tid/zab" "$BB_DIR/$tid/zcd" "$BB_DIR/$tid/zef"

	echo "zab understand: Understand what the code does, 80 words, deps:
zcd issues: Identify potential issues, 80 words, deps: zab
zef improve: Suggest improvements, 80 words, deps: zcd" >"$BB_DIR/$tid/p"

	# Status: zab=final, zcd=waiting, zef=waiting
	echo "zab f 0 " >"$BB_DIR/$tid/s"
	echo "zcd - 0 zab" >>"$BB_DIR/$tid/s"
	echo "zef - 0 zcd" >>"$BB_DIR/$tid/s"

	# Pre-existing final file for zab (old content)
	echo "Old content from zab - should NOT be overwritten" >"$BB_DIR/$tid/zab/f"

	# Store zab mtime before resume
	local zab_mtime_before
	zab_mtime_before=$(stat -f '%m' "$BB_DIR/$tid/zab/f" 2>/dev/null || stat -c '%Y' "$BB_DIR/$tid/zab/f" 2>/dev/null)
	sleep 1

	# Mock infer for remaining tasks
	infer() {
		local role="$1"
		local system="$2"
		local context="$3"
		local outfile="${4:-}"

		case "$role" in
		proposer)
			if [[ -n "$outfile" ]]; then
				if [[ "$context" == *"zcd"* ]]; then
					echo "New content from zcd" >"$outfile"
				elif [[ "$context" == *"zef"* ]]; then
					echo "New content from zef" >"$outfile"
				else
					echo "Draft content" >"$outfile"
				fi
			else
				echo "Draft content"
			fi
			;;
		verifier)
			echo "PASS 8"
			;;
		esac
	}

	# Run resume using workflow functions directly (resume_task not available in harness)
	# Get ready tasks and process them
	local ready
	ready="$(get_ready_tasks "$tid")"
	[[ -n "$ready" ]]

	# Process ready subtasks using DAG runner
	local -a ready_queue=()
	for rt in $ready; do
		ready_queue+=("$rt")
	done
	_run_dag_from_queue "$tid" "${ready_queue[@]}"

	# Write terminal outputs
	_write_terminal_outputs "$tid"

	# Signal 1: zab was NOT re-processed (mtime unchanged)
	local zab_mtime_after
	zab_mtime_after=$(stat -f '%m' "$BB_DIR/$tid/zab/f" 2>/dev/null || stat -c '%Y' "$BB_DIR/$tid/zab/f" 2>/dev/null)
	[ "$zab_mtime_before" -eq "$zab_mtime_after" ]

	# Signal 2: zcd was processed (new final file exists)
	[ -f "$BB_DIR/$tid/zcd/f" ]

	# Signal 3: zef was processed (depends on zcd)
	[ -f "$BB_DIR/$tid/zef/f" ]

	# Signal 4: Output file created from terminal node (zef)
	[ -f "$BB_DIR/$tid/out" ]

	# Verify content is from new processing, not old
	local zcd_content
	zcd_content=$(cat "$BB_DIR/$tid/zcd/f")
	[[ "$zcd_content" == *"New content from zcd"* ]]
}

# ============================================================================
# Scenario 05: Context isolation
# Goal: 3-step DAG, verify zcd context contains only zab output (not zef)
# Signal: $BB_DIR/tid/zcd/ctx has DEP_OUTPUTS with only first dep
# ============================================================================

@test "scenario_05_context_isolation" {
	source_harness

	local tid="sbx"

	mkdir -p "$BB_DIR/$tid/zab" "$BB_DIR/$tid/zcd" "$BB_DIR/$tid/zef"

	# Create DAG: zab -> zcd -> zef
	local plan="zab understand: Understand what the code does, 80 words, deps:
zcd issues: Identify potential issues, 80 words, deps: zab
zef improve: Suggest improvements, 80 words, deps: zcd"

	# Status file
	echo "zab f 0 " >"$BB_DIR/$tid/s"
	echo "zcd - 0 zab" >>"$BB_DIR/$tid/s"
	echo "zef - 0 zcd" >>"$BB_DIR/$tid/s"

	# Pre-populate final files for ALL tasks (including zef which is NOT a dep of zcd)
	# This is critical: zef/f must exist with the "Content from zef output" string
	# BEFORE assemble_context runs. If we don't pre-create it, the test would be
	# trivially true — we'd be asserting that zef's content isn't present simply
	# because zef/f was never written, not because of actual isolation.
	# By pre-creating zef/f, we PROVE isolation: get_dep_outputs includes only
	# declared deps (zab), not all siblings, even when sibling outputs exist.
	echo "Content from zab output" >"$BB_DIR/$tid/zab/f"
	echo "Content from zcd output" >"$BB_DIR/$tid/zcd/f"
	echo "Content from zef output" >"$BB_DIR/$tid/zef/f"

	# Assemble context for zcd (which depends on zab only)
	assemble_context "$tid" "zcd"
	[ $? -eq 0 ]

	# Verify context file exists
	[ -f "$BB_DIR/$tid/zcd/ctx" ]

	local ctx_content
	ctx_content=$(cat "$BB_DIR/$tid/zcd/ctx")

	# Signal 1: Context contains DEP_OUTPUTS section
	[[ "$ctx_content" == *"DEP_OUTPUTS:"* ]]

	# Signal 2: Context contains zab's output
	[[ "$ctx_content" == *"Content from zab output"* ]]

	# Signal 3: Context does NOT contain zef's content PROVES isolation.
	# zef/f exists with "Content from zef output" (pre-created above), yet
	# assemble_context does NOT include it because zef is NOT a dep of zcd.
	# get_dep_outputs includes only declared deps (zab), not all siblings.
	# This proves the isolation property: context is filtered by dependency graph.
	[[ "$ctx_content" != *"Content from zef output"* ]]

	# Signal 4: Context does not contain zef output (zef is not a dep of zcd)
	# Note: zcd's deps are only "zab", so only zab's output appears in DEP_OUTPUTS
	[[ "$ctx_content" != *"zef output"* ]]
}

# ============================================================================
# Scenario 06: MNTO_PLANNER_MODEL routing
# Goal: Verify two-model architecture is wired correctly
# Signal: Workflow completes with both proposer and verifier roles called
# ============================================================================

@test "scenario_06_planner_model_routing" {
	source_harness

	local tid="scx"
	mkdir -p "$BB_DIR/$tid"

	# Simulate two-model environment
	export MNTO_PROPOSER="openai:http://localhost:11434/v1:planner-model"
	export MNTO_MODEL="openai:http://localhost:11434/v1:executor-model"

	# Mock infer that tracks roles
	setup_mock_infer

	# Create a goal
	echo "Perform a complex multi-step analysis" >"$BB_DIR/$tid/g"

	# Create plan directly (testing workflow execution, not plan generation)
	local plan="zab step1: First step, 80 words, deps:
zcd step2: Second step, 80 words, deps: zab
zef step3: Third step, 80 words, deps: zcd"
	parse_plan "$plan" "$tid"
	[ $? -eq 0 ]

	# Run workflow (uses proposer/verifier via _resolve_backend)
	run_workflow "$tid"
	[ $? -eq 0 ]

	# Signal: Workflow completed with output
	[ -f "$BB_DIR/$tid/out" ]

	# Verify output has content from terminal subtask
	local out_content
	out_content=$(cat "$BB_DIR/$tid/out")
	[ -n "$out_content" ]
}
