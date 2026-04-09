#!/usr/bin/env bash
# e2e-qa.sh - End-to-end validation suite for mnto with real inference calls
# Usage: ./test/e2e/e2e-qa.sh [--scenario SCENARIO] [--backend SPEC] [--dry-run]

set -euo pipefail

# Script directory for reliable path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly PROJECT_ROOT
readonly SCENARIOS_DIR="$SCRIPT_DIR/scenarios"
readonly RESULTS_DIR="$SCRIPT_DIR/results"

# Backend configuration
BACKEND=""
BACKEND_EXPLICIT=false
readonly DEFAULT_BACKEND="apfel"

# Global metrics
total_duration=0
total_inference_calls=0
total_retries=0
scenarios_run=0
scenarios_passed=0

# Run directory (set during init)
RUN_DIR=""
METRICS_FILE=""
SUMMARY_FILE=""

usage() {
	cat <<EOF
Usage: e2e-qa.sh [OPTIONS]

End-to-end validation suite for mnto with real inference calls.

OPTIONS:
    --scenario SCENARIO    Run specific scenario (e.g., 01, 02, etc.)
    --backend SPEC         Backend specification (apfel, openai)
    --dry-run              Show what would run without executing
    --help                 Show this help message

BACKEND SELECTION:
    --backend apfel        Use apfel CLI for inference
    --backend openai       Use OpenAI API for inference (requires OPENAI_API_KEY or MNTO_API_KEY)

    Backend precedence (from highest to lowest):
    1. --backend flag (explicit override, takes precedence)
    2. MNTO_VERIFIER environment variable
    3. MNTO_MODEL environment variable
    4. Default: apfel

    When --backend is provided, it overrides any existing MNTO_MODEL for this run.

EXAMPLES:
    e2e-qa.sh                    # Run all scenarios with auto-detected backend
    e2e-qa.sh --scenario 01      # Run only scenario 01
    e2e-qa.sh --backend openai   # Run all scenarios with OpenAI backend
    e2e-qa.sh --dry-run           # Preview scenarios to run

EOF
}

log() {
	echo "[$(date +%H:%M:%S)] $*" | tee -a "${SUMMARY_FILE}"
}

log_section() {
	echo "" | tee -a "${SUMMARY_FILE}"
	echo "=== $*" | tee -a "${SUMMARY_FILE}"
	echo "" | tee -a "${SUMMARY_FILE}"
}

# Portable timing function - returns decimal seconds
# Works on both Linux and macOS
now_seconds() {
	local time_str
	time_str=$(date +%s.%N 2>/dev/null || true)
	# If %N is not supported (macOS), it appears literally in output
	if [[ "$time_str" == *"%N" ]]; then
		echo "$(date +%s).000000000"
	else
		echo "$time_str"
	fi
}

# Extract backend prefix from spec (format: backend:rest)
extract_backend_prefix() {
	local spec="$1"
	echo "${spec%%:*}"
}

# Warn if --backend is explicitly overriding a mismatched MNTO_MODEL value
_warn_on_backend_override() {
	local expected_backend="$1"
	if [[ "$BACKEND_EXPLICIT" == true ]] && [[ -n "${MNTO_MODEL:-}" ]]; then
		local old_model="${MNTO_MODEL}"
		local old_backend
		old_backend=$(extract_backend_prefix "$old_model")
		if [[ "$old_backend" != "$expected_backend" ]]; then
			log "WARNING: --backend ${expected_backend} overriding existing MNTO_MODEL=$old_model"
		fi
	fi
}

detect_backend() {
	# If backend explicitly set, use it
	if [[ -n "$BACKEND" ]]; then
		return 0
	fi

	# Detect from MNTO_VERIFIER using prefix semantics
	local verifier
	verifier="${MNTO_VERIFIER:-}"
	if [[ -n "$verifier" ]]; then
		local detected_backend
		detected_backend=$(extract_backend_prefix "$verifier")
		case "$detected_backend" in
			apfel|openai)
				BACKEND="$detected_backend"
				;;
			*)
				echo "ERROR: Unsupported backend in MNTO_VERIFIER: $detected_backend (supported: apfel, openai)" >&2
				exit 1
				;;
		esac
		return 0
	fi

	# Detect from MNTO_MODEL using prefix semantics
	local model
	model="${MNTO_MODEL:-}"
	if [[ -n "$model" ]]; then
		local detected_backend
		detected_backend=$(extract_backend_prefix "$model")
		case "$detected_backend" in
			apfel|openai)
				BACKEND="$detected_backend"
				;;
			*)
				echo "ERROR: Unsupported backend in MNTO_MODEL: $detected_backend (supported: apfel, openai)" >&2
				exit 1
				;;
		esac
		return 0
	fi

	# Default to apfel
	BACKEND="$DEFAULT_BACKEND"
	return 0
}

