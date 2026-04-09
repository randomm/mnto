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
	local backend
	backend="$(_resolve_backend "$role")"

	# Unified validation and dispatch:
	# - Extract backend type (before first colon)
	# - Validate according to type
	# - Dispatch to appropriate function
	local backend_type="${backend%%:*}"
	case "$backend_type" in
	apfel)
		# apfel backend accepts both "apfel" and "apfel:spec"
		_infer_apfel "$system" "$context" "$outfile"
		;;
	openai)
		# OpenAI backend requires full spec: openai:URL:MODEL (two colons after prefix)
		case "$backend" in
			openai:*:*)
				# Valid spec: openai:URL:MODEL
				_infer_openai "$backend" "$system" "$context" "$outfile"
				;;
			*)
				# Invalid: missing URL and/or model segments
				echo "ERROR: OpenAI backend requires spec format openai:URL:MODEL" >&2
				return 1
				;;
		esac
		;;
	*)
		# Unknown backend type
		echo "ERROR: Invalid backend specification: $backend (expected openai:URL:MODEL)" >&2
		return 1
		;;
	esac
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

# Usage: _infer_openai <backend_spec> <system_prompt> <context> [output_file]
# Stub: OpenAI backend (full implementation in issue #49)
# backend_spec: backend specification string (e.g., "openai:gpt-4")
# system_prompt: system prompt for the model
# context: input context (user message)
# output_file: optional file path to write output
# Returns: 1 (not implemented)
# shellcheck disable=SC2034 # backend_spec used in future implementation
_infer_openai() {
	local backend_spec="$1"
	local system="$2"
	local context="$3"
	local outfile="${4:-}"

	echo "ERROR: OpenAI backend not yet implemented" >&2
	return 1
}