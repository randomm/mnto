#!/usr/bin/env bats
# Test suite for backend.bash unified inference abstraction

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
	# Source the backend library
	source "${BATS_TEST_DIRNAME}/../lib/backend.bash"
}

# Test helper: Mock apfel with different behaviors
mock_apfel_success() {
	apfel() {
		echo "mocked response"
		return 0
	}
	export -f apfel
}

mock_apfel_guardrail() {
	apfel() {
		echo "guardrail blocked"
		return 3
	}
	export -f apfel
}

mock_apfel_overflow() {
	apfel() {
		echo "context overflow"
		return 4
	}
	export -f apfel
}

# Test _resolve_backend for role mapping
@test "_resolve_backend returns correct backend for verifier role" {
	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL
	local result
	result="$(_resolve_backend verifier)"
	assert_equal "$result" "apfel"
}

@test "_resolve_backend returns correct backend for planner role" {
	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL
	local result
	result="$(_resolve_backend planner)"
	assert_equal "$result" "apfel"
}

@test "_resolve_backend returns correct backend for proposer role" {
	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL
	local result
	result="$(_resolve_backend proposer)"
	assert_equal "$result" "apfel"
}

@test "_resolve_backend returns correct backend for stitcher role" {
	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL
	local result
	result="$(_resolve_backend stitcher)"
	assert_equal "$result" "apfel"
}

@test "_resolve_backend returns correct backend for unknown role" {
	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL
	local result
	result="$(_resolve_backend unknown)"
	assert_equal "$result" "apfel"
}

# Test _resolve_backend with MNTO_VERIFIER env var
@test "_resolve_backend respects MNTO_VERIFIER env var for verifier role" {
	export MNTO_VERIFIER="openai:http://api.openai.com/v1:gpt-4"
	unset MNTO_PROPOSER MNTO_MODEL
	local result
	result="$(_resolve_backend verifier)"
	assert_equal "$result" "openai:http://api.openai.com/v1:gpt-4"
	unset MNTO_VERIFIER
}

@test "_resolve_backend ignores MNTO_VERIFIER for other roles" {
	export MNTO_VERIFIER="openai:http://api.openai.com/v1:gpt-4"
	unset MNTO_PROPOSER MNTO_MODEL
	local result
	result="$(_resolve_backend planner)"
	assert_equal "$result" "apfel"
	unset MNTO_VERIFIER
}

# Test _resolve_backend with MNTO_PROPOSER env var
@test "_resolve_backend respects MNTO_PROPOSER env var for planner role" {
	unset MNTO_VERIFIER
	export MNTO_PROPOSER="openai:http://localhost:11434/v1:gpt-4"
	unset MNTO_MODEL
	local result
	result="$(_resolve_backend planner)"
	assert_equal "$result" "openai:http://localhost:11434/v1:gpt-4"
	unset MNTO_PROPOSER
}

@test "_resolve_backend respects MNTO_PROPOSER env var for proposer role" {
	unset MNTO_VERIFIER
	export MNTO_PROPOSER="openai:http://localhost:11434/v1:gpt-4"
	unset MNTO_MODEL
	local result
	result="$(_resolve_backend proposer)"
	assert_equal "$result" "openai:http://localhost:11434/v1:gpt-4"
	unset MNTO_PROPOSER
}

@test "_resolve_backend respects MNTO_PROPOSER env var for stitcher role" {
	unset MNTO_VERIFIER
	export MNTO_PROPOSER="openai:http://localhost:11434/v1:gpt-4"
	unset MNTO_MODEL
	local result
	result="$(_resolve_backend stitcher)"
	assert_equal "$result" "openai:http://localhost:11434/v1:gpt-4"
	unset MNTO_PROPOSER
}

# Test _resolve_backend with MNTO_MODEL env var as fallback
@test "_resolve_backend falls back to MNTO_MODEL for verifier" {
	unset MNTO_VERIFIER
	unset MNTO_PROPOSER
	export MNTO_MODEL="openai:http://localhost:11434/v1:gpt-3.5"
	local result
	result="$(_resolve_backend verifier)"
	assert_equal "$result" "openai:http://localhost:11434/v1:gpt-3.5"
	unset MNTO_MODEL
}

@test "_resolve_backend falls back to MNTO_MODEL for planner" {
	unset MNTO_VERIFIER
	unset MNTO_PROPOSER
	export MNTO_MODEL="openai:http://localhost:11434/v1:gpt-3.5"
	local result
	result="$(_resolve_backend planner)"
	assert_equal "$result" "openai:http://localhost:11434/v1:gpt-3.5"
	unset MNTO_MODEL
}

