#!/usr/bin/env bash
# e2e-qa.sh - End-to-end validation suite for mnto workflow orchestrator
# Thin wrapper that delegates to bats for test execution
#
# Usage:
#   ./test/e2e/e2e-qa.sh              Run all scenarios (mock mode)
#   ./test/e2e/e2e-qa.sh --scenario N Run specific scenario (01-06)
#   ./test/e2e/e2e-qa.sh --dry-run    Show what would run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly E2E_BATS="$SCRIPT_DIR/e2e.bats"

usage() {
	cat <<EOF
Usage: e2e-qa.sh [OPTIONS]

End-to-end validation suite for mnto workflow orchestrator.
Delegates to bats for actual test execution.

OPTIONS:
    --scenario N     Run specific scenario (01-06)
    --dry-run        Show what would run without executing
    --help           Show this help message

EXAMPLES:
    e2e-qa.sh                    Run all mock-based scenarios
    e2e-qa.sh --scenario 03     Run only DAG dependency ordering test
    e2e-qa.sh --dry-run         Preview test list

SCENARIOS:
    01  Single-shot routing      - Direct mode for short goals
    02  Workflow routing          - Harness mode with --workflow flag
    03  DAG dependency ordering   - Sequential deps execute in order
    04  Resume correctness         - Partial state resume processes remaining
    05  Context isolation         - Dep outputs in context, not future tasks
    06  Planner model routing     - Two-model architecture end-to-end

EOF
}

main() {
	local scenario_filter=""
	local is_dry_run=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--scenario)
			scenario_filter="$2"
			shift 2
			;;
		--dry-run)
			is_dry_run=true
			shift
			;;
		--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			usage
			exit 1
			;;
		esac
	done

	# Verify bats is available
	if ! command -v bats &>/dev/null; then
		echo "ERROR: bats not found in PATH (required for e2e tests)" >&2
		exit 1
	fi

	# Verify e2e.bats exists
	if [[ ! -f "$E2E_BATS" ]]; then
		echo "ERROR: e2e.bats not found at $E2E_BATS" >&2
		exit 1
	fi

	# Build bats command
	local bats_args=("$E2E_BATS")

	if [[ "$is_dry_run" == true ]]; then
		echo "DRY RUN - Tests that would be executed:"
		echo ""
		bats --list "$E2E_BATS" 2>/dev/null || true
		echo ""
		echo "Scenarios available:"
		echo "  01  Single-shot routing"
		echo "  02  Workflow routing"
		echo "  03  DAG dependency ordering"
		echo "  04  Resume correctness"
		echo "  05  Context isolation"
		echo "  06  Planner model routing"
		exit 0
	fi

	if [[ -n "$scenario_filter" ]]; then
		bats_args=(--filter "scenario_${scenario_filter}_" "$E2E_BATS")
	fi

	# Run bats with verbose output
	exec bats "${bats_args[@]}"
}

main "$@"
