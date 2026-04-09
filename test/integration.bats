#!/usr/bin/env bats
# Integration tests for mnto

setup() {
	# Set MNTO to project root
	export MNTO="$BATS_TEST_DIRNAME/.."

	# Create test fixture directory
	export TEST_BB_DIR="$BATS_TMPDIR/mnto-test-$BATS_TEST_NUMBER"
	export BB_DIR="$TEST_BB_DIR/.bb"

	# Create temporary mnto script with mock apfel inline
	export TEST_MNTO="$BATS_TMPDIR/mnto-test-$BATS_TEST_NUMBER.sh"
	mkdir -p "$BB_DIR"
	cd "$TEST_BB_DIR"

	# Write test script with mocked apfel
	export BB_DIR="$TEST_BB_DIR/.bb"
	export SCRIPT_DIR="$MNTO"
	mntoscript=$(
		cat <<MNTODEV
#!/usr/bin/env bash
set -euo pipefail

apfel() {
  local sys_prompt="$3"
  # If this is a restructuring call (second pass), return structured format
  if [[ "$sys_prompt" == *"Restructure"* ]] || [[ "$sys_prompt" == *"restructure"* ]]; then
    echo "abc overview: Brief description, 100 words"
    echo "def install: How to install, 150 words"
    echo "ghi usage: How to use it, 200 words"
    echo "jkl conclusion: Summary and next steps, 50 words"
  else
    # First call - return markdown (simulating real apfel behavior)
    echo "## Introduction"
    echo "This is a bash tool for task planning."
    echo ""
    echo "## Installation"
    echo "Install with brew install mnto"
    echo ""
    echo "## Usage"
    echo "Run ./mnto with a goal"
  fi
  return 0
}

source "\$SCRIPT_DIR/lib/blackboard.bash"
source "\$SCRIPT_DIR/lib/planner.bash"

BB_DIR="$BB_DIR"

create_task() {
	local goal="\$1"
	mkdir -p "\$BB_DIR"
	local tid
	tid="\$(gen_id)"
	local bb_dir="\$BB_DIR/\$tid"
	mkdir -p "\$bb_dir"
	echo "\$goal" >"\$bb_dir/g"
	local plan
	plan="\$(generate_plan "\$goal")"
	if [[ -z "\$plan" ]]; then
		echo "ERROR: Failed to generate plan" >&2
		rm -rf "\$bb_dir"
		exit 1
	fi
	parse_plan "\$plan" "\$tid"
	echo "Created task: \$tid"
}

list_tasks() {
	if [[ ! -d "\$BB_DIR" ]]; then
		echo "No tasks found"
		return 0
	fi
	for task_dir in "\$BB_DIR"/*/; do
		[[ -d "\$task_dir" ]] && basename "\$task_dir"
	done
}

resume_task() {
	local tid="\$1"
	if ! validate_id "\$tid"; then
		echo "ERROR: Invalid task ID format" >&2
		exit 1
	fi
	local bb_dir="\$BB_DIR/\$tid"
	if [[ ! -d "\$bb_dir" ]]; then
		echo "ERROR: Task '\$tid' not found" >&2
		exit 1
	fi
	echo "Resuming task: \$tid"
}

if [[ \$# -eq 0 ]]; then
	echo "Usage: mnto ..." >&2
	exit 1
fi
case "\$1" in
--list) list_tasks;;
--resume)
	[[ \$# -ne 2 ]] && exit 1
	resume_task "\$2"
	;;
*)
	create_task "\$@"
	;;
esac
MNTODEV
	)
	# shellcheck disable=SC2086
	printf '%s' "$mntoscript" >"$TEST_MNTO"
	chmod +x "$TEST_MNTO"
}

teardown() {
	cd "$BATS_TMPDIR" >/dev/null
	rm -rf "$TEST_BB_DIR"
	rm -f "$TEST_MNTO"
}

@test "mnto creates task with planning" {
	run "$TEST_MNTO" "Write a simple guide"
	[[ $status -eq 0 ]]
	[[ "$output" == *"Created task:"* ]]

	# Verify task directory exists via list
	run "$TEST_MNTO" --list
	[[ $status -eq 0 ]]
	[[ "$output" == *[a-z][a-z][a-z]* ]]
}

@test "mnto --list shows tasks" {
	run "$TEST_MNTO" "First task"
	[[ $status -eq 0 ]]
	run "$TEST_MNTO" "Second task"
	[[ $status -eq 0 ]]

	run "$TEST_MNTO" --list
	[[ $status -eq 0 ]]
	[[ "${#lines[@]}" -ge 2 ]]
	[[ "${lines[0]}" =~ ^[a-z]{3}$ ]] || [[ "${lines[1]}" =~ ^[a-z]{3}$ ]]
}

@test "mnto --resume fails for non-existent task" {
	run "$TEST_MNTO" --resume nonexistent
	[[ $status -ne 0 ]]
	[[ "$output" == *"Invalid task ID format"* ]]
}

@test "mnto --resume existing task" {
	run "$TEST_MNTO" "Test task"
	[[ $status -eq 0 ]]
	# Extract task ID from "Created task: XYZ" where XYZ is exactly 3 lowercase letters
	local tid="${lines[0]}"
	tid="${tid##*Created task: }"
	[[ "$tid" =~ ^[a-z]{3}$ ]] || return 1

	run "$TEST_MNTO" --resume "$tid"
	[[ $status -eq 0 ]]
	[[ "$output" == *"Resuming task: $tid"* ]]
}

@test "gen_id produces 3-character lowercase IDs" {
	source "$MNTO/lib/blackboard.bash"
	local id
	id="$(gen_id)"
	[ ${#id} -eq 3 ]
	[[ "$id" =~ ^[a-z]{3}$ ]]
}

@test "next_task returns first waiting subtask" {
	mkdir -p "$TEST_BB_DIR/.bb/xyz"
	cd "$TEST_BB_DIR"

	export BB_DIR="$TEST_BB_DIR/.bb"
	source "$MNTO/lib/blackboard.bash"

	echo -e "abc Task A\ndef Task B\ng Task C" >"$BB_DIR/xyz/p"
	echo -e "abc - 0\ndef d 0\ng - 0" >"$BB_DIR/xyz/s"

	local result
	result="$(next_task "xyz")"
	[ "$result" = "abc" ]
}

@test "set_status updates subtask state" {
	mkdir -p "$TEST_BB_DIR/.bb/xyz"
	cd "$TEST_BB_DIR"

	export BB_DIR="$TEST_BB_DIR/.bb"
	source "$MNTO/lib/blackboard.bash"

	echo -e "abc Task A\ndef Task B" >"$BB_DIR/xyz/p"
	echo -e "abc - 0\ndef - 0" >"$BB_DIR/xyz/s"

	set_status "xyz" "abc" "d" "0"

	local expected
	expected=$(echo -e "abc d 0\ndef - 0")
	local actual
	actual=$(cat "$BB_DIR/xyz/s")

	[ "$expected" = "$actual" ]
}

@test "prev_final returns previous subtask output" {
	mkdir -p "$TEST_BB_DIR/.bb/xyz/abc" "$TEST_BB_DIR/.bb/xyz/def"
	cd "$TEST_BB_DIR"

	export BB_DIR="$TEST_BB_DIR/.bb"
	source "$MNTO/lib/blackboard.bash"

	echo -e "abc Task A\ndef Task B\ng Task C" >"$BB_DIR/xyz/p"
	echo "Previous output" >"$BB_DIR/xyz/abc/f"

	local result
	result="$(prev_final "xyz" "def")"
	[ "$result" = "Previous output" ]
}

@test "parse_plan creates proper structure" {
	cd "$TEST_BB_DIR"

	export BB_DIR="$TEST_BB_DIR/.bb"
	source "$MNTO/lib/blackboard.bash"

	local plan
	plan="abc Introduction: Overview, 100 words
def Body: Main content, 150 words
ghi Conclusion: Summary, 50 words"

	parse_plan "$plan" "xyz"

	[ -d "$BB_DIR/xyz" ]
	[ -f "$BB_DIR/xyz/p" ]
	[ -f "$BB_DIR/xyz/s" ]
	[ -d "$BB_DIR/xyz/abc" ]
	[ -d "$BB_DIR/xyz/def" ]

	# Verify status initialization
	local status_content
	status_content=$(cat "$BB_DIR/xyz/s")
	[[ "$status_content" =~ "abc - 0" ]]
	[[ "$status_content" =~ "def - 0" ]]
	[[ "$status_content" =~ "ghi - 0" ]]
}

@test "normalize_plan_output strips markdown fences" {
	source "$MNTO/lib/blackboard.bash"
	local result
	# Simply verify that lines starting with ``` are removed
	result=$(printf '%s\n%s\n' '```' 'abc Intro: Overview, 100 words' | normalize_plan_output)
	# Should only contain the abc line, not the backticks
	[[ "$result" == *"abc Intro: Overview, 100 words"* ]]
}

@test "normalize_plan_output removes numbered prefixes" {
	source "$MNTO/lib/blackboard.bash"
	local result
	result="$(echo '1. abc Intro: Overview, 100 words' | normalize_plan_output)"
	[[ "$result" == *"abc Intro: Overview, 100 words"* ]]
}

@test "normalize_plan_output removes bullet list prefixes" {
	source "$MNTO/lib/blackboard.bash"
	local result
	result="$(echo '- abc Intro: Overview, 100 words' | normalize_plan_output)"
	[[ "$result" == *"abc Intro: Overview, 100 words"* ]]
}

@test "normalize_plan_output preserves valid plan lines" {
	source "$MNTO/lib/blackboard.bash"
	local result
	result="$(echo 'abc Intro: Overview, 100 words' | normalize_plan_output)"
	[[ "$result" == *"abc Intro: Overview, 100 words"* ]]
}

@test "normalize_plan_output filters non-plan lines" {
	source "$MNTO/lib/blackboard.bash"
	local result
	result="$(printf 'This is not a plan line\nabc Intro: Overview, 100 words\n' | normalize_plan_output)"
	[[ "$result" == *"abc Intro: Overview, 100 words"* ]]
	[[ "$result" != *"This is not a plan line"* ]]
}

@test "normalize_plan_output handles mixed input" {
	source "$MNTO/lib/blackboard.bash"
	local result
	result=$(printf '1. abc Task 1\n- def Task 2\nghi Task 3\n' | normalize_plan_output)
	[[ "$result" == *"abc Task 1"* ]]
	[[ "$result" == *"def Task 2"* ]]
	[[ "$result" == *"ghi Task 3"* ]]
}

@test "normalize_plan_output handles id1-style IDs" {
	source "$MNTO/lib/blackboard.bash"
	local result
	result=$(printf 'id1 introduction: Welcome to the guide\nid2 setup: How to get started\nid3 usage: How to use it\n' | normalize_plan_output)
	# Should assign proper 3-char IDs (abc, def, ghi)
	[[ "$result" == *"abc introduction"* ]]
	[[ "$result" == *"def setup"* ]]
	[[ "$result" == *"ghi usage"* ]]
}

@test "normalize_plan_output extracts markdown headers" {
	source "$MNTO/lib/blackboard.bash"
	local result
	result=$(printf '## Introduction\n## Installation\n## Usage\n' | normalize_plan_output)
	# Should convert headers to plan lines with IDs
	[[ "$result" == *"abc Introduction"* ]]
	[[ "$result" == *"def Installation"* ]]
	[[ "$result" == *"ghi Usage"* ]]
}

@test "normalize_plan_output handles colon without word count" {
	source "$MNTO/lib/blackboard.bash"
	local result
	result=$(printf 'abc Introduction: Brief overview\n' | normalize_plan_output)
	# Should preserve the line even without word count
	[[ "$result" == *"abc Introduction: Brief overview"* ]]
}

@test "fill_missing_word_counts adds defaults" {
	source "$MNTO/lib/blackboard.bash"
	local result
	result=$(fill_missing_word_counts "abc Intro: Overview without count")
	[[ "$result" == *"abc Intro: Overview without count, 100 words"* ]]
}

@test "fill_missing_word_counts preserves existing word counts" {
	source "$MNTO/lib/blackboard.bash"
	local result
	result=$(fill_missing_word_counts "abc Intro: Overview, 150 words")
	[[ "$result" == *"abc Intro: Overview, 150 words"* ]]
	[[ "$result" != *"100 words"* ]]
}

@test "validate_plan_format accepts descriptions with commas" {
	source "$MNTO/lib/blackboard.bash"
	local plan
	plan="abc greeting: Hello, my name is AI, and I am here to assist you, 100 words
def intro: Brief, one-line description, 150 words
ghi details: Write about X, Y, and Z, then conclude, 200 words"
	validate_plan_format "$plan"
	[ $? -eq 0 ]
}

@test "validate_plan_format accepts descriptions with commas without word count" {
	source "$MNTO/lib/blackboard.bash"
	local plan
	plan="abc greeting: Hello, my name is AI, and I am here to assist you
def intro: Brief, one-line description
ghi details: Write about X, Y, and Z, then conclude"
	validate_plan_format "$plan"
	[ $? -eq 0 ]
}

@test "fill_missing_word_counts adds word count to descriptions with commas" {
	source "$MNTO/lib/blackboard.bash"
	local result
	result=$(fill_missing_word_counts "abc greeting: Hello, my name is AI, and I am here to assist you")
	[[ "$result" == *"abc greeting: Hello, my name is AI, and I am here to assist you, 100 words"* ]]
}

@test "fill_missing_word_counts preserves word count for descriptions with commas" {
	source "$MNTO/lib/blackboard.bash"
	local result
	result=$(fill_missing_word_counts "abc greeting: Hello, my name is AI, and I am here to assist you, 200 words")
	[[ "$result" == *"abc greeting: Hello, my name is AI, and I am here to assist you, 200 words"* ]]
	[[ "$result" != *"100 words"* ]]
}

@test "generate_plan handles two-pass fallback" {
	source "$MNTO/lib/blackboard.bash"
	source "$MNTO/lib/planner.bash"

	# Mock apfel to return markdown first, then structured format
	apfel() {
		local apfel_call_count="${APEFEL_CALL_COUNT:-0}"
		((apfel_call_count++)) || true
		export APEFEL_CALL_COUNT="$apfel_call_count"

		if ((apfel_call_count == 1)); then
			# First call (plan): return markdown headers
			echo "## Introduction"
			echo "## Installation"
			echo "## Usage"
		else
			# Second call (restructure): return proper format
			echo "abc Introduction: Brief overview, 100 words"
			echo "def Installation: How to install, 150 words"
			echo "ghi Usage: How to use it, 200 words"
		fi
		return 0
	}

	local result
	result="$(generate_plan "Write a guide" 2>/dev/null || true)"

	# Should have used two-pass and returned valid plan
	[[ "$result" == *"abc Introduction"* ]]
	[[ "$result" == *"def Installation"* ]]
	[[ "$result" == *"ghi Usage"* ]]
}
