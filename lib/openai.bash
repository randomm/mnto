#!/usr/bin/env bash
# OpenAI-compatible API backend adapter for mnto
set -euo pipefail

# shellcheck disable=SC2317
declare -r _OPENAI_SOURCED=1

# Parse OpenAI backend specification
# Usage: _parse_openai_spec SPEC
# Prints: base_url\tmodel (tab-separated)
# Spec format: openai:SCHEME://HOST:PORT/PATH:MODEL
# Example: openai:http://localhost:11434/v1:qwen3:30b-a3b
# Note: model is ALWAYS the last segment after the final colon (handles model names with colons)
_parse_openai_spec() {
	local spec="$1"

	# Strip "openai:" prefix
	local url_and_model="${spec#openai:}"

	# Extract base URL and model by splitting on last colon
	# Base URL is everything before the last colon, model is everything after
	# This handles: http://localhost:11434/v1:gpt-4 and model names with colons
	local base_url="${url_and_model%:*}"
	local model="${url_and_model##*:}"

	# Validate that both segments are non-empty after stripping "openai:" prefix
	if [[ -z "$base_url" || -z "$model" ]]; then
		echo "ERROR: Could not parse backend spec: $1" >&2
		return 1
	fi

	# Validate URL scheme to prevent SSRF
	if [[ ! "$base_url" =~ ^https?:// ]]; then
		echo "ERROR: Invalid URL scheme in backend spec" >&2
		return 1
	fi

	# Extract and validate host is not empty (prevents malformed URLs like http:///path)
	local host="${base_url#*://}"
	host="${host%%/*}"
	if [[ -z "$host" ]]; then
		echo "ERROR: Invalid URL: empty host" >&2
		return 1
	fi

	# Validate URL and model are not whitespace-only
	if [[ "$base_url" =~ ^[[:space:]]+$ ]]; then
		echo "ERROR: Base URL cannot be whitespace" >&2
		return 1
	fi
	if [[ "$model" =~ ^[[:space:]]+$ ]]; then
		echo "ERROR: Model cannot be whitespace" >&2
		return 1
	fi

	# Return values safely via stdout (tab-separated)
	printf '%s\t%s\n' "$base_url" "$model"
}

# Send request to OpenAI-compatible API
# Usage: _infer_openai BACKEND_SPEC SYSTEM_PROMPT CONTEXT [OUTPUT_FILE]
# BACKEND_SPEC format: openai:BASE_URL:MODEL (e.g., openai:http://localhost:11434/v1:qwen3)
# Sends POST to BASE_URL/chat/completions
# Exit codes: 0=success, 1=fail, 3=content_filter, 4=token_limit
_infer_openai() {
	local spec="$1" system="$2" context="$3" outfile="${4:-}"
	local base_url model api_key response content

	# Early validation: spec must start with "openai:" prefix (TYPE_SAFETY)
	if ! [[ "$spec" =~ ^openai: ]]; then
		echo "ERROR: Invalid OpenAI spec: must start with 'openai:'" >&2
		return 1
	fi

	# Validate timeout (must be numeric)
	local timeout="${MNTO_TIMEOUT:-120}"
	if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
		echo "ERROR: MNTO_TIMEOUT must be a positive integer" >&2
		return 1
	fi

	# Parse spec — CRITICAL: URL contains colons, model is LAST segment
	# Returns tab-separated base_url and model from _parse_openai_spec
	local parse_result
	parse_result="$(_parse_openai_spec "$spec")" || return 1
	IFS=$'\t' read -r base_url model <<<"$parse_result"

	api_key="${MNTO_API_KEY:-${OPENAI_API_KEY:-}}"

	# Build request with jq (safe JSON encoding of prompts containing special chars)
	local payload
	payload="$(jq -n \
		--arg model "$model" \
		--arg sys "$system" \
		--arg ctx "$context" \
		'{model:$model, messages:[{role:"system",content:$sys},{role:"user",content:$ctx}]}'
	)" || return 1

# Send request with secure header file to avoid exposing API key in process list
 	local header_file=""
 	# shellcheck disable=SC2329  # invoked via trap
 	_cleanup_header() { [[ -n "$header_file" ]] && rm -f "$header_file"; }
 	trap '_cleanup_header' RETURN INT TERM HUP

	local curl_auth_args=()
	if [[ -n "$api_key" ]]; then
		# Validate API key contains no newlines (header injection prevention)
		if [[ "$api_key" == *$'\n'* ]] || [[ "$api_key" == *$'\r'* ]]; then
			echo "ERROR: API key contains invalid characters (newline)" >&2
			return 1
		fi

		# Create temporary file with restrictive permissions (umask defense)
		local old_umask
		old_umask="$(umask)"
		umask 077
		header_file="$(mktemp)" || {
			umask "$old_umask"
			return 1
		}
		umask "$old_umask"
		chmod 600 "$header_file"  # Defense-in-depth: ensure owner-only
		printf 'header "Authorization: Bearer %s"\n' "$api_key" > "$header_file"
		curl_auth_args=(--config "$header_file")
	fi

	# Use unit separator (0x1F) for robust response parsing
	# This character won't appear in valid JSON
	response="$(curl -sS --max-time "$timeout" \
		-w $'\x1f%{http_code}' \
		"${base_url}/chat/completions" \
		-H "Content-Type: application/json" \
		"${curl_auth_args[@]}" \
		-d "$payload"
	)" || return 1

	# Extract HTTP status code and body using parameter expansion
	# Separator is $'\x1f' (unit separator), HTTP code is after it
	http_code="${response##*$'\x1f'}"
	local body="${response%$'\x1f'"$http_code"}"

	# Map HTTP errors to exit codes
	case "$http_code" in
		200) ;; # success, continue
		400) return 4 ;; # often token limit
		403|451) return 3 ;; # content filter
		*)
			echo "ERROR: OpenAI API returned HTTP $http_code" >&2
			return 1
			;;
	esac

	# Extract content and error in single jq pass (performance optimization)
	local parse_result
	parse_result="$(echo "$body" | jq -r '
		if (.choices[0].message.content // null) != null then
			.content = (.choices[0].message.content)
		elif (.error.message // null) != null then
			.error = (.error.message)
		else
			.error = "Unknown API error"
		end
		| if .content then .content else .error end
	')" || {
		echo "ERROR: OpenAI API: Could not parse response" >&2
		return 1
	}

	# Check if result is an error (no content field present in response)
	if ! echo "$body" | jq -e '.choices[0].message.content' >/dev/null 2>&1; then
		echo "ERROR: OpenAI API: $parse_result" >&2
		return 1
	fi

	content="$parse_result"

	# Output
	if [[ -n "$outfile" ]]; then
		echo "$content" > "$outfile"
	else
		echo "$content"
	fi
}