check_backend_dependencies() {
	case "$BACKEND" in
	apfel)
		if ! command -v apfel &>/dev/null; then
			echo "ERROR: apfel not found in PATH (required for apfel backend)"
			exit 1
		fi
		;;
	openai)
		if ! command -v curl &>/dev/null; then
			echo "ERROR: curl not found in PATH (required for openai backend)"
			exit 1
		fi
		if ! command -v jq &>/dev/null; then
			echo "ERROR: jq not found in PATH (required for openai backend)"
			exit 1
		fi
		if [[ -z "${OPENAI_API_KEY:-}" ]] && [[ -z "${MNTO_API_KEY:-}" ]]; then
			echo "ERROR: Neither OPENAI_API_KEY nor MNTO_API_KEY is set (required for openai backend)"
			exit 1
		fi
		;;
	*)
		echo "ERROR: Unknown backend: $BACKEND (supported: apfel, openai)"
		exit 1
		;;
	esac
}

init_results_dir() {
	local timestamp
	timestamp="$(date +%Y%m%d_%H%M%S)"
	RUN_DIR="${RESULTS_DIR}/${timestamp}"
	METRICS_FILE="${RUN_DIR}/metrics.jsonl"
	SUMMARY_FILE="${RUN_DIR}/summary.txt"

	mkdir -p "${RUN_DIR}"
	echo "Run started at $(date)" >"${SUMMARY_FILE}"
	echo "Results directory: ${RUN_DIR}" | tee -a "${SUMMARY_FILE}"
}

collect_scenario_metrics() {
	local scenario_path="$1"
	local scenario_name
	scenario_name=$(basename "${scenario_path}" .txt)
	local scenario_dir="${RUN_DIR}/${scenario_name}"
	mkdir -p "${scenario_dir}"

	local start_time end_time duration
	start_time=$(now_seconds)

	# Count inference calls and retries from blackboard state
	local inference_calls=0
	local retry_count=0

	log_section "Running scenario: ${scenario_name}"
	log "Goal: $(head -1 "${scenario_path}")"

	# Set environment based on backend
	# Only override MNTO_MODEL when --backend is explicit or MNTO_MODEL is empty
	if [[ "$BACKEND" == "openai" ]]; then
		if [[ "$BACKEND_EXPLICIT" == true ]] || [[ -z "${MNTO_MODEL:-}" ]]; then
			_warn_on_backend_override "openai"
			export MNTO_MODEL="${E2E_OPENAI_MODEL:-openai:http://localhost:11434/v1:llama3.2}"
		fi
	elif [[ "$BACKEND" == "apfel" ]]; then
		if [[ "$BACKEND_EXPLICIT" == true ]] || [[ -z "${MNTO_MODEL:-}" ]]; then
			_warn_on_backend_override "apfel"
			export MNTO_MODEL="apfel"
		fi
	fi

	# Run mnto with the scenario goal
	# Capture the task ID for metrics collection
	local task_id
	local mnto_output

	mnto_output=$("$PROJECT_ROOT/mnto" "$(cat "${scenario_path}")" 2>&1) || {
		log "ERROR: mnto failed with exit code $?"
		return 1
	}

	# Extract task ID using BASH_REMATCH to avoid matching unrelated 3-char strings
	if [[ "${mnto_output}" =~ Created\ task:\ ([a-z]{3}) ]]; then
		task_id="${BASH_REMATCH[1]}"
	else
		task_id=""
	fi

	# Validate task ID format before filesystem use (must match validate_id() format)
	if [[ ! "$task_id" =~ ^[a-z]{3}$ ]]; then
		log "ERROR: Invalid task ID format: $task_id"
		return 1
	fi

	# Validate task ID before using it
	if [[ -z "$task_id" ]]; then
		log "ERROR: Could not extract task ID from mnto output"
		return 1
	fi

	# Write output on success path
	echo "${mnto_output}" >"${scenario_dir}/output.txt"

	# Collect metrics from blackboard if available
	local bb_dir="${BB_DIR:-$PROJECT_ROOT/.mnto/bb}"
	if [[ -d "$bb_dir/${task_id}" ]]; then
		# Count inference calls by counting lines in status file
		if [[ -f "$bb_dir/${task_id}/s" ]]; then
			local wc_output
			wc_output=$(wc -l <"$bb_dir/${task_id}/s")
			# Normalize: strip whitespace (macOS wc may have leading spaces)
			inference_calls=$(echo "$wc_output" | tr -d ' ')
		else
			inference_calls=0
		fi

# Count retry occurrences, with error handling for unreadable directories
		if [[ -r "$bb_dir/${task_id}" ]]; then
			retry_count=$(grep -r "retry" "$bb_dir/${task_id}" 2>/dev/null | wc -l || echo 0)
			# Normalize: strip whitespace
			retry_count=$(echo "$retry_count" | tr -d ' ')
		else
			log "WARNING: Blackboard directory not readable: $bb_dir/${task_id}"
			retry_count=0
		fi
	fi

	end_time=$(now_seconds)
	duration=$(echo "${end_time} - ${start_time}" | bc || echo "0")

	# Get output size
	local output_size
	output_size=$(wc -c <"${scenario_dir}/output.txt" 2>/dev/null || echo 0)

	# Write metrics to JSONL
	cat >>"${METRICS_FILE}" <<EOF
{"scenario":"${scenario_name}","task_id":"${task_id}","duration":${duration},"backend":"${BACKEND}","inference_calls":${inference_calls},"retries":${retry_count},"output_size":${output_size},"status":"success"}
EOF

	# Update totals
	total_duration=$(echo "${total_duration} + ${duration}" | bc)
	total_inference_calls=$((total_inference_calls + inference_calls))
	total_retries=$((total_retries + retry_count))
	scenarios_run=$((scenarios_run + 1))
	scenarios_passed=$((scenarios_passed + 1))

	log "Completed in ${duration}s | inference calls: ${inference_calls} | retries: ${retry_count}"

	return 0
}

run_scenario_list() {
	local scenario_filter="${1:-}"

	for scenario_path in "${SCENARIOS_DIR}"/*.txt; do
		[[ -e "${scenario_path}" ]] || continue

		# Skip empty scenario files
		if [[ ! -s "${scenario_path}" ]]; then
			echo "WARNING: Skipping empty scenario: ${scenario_path}"
			continue
		fi

		local scenario_name
		scenario_name=$(basename "${scenario_path}" .txt)

		# Apply filter if specified
		if [[ -n "${scenario_filter}" && "${scenario_name}" != "${scenario_filter}"* ]]; then
			continue
		fi

		collect_scenario_metrics "${scenario_path}" || true
	done
}

print_summary() {
	log_section "SUMMARY"

	if [[ ${scenarios_run} -eq 0 ]]; then
		log "No scenarios run."
		return
	fi

	log "Backend: ${BACKEND}"
	log "Scenarios run: ${scenarios_run}"
	log "Scenarios passed: ${scenarios_passed}"
	log "Total duration: ${total_duration}s"
	log "Total inference calls: ${total_inference_calls}"
	log "Total retries: ${total_retries}"

	if [[ ${scenarios_run} -gt 0 ]]; then
		local avg_duration
		avg_duration=$(echo "scale=2; ${total_duration} / ${scenarios_run}" | bc)
		log "Average duration: ${avg_duration}s"
	fi

	log ""
	log "Results saved to: ${RUN_DIR}"
	log "Metrics: ${METRICS_FILE}"

	# Calculate pass rate
	local pass_rate
	pass_rate=$(echo "scale=1; (${scenarios_passed} * 100) / ${scenarios_run}" | bc)
	log "Pass rate: ${pass_rate}%"

	echo ""
	echo "========================================"
	echo "E2E VALIDATION ${pass_rate}% PASSED"
	echo "========================================"
}

dry_run() {
	log "DRY RUN - Scenarios that would be executed:"
	for scenario_path in "${SCENARIOS_DIR}"/*.txt; do
		[[ -e "${scenario_path}" ]] || continue
		local scenario_name
		scenario_name=$(basename "${scenario_path}" .txt)
		echo "  - ${scenario_name}: $(head -1 "${scenario_path}")"
	done
}

main() {
	local scenario_filter=""
	local is_dry_run=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--scenario)
			scenario_filter="$2"
			shift 2
			;;
		--backend)
			BACKEND="$2"
			BACKEND_EXPLICIT=true
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
			echo "Unknown option: $1"
			usage
			exit 1
			;;
		esac
	done

	# Detect backend if not explicitly set
	detect_backend

	# Check dependencies
	if [[ ! -x "$PROJECT_ROOT/mnto" ]]; then
		echo "ERROR: mnto not found at $PROJECT_ROOT/mnto"
		exit 1
	fi

	# Check backend-specific dependencies
	check_backend_dependencies

	if ! command -v bc &>/dev/null; then
		echo "ERROR: bc not found in PATH (required for metrics)"
		exit 1
	fi

	# Log detected backend and source
	if [[ "$BACKEND_EXPLICIT" == true ]]; then
		echo "Backend: ${BACKEND} (explicit --backend override, MNTO_MODEL will be set for this run)"
	elif [[ -n "${MNTO_VERIFIER:-}" ]]; then
		echo "Backend: ${BACKEND} (auto-detected from MNTO_VERIFIER)"
	elif [[ -n "${MNTO_MODEL:-}" ]]; then
		echo "Backend: ${BACKEND} (auto-detected from MNTO_MODEL)"
	else
		echo "Backend: ${BACKEND} (default)"
	fi

	# Initialize
	init_results_dir

	if [[ "${is_dry_run}" == true ]]; then
		dry_run
		exit 0
	fi

	log_section "E2E VALIDATION SUITE"
	log "Starting validation run..."

	# Run scenarios
	run_scenario_list "${scenario_filter}"

	# Print summary
	print_summary

	# Exit with appropriate code
	if [[ ${scenarios_passed} -eq ${scenarios_run} && ${scenarios_run} -gt 0 ]]; then
		exit 0
	else
		exit 1
	fi
}

main "$@"
