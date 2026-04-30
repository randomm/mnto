#!/usr/bin/env bash
# Unified inference abstraction layer for mnto
# Provides backend-agnostic inference via env var configuration
#
# Exit codes:
#   0 = success
#   1 = failure
#   3 = guardrail blocked
#   4 = context overflow
set -euo pipefail

# Idempotency guard — prevent double-sourcing
[[ -n "${_BACKEND_SOURCED:-}" ]] && return 0
declare -r _BACKEND_SOURCED=1

# Usage: _infer_dispatch <backend_spec> <system> <context> <outfile>
# Internal: dispatch to backend implementation
# Returns: 0 on success, 1 on failure, 3 on guardrail, 4 on overflow
_infer_dispatch() {
	local backend="$1"
	local system="$2"
	local context="$3"
	local outfile="${4:-}"

	local backend_type="${backend%%:*}"
	case "$backend_type" in
	apfel)
		_infer_apfel "$system" "$context" "$outfile"
		;;
	openai)
		_valid_openai_spec "$backend" || {
			echo "ERROR: OpenAI backend requires spec format openai:URL:MODEL" >&2
			return 1
		}
		_infer_openai "$backend" "$system" "$context" "$outfile"
		;;
	*)
		echo "ERROR: Invalid backend specification: $backend (expected openai:URL:MODEL)" >&2
		return 1
		;;
	esac
}

# Usage: infer <role> <system_prompt> <context> [output_file]
# Role-based inference dispatcher
# role: planner|proposer|verifier|stitcher
# system_prompt: system prompt for the model
# context: input context (user message)
# output_file: optional file path to write output
# Returns: 0 on success, 1 on failure, 3 on guardrail, 4 on overflow
infer() {
	local role="$1"
	local system="$2"
	local context="$3"
	local outfile="${4:-}"

	# Validate role parameter (TYPE_SAFETY: guard against invalid roles)
	local allowed_roles="planner|proposer|verifier|stitcher"
	if ! [[ "$role" =~ ^($allowed_roles)$ ]]; then
		echo "ERROR: Invalid role '$role' (must be one of: $allowed_roles)" >&2
		return 1
	fi

	# Role-based temperature: low for structured output (planner/verifier),
	# higher for creative content (proposer/stitcher).
	local temperature
	case "$role" in
	planner | verifier) temperature="${MNTO_TEMP_STRUCTURED:-0.2}" ;;
	proposer | stitcher) temperature="${MNTO_TEMP_CREATIVE:-0.7}" ;;
	esac
	export MNTO_TEMPERATURE="$temperature"

	local backend
	backend="$(_resolve_backend "$role")"

	_infer_dispatch "$backend" "$system" "$context" "$outfile"
}

# Usage: _valid_openai_spec <backend_spec>
# Check if backend spec has valid OpenAI format (prefix with 2 colons minimum)
# Rejects whitespace-only URL/model segments and malformed one-colon forms
# Returns: 0 if valid, 1 if invalid
_valid_openai_spec() {
	local backend_spec="$1"

	# Must start with "openai:" and have at least 2 more colons for URL:MODEL
	[[ "$backend_spec" =~ ^openai:.*:.* ]] || return 1

	# Strip "openai:" prefix and check segments
	local url_and_model="${backend_spec#openai:}"

	# Extract URL and model by splitting on last colon
	local url="${url_and_model%:*}"
	local model="${url_and_model##*:}"

	# Reject empty segments
	[[ -n "$url" ]] || return 1
	[[ -n "$model" ]] || return 1

	# Reject whitespace-only segments
	[[ ! "$url" =~ ^[[:space:]]+$ ]] || return 1
	[[ ! "$model" =~ ^[[:space:]]+$ ]] || return 1

	return 0
}

# Usage: _resolve_backend <role>
# Resolve backend from env vars based on role
# Resolution order:
#   1. Role-specific env var (MNTO_VERIFIER, MNTO_PROPOSER)
#   2. Generic MNTO_MODEL
#   3. "apfel" (backward compatible default)
# Returns: backend identifier string
_resolve_backend() {
	local role="$1"
	local result

	# Try role-specific env var first
	case "$role" in
	verifier)
		if [[ -n "${MNTO_VERIFIER:-}" ]]; then
			result="$MNTO_VERIFIER"
		else
			# Fall back to generic model var
			result="${MNTO_MODEL:-apfel}"
		fi
		;;
	planner | proposer | stitcher)
		if [[ -n "${MNTO_PROPOSER:-}" ]]; then
			result="$MNTO_PROPOSER"
		else
			# Fall back to generic model var
			result="${MNTO_MODEL:-apfel}"
		fi
		;;
	*)
		# Unknown role: use generic model var
		result="${MNTO_MODEL:-apfel}"
		;;
	esac

	echo "$result"
}

# Usage: _infer_apfel <system_prompt> <context> [output_file]
# Execute inference using apfel backend
# system_prompt: system prompt for the model
# context: input context (user message)
# output_file: optional file path to write output
# Returns: 0 on success, 3 on guardrail, 4 on overflow, 1 on other errors
_infer_apfel() {
	local system="$1"
	local context="$2"
	local outfile="${3:-}"

	# Input safety: prevent flag injection
	if [[ "$context" == -* ]]; then
		context=$'\n'"$context"
	fi

	if [[ -n "$outfile" ]]; then
		apfel -q -s "$system" "$context" >"$outfile" 2>/dev/null
	else
		apfel -q -s "$system" "$context" 2>/dev/null
	fi
	# Exit codes pass through naturally: 3=guardrail, 4=overflow
}

# Usage: infer_with_backend <backend> <role> <system> <context> [outfile]
# Invoke infer with explicit backend instead of role-based dispatch
# Usage: out="$(infer_with_backend "$backend" "$role" "$system" "$context")"
infer_with_backend() {
	local backend="$1"
	local role="$2"
	local system="$3"
	local context="$4"
	local outfile="${5:-}"

	# Mirror temperature injection from backend.bash:infer()
	local temperature
	case "$role" in
	planner | verifier) temperature="${MNTO_TEMP_STRUCTURED:-0.2}" ;;
	proposer | stitcher) temperature="${MNTO_TEMP_CREATIVE:-0.7}" ;;
	*) temperature="0.7" ;;
	esac
	export MNTO_TEMPERATURE="$temperature"

	_infer_dispatch "$backend" "$system" "$context" "$outfile"
}
