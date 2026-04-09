#!/usr/bin/env bats
# Harness tests for draft-verify loop - Part 1: Context assembly + Draft step

setup() {
	export MNTO="${BATS_TEST_DIRNAME}/.."
	export TEST_BB_DIR="$BATS_TMPDIR/mnto-harness-$BATS_TEST_NUMBER"
	export BB_DIR="$TEST_BB_DIR/.bb"
	mkdir -p "$BB_DIR"
}

teardown() {
	rm -rf "$TEST_BB_DIR"
}

# Source all harness dependencies in correct order
source_harness() {
	source "$MNTO/lib/blackboard.bash"
	source "$MNTO/lib/backend.bash"
	source "$MNTO/lib/planner.bash"
	source "$MNTO/lib/harness.bash"
	source "$MNTO/lib/stitcher.bash"
}

# Mock infer for testing
mock_infer() {
	echo "mock draft response"
}

@test "assemble_context creates context file" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "Write a comprehensive guide" >"$BB_DIR/tst/g"
	echo "abc Introduction: Overview of the topic" >"$BB_DIR/tst/p"

	assemble_context "tst" "abc"

	[ -f "$BB_DIR/tst/abc/ctx" ]
}

@test "assemble_context includes goal" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "Test goal content" >"$BB_DIR/tst/g"
	echo "abc Introduction: An overview" >"$BB_DIR/tst/p"

	assemble_context "tst" "abc"

	local content
	content=$(cat "$BB_DIR/tst/abc/ctx")
	[[ "$content" == *"Test goal content"* ]]
}

@test "assemble_context includes plan line" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "Some goal" >"$BB_DIR/tst/g"
	echo "abc Introduction: An overview of the topic" >"$BB_DIR/tst/p"

	assemble_context "tst" "abc"

	local content
	content=$(cat "$BB_DIR/tst/abc/ctx")
	[[ "$content" == *"abc Introduction: An overview of the topic"* ]]
}

@test "assemble_context includes previous output when exists" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc" "$BB_DIR/tst/def"
	echo "Previous section content" >"$BB_DIR/tst/abc/f"
	echo "abc Introduction: Overview" >"$BB_DIR/tst/p"
	echo "def Background: Details" >>"$BB_DIR/tst/p"

	# prev_final for "def" should return content from "abc"
	assemble_context "tst" "def"

	local content
	content=$(cat "$BB_DIR/tst/def/ctx")
	[[ "$content" == *"PREV:"* ]]
	[[ "$content" == *"Previous section content"* ]]
}

@test "assemble_context includes critique when exists (retry)" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "Goal" >"$BB_DIR/tst/g"
	echo "abc Introduction: Overview" >"$BB_DIR/tst/p"
	echo "Please add more detail" >"$BB_DIR/tst/abc/c"

	assemble_context "tst" "abc"

	local content
	content=$(cat "$BB_DIR/tst/abc/ctx")
	[[ "$content" == *"CRIT:"* ]]
	[[ "$content" == *"Please add more detail"* ]]
}

@test "assemble_context validates task ID" {
	source_harness

	run assemble_context "xx" "abc"
	[ "$status" -ne 0 ]
}

@test "assemble_context validates subtask ID" {
	source_harness

	run assemble_context "tst" "zz"
	[ "$status" -ne 0 ]
}

@test "draft_subtask calls apfel and creates draft file" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "Goal" >"$BB_DIR/tst/g"
	echo "abc Introduction: An overview" >"$BB_DIR/tst/p"
	echo "abc - 0" >"$BB_DIR/tst/s"

	# Create context file that draft_subtask reads
	{
		echo "GOAL:"
		echo "Test goal"
		echo ""
		echo "TASK:"
		echo "abc Introduction: An overview"
	} >"$BB_DIR/tst/abc/ctx"

	# Mock infer
	infer() {
		echo "Draft content for section"
	}

	draft_subtask "tst" "abc"

	[ -f "$BB_DIR/tst/abc/d" ]
	local content
	content=$(cat "$BB_DIR/tst/abc/d")
	[[ "$content" == *"Draft content"* ]]
}

@test "draft_subtask fails if context missing" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "abc - 0" >"$BB_DIR/tst/s"

	run draft_subtask "tst" "abc"
	[ "$status" -ne 0 ]
}

@test "draft_subtask handles apfel failure" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "Goal" >"$BB_DIR/tst/g"
	echo "abc Section" >"$BB_DIR/tst/p"
	echo "abc - 0" >"$BB_DIR/tst/s"
	{
		echo "GOAL:"
		echo "Test"
		echo ""
		echo "TASK:"
		echo "abc Section"
	} >"$BB_DIR/tst/abc/ctx"

	# Mock infer to fail
	infer() {
		return 1
	}

	run draft_subtask "tst" "abc"
	[ "$status" -ne 0 ]
}

@test "draft_subtask validates IDs" {
	source_harness

	run draft_subtask "xx" "abc"
	[ "$status" -ne 0 ]

	run draft_subtask "tst" "zz"
	[ "$status" -ne 0 ]
}

# ============ Part 2: Verify and Retry Tests ============

@test "verify_subtask promotes draft to final on PASS" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "Some goal" >"$BB_DIR/tst/g"
	echo "abc Introduction: An overview" >"$BB_DIR/tst/p"
	echo "Draft content for section" >"$BB_DIR/tst/abc/d"
	echo "abc d 0" >"$BB_DIR/tst/s"

	infer() {
		echo "PASS"
	}

	run verify_subtask "tst" "abc"
	[ "$status" -eq 0 ]
	[ -f "$BB_DIR/tst/abc/f" ]
	[ ! -f "$BB_DIR/tst/abc/d" ]

	local status
	status=$(grep "^abc" "$BB_DIR/tst/s")
	[[ "$status" == "abc f "* ]]
}

@test "verify_subtask creates critique on FAIL" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "Some goal" >"$BB_DIR/tst/g"
	echo "abc Introduction: An overview" >"$BB_DIR/tst/p"
	echo "Draft content" >"$BB_DIR/tst/abc/d"
	echo "abc d 0" >"$BB_DIR/tst/s"

	infer() {
		echo "FAIL: Missing required content"
	}

	run verify_subtask "tst" "abc"
	[ "$status" -eq 1 ]
	[ -f "$BB_DIR/tst/abc/c" ]
	[ -f "$BB_DIR/tst/abc/d" ]

	local critique
	critique=$(cat "$BB_DIR/tst/abc/c")
	[[ "$critique" == "Missing required content"* ]]

	local status
	status=$(grep "^abc" "$BB_DIR/tst/s")
	[[ "$status" == "abc c "* ]]
}

@test "verify_subtask handles apfel failure" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "Goal" >"$BB_DIR/tst/g"
	echo "abc Section" >"$BB_DIR/tst/p"
	echo "Draft content" >"$BB_DIR/tst/abc/d"
	echo "abc d 0" >"$BB_DIR/tst/s"

	infer() {
		return 1
	}

	run verify_subtask "tst" "abc"
	[ "$status" -ne 0 ]
}

@test "verify_subtask validates IDs" {
	source_harness

	run verify_subtask "xx" "abc"
	[ "$status" -ne 0 ]

	run verify_subtask "tst" "zz"
	[ "$status" -ne 0 ]
}

@test "verify_subtask fails if draft missing" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "abc d 0" >"$BB_DIR/tst/s"

	run verify_subtask "tst" "abc"
	[ "$status" -ne 0 ]
}

@test "handle_retry increments count on retry" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "abc c 1" >"$BB_DIR/tst/s"

	run handle_retry "tst" "abc" 3
	[ "$status" -eq 0 ]

	local retries
	retries="$(get_retries "tst" "abc")"
	[ "$retries" -eq 2 ]

	local status
	status=$(grep "^abc" "$BB_DIR/tst/s")
	[[ "$status" == "abc c 2" ]]
}

@test "handle_retry accepts draft after max retries" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "abc c 3" >"$BB_DIR/tst/s"
	echo "Best effort draft content" >"$BB_DIR/tst/abc/d"

	run handle_retry "tst" "abc" 3
	[ "$status" -eq 1 ]
	[ -f "$BB_DIR/tst/abc/f" ]
	[ ! -f "$BB_DIR/tst/abc/d" ]

	local final
	final=$(cat "$BB_DIR/tst/abc/f")
	[[ "$final" == *"Best effort draft content"* ]]
	[[ "$final" == *"<!-- memento: unverified -->"* ]]
}

@test "handle_retry validates IDs" {
	source_harness

	run handle_retry "xx" "abc" 3
	[ "$status" -ne 0 ]

	run handle_retry "tst" "zz" 3
	[ "$status" -ne 0 ]
}

