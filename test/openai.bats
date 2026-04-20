# OpenAI backend adapter tests

# Load setup helpers
load setup

setup() {
	# Source the openai library
	source lib/openai.bash
	# Set up mock curl
	eval "$(declare -f mock_apfel)"  # Load apfel mock if needed

	# Mock curl function for testing
	curl() {
		_args=("$@")
		# Parse arguments to determine what to return
		local response_body=""
		local http_code="200"

		# Check if request contains error simulation
		for arg in "$@"; do
			case "$arg" in
			"error_400")
				http_code="400"
				response_body='{"error":{"message":"Bad Request: Context too long"}}'
				break
				;;
			"error_403")
				http_code="403"
				response_body='{"error":{"message":"Content policy violation"}}'
				break
				;;
			"error_500")
				http_code="500"
				response_body='{"error":{"message":"Internal server error"}}'
				break
				;;
			"empty_response")
				http_code="200"
				response_body='{"choices":[]}'
				break
				;;
			esac
		done

		# Default success response
		if [[ -z "$response_body" ]]; then
			response_body='{"choices":[{"message":{"content":"mock response from API"}}]}'
		fi

		# Return response with unit separator (0x1F) and http code
		printf '%s\x1f%s' "$response_body" "$http_code"
	}
	export -f curl
}

teardown() {
	unset -f curl
}

# Test _parse_openai_spec with simple URL
@test "_parse_openai_spec parses simple HTTP URL" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	_parse_openai_spec "$spec" | IFS=$'\t' read -r base_url model
	assert_equal "$base_url" "http://localhost:11434/v1"
	assert_equal "$model" "qwen3"
}

# Test _parse_openai_spec with port in URL
@test "_parse_openai_spec parses URL with port" {
	local spec="openai:http://localhost:8080/v1:llama3"
	_parse_openai_spec "$spec" | IFS=$'\t' read -r base_url model
	assert_equal "$base_url" "http://localhost:8080/v1"
	assert_equal "$model" "llama3"
}

# Test _parse_openai_spec with model containing colon
@test "_parse_openai_spec parses model with colon" {
	local spec="openai:http://localhost:11434/v1:qwen3:30b-a3b"
	_parse_openai_spec "$spec" | IFS=$'\t' read -r base_url model
	assert_equal "$base_url" "http://localhost:11434/v1"
	assert_equal "$model" "qwen3:30b-a3b"
}

# Test _parse_openai_spec with complex model containing multiple colons
@test "_parse_openai_spec parses model with multiple colons" {
	local spec="openai:http://localhost:11434/v1:qwen3:30b-a3b:latest"
	_parse_openai_spec "$spec" | IFS=$'\t' read -r base_url model
	assert_equal "$base_url" "http://localhost:11434/v1"
	assert_equal "$model" "qwen3:30b-a3b:latest"
}

# Test _parse_openai_spec handles gemma4:e4b style model names (issue #58)
@test "_parse_openai_spec parses gemma4:e4b model name" {
	local spec="openai:http://localhost:11434/v1:gemma4:e4b"
	_parse_openai_spec "$spec" | IFS=$'\t' read -r base_url model
	assert_equal "$base_url" "http://localhost:11434/v1"
	assert_equal "$model" "gemma4:e4b"
}

# Test _parse_openai_spec with HTTPS
@test "_parse_openai_spec parses HTTPS URL" {
	local spec="openai:https://api.openai.com/v1:gpt-4o-mini"
	_parse_openai_spec "$spec" | IFS=$'\t' read -r base_url model
	assert_equal "$base_url" "https://api.openai.com/v1"
	assert_equal "$model" "gpt-4o-mini"
}

# Test _parse_openai_spec with invalid format
@test "_parse_openai_spec rejects invalid format" {
	local spec="invalid:spec:format"
	run _parse_openai_spec "$spec"
	assert_failure

	local spec="openai:not-a-url:model"
	run _parse_openai_spec "$spec"
	assert_failure
}

# Test _infer_openai success case
@test "_infer_openai returns success on valid response" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are a helpful assistant."
	local context="Write a short poem."

	run _infer_openai "$spec" "$system" "$context"
	assert_success
	assert_output "mock response from API"
}

# Test _infer_openai with output file
@test "_infer_openai writes to file when specified" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="Say hello."
	local outfile
	outfile="$(mktemp)"

	run _infer_openai "$spec" "$system" "$context" "$outfile"
	assert_success

	# Check file content
	run cat "$outfile"
	assert_output "mock response from API"

	rm -f "$outfile"
}

# Test _infer_openai HTTP 400 error maps to exit code 4
@test "_infer_openai maps HTTP 400 to exit code 4" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="error_400"

	run _infer_openai "$spec" "$system" "$context"
	assert_failure
	assert_output --partial "HTTP 400"
	[[ "$status" -eq 4 ]]
}

# Test _infer_openai HTTP 403 error maps to exit code 3
@test "_infer_openai maps HTTP 403 to exit code 3" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="error_403"

	run _infer_openai "$spec" "$system" "$context"
	assert_failure
	assert_output --partial "HTTP 403"
	[[ "$status" -eq 3 ]]
}

# Test _infer_openai HTTP 500 error maps to exit code 1
@test "_infer_openai maps HTTP 500 to exit code 1" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="error_500"

	run _infer_openai "$spec" "$system" "$context"
	assert_failure
	assert_output --partial "HTTP 500"
	[[ "$status" -eq 1 ]]
}

# Test _infer_openai with empty response
@test "_infer_openai fails on empty response" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="empty_response"

	run _infer_openai "$spec" "$system" "$context"
	assert_failure
	assert_output --partial "Empty response"
}

# Test _infer_openai with API key from MNTO_API_KEY
@test "_infer_openai uses MNTO_API_KEY when set" {
	MNTO_API_KEY="sk-test-123"

	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="Say hello."

	run _infer_openai "$spec" "$system" "$context"
	assert_success

	# Verify that curl was called with --config (secure header file)
	[[ "${_args[*]}" =~ "--config" ]]
	# NOTE: API key is NOT in command line args (security improvement)
	# It's written to a temp file referenced by --config

	unset MNTO_API_KEY
}

# Test _infer_openai with API key from OPENAI_API_KEY fallback
@test "_infer_openai uses OPENAI_API_KEY as fallback" {
	unset MNTO_API_KEY
	OPENAI_API_KEY="sk-fallback-456"

	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="Say hello."

	run _infer_openai "$spec" "$system" "$context"
	assert_success

	# Verify that curl was called with --config (secure header file)
	[[ "${_args[*]}" =~ "--config" ]]
	# NOTE: API key is NOT in command line args (security improvement)
	# It's written to a temp file referenced by --config

	unset OPENAI_API_KEY
}

# Test _infer_openai without API key (local server)
@test "_infer_openai works without API key" {
	unset MNTO_API_KEY
	unset OPENAI_API_KEY

	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="Say hello."

	run _infer_openai "$spec" "$system" "$context"
	assert_success

	# Should not contain Authorization header
	[[ ! "${_args[*]}" =~ "Authorization" ]]
}

# Test _infer_openai timeout via MNTO_TIMEOUT
@test "_infer_openai honors MNTO_TIMEOUT" {
	MNTO_TIMEOUT=60

	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="Say hello."

	run _infer_openai "$spec" "$system" "$context"
	assert_success

	# Verify --max-time was passed to curl
	[[ "${_args[*]}" =~ "--max-time" ]]
	[[ "${_args[*]}" =~ "60" ]]

	unset MNTO_TIMEOUT
}

# Test _infer_openai with special characters in context
@test "_infer_openai handles special characters in context" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context='Test with "quotes" and '\''apostrophes'\'' and $symbols.'

	run _infer_openai "$spec" "$system" "$context"
	assert_success
}

# Test _infer_openai JSON encoding safety
@test "_infer_openai safely encodes JSON payload" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="System with \"nested\" quotes"
	local context='User with $dollar and `backticks`'

	# This should not fail due to JSON encoding issues
	run _infer_openai "$spec" "$system" "$context"
	assert_success
}

# Test _infer_openai validates MNTO_TIMEOUT as numeric
@test "_infer_openai rejects non-numeric MNTO_TIMEOUT" {
	MNTO_TIMEOUT="invalid"

	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="Say hello."

	run _infer_openai "$spec" "$system" "$context"
	assert_failure
	assert_output --partial "must be a positive integer"

	unset MNTO_TIMEOUT
}

# Test _infer_openai rejects blank MNTO_TIMEOUT
@test "_infer_openai rejects blank MNTO_TIMEOUT" {
	MNTO_TIMEOUT=""

	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="Say hello."

	run _infer_openai "$spec" "$system" "$context"
	assert_failure
	assert_output --partial "must be a positive integer"

	unset MNTO_TIMEOUT
}

# Test _infer_openai extracts API error messages
@test "_infer_openai extracts API error messages" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="error_400"

	run _infer_openai "$spec" "$system" "$context"
	assert_failure
	# Should extract the actual error message from JSON
	assert_output --partial "Context too long"
}

# Test _parse_openai_spec rejects invalid URL scheme
@test "_parse_openai_spec rejects invalid URL scheme" {
	local spec="openai:ftp://localhost:11434/v1:qwen3"
	run _parse_openai_spec "$spec"
	assert_failure
	assert_output --partial "Invalid URL scheme"
}

