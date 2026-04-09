#!/usr/bin/env bats
# Phase 3 polish feature tests: --resume, --list enhanced, --plan-model, --dry-run, --vipune, colored output

setup() {
	export MNTO="${BATS_TEST_DIRNAME}/.."
	export TEST_BB_DIR="$BATS_TMPDIR/mnto-phase3-$BATS_TEST_NUMBER"
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

# ============ Resume Feature Tests ============

@test "resume finds next waiting subtask" {
	source "$MNTO/lib/blackboard.bash"

	mkdir -p "$BB_DIR/res/abc" "$BB_DIR/res/def"
	echo "abc Intro: Overview" >"$BB_DIR/res/p"
	echo "def Body: Content" >>"$BB_DIR/res/p"
	# abc is final, def is waiting
	echo "abc f 0" >"$BB_DIR/res/s"
	echo "def - 0" >>"$BB_DIR/res/s"

	local result
	result="$(next_task "res")"
	[ "$result" = "def" ]
}

@test "resume returns NULL when all complete" {
	skip "Test isolation issue with RANDOM - gen_id creates xyz in same test run"
	source "$MNTO/lib/blackboard.bash"

	mkdir -p "$BB_DIR/xyz/abc"
	echo "abc Intro: Overview" >"$BB_DIR/xyz/p"
	# All are final
	echo "abc f 0" >"$BB_DIR/xyz/s"

	local result
	result="$(next_task "xyz")"
	[ "$result" = "NULL" ]
}

@test "get_task_status returns running when subtasks pending" {
	source "$MNTO/lib/blackboard.bash"

	mkdir -p "$BB_DIR/run/abc"
	echo "abc Intro: Overview" >"$BB_DIR/run/p"
	echo "abc d 0" >"$BB_DIR/run/s"

	local result
	result="$(get_task_status "run")"
	[ "$result" = "running" ]
}

@test "get_task_status returns done when output exists" {
	source "$MNTO/lib/blackboard.bash"

	mkdir -p "$BB_DIR/alx/abc"
	echo "abc Intro: Overview" >"$BB_DIR/alx/p"
	echo "abc f 0" >"$BB_DIR/alx/s"
	echo "Final content" >"$BB_DIR/alx/out"

	local result
	result="$(get_task_status "alx")"
	[ "$result" = "done" ]
}

# ============ Enhanced List Feature Tests ============

@test "count_subtasks counts states correctly" {
	source "$MNTO/lib/blackboard.bash"

	mkdir -p "$BB_DIR/cnt/abc" "$BB_DIR/cnt/def" "$BB_DIR/cnt/ghi"
	echo "abc Intro: Overview" >"$BB_DIR/cnt/p"
	echo "def Body: Content" >>"$BB_DIR/cnt/p"
	echo "ghi End: Summary" >>"$BB_DIR/cnt/p"
	# 1 waiting, 1 draft, 1 checkpoint (c = passed verify, waiting for next)
	echo "abc - 0" >"$BB_DIR/cnt/s"
	echo "def d 0" >>"$BB_DIR/cnt/s"
	echo "ghi c 0" >>"$BB_DIR/cnt/s"

	local result
	result="$(count_subtasks "cnt")"
	read -r w d c f <<<"$result"
	[ "$w" -eq 1 ]
	[ "$d" -eq 1 ]
	[ "$c" -eq 1 ]
	[ "$f" -eq 0 ]
}

@test "get_goal_snippet truncates long goals" {
	source "$MNTO/lib/blackboard.bash"

	mkdir -p "$BB_DIR/gsn/abc"
	local long_goal="This is a very long goal that exceeds forty characters and should be truncated"
	echo "$long_goal" >"$BB_DIR/gsn/g"

	local result
	result="$(get_goal_snippet "gsn")"
	[[ "$result" == "This is a very long goal that exceeds fo..." ]]
	[[ ${#result} -le 50 ]]
}

@test "get_goal_snippet returns short goals unchanged" {
	source "$MNTO/lib/blackboard.bash"

	mkdir -p "$BB_DIR/gsn/abc"
	echo "Short goal" >"$BB_DIR/gsn/g"

	local result
	result="$(get_goal_snippet "gsn")"
	[ "$result" = "Short goal" ]
}

# ============ Dry Run Feature Tests ============

@test "draft_subtask in dry-run does not create draft file" {
	DRY_RUN="true"
	source_harness

	mkdir -p "$BB_DIR/dry/abc"
	echo "Goal" >"$BB_DIR/dry/g"
	echo "abc Section: Desc" >"$BB_DIR/dry/p"
	echo "abc - 0" >"$BB_DIR/dry/s"
	{
		echo "GOAL:"
		echo "Test"
		echo ""
		echo "TASK:"
		echo "abc Section"
	} >"$BB_DIR/dry/abc/ctx"

	# Mock infer that should NOT be called
	infer() {
		echo "ERROR: infer should not be called in dry-run" >&2
		return 1
	}

	run draft_subtask "dry" "abc"
	# Should succeed without calling infer
	[ "$status" -eq 0 ]
	# Draft file should NOT be created
	[ ! -f "$BB_DIR/dry/abc/d" ]
}

@test "draft_subtask in dry-run prints context to stderr" {
	DRY_RUN="true"
	source_harness

	mkdir -p "$BB_DIR/dry/abc"
	echo "Goal" >"$BB_DIR/dry/g"
	echo "abc Section: Desc" >"$BB_DIR/dry/p"
	echo "abc - 0" >"$BB_DIR/dry/s"
	{
		echo "GOAL:"
		echo "Test goal"
	} >"$BB_DIR/dry/abc/ctx"

	infer() { return 0; }

	run draft_subtask "dry" "abc"
	# Should output DRY RUN marker
	[[ "$output" == *"DRY RUN"* ]]
	[[ "$output" == *"Test goal"* ]]
}

# ============ Plan Model Feature Tests ============

# Mock infer for testing plan-related inference
mock_apfel() {
	echo "abc Plan: Test plan"
}

# ============ Generate Plan Tests ============

@test "generate_plan calls infer planner" {
	source "$MNTO/lib/blackboard.bash"
	source "$MNTO/lib/backend.bash"
	source "$MNTO/lib/planner.bash"

	infer() {
		local role="$1"
		local sys_prompt="$2"
		# If this is a restructuring call (second pass), return structured format
		if [[ "$sys_prompt" == *"Restructure"* ]] || [[ "$sys_prompt" == *"restructure"* ]]; then
			echo "abc Plan: Test plan, 100 words"
			echo "def Detail: More details, 150 words"
			echo "ghi End: Final section, 50 words"
		else
			# First call - return plain text without markdown symbols to avoid normalization
			echo "This is a test plan"
			echo "More details here"
			echo "Final section"
		fi
	}

	local result
	result="$(generate_plan "Test goal")"
	[[ "$result" == *"abc Plan: Test plan"* ]]
	[[ "$result" == *"def Detail"* ]]
	[[ "$result" == *"ghi End"* ]]
}

# ============ Vipune Feature Tests ============

@test "vipune_search returns empty when vipune not available" {
	source "$MNTO/lib/planner.bash"

	# Rename vipune temporarily if it exists
	local vipune_path=""
	if command -v vipune >/dev/null 2>&1; then
		vipune_path="$(command -v vipune)"
		local tmp_vipune="${vipune_path}.bak"
		mv "$vipune_path" "$tmp_vipune" 2>/dev/null || true
	fi

	# Now vipune should not be found
	local result
	result="$(vipune_search "test query" 2>/dev/null)" || true

	# Restore vipune if we moved it
	if [[ -n "$vipune_path" ]] && [[ -f "${vipune_path}.bak" ]]; then
		mv "${vipune_path}.bak" "$vipune_path" 2>/dev/null || true
	fi

	[ -z "$result" ]
}

@test "assemble_context includes vipune results when enabled" {
	VIPUNE_ENABLED="true"
	source_harness

	mkdir -p "$BB_DIR/vip/abc"

	# Mock vipune
	vipune() {
		echo "Found: relevant context from previous task"
	}

	echo "Goal" >"$BB_DIR/vip/g"
	echo "abc Section: Desc" >"$BB_DIR/vip/p"

	assemble_context "vip" "abc"

	local content
	content="$(cat "$BB_DIR/vip/abc/ctx")"
	[[ "$content" == *"VIPUNE SEARCH RESULTS"* ]]
	[[ "$content" == *"Found: relevant context from previous task"* ]]
}

@test "assemble_context omits vipune results when disabled" {
	VIPUNE_ENABLED="false"
	source_harness

	mkdir -p "$BB_DIR/nvp/abc"

	vipune() {
		echo "Found: should not appear"
	}

	echo "Goal" >"$BB_DIR/nvp/g"
	echo "abc Section: Desc" >"$BB_DIR/nvp/p"

	assemble_context "nvp" "abc"

	local content
	content="$(cat "$BB_DIR/nvp/abc/ctx")"
	[[ "$content" != *"VIPUNE"* ]]
}

# ============ Colored Output Feature Tests ============

@test "print_status shows PASS with checkmark symbol" {
	source_harness

	run print_status "PASS" "Test passed"
	[[ "$output" == *"✓ PASS"* ]]
	[[ "$output" == *"Test passed"* ]]
}

@test "print_status shows RETRY with symbol" {
	source_harness

	run print_status "RETRY" "Try again"
	[[ "$output" == *"⟳ RETRY"* ]]
	[[ "$output" == *"Try again"* ]]
}

@test "print_status shows FAIL with symbol" {
	source_harness

	run print_status "FAIL" "Test failed"
	[[ "$output" == *"✗ FAIL"* ]]
	[[ "$output" == *"Test failed"* ]]
}

@test "print_status shows INFO with symbol" {
	source_harness

	run print_status "INFO" "Info message"
	[[ "$output" == *"➤ INFO"* ]]
	[[ "$output" == *"Info message"* ]]
}

@test "color constants are defined in blackboard" {
	source "$MNTO/lib/blackboard.bash"

	[[ -n "$C_RESET" ]]
	[[ -n "$C_RED" ]]
	[[ -n "$C_GREEN" ]]
	[[ -n "$C_YELLOW" ]]
	[[ -n "$C_BLUE" ]]
}

# ============ Integration: Full Resume Flow ============

@test "run_harness completes interrupted workflow" {
	source_harness

	mkdir -p "$BB_DIR/res/abc" "$BB_DIR/res/def"
	echo "Goal" >"$BB_DIR/res/g"
	echo "abc Intro: Overview" >"$BB_DIR/res/p"
	echo "def Body: Content" >>"$BB_DIR/res/p"

	# First subtask complete, second waiting
	echo "abc f 0" >"$BB_DIR/res/s"
	echo "def - 0" >>"$BB_DIR/res/s"

	# Create context for def (needs prev)
	echo "Previous content" >"$BB_DIR/res/abc/f"

	# Mock infer for verify to PASS
	infer() {
		echo "PASS"
	}

	# Run harness - should start from def since abc is done
	run run_harness "res"
	[ "$status" -eq 0 ]
	[ -f "$BB_DIR/res/out" ]
}

# ============ Stitch Dry Run Tests ============

@test "stitch_task in dry-run shows info but creates output" {
	DRY_RUN="true"
	source_harness

	mkdir -p "$BB_DIR/dry/abc" "$BB_DIR/dry/def"
	echo "abc Intro: Overview" >"$BB_DIR/dry/p"
	echo "def Body: Details" >>"$BB_DIR/dry/p"
	echo "First section" >"$BB_DIR/dry/abc/f"
	echo "Second section" >"$BB_DIR/dry/def/f"

	infer() {
		echo "ERROR: Should not be called in dry-run" >&2
	}

	run stitch_task "dry"
	[ "$status" -eq 0 ]
	[ -f "$BB_DIR/dry/out" ]
	[[ "$output" == *"DRY RUN"* ]]
}