# ============ Part 3: Stitch and Main Loop Tests ============

@test "stitch_task combines final drafts" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc" "$BB_DIR/tst/def"
	echo "abc Introduction: Overview" >"$BB_DIR/tst/p"
	echo "def Background: Details" >>"$BB_DIR/tst/p"
	echo "First section content" >"$BB_DIR/tst/abc/f"
	echo "Second section content" >"$BB_DIR/tst/def/f"

	# Mock infer for stitching task
	infer() {
		echo "Combined sections"
	}

	stitch_task "tst"

	[ -f "$BB_DIR/tst/out" ]
	local output
	output="$(cat "$BB_DIR/tst/out")"
}

@test "stitch_task uses infer when under 3000 chars" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "abc Short: Brief section" >"$BB_DIR/tst/p"
	echo "Small content" >"$BB_DIR/tst/abc/f"

	infer() {
		echo "Combined by infer"
	}

	stitch_task "tst"

	[ -f "$BB_DIR/tst/out" ]
	local output
	output="$(cat "$BB_DIR/tst/out")"
	[[ "$output" == *"Combined by infer"* ]]
}

@test "stitch_task concatenates directly when over 3000 chars" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "abc Long: Detailed section" >"$BB_DIR/tst/p"
	# Create content > 3000 chars
	local large_content
	printf -v large_content 'A%.0s' {1..4000}
	echo "$large_content" >"$BB_DIR/tst/abc/f"

	infer() {
		# Should NOT be called for large content
		echo "ERROR: infer should not be called" >&2
	}

	stitch_task "tst"

	[ -f "$BB_DIR/tst/out" ]
	local output
	output="$(cat "$BB_DIR/tst/out")"
	[[ "$output" == "$large_content" ]]
}

@test "run_harness processes all subtasks" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc" "$BB_DIR/tst/def" "$BB_DIR/tst/ghi"
	echo "abc Intro: Overview" >"$BB_DIR/tst/p"
	echo "def Body: Details" >>"$BB_DIR/tst/p"
	echo "ghi End: Summary" >>"$BB_DIR/tst/p"
	echo "Goal" >"$BB_DIR/tst/g"
	echo "abc - 0" >"$BB_DIR/tst/s"
	echo "def - 0" >>"$BB_DIR/tst/s"
	echo "ghi - 0" >>"$BB_DIR/tst/s"

	# Mock infer to return PASS for all
	infer() {
		echo "PASS"
	}

	run run_harness "tst"
	[ "$status" -eq 0 ]
	[ -f "$BB_DIR/tst/out" ]
}

@test "run_harness handles retry loop" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "abc Section: Details" >"$BB_DIR/tst/p"
	echo "Goal" >"$BB_DIR/tst/g"
	echo "abc - 0" >"$BB_DIR/tst/s"

	local count_file="$BATS_TMPDIR/call_count_$$"
	echo "0" >"$count_file"
	infer() {
		local count
		count=$(cat "$count_file")
		echo "$((++count))" >"$count_file"
		if [[ "$count" -le 2 ]]; then
			echo "FAIL: Try again"
		else
			echo "PASS"
		fi
	}

	run run_harness "tst"
	[ "$status" -eq 0 ]
	local final_count
	final_count=$(cat "$count_file")
	[ "$final_count" -ge 3 ]
	[ -f "$BB_DIR/tst/out" ]
	rm -f "$count_file"
}

@test "run_harness accepts unverified after max retries" {
	source_harness

	mkdir -p "$BB_DIR/tst/abc"
	echo "abc Section: Details" >"$BB_DIR/tst/p"
	echo "Goal" >"$BB_DIR/tst/g"
	echo "abc - 0" >"$BB_DIR/tst/s"

	# Mock infer - echo last arg for SYS_STITCH, fail for others
	infer() {
		if [[ "$*" == *"$SYS_STITCH"* ]]; then
			# Last positional argument is the content
			echo "${@: -1}"
		else
			echo "FAIL: Always fails"
		fi
	}

	run run_harness "tst"
	[ "$status" -eq 0 ]
	[ -f "$BB_DIR/tst/out" ]

	# Should contain unverified marker
	local output
	output="$(cat "$BB_DIR/tst/out")"
	[[ "$output" == *"<!-- memento: unverified -->"* ]]
}