@test "_resolve_backend falls back to MNTO_MODEL for unknown role" {
	unset MNTO_VERIFIER
	unset MNTO_PROPOSER
	export MNTO_MODEL="openai:http://localhost:11434/v1:gpt-3.5"
	local result
	result="$(_resolve_backend unknown)"
	assert_equal "$result" "openai:http://localhost:11434/v1:gpt-3.5"
	unset MNTO_MODEL
}

# Test _resolve_backend defaults to apfel
@test "_resolve_backend defaults to apfel with no env vars" {
	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL
	local result
	result="$(_resolve_backend verifier)"
	assert_equal "$result" "apfel"
}

# Test infer dispatches to apfel by default
@test "infer dispatches to apfel by default" {
	mock_apfel_success
	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL

	run infer planner "system" "context"
	assert_success
	assert_output "mocked response"
}

@test "infer returns exit code 0 on success" {
	mock_apfel_success
	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL

	run infer planner "system" "context"
	assert_success
	assert_equal "$status" 0
}

@test "infer returns exit code 3 on guardrail" {
	mock_apfel_guardrail
	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL

	run infer proposer "system" "context"
	assert_equal "$status" 3
}

@test "infer returns exit code 4 on context overflow" {
	mock_apfel_overflow
	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL

	run infer verifier "system" "context"
	assert_equal "$status" 4
}

@test "infer handles different roles correctly" {
	mock_apfel_success
	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL

	run infer planner "system" "context"
	assert_success

	run infer proposer "system" "context"
	assert_success

	run infer verifier "system" "context"
	assert_success

	run infer stitcher "system" "context"
	assert_success
}

