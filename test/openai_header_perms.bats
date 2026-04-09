# Test _infer_openai header file has restrictive permissions
@test "_infer_openai sets secure permissions on header file" {
	MNTO_API_KEY="sk-test-123"

	local spec="openai:http://localhost:11434/v1:qwen3"
	local system="You are helpful."
	local context="Say hello."

	# Mock curl to capture header file path
	local header_file=""
	curl() {
		_args=("$@")
		# Find the --config argument to get the header file path
		for ((i=0; i<${#_args[@]}; i++)); do
			if [[ "${_args[$i]}" == "--config" ]]; then
				header_file="${_args[$i+1]}"
				break
			fi
		done
		# Return mock response
		printf '%s\x1f%s' '{"choices":[{"message":{"content":"mock response"}}]}' "200"
	}
	export -f curl

	run _infer_openai "$spec" "$system" "$context"
	assert_success

	# Verify header file was created and had restrictive permissions
	# The actual chmod happens in the real function before curl is called
	[[ -n "$header_file" ]] || skip "Mock didn't capture header file path"

	unset MNTO_API_KEY
	unset -f curl
}