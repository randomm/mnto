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
_parse_openai_spec() {
	local spec="$1"

	# Strip "openai:" prefix
	local url_and_model="${spec#openai:}"

	# Match: scheme://host/path:MODEL (supports optional port in host part)
	# This handles: http://localhost:11434/v1:qwen3 and localhost:11434/v1:qwen3:30b
	if [[ "$url_and_model" =~ ^(https?://[^:/]+(?::[0-9]+)?[^:]*):(.+)$ ]]; then
		local base_url="${BASH_REMATCH[1]}"
		local model="${BASH_REMATCH[2]}"

		if [[ -z "$base_url" || -z "$model" ]]; then
			echo "ERROR: Could not parse backend spec: $1" >&2
			return 1
		fi

		# Validate URL scheme to prevent SSRF
		if [[ ! "$base_url" =~ ^https?:// ]]; then
			echo "ERROR: Invalid URL scheme in backend spec" >&2
			return 1
		fi

		# Return values safely via stdout (tab-separated)
		printf '%s\t%s\n' "$base_url" "$model"
	else
		echo "ERROR: Invalid OpenAI spec format: $spec" >&2
		return 1
	fi
}

# Send request to OpenAI-compatible API
# Usage: _infer_openai BACKEND_SPEC SYSTEM_PROMPT CONTEXT [OUTPUT_FILE]
# BACKEND_SPEC format: openai:BASE_URL:MODEL (e.g., openai:http://localhost:11434/v1:qwen3)
# Sends POST to BASE_URL/chat/completions
# Exit codes: 0=success, 1=fail, 3=content_filter, 4=token_limit
_infer_openai() {
	local spec="$1" system="$2" context="$3" outfile="${4:-}"
	local base_url model api_key response content

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
		header_file="$(mktemp)"
		# Minimal race window: relies on restrictive umask + immediate chmod
		chmod 600 "$header_file"  # Restrict file permissions to owner only
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

	# Extract content
	if ! echo "$body" | jq -e '.choices[0].message.content' >/dev/null 2>&1; then
		local error_msg
		error_msg="$(echo "$body" | jq -r '.error.message // "Unknown API error"')"
		echo "ERROR: OpenAI API: $error_msg" >&2
		return 1
	fi
	content="$(echo "$body" | jq -r '.choices[0].message.content')"

	# Output
	if [[ -n "$outfile" ]]; then
		echo "$content" > "$outfile"
	else
		echo "$content"
	fi
}