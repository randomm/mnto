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
  # Mock apfel for testing - simple pattern matching
  case "\$1" in
  -q)
  	# Check if any argument contains "section" (from SYS_PLAN content)
  	for arg; do
  		if [[ "\$arg" == *"section"* ]] || [[ "\$arg" == *"SYS_PLAN"* ]]; then
  			echo "abc Introduction: An overview of the project, 100 words"
  			echo "def Body: Main content, 150 words"
  			echo "ghi Conclusion: Summary and next steps, 50 words"
  			return 0
  		fi
  	done
  	# Default response for other requests (SYS_DRAFT, SYS_VERIFY, SYS_STITCH)
  	echo "PASS"
  	return 0
  	;;
  -p)
  	echo "abc Introduction: An overview of the project, 100 words"
  	echo "def Body: Main content, 150 words"
  	echo "ghi Conclusion: Summary and next steps, 50 words"
  	return 0
  	;;
  *)
  	# Fallback
  	echo "mock response"
  	return 0
  	;;
  esac
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
	[[ "$output" == *[a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9]* ]]
}

@test "mnto --list shows tasks" {
	run "$TEST_MNTO" "First task"
	[[ $status -eq 0 ]]
	run "$TEST_MNTO" "Second task"
	[[ $status -eq 0 ]]

	run "$TEST_MNTO" --list
	[[ $status -eq 0 ]]
	[[ "${#lines[@]}" -ge 2 ]]
}

@test "mnto --resume fails for non-existent task" {
	run "$TEST_MNTO" --resume nonexistent
	[[ $status -ne 0 ]]
	[[ "$output" == *"Invalid task ID format"* ]]
}

@test "mnto --resume existing task" {
	run "$TEST_MNTO" "Test task"
	[[ $status -eq 0 ]]
	# Extract task ID from "Created task: XYZ" where XYZ is exactly 3 alphanumeric
	local tid="${lines[0]}"
	tid="${tid##*Created task: }"
	[[ "$tid" =~ ^[a-zA-Z0-9]{3}$ ]] || return 1

	run "$TEST_MNTO" --resume "$tid"
	[[ $status -eq 0 ]]
	[[ "$output" == *"Resuming task: $tid"* ]]
}

@test "gen_id produces 3-character IDs" {
	source "$MNTO/lib/blackboard.bash"
	local id
	id="$(gen_id)"
	[ ${#id} -eq 3 ]
	[[ "$id" =~ ^[a-zA-Z0-9]{3}$ ]]
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
