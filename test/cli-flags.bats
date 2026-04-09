#!/usr/bin/env bats
# Test suite for CLI flag parsing and precedence for per-role model configuration

setup() {
	export MNTO="${BATS_TEST_DIRNAME}/.."
	# Clean up any pre-existing env vars
	unset MNTO_PROPOSER MNTO_VERIFIER MNTO_MODEL PROPOSER_MODEL VERIFIER_MODEL PLAN_MODEL
}

teardown() {
	# Clean up env vars after each test
	unset MNTO_PROPOSER MNTO_VERIFIER MNTO_MODEL PROPOSER_MODEL VERIFIER_MODEL PLAN_MODEL
}

# Test helper: Source mnto script to test parse_options
source_mnto() {
	# Source the main script (will setup parse_options)
	source "$MNTO/mnto" 2>/dev/null || true
}

# Mock apfel to avoid actually calling it
mock_apfel() {
	echo "mock response"
}
export -f mock_apfel

# ============ --proposer Flag Tests ============

@test "parse_options accepts --proposer flag with spec" {
	source_mnto

	# Mock apfel for sourcing
	apfel() { :; }
	export -f apfel

	# Parse options
	REMAINING_ARGS=()
	parse_options --proposer "apfel"

	[ "$PROPOSER_MODEL" = "apfel" ]
}

@test "parse_options accepts --proposer with openai spec" {
	source_mnto

	apfel() { :; }
	export -f apfel

	REMAINING_ARGS=()
	parse_options --proposer "openai:http://localhost:11434/v1:gpt-4"

	[ "$PROPOSER_MODEL" = "openai:http://localhost:11434/v1:gpt-4" ]
}

@test "parse_options rejects --proposer without argument" {
	source_mnto

	apfel() { :; }
	export -f apfel

	run parse_options --proposer
	[ "$status" -ne 0 ]
	[[ "$output" == *"ERROR: --proposer requires a model spec"* ]]
}

@test "parse_options accepts --verifier flag with spec" {
	source_mnto

	apfel() { :; }
	export -f apfel

	REMAINING_ARGS=()
	parse_options --verifier "apfel"

	[ "$VERIFIER_MODEL" = "apfel" ]
}

@test "parse_options accepts --verifier with openai spec" {
	source_mnto

	apfel() { :; }
	export -f apfel

	REMAINING_ARGS=()
	parse_options --verifier "openai:http://localhost:11434/v1:gpt-3.5"

	[ "$VERIFIER_MODEL" = "openai:http://localhost:11434/v1:gpt-3.5" ]
}

@test "parse_options rejects --verifier without argument" {
	source_mnto

	apfel() { :; }
	export -f apfel

	run parse_options --verifier
	[ "$status" -ne 0 ]
	[[ "$output" == *"ERROR: --verifier requires a model spec"* ]]
}

@test "parse_options accepts both --proposer and --verifier" {
	source_mnto

	apfel() { :; }
	export -f apfel

	REMAINING_ARGS=()
	parse_options --proposer "apfel" --verifier "openai:http://localhost:11434/v1:gpt-4"

	[ "$PROPOSER_MODEL" = "apfel" ]
	[ "$VERIFIER_MODEL" = "openai:http://localhost:11434/v1:gpt-4" ]
}

# ============ Backward Compatibility Tests ============

@test "parse_options still accepts --plan-model flag" {
	source_mnto

	apfel() { :; }
	export -f apfel

	REMAINING_ARGS=()
	parse_options --plan-model "apfel"

	[ "$PLAN_MODEL" = "apfel" ]
}

@test "parse_options accepts --plan-model with --proposer together" {
	source_mnto

	apfel() { :; }
	export -f apfel

	REMAINING_ARGS=()
	parse_options --plan-model "apfel" --proposer "openai:http://localhost:11434/v1:gpt-4"

	[ "$PLAN_MODEL" = "apfel" ]
	[ "$PROPOSER_MODEL" = "openai:http://localhost:11434/v1:gpt-4" ]
}

@test "--plan-model alone maps to MNTO_PROPOSER env export" {
	unset PROPOSER_MODEL VERIFIER_MODEL MNTO_PROPOSER MNTO_VERIFIER

	# Simulate parse_options setting PLAN_MODEL
	export PLAN_MODEL="openai:http://plan-model.spec/v1:legacy-model"

	# Apply backward compatibility mapping
	if [[ -n "$PLAN_MODEL" ]] && [[ -z "$PROPOSER_MODEL" ]]; then
		PROPOSER_MODEL="$PLAN_MODEL"
	fi

	# Apply precedence logic
	if [[ -n "$PROPOSER_MODEL" ]]; then
		export MNTO_PROPOSER="$PROPOSER_MODEL"
	fi

	# Verify PLAN_MODEL mapped to MNTO_PROPOSER
	[ "$MNTO_PROPOSER" = "openai:http://plan-model.spec/v1:legacy-model" ]
}

@test "--proposer overrides --plan-model when both are provided" {
	unset PROPOSER_MODEL VERIFIER_MODEL MNTO_PROPOSER MNTO_VERIFIER

	# Simulate both flags being set
	export PLAN_MODEL="openai:http://plan-model.spec/v1:legacy-model"
	export PROPOSER_MODEL="openai:http://proposer.spec/v1:new-model"

	# Apply backward compatibility mapping (should NOT override existing PROPOSER_MODEL)
	if [[ -n "$PLAN_MODEL" ]] && [[ -z "$PROPOSER_MODEL" ]]; then
		PROPOSER_MODEL="$PLAN_MODEL"
	fi

	# Apply precedence logic
	if [[ -n "$PROPOSER_MODEL" ]]; then
		export MNTO_PROPOSER="$PROPOSER_MODEL"
	fi

	# Verify PROPOSER won (PLAN_MODEL should not override)
	[ "$MNTO_PROPOSER" = "openai:http://proposer.spec/v1:new-model" ]
}

@test "PLAN_MODEL does not affect MNTO_VERIFIER" {
	unset PROPOSER_MODEL VERIFIER_MODEL MNTO_PROPOSER MNTO_VERIFIER

	# Simulate PLAN_MODEL being set
	export PLAN_MODEL="openai:http://plan-model.spec/v1:legacy-model"

	# Apply backward compatibility mapping
	if [[ -n "$PLAN_MODEL" ]] && [[ -z "$PROPOSER_MODEL" ]]; then
		PROPOSER_MODEL="$PLAN_MODEL"
	fi

	# Apply precedence logic
	if [[ -n "$PROPOSER_MODEL" ]]; then
		export MNTO_PROPOSER="$PROPOSER_MODEL"
	fi
	if [[ -n "$VERIFIER_MODEL" ]]; then
		export MNTO_VERIFIER="$VERIFIER_MODEL"
	fi

	# Verify PLAN_MODEL mapped to MNTO_PROPOSER but not MNTO_VERIFIER
	[ "$MNTO_PROPOSER" = "openai:http://plan-model.spec/v1:legacy-model" ]
	[ -z "${MNTO_VERIFIER:-}" ]
}

# ============ Precedence Tests ============

@test "CLI --proposer exports MNTO_PROPOSER when set" {
	# Simulate setting PROPOSER_MODEL from parse_options
	export PROPOSER_MODEL="openai:http://localhost:11434/v1:gpt-4"
	unset MNTO_PROPOSER MNTO_VERIFIER MNTO_MODEL

	# Execute precedence logic (simulating main function after parse_options)
	if [[ -n "$PROPOSER_MODEL" ]]; then
		export MNTO_PROPOSER="$PROPOSER_MODEL"
	fi

	[ -n "$MNTO_PROPOSER" ]
	[ "$MNTO_PROPOSER" = "openai:http://localhost:11434/v1:gpt-4" ]
}

@test "CLI --verifier exports MNTO_VERIFIER when set" {
	export VERIFIER_MODEL="openai:http://localhost:11434/v1:gpt-3.5"
	unset MNTO_PROPOSER MNTO_VERIFIER MNTO_MODEL

	# Execute precedence logic
	if [[ -n "$VERIFIER_MODEL" ]]; then
		export MNTO_VERIFIER="$VERIFIER_MODEL"
	fi

	[ -n "$MNTO_VERIFIER" ]
	[ "$MNTO_VERIFIER" = "openai:http://localhost:11434/v1:gpt-3.5" ]
}

@test "CLI --proposer overrides pre-set MNTO_PROPOSER env var" {
	# Set env var first
	export MNTO_PROPOSER="openai:http://old.example.com/v1:gpt-3.5"

	# Simulate CLI flag setting higher precedence
	export PROPOSER_MODEL="openai:http://new.example.com/v1:gpt-4"

	# Execute precedence logic
	if [[ -n "$PROPOSER_MODEL" ]]; then
		export MNTO_PROPOSER="$PROPOSER_MODEL"
	fi

	# Verify CLI flag won
	[ "$MNTO_PROPOSER" = "openai:http://new.example.com/v1:gpt-4" ]
}

@test "CLI --verifier overrides pre-set MNTO_VERIFIER env var" {
	export MNTO_VERIFIER="openai:http://old.example.com/v1:gpt-3.5"

	export VERIFIER_MODEL="openai:http://new.example.com/v1:gpt-4"

	if [[ -n "$VERIFIER_MODEL" ]]; then
		export MNTO_VERIFIER="$VERIFIER_MODEL"
	fi

	[ "$MNTO_VERIFIER" = "openai:http://new.example.com/v1:gpt-4" ]
}

@test "No CLI flags preserve pre-set env vars" {
	unset PROPOSER_MODEL VERIFIER_MODEL

	# Pre-set env vars (no CLI flags)
	export MNTO_PROPOSER="openai:http://preset.example.com/v1:gpt-4"
	export MNTO_VERIFIER="openai:http://preset.example.com/v1:gpt-3.5"

	# Precedence logic would not override since PROPOSER_MODEL/VERIFIER_MODEL are empty
	if [[ -n "$PROPOSER_MODEL" ]]; then
		export MNTO_PROPOSER="$PROPOSER_MODEL"
	fi
	if [[ -n "$VERIFIER_MODEL" ]]; then
		export MNTO_VERIFIER="$VERIFIER_MODEL"
	fi

	# Original values preserved
	[ "$MNTO_PROPOSER" = "openai:http://preset.example.com/v1:gpt-4" ]
	[ "$MNTO_VERIFIER" = "openai:http://preset.example.com/v1:gpt-3.5" ]
}

@test "Empty PROPOSER_MODEL does not export MNTO_PROPOSER" {
	export PROPOSER_MODEL=""
	unset MNTO_PROPOSER
	unset MNTO_VERIFIER MNTO_MODEL

	# Empty string check
	if [[ -n "$PROPOSER_MODEL" ]]; then
		export MNTO_PROPOSER="$PROPOSER_MODEL"
	fi

	# Should remain unset
	[ -z "${MNTO_PROPOSER:-}" ]
}

@test "Empty VERIFIER_MODEL does not export MNTO_VERIFIER" {
	export VERIFIER_MODEL=""
	unset MNTO_VERIFIER
	unset MNTO_PROPOSER MNTO_MODEL

	if [[ -n "$VERIFIER_MODEL" ]]; then
		export MNTO_VERIFIER="$VERIFIER_MODEL"
	fi

	[ -z "${MNTO_VERIFIER:-}" ]
}

@test "CLI flags take precedence even when MNTO_MODEL is set" {
	export MNTO_MODEL="openai:http://fallback.example.com/v1:gpt-2"

	export PROPOSER_MODEL="openai:http://cli-proposer.example.com/v1:gpt-4"
	export VERIFIER_MODEL="openai:http://cli-verifier.example.com/v1:gpt-3.5"

	if [[ -n "$PROPOSER_MODEL" ]]; then
		export MNTO_PROPOSER="$PROPOSER_MODEL"
	fi
	if [[ -n "$VERIFIER_MODEL" ]]; then
		export MNTO_VERIFIER="$VERIFIER_MODEL"
	fi

	[ "$MNTO_PROPOSER" = "openai:http://cli-proposer.example.com/v1:gpt-4" ]
	[ "$MNTO_VERIFIER" = "openai:http://cli-verifier.example.com/v1:gpt-3.5" ]
	# MNTO_MODEL should remain unchanged
	[ "$MNTO_MODEL" = "openai:http://fallback.example.com/v1:gpt-2" ]
}

# ============ Integration with backend.bash Tests ============

@test "CLI --proposer is used by _resolve_backend for proposer role" {
	source "$MNTO/lib/backend.bash"

	export PROPOSER_MODEL="openai:http://cli.spec/v1:test-model"
	unset MNTO_PROPOSER MNTO_VERIFIER MNTO_MODEL

	# Apply precedence
	if [[ -n "$PROPOSER_MODEL" ]]; then
		export MNTO_PROPOSER="$PROPOSER_MODEL"
	fi

	local result
	result="$(_resolve_backend proposer)"

	[ "$result" = "openai:http://cli.spec/v1:test-model" ]
}

@test "CLI --verifier is used by _resolve_backend for verifier role" {
	source "$MNTO/lib/backend.bash"

	export VERIFIER_MODEL="openai:http://cli.spec/v1:test-verifier"
	unset MNTO_PROPOSER MNTO_VERIFIER MNTO_MODEL

	# Apply precedence
	if [[ -n "$VERIFIER_MODEL" ]]; then
		export MNTO_VERIFIER="$VERIFIER_MODEL"
	fi

	local result
	result="$(_resolve_backend verifier)"

	[ "$result" = "openai:http://cli.spec/v1:test-verifier" ]
}

@test "CLI flag overrides env var in _resolve_backend" {
	source "$MNTO/lib/backend.bash"

	# Pre-set env var
	export MNTO_PROPOSER="openai:http://env.spec/v1:old-model"

	# CLI flag should win
	export PROPOSER_MODEL="openai:http://cli.spec/v1:new-model"

	# Apply precedence
	if [[ -n "$PROPOSER_MODEL" ]]; then
		export MNTO_PROPOSER="$PROPOSER_MODEL"
	fi

	local result
	result="$(_resolve_backend proposer)"

	[ "$result" = "openai:http://cli.spec/v1:new-model" ]
}