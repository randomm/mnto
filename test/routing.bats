#!/usr/bin/env bats
# Routing tests for auto-routing (issue #78) and dispatch deduplication (issue #81)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
	export MNTO="${BATS_TEST_DIRNAME}/.."
	export TEST_BB_DIR="$BATS_TMPDIR/mnto-routing-$BATS_TEST_NUMBER"
	export BB_DIR="$TEST_BB_DIR/.bb"
	mkdir -p "$BB_DIR"

	# openai.bash must be sourced before backend.bash (order matters)
	source "$MNTO/lib/openai.bash"
	source "$MNTO/lib/blackboard.bash"
	source "$MNTO/lib/backend.bash"
	source "$MNTO/lib/planner.bash"
	source "$MNTO/lib/direct.bash"
}

teardown() {
	rm -rf "$TEST_BB_DIR"
}

# ============================================================
# Issue #81: _infer_dispatch and infer_with_backend tests
# ============================================================

# For these tests we need to mock at the function level since
# _infer_apfel and _infer_openai are called internally by _infer_dispatch.

@test "_infer_dispatch: calls _infer_apfel for apfel backend" {
	# Mock _infer_apfel - receives: system context outfile (no backend arg)
	_infer_apfel() {
		local system="$1" context="$2" outfile="$3"
		if [[ -n "$outfile" ]]; then
			echo "apfel-dispatched" > "$outfile"
		else
			echo "apfel-dispatched"
		fi
	}
	export -f _infer_apfel

	local outfile="$TEST_BB_DIR/out.txt"
	_infer_dispatch "apfel" "system prompt" "context" "$outfile"

	[[ -f "$outfile" ]]
	grep -q "apfel-dispatched" "$outfile"
}

@test "_infer_dispatch: calls _infer_openai for openai backend" {
	# Mock _infer_openai - receives: backend system context outfile
	_infer_openai() {
		local backend="$1" system="$2" context="$3" outfile="$4"
		if [[ -n "$outfile" ]]; then
			echo "openai-dispatched" > "$outfile"
		else
			echo "openai-dispatched"
		fi
	}
	export -f _infer_openai

	local outfile="$TEST_BB_DIR/out.txt"
	_infer_dispatch "openai:http://localhost:8080/v1:gpt-4" "system prompt" "context" "$outfile"

	[[ -f "$outfile" ]]
	grep -q "openai-dispatched" "$outfile"
}

@test "_infer_dispatch: errors on unknown backend type" {
	run _infer_dispatch "unknown:type" "system" "context" ""
	[[ $status -ne 0 ]]
	[[ "$output" == *"ERROR: Invalid backend specification"* ]]
}

@test "infer_with_backend: delegates to _infer_dispatch for apfel" {
	# Mock _infer_apfel - receives: system context outfile (no backend arg)
	_infer_apfel() {
		local system="$1" context="$2" outfile="$3"
		if [[ -n "$outfile" ]]; then
			echo "apfel-dispatched" > "$outfile"
		else
			echo "apfel-dispatched"
		fi
	}
	export -f _infer_apfel

	local out
	out="$(infer_with_backend "apfel" "proposer" "system" "context" 2>/dev/null)" || true

	[[ "$out" == "apfel-dispatched" ]]
}

# ============================================================
# Issue #78: Auto-routing tests
# ============================================================

@test "should_use_workflow: function exists" {
	type should_use_workflow >/dev/null 2>&1
}

@test "should_use_workflow: MNTO_FORCE_WORKFLOW=true forces workflow" {
	MNTO_FORCE_WORKFLOW="true"
	run should_use_workflow "Hello world"
	[[ $status -eq 0 ]]
}

@test "should_use_workflow: MNTO_FORCE_DIRECT=true forces direct" {
	MNTO_FORCE_DIRECT="true"
	run should_use_workflow "Hello world"
	[[ $status -eq 1 ]]
}

@test "should_use_workflow: large goal routes to workflow" {
	local large_goal
	large_goal="$(printf 'x%.0s' {1..130000})"

	MNTO_WORKFLOW_THRESHOLD="120000"
	run should_use_workflow "$large_goal"
	[[ $status -eq 0 ]]
}

@test "should_use_workflow: small goal without intent routes to direct" {
	local small_goal="This is a simple task."

	MNTO_WORKFLOW_THRESHOLD="120000"
	run should_use_workflow "$small_goal"
	[[ $status -eq 1 ]]
}

@test "should_use_workflow: goal with 'then' routes to workflow" {
	local sequential_goal="First do the introduction, then write the body, then conclude."

	MNTO_WORKFLOW_THRESHOLD="120000"
	run should_use_workflow "$sequential_goal"
	[[ $status -eq 0 ]]
}

@test "should_use_workflow: goal with 'after' routes to workflow" {
	local after_goal="Gather materials after securing the permit"

	MNTO_WORKFLOW_THRESHOLD="120000"
	run should_use_workflow "$after_goal"
	[[ $status -eq 0 ]]
}

@test "should_use_workflow: goal with 'depends on' routes to workflow" {
	local dep_goal="Task B depends on Task A completing first"

	MNTO_WORKFLOW_THRESHOLD="120000"
	run should_use_workflow "$dep_goal"
	[[ $status -eq 0 ]]
}

@test "should_use_workflow: goal with 'step 1' routes to workflow" {
	local step_goal="Step 1: gather materials, Step 2: build foundation"

	MNTO_WORKFLOW_THRESHOLD="120000"
	run should_use_workflow "$step_goal"
	[[ $status -eq 0 ]]
}

@test "should_use_workflow: goal with 'first...then' routes to workflow" {
	local first_then_goal="First write the introduction, then elaborate the main points"

	MNTO_WORKFLOW_THRESHOLD="120000"
	run should_use_workflow "$first_then_goal"
	[[ $status -eq 0 ]]
}

@test "should_use_workflow: goal with 'review and' routes to workflow" {
	local review_goal="Write the content, review and revise the document"

	MNTO_WORKFLOW_THRESHOLD="120000"
	run should_use_workflow "$review_goal"
	[[ $status -eq 0 ]]
}

@test "should_use_workflow: MNTO_FORCE_WORKFLOW overrides threshold" {
	local small_goal="Short task"
	MNTO_WORKFLOW_THRESHOLD="120000"
	MNTO_FORCE_WORKFLOW="true"

	run should_use_workflow "$small_goal"
	[[ $status -eq 0 ]]
}

@test "should_use_workflow: MNTO_FORCE_DIRECT overrides threshold" {
	local large_goal
	large_goal="$(printf 'x%.0s' {1..200000})"
	MNTO_WORKFLOW_THRESHOLD="100"
	MNTO_FORCE_DIRECT="true"

	run should_use_workflow "$large_goal"
	[[ $status -eq 1 ]]
}

@test "should_use_workflow: 100 char threshold with 200 char goal routes to workflow" {
	local goal200
	goal200="$(printf 'x%.0s' {1..200})"
	MNTO_WORKFLOW_THRESHOLD="100"

	run should_use_workflow "$goal200"
	[[ $status -eq 0 ]]
}

@test "should_use_workflow: simple sentence without signals routes to direct" {
	local simple_goal="Write a haiku about autumn leaves"

	MNTO_WORKFLOW_THRESHOLD="120000"
	run should_use_workflow "$simple_goal"
	[[ $status -eq 1 ]]
}