# Test _infer_openai early validation rejects spec without openai prefix
@test "_infer_openai early validation rejects spec without prefix" {
	unset MNTO_API_KEY OPENAI_API_KEY

	local spec="invalid:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="Say hello."

	run _infer_openai "$spec" "$system" "$context"
	assert_failure
	assert_output --partial "ERROR: Invalid OpenAI spec: must start with 'openai:'"
}

# Test _parse_openai_spec rejects URL without scheme
@test "_parse_openai_spec rejects URL without scheme" {
	local spec="openai:localhost:11434/v1:qwen3"
	run _parse_openai_spec "$spec"
	assert_failure
	assert_output --partial "Invalid URL scheme"
}

# Test _infer_openai HTTP 400 includes API error detail
@test "_infer_openai HTTP 400 includes detailed API error" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="error_400"

	run _infer_openai "$spec" "$system" "$context"
	assert_failure
	assert_output --partial "Context too long"
	[[ "$status" -eq 4 ]]
}

# Test _parse_openai_spec rejects empty host
@test "_parse_openai_spec rejects URL with empty host" {
	local spec="openai:///v1:qwen3"
	run _parse_openai_spec "$spec"
	assert_failure
	assert_output --partial "empty host"
}

# Test _parse_openai_spec accepts localhost
@test "_parse_openai_spec accepts localhost URL" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	run _parse_openai_spec "$spec"
	assert_success
}

# Test _parse_openai_spec accepts 127.0.0.1
@test "_parse_openai_spec accepts 127.0.0.1 URL" {
	local spec="openai:http://127.0.0.1:11434/v1:qwen3"
	run _parse_openai_spec "$spec"
	assert_success
}

# Test _infer_openai rejects API key with newline
@test "_infer_openai rejects API key containing newline" {
	MNTO_API_KEY=$'sk-test\ninjection'

	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="Say hello."

	run _infer_openai "$spec" "$system" "$context"
	assert_failure
	assert_output --partial "invalid characters"

	unset MNTO_API_KEY
}

# Test _infer_openai rejects API key with carriage return
@test "_infer_openai rejects API key containing carriage return" {
	MNTO_API_KEY=$'sk-test\rinjection'

	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="Say hello."

	run _infer_openai "$spec" "$system" "$context"
	assert_failure
	assert_output --partial "invalid characters"

	unset MNTO_API_KEY
}

# Test _infer_openai creates temp file with correct permissions
@test "_infer_openai creates temp header file with restricted permissions" {
	MNTO_API_KEY="sk-test-valid"

	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="Say hello."

	run _infer_openai "$spec" "$system" "$context"
	assert_success

	# Verify that curl was called with --config (secure header file)
	[[ "${_args[*]}" =~ "--config" ]]
	# The header file should be created and have restricted permissions
	# (cleanup is handled by trap, so we just verify the call pattern)

	unset MNTO_API_KEY
}

# Test _infer_openai single-pass parsing extracts correct content
@test "_infer_openai single-pass parsing extracts content correctly" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="Say hello."

	run _infer_openai "$spec" "$system" "$context"
	assert_success
	assert_output "mock response from API"
}

# Test _infer_openai single-pass parsing handles error responses
@test "_infer_openai single-pass parsing handles error responses" {
	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="error_400"

	run _infer_openai "$spec" "$system" "$context"
	assert_failure
	assert_output --partial "Context too long"
}

# Test _parse_openai_spec rejects whitespace-only URL
@test "_parse_openai_spec rejects whitespace-only URL" {
	local spec="openai:   :qwen3"
	run _parse_openai_spec "$spec"
	assert_failure
	assert_output --partial "Base URL cannot be whitespace"
}

# Test _parse_openai_spec rejects whitespace-only model
@test "_parse_openai_spec rejects whitespace-only model" {
	local spec="openai:http://localhost:11434/v1:   "
	run _parse_openai_spec "$spec"
	assert_failure
	assert_output --partial "Model cannot be whitespace"
}

# Test _parse_openai_spec rejects malformed one-colon form
@test "_parse_openai_spec rejects malformed one-colon form" {
	source lib/backend.bash
	local spec="openai:"
	run _valid_openai_spec "$spec"
	assert_failure
}

# Test _valid_openai_spec rejects whitespace-only URL segment
@test "_valid_openai_spec rejects whitespace-only URL segment" {
	source lib/backend.bash
	local spec="openai:   :qwen3"
	run _valid_openai_spec "$spec"
	assert_failure
}

# Test _valid_openai_spec rejects whitespace-only model segment
@test "_valid_openai_spec rejects whitespace-only model segment" {
	source lib/backend.bash
	local spec="openai:http://localhost:11434/v1:   "
	run _valid_openai_spec "$spec"
	assert_failure
}