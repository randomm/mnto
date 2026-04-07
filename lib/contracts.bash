#!/usr/bin/env bash
# Contract loading with hybrid pattern (workspace overrides default)
# Used by validator pipeline (future issue)

# Load contract for stage (workspace override or default)
# Usage: load_contract <stage>
# Returns: path to contract file, or empty if none found
# Note: Caller is responsible for validating YAML content after loading
load_contract() {
	local stage="$1"

	# Validate stage is non-empty and contains only safe characters
	if [[ -z "$stage" ]] || ! [[ "$stage" =~ ^[a-z_]+$ ]]; then
		echo "ERROR: Invalid stage name - must be lowercase letters and underscores" >&2
		return 1
	fi

	# Reject path traversal attempts
	if [[ "$stage" =~ \.\./ ]] || [[ "$stage" =~ ^/ ]]; then
		echo "ERROR: Invalid stage name - path traversal not allowed" >&2
		return 1
	fi

	local workspace_contract=".mnto/contracts/${stage}.yaml"
	local default_contract="${SCRIPT_DIR}/contracts/${stage}.yaml"

	if [[ -f "$workspace_contract" ]]; then
		echo "$workspace_contract"
	elif [[ -f "$default_contract" ]]; then
		echo "$default_contract"
	else
		# Return empty string + exit 1 when no contract found
		echo ""
		return 1
	fi
}
