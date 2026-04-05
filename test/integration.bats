#!/usr/bin/env bats
# Integration tests for mnto

setup() {
	# Set MNTO to project root
	export MNTO="$BATS_TEST_DIRNAME/.."

	# Create test fixture directory
	export TEST_BB_DIR="$BATS_TMPDIR/mnto-test-$BATS_TEST_NUMBER"
	export BB_DIR="$TEST_BB_DIR/.bb"

	# Create temporary mnto script with mock command inline
	export TEST_MNTO="$BATS_TMPDIR/mnto-test-$BATS_TEST_NUMBER.sh"
	mkdir -p "$BB_DIR"
	cd "$TEST_BB_DIR"

	# Prepend mock function and rewrite mnto with inline mock
	{
		echo '#!/usr/bin/env bash'
		echo 'set -euo pipefail'
		echo 'apfel() {'
		echo '	case "$1" in'
		echo '	-p)'

		echo '		echo "abc Introduction: An overview of the project, 100 words"'
		echo '		echo "def Conclusion: Summary and next steps, 50 words"'
		echo '		;;'
		echo '	*)'
		echo '		echo "mock response"'
		echo '		;;'
		echo '	esac'
		echo '}'
		cat "$MNTO/mnto"
	} >"$TEST_MNTO"
	chmod +x "$TEST_MNTO"
}

teardown() {
	cd "$BATS_TMPDIR" >/dev/null
	rm -rf "$TEST_BB_DIR"
	rm -f "$TEST_MNTO"
}

@test "mnto creates task with planning" {
	run "$TEST_MNTO" "Write a simple guide"
	assert_success
	assert_output --partial "Created task:"

	# Verify task directory exists
	local tid
	tid="$("$TEST_MNTO" --list | head -1)"
	[ -d "$BB_DIR/$tid" ]
	[ -f "$BB_DIR/$tid/g" ]
	[ -f "$BB_DIR/$tid/p" ]
	[ -f "$BB_DIR/$tid/s" ]

	# Verify subtask directories
	[ -d "$BB_DIR/$tid/abc" ]
	[ -d "$BB_DIR/$tid/def" ]
}

@test "mnto --list shows tasks" {
	"$TEST_MNTO" "First task" >/dev/null
	"$TEST_MNTO" "Second task" >/dev/null

	run "$TEST_MNTO" --list
	assert_success
	[ "${#lines[@]}" -eq 2 ]
}

@test "mnto --resume fails for non-existent task" {
	run "$TEST_MNTO" --resume nonexistent
	assert_failure
	assert_output --partial "ERROR: Task 'nonexistent' not found"
}

@test "mnto --resume existing task" {
	"$TEST_MNTO" "Test task" >/dev/null
	local tid
	tid="$("$TEST_MNTO" --list | head -1)"

	run "$TEST_MNTO" --resume "$tid"
	assert_success
	assert_output --partial "Resuming task: $tid"
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

	source "$MNTO/lib/blackboard.bash"

	echo -e "abc Task A\ndef Task B\ng Task C" >".bb/xyz/p"
	echo -e "abc - 0\ndef d 0\ng - 0" >".bb/xyz/s"

	local result
	result="$(next_task "xyz")"
	[ "$result" = "abc" ]
}

@test "set_status updates subtask state" {
	mkdir -p "$TEST_BB_DIR/.bb/xyz"
	cd "$TEST_BB_DIR"

	source "$MNTO/lib/blackboard.bash"

	echo -e "abc Task A\ndef Task B" >".bb/xyz/p"
	echo -e "abc - 0\ndef - 0" >".bb/xyz/s"

	set_status "xyz" "abc" "d" "0"

	local expected
	expected=$(echo -e "abc d 0\ndef - 0")
	local actual
	actual=$(cat ".bb/xyz/s")

	[ "$expected" = "$actual" ]
}

@test "prev_final returns previous subtask output" {
	mkdir -p "$TEST_BB_DIR/.bb/xyz/abc" "$TEST_BB_DIR/.bb/xyz/def"
	cd "$TEST_BB_DIR"

	source "$MNTO/lib/blackboard.bash"

	echo -e "abc Task A\ndef Task B\ng Task C" >".bb/xyz/p"
	echo "Previous output" >".bb/xyz/abc/f"

	local result
	result="$(prev_final "xyz" "def")"
	[ "$result" = "Previous output" ]
}

@test "parse_plan creates proper structure" {
	cd "$TEST_BB_DIR"

	source "$MNTO/lib/blackboard.bash"

	local plan
	plan="abc Introduction: Overview, 100 words
def Body: Main content, 200 words"

	parse_plan "$plan" "xyz"

	[ -d ".bb/xyz" ]
	[ -f ".bb/xyz/p" ]
	[ -f ".bb/xyz/s" ]
	[ -d ".bb/xyz/abc" ]
	[ -d ".bb/xyz/def" ]

	# Verify status initialization
	local status_content
	status_content=$(cat ".bb/xyz/s")
	[[ "$status_content" =~ "abc - 0" ]]
	[[ "$status_content" =~ "def - 0" ]]
}
