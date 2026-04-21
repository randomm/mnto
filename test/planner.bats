#!/usr/bin/env bats
# Planner redesign tests: dependency-aware workflow steps + MNTO_PLANNER_MODEL

setup() {
	export MNTO="${BATS_TEST_DIRNAME}/.."
	export TEST_BB_DIR="$BATS_TMPDIR/mnto-planner-$BATS_TEST_NUMBER"
	export BB_DIR="$TEST_BB_DIR/.bb"
	mkdir -p "$BB_DIR"
}

teardown() {
	rm -rf "$TEST_BB_DIR"
}

source_libs() {
	source "$MNTO/lib/blackboard.bash"
	source "$MNTO/lib/backend.bash"
	source "$MNTO/lib/planner.bash"
}

# ============ Dependencies parsing tests ============

@test "parse_plan writes deps as 4th field in status file" {
	source_libs

	local plan
	plan="zab overview: Brief summary, 50 words, deps:
zcd details: Key information, 100 words, deps: zab
zef conclusion: Summary, 50 words, deps: zcd"

	parse_plan "$plan" "xyz"

	local status_content
	status_content=$(cat "$BB_DIR/xyz/s")
	# zab has no deps, zcd depends on zab, zef depends on zcd
	[[ "$status_content" == *"zab - 0 "* ]]
	[[ "$status_content" == *"zcd - 0 zab"* ]]
	[[ "$status_content" == *"zef - 0 zcd"* ]]
}

@test "parse_plan with empty deps (root step) writes 4th field as empty" {
	source_libs

	# Must have at least 3 sections per validate_plan_format
	local plan
	plan="zab root: First step, 50 words, deps:
zcd second: Second step, 50 words, deps: zab
zef third: Third step, 50 words, deps: zcd"

	parse_plan "$plan" "xyz"

	local status_content
	status_content=$(cat "$BB_DIR/xyz/s")
	local first_line
	first_line="$(echo "$status_content" | head -1)"
	# zab has empty deps - first field should end with space after "0"
	[[ "$first_line" == "zab - 0 " ]]
}

@test "get_task_deps returns correct dep IDs" {
	source_libs

	mkdir -p "$BB_DIR/xyz/abc"
	echo "zab - 0 " >"$BB_DIR/xyz/s"
	echo "abc - 0 zab,zcd" >>"$BB_DIR/xyz/s"
	echo "def - 0 zcd" >>"$BB_DIR/xyz/s"

	local deps
	deps="$(get_task_deps "xyz" "abc")"
	[[ "$deps" == "zab,zcd" ]]
}

@test "get_task_deps returns empty for root step" {
	source_libs

	mkdir -p "$BB_DIR/xyz/abc"
	echo "abc - 0 " >"$BB_DIR/xyz/s"

	local deps
	deps="$(get_task_deps "xyz" "abc")"
	[[ "$deps" == "" ]]
}

@test "get_task_deps returns empty for non-existent subtask" {
	source_libs

	mkdir -p "$BB_DIR/xyz"
	echo "abc - 0 " >"$BB_DIR/xyz/s"

	local deps
	deps="$(get_task_deps "xyz" "zzz")"
	[[ "$deps" == "" ]]
}

# ============ validate_plan_format with new format ============

@test "validate_plan_format passes on new deps format" {
	source_libs

	local plan
	plan="zab overview: Brief summary, 50 words, deps:
zcd details: Key information, 100 words, deps: zab
zef conclusion: Summary, 50 words, deps: zcd"

	run validate_plan_format "$plan"
	[ "$status" -eq 0 ]
}

@test "validate_plan_format passes on mixed deps (some empty, some with deps)" {
	source_libs

	local plan
	plan="zab planning: Gather info, 50 words, deps:
zcd research: Analyze data, 100 words, deps: zab
zef write: Draft document, 150 words, deps: zcd
zij review: Final check, 50 words, deps: zef"

	run validate_plan_format "$plan"
	[ "$status" -eq 0 ]
}

@test "validate_plan_format passes on plan with multi-part deps" {
	source_libs

	local plan
	plan="zab gather: Collect information, 50 words, deps:
zcd analyze: Process data, 100 words, deps: zab
zef write: Create draft, 150 words, deps: zab,zcd
zij review: Check quality, 50 words, deps: zef"

	run validate_plan_format "$plan"
	[ "$status" -eq 0 ]
}

# ============ fill_missing_word_counts ensures deps: ============

@test "fill_missing_word_counts adds deps: suffix when missing" {
	source_libs

	local result
	result="$(fill_missing_word_counts "zab intro: Brief overview, 100 words")"
	[[ "$result" == *"deps:"* ]]
}

@test "fill_missing_word_counts preserves existing deps field" {
	source_libs

	local result
	result="$(fill_missing_word_counts "zab intro: Brief overview, 100 words, deps: zcd")"
	[[ "$result" == *"deps: zcd"* ]]
}

# ============ MNTO_PLANNER_MODEL tests ============

setup() {
	export MNTO="${BATS_TEST_DIRNAME}/.."
	export TEST_BB_DIR="$BATS_TMPDIR/mnto-planner-$BATS_TEST_NUMBER"
	export BB_DIR="$TEST_BB_DIR/.bb"
	mkdir -p "$BB_DIR"
}

teardown() {
	rm -rf "$TEST_BB_DIR"
}

source_libs() {
	source "$MNTO/lib/blackboard.bash"
	source "$MNTO/lib/backend.bash"
	source "$MNTO/lib/planner.bash"
}

# Redefine infer_with_backend after sourcing to mock it
mock_infer_with_backend() {
	unset -f infer_with_backend || true
	eval "infer_with_backend() {
		local backend=\"\$1\" role=\"\$2\" system=\"\$3\" context=\"\$4\"
		echo \"zab intro: First section, 50 words, deps:
zcd body: Second section, 100 words, deps: zab
zef conclusion: Third section, 50 words, deps: zcd\"
	}"
}

mock_infer() {
	unset -f infer || true
	eval "infer() {
		local role=\"\$1\" system=\"\$2\" context=\"\$3\"
		[[ \"\$role\" == \"planner\" ]]
		echo \"zab intro: First section, 50 words, deps:
zcd body: Second section, 100 words, deps: zab
zef conclusion: Third section, 50 words, deps: zcd\"
	}"
}

@test "MNTO_PLANNER_MODEL set uses that model for planning" {
	setup
	source_libs
	mock_infer_with_backend
	export MNTO_PLANNER_MODEL="openai:http://localhost:8080/v1:gpt-4"

	local result
	result="$(generate_plan "Test goal" 2>/dev/null || true)"
	[[ "$result" == *"zab intro"* ]]
}

@test "MNTO_PLANNER_MODEL unset falls back to default inference" {
	setup
	source_libs
	mock_infer
	unset MNTO_PLANNER_MODEL || true

	local result
	result="$(generate_plan "Test goal" 2>/dev/null || true)"
	[[ "$result" == *"zab intro"* ]]
}

# ============ SYS_PLAN output format verification ============

@test "SYS_PLAN contains deps: format in examples" {
	source_libs

	# Verify the SYS_PLAN prompt contains the new format
	[[ "$SYS_PLAN" == *"deps:"* ]]
	[[ "$SYS_PLAN" == *"deps: zab"* ]]
}

@test "SYS_RESTRUCTURE contains deps: format in examples" {
	source_libs

	[[ "$SYS_RESTRUCTURE" == *"deps:"* ]]
}

@test "SYS_PLAN_MINIMAL contains deps: format in examples" {
	source_libs

	[[ "$SYS_PLAN_MINIMAL" == *"deps:"* ]]
}

@test "PLAN_TEMPLATE_GENERIC contains deps: format" {
	source_libs

	[[ "$PLAN_TEMPLATE_GENERIC" == *"deps:"* ]]
	[[ "$PLAN_TEMPLATE_GENERIC" == *"deps: zab"* ]]
	[[ "$PLAN_TEMPLATE_GENERIC" == *"deps: zcd"* ]]
}