# Test _infer_apfel with system prompts and context
@test "_infer_apfel calls apfel with correct arguments without output file" {
	apfel() {
		# Should receive exactly 2 args: system and context
		if [[ $# -eq 2 ]]; then
			echo "mocked response"
			return 0
		else
			echo "ERROR: wrong arg count $#, expected 2" >&2
			return 1
		fi
	}
	export -f apfel

	run _infer_apfel "system prompt" "user context"
	assert_success
	assert_output "mocked response"
}

# Test _infer_apfel input safety (context starting with -)
@test "_infer_apfel handles context starting with dash" {
	apfel() {
		# Capture arguments to verify safety - context should have leading newline
		if [[ "$2" == $'\n'* ]]; then
			# Context was properly escaped
			echo "safe response"
			return 0
		else
			echo "unsafe - context not escaped"
			return 1
		fi
	}
	export -f apfel

	run _infer_apfel "system" "-dangerous-flag"
	assert_success
	assert_output "safe response"
}

@test "_infer_apfel does not escape normal context" {
	apfel() {
		# Capture arguments - context should NOT have leading newline
		if [[ "$2" == $'\n'* ]]; then
			echo "unexpected - context escaped"
			return 1
		else
			echo "normal response"
			return 0
		fi
	}
	export -f apfel

	run _infer_apfel "system" "normal context"
	assert_success
	assert_output "normal response"
}

# Test _infer_apfel with output file argument
@test "_infer_apfel writes to output file when provided" {
	apfel() {
		# Uses redirection, receives only 2 positional args: system and context
		if [[ $# -eq 2 ]]; then
			echo "response written to file"
			return 0
		else
			echo "wrong - received $# args, expected 2"
			return 1
		fi
	}
	export -f apfel

	local tmpfile
	tmpfile="$(mktemp)"

	run _infer_apfel "system" "context" "$tmpfile"
	assert_success

	# Verify output file was written via redirection
	assert_equal "$(cat "$tmpfile")" "response written to file"

	rm -f "$tmpfile"
}

@test "_infer_apfel uses stdout when no output file provided" {
	apfel() {
		# No output file: receives 2 positional args
		if [[ $# -eq 2 ]]; then
			echo "stdout response"
			return 0
		else
			echo "wrong - received $# args, expected 2"
			return 1
		fi
	}
	export -f apfel

	run _infer_apfel "system" "context"
	assert_success
	assert_output "stdout response"
}

# Test infer with OpenAI backend stub
@test "infer returns error for unknown backend" {
	export MNTO_MODEL="unknown-backend"
	unset MNTO_VERIFIER MNTO_PROPOSER

	run infer planner "system" "context"
	assert_failure
	assert_output --partial "ERROR: Unknown backend: unknown-backend"

	unset MNTO_MODEL
}

@test "_infer_openai returns error (stub not implemented)" {
	export MNTO_MODEL="openai:http://localhost:11434/v1:gpt-4"

	run _infer_openai "openai:http://localhost:11434/v1:gpt-4" "system" "context"
	assert_failure
	assert_output --partial "ERROR: OpenAI backend not yet implemented"

	unset MNTO_MODEL
}

# Test infer respects role-specific backends
@test "infer verifier uses MNTO_VERIFIER when set" {
	apfel() {
		echo "verifier response"
		return 0
	}
	export -f apfel

	export MNTO_VERIFIER="apfel"
	unset MNTO_PROPOSER MNTO_MODEL

	run infer verifier "system" "context"
	assert_success
	assert_output "verifier response"

	unset MNTO_VERIFIER
}

@test "infer proposer uses MNTO_PROPOSER when set" {
	apfel() {
		echo "proposer response"
		return 0
	}
	export -f apfel

	unset MNTO_VERIFIER
	export MNTO_PROPOSER="apfel"
	unset MNTO_MODEL

	run infer proposer "system" "context"
	assert_success
	assert_output "proposer response"

	unset MNTO_PROPOSER
}

# Test OpenAI backend validation
@test "infer rejects openai backend without model spec" {
	export MNTO_MODEL="openai"
	unset MNTO_VERIFIER MNTO_PROPOSER

	run infer planner "system" "context"
	assert_failure
	assert_output --partial "ERROR: OpenAI backend requires spec format openai:URL:MODEL"

	unset MNTO_MODEL
}

@test "infer rejects invalid openai backend format" {
	export MNTO_MODEL="openai-invalid"
	unset MNTO_VERIFIER MNTO_PROPOSER

	run infer planner "system" "context"
	assert_failure
	assert_output --partial "ERROR: Invalid backend specification: openai-invalid (expected openai:URL:MODEL)"

	unset MNTO_MODEL
}

@test "infer rejects openai backend with only model (missing URL)" {
	export MNTO_MODEL="openai:gpt-4"
	unset MNTO_VERIFIER MNTO_PROPOSER

	run infer planner "system" "context"
	assert_failure
	assert_output --partial "ERROR: OpenAI backend requires spec format openai:URL:MODEL"

	unset MNTO_MODEL
}

@test "infer rejects openai backend with trailing colon only" {
	export MNTO_MODEL="openai:"
	unset MNTO_VERIFIER MNTO_PROPOSER

	run infer planner "system" "context"
	assert_failure
	assert_output --partial "ERROR: OpenAI backend requires spec format openai:URL:MODEL"

	unset MNTO_MODEL
}

@test "infer accepts valid openai backend with URL and model" {
	export MNTO_MODEL="openai:http://localhost:11434/v1:qwen3"
	unset MNTO_VERIFIER MNTO_PROPOSER

	run infer planner "system" "context"
	assert_failure
	assert_output --partial "ERROR: OpenAI backend not yet implemented"

	unset MNTO_MODEL
}

# Test edge cases for context
@test "infer handles empty context" {
	apfel() {
		echo "empty context handled"
		return 0
	}
	export -f apfel

	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL

	run infer planner "system" ""
	assert_success
	assert_output "empty context handled"
}

# Test system prompts with special characters
@test "infer handles system prompts with quotes" {
	apfel() {
		# Verify we receive the quoted system prompt intact
		if [[ "$2" == *'system "prompt" with quotes'* ]]; then
			echo "quotes handled"
			return 0
		else
			echo "quotes lost"
			return 1
		fi
	}
	export -f apfel

	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL

	run infer planner 'system "prompt" with quotes' "context"
	assert_success
	assert_output "quotes handled"
}

@test "infer handles system prompts with backslashes" {
	apfel() {
		if [[ "$2" == *'system\\prompt\\with\\backslashes'* ]]; then
			echo "backslashes handled"
			return 0
		else
			echo "backslashes lost"
			return 1
		fi
	}
	export -f apfel

	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL

	run infer planner 'system\\prompt\\with\\backslashes' "context"
	assert_success
	assert_output "backslashes handled"
}

@test "infer handles system prompts with dollar signs" {
	apfel() {
		if [[ "$2" == *'system$prompt$with$dollars'* ]]; then
			echo "dollars handled"
			return 0
		else
			echo "dollars lost"
			return 1
		fi
	}
	export -f apfel

	unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL

	run infer planner 'system$prompt$with$dollars' "context"
	assert_success
	assert_output "dollars handled"
}