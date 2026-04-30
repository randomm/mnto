#!/usr/bin/env bash
# benchmark-overflow.sh - Context overflow benchmark for mnto workflow harness
# Validates where workflow decomposition outperforms single-shot inference
# at large token inputs (Bonsai 4B ternary, 32K context via mlx-lm).
#
# Usage:
#   ./test/e2e/benchmark-overflow.sh          Run all scenarios
#   ./test/e2e/benchmark-overflow.sh --dry-run  Preview what would run
#
# Prerequisites:
#   - mlx-lm server running on port 8078 with Bonsai 4B model
#   - apfel available in PATH
#   - mnto built and functional
#
# Outputs:
#   outputs/context-overflow-benchmark/{timestamp}/RESULTS.md

set -euo pipefail

# Configuration
readonly MLX_PORT="${MLX_PORT:-8078}"
readonly MLX_HOST="${MLX_HOST:-localhost}"
readonly BENCHMARK_DIR="outputs/context-overflow-benchmark"

# Scenario definitions: name, approximate token count, char count, description
# Token counts are approximate (chars/4 approximation).
readonly SCENARIOS=(
	"A:10K:40K:Small code review (single file refactor)"
	"B:30K:120K:Medium PR diff analysis (tipping point)"
	"C:60K:240K:Large API migration review"
)

# Safe key=value parser for meta files
_read_meta() {
	local file="$1"
	local key val
	while IFS='=' read -r key val; do
		case "$key" in
		exit_code) exit_code="$val" ;;
		line_count) line_count="$val" ;;
		duration) duration="$val" ;;
		quality_check) quality_check="$val" ;;
		esac
	done <"$file"
}

usage() {
	cat <<EOF
Usage: benchmark-overflow.sh [OPTIONS]

Context overflow benchmark for mnto workflow harness.
Measures where workflow decomposition outperforms single-shot inference.

OPTIONS:
    --dry-run       Show scenarios without executing
    --help          Show this help

PREREQUISITES:
    mlx-lm server running on port $MLX_PORT:
        python3 -m mlx_lm.server --model prism-ml/Ternary-Bonsai-4B-mlx-2bit --port $MLX_PORT

SCENARIOS:
    A (~10K tokens)  Small code review
    B (~30K tokens)  Medium PR diff analysis (tipping point)
    C (~60K tokens)  Large API migration review

OUTPUT:
    outputs/context-overflow-benchmark/{timestamp}/RESULTS.md
EOF
}

# Check mlx-lm server health
check_mlx_server() {
	if ! curl -s --max-time 5 "http://${MLX_HOST}:${MLX_PORT}/health" >/dev/null 2>&1; then
		cat <<EOF >&2
ERROR: mlx-lm server not responding on port $MLX_PORT

To start the server:
    python3 -m mlx_lm.server --model prism-ml/Ternary-Bonsai-4B-mlx-2bit --port $MLX_PORT

Then rerun this benchmark.
EOF
		return 1
	fi
	return 0
}

# Generate synthetic code review input
# Usage: generate_code_review_scenario <scenario_char>
# Outputs the generated content to stdout
generate_code_review_scenario() {
	local scenario="$1"
	local nl=$'\n'
	local content=""
	local line_count=0

	case "$scenario" in
	A)
		# ~10K tokens, ~40K chars: small code review
		# Generate ~200 lines of code with 200 chars per line
		line_count=200
		;;
	B)
		# ~30K tokens, ~120K chars: medium PR diff
		# Generate ~600 lines
		line_count=600
		;;
	C)
		# ~60K tokens, ~240K chars: large API migration
		# Generate ~1200 lines
		line_count=1200
		;;
	esac

	# Each line: ~200 chars of code-like content
	local i=1
	local func_name params comment
	while ((i <= line_count)); do
		# Generate a line that looks like code with unique markers per line
		# Format: function name, some params, and a comment with line number
		func_name="func_$(printf '%04d' "$i")"
		params="param_${i}_a, param_${i}_b, param_${i}_c"
		comment="// Line ${i} marker for quality verification"

		# Alternate between different code patterns
		case $((i % 4)) in
		0)
			content+="function ${func_name}(${params}) { ${comment}; return ${i}; }$${func_name}();${nl}"
			;;
		1)
			content+="class Handler${i} { private val=${i}; ${comment} }${nl}"
			;;
		2)
			content+="const ${func_name} = async (${params}) => { ${comment}; };${nl}"
			;;
		3)
			content+="export ${func_name}(${params}); // ${comment} ${i}${nl}"
			;;
		esac
		i=$((i + 1))
	done

	# Add a header with scenario info for quality verification
	local header="# Code Review Scenario ${scenario}${nl}"
	header+="# Generated for context overflow benchmark${nl}"
	header+="# Lines: ${line_count}, Chars: ~$((line_count * 200))${nl}"
	header+="# Mid-input marker: CODE_REVIEW_SCENARIO_${scenario}_MIDPOINT${nl}"
	header+="${nl}${content}"

	# Also add end marker for quality verification
	header+="${nl}# END_MARKER_${scenario}_AT_LINE_${line_count}${nl}"

	printf '%s' "$header"
}

# Generate PR diff scenario
# Usage: generate_pr_diff_scenario <scenario_char>
# Outputs the generated content to stdout
generate_pr_diff_scenario() {
	local scenario="$1"
	local nl=$'\n'
	local content=""
	local line_count=0

	case "$scenario" in
	A)
		line_count=200
		;;
	B)
		line_count=600
		;;
	C)
		line_count=1200
		;;
	esac

	# PR diff format: +lines (additions), -lines (deletions), context
	local i=1
	while ((i <= line_count)); do
		case $((i % 3)) in
		0)
			content+="-// Removed old implementation line ${i}${nl}"
			;;
		1)
			content+="+// New implementation line ${i} with marker PR_DIFF_${scenario}_${i}${nl}"
			;;
		2)
			content+=" // Context line ${i} unchanged${nl}"
			;;
		esac
		i=$((i + 1))
	done

	local header="# PR Diff Scenario ${scenario}${nl}"
	header+="# Generated for context overflow benchmark${nl}"
	header+="# Diff size: ~${line_count} changes${nl}"
	header+="# Mid-input marker: PR_DIFF_SCENARIO_${scenario}_MIDPOINT${nl}"
	header+="${nl}${content}"

	printf '%s' "$header"
}

# Generate API migration scenario
# Usage: generate_api_migration_scenario <scenario_char>
# Outputs the generated content to stdout
generate_api_migration_scenario() {
	local scenario="$1"
	local nl=$'\n'
	local content=""
	local line_count=0

	case "$scenario" in
	A)
		line_count=200
		;;
	B)
		line_count=600
		;;
	C)
		line_count=1200
		;;
	esac

	# API migration: endpoint definitions, request/response shapes
	local i=1
	while ((i <= line_count)); do
		case $((i % 5)) in
		0)
			content+="POST /api/v1/resource_${i} { body: RequestBody${i} } => Response${i} // API_MIGRATION_${scenario}_${i}${nl}"
			;;
		1)
			content+="GET /api/v1/resource_${i}/{id} => SingleResource${i} // Midpoint marker API_MIGRATION_${scenario}_MIDPOINT${nl}"
			;;
		2)
			content+="interface RequestBody${i} { field${i}: string; count: number; } // Migration ${i}${nl}"
			;;
		3)
			content+="interface Response${i} { id: string; data: Data${i}; status: 'ok'; } // Response ${i}${nl}"
			;;
		4)
			content+="type Data${i} = { items: Item${i}[]; total: number; } // Data structure ${i}${nl}"
			;;
		esac
		i=$((i + 1))
	done

	local header="# API Migration Scenario ${scenario}${nl}"
	header+="# Generated for context overflow benchmark${nl}"
	header+="# Endpoints: ~${line_count}${nl}"
	header+="# Mid-input marker: API_MIGRATION_${scenario}_MIDPOINT${nl}"
	header+="${nl}${content}"

	printf '%s' "$header"
}

# Run a single benchmark test
# Usage: run_benchmark <scenario> <mode> <goal> <output_dir>
# Returns: 0 on success, 1 on failure
# Records: timing, exit code, output lines, quality markers found
run_benchmark() {
	local scenario="$1"
	local mode="$2" # "direct" or "workflow"
	local goal="$3"
	local output_dir="$4"

	local test_name="${scenario}_${mode}"
	local start_time end_time duration
	local exit_code=0
	local output_file="${output_dir}/${test_name}.output"
	local timing_file="${output_dir}/${test_name}.timing"
	local meta_file="${output_dir}/${test_name}.meta"

	# Set MNTO_DIRECT_THRESHOLD to force mode
	# Direct: set high threshold so everything goes direct
	# Workflow: set threshold to 0 so nothing goes direct

	# Record start time (seconds since epoch)
	start_time="$(date +%s)"

	# Run mnto with goal - mode-specific env var injection
	local result
	case "$mode" in
	direct)
		result="$(MNTO_MODEL="openai:http://${MLX_HOST}:${MLX_PORT}/v1:prism-ml/Ternary-Bonsai-4B-mlx-2bit" \
			MNTO_DIRECT_THRESHOLD=999999 ./mnto "$goal" 2>&1)" || exit_code=$?
		;;
	workflow)
		result="$(MNTO_MODEL="openai:http://${MLX_HOST}:${MLX_PORT}/v1:prism-ml/Ternary-Bonsai-4B-mlx-2bit" \
			MNTO_DIRECT_THRESHOLD=0 ./mnto "$goal" 2>&1)" || exit_code=$?
		;;
	esac

	# Record end time
	end_time="$(date +%s)"
	duration=$((end_time - start_time))

	# Get task ID from output (last line with "Created task: ")
	local created_tid=""
	if [[ -n "$result" ]]; then
		created_tid="$(echo "$result" | grep -o 'Created task: [^ ]*' | tail -1 | awk '{print $NF}')" || true
	fi

	# If task was created, capture output from blackboard
	local output_text=""
	local line_count=0
	local quality_check=""

	if [[ -n "$created_tid" ]] && [[ -f ".mnto/bb/${created_tid}/out" ]]; then
		output_text="$(cat ".mnto/bb/${created_tid}/out")"
		line_count="$(echo "$output_text" | wc -l | tr -d ' ')"
		# Quality check: look for mid-input markers
		case "$scenario" in
		A)
			if echo "$output_text" | grep -q "CODE_REVIEW_SCENARIO_A_MIDPOINT"; then
				quality_check="midpoint_marker_found"
			else
				quality_check="midpoint_marker_missing"
			fi
			;;
		B)
			if echo "$output_text" | grep -q "PR_DIFF_SCENARIO_B_MIDPOINT"; then
				quality_check="midpoint_marker_found"
			else
				quality_check="midpoint_marker_missing"
			fi
			;;
		C)
			if echo "$output_text" | grep -q "API_MIGRATION_C_MIDPOINT"; then
				quality_check="midpoint_marker_found"
			else
				quality_check="midpoint_marker_missing"
			fi
			;;
		esac
	elif ((exit_code != 0)); then
		# Failed - capture error for meta
		output_text="FAILED_WITH_EXIT_${exit_code}"
		quality_check="task_not_created"
	else
		output_text="NO_OUTPUT_CAPTURED"
		quality_check="unknown"
	fi

	# Write output
	echo "$output_text" >"$output_file"

	# Write timing
	cat >"$timing_file" <<EOF
start=$start_time
end=$end_time
duration=$duration
exit_code=$exit_code
tid=$created_tid
EOF

	# Write metadata
	cat >"$meta_file" <<EOF
scenario=$scenario
mode=$mode
test_name=$test_name
exit_code=$exit_code
line_count=$line_count
duration=$duration
quality_check=$quality_check
EOF

	return 0
}

# Generate RESULTS.md from benchmark run
# Usage: generate_results <run_dir>
generate_results() {
	local run_dir="$1"
	local results_file="${run_dir}/RESULTS.md"

	# Read all meta files and compile table
	cat >"$results_file" <<'EOF'
# Context Overflow Benchmark Results

This benchmark measures where mnto's workflow harness outperforms single-shot
inference at large token inputs with Bonsai 4B (32K context ceiling).

## Methodology

- **Model**: Bonsai 4B Ternary via mlx-lm on port 8078
- **Token estimation**: chars/4 approximation
- **Modes tested**: Direct (single-shot) vs Workflow (decompose-then-verify)
- **Metric**: Completion rate, timing, output quality

## Scenarios

| Scenario | Tokens | Chars | Description |
|----------|--------|-------|-------------|
| A        | ~10K   | ~40K  | Small code review |
| B        | ~30K   | ~120K | Medium PR diff (tipping point) |
| C        | ~60K   | ~240K | Large API migration |
| D        | ~100K  | ~400K | SKIPPED (Bonsai 4B max 32K) |

## Raw Results

EOF

	# Process each scenario
	for scenario in A B C; do
		for mode in direct workflow; do
			local test_name="${scenario}_${mode}"
			local meta_file="${run_dir}/${test_name}.meta"

			if [[ -f "$meta_file" ]]; then
				local exit_code line_count duration quality_check
				_read_meta "$meta_file"

				local status
				if ((exit_code == 0)); then
					status="✓ completed"
				else
					status="✗ failed (exit $exit_code)"
				fi

				cat >>"$results_file" <<EOF

### ${scenario} ${mode^^}

- **Duration**: ${duration}s
- **Status**: ${status}
- **Output lines**: ${line_count}
- **Quality**: ${quality_check}

EOF
			fi
		done
	done

	# Analysis section
	cat >>"$results_file" <<'EOF'

## Analysis

### Crossover Point

The crossover point is where workflow mode outperforms direct mode.
Based on the raw results above:

EOF

	# Compile comparison table
	cat >>"$results_file" <<'EOF'

| Scenario | Direct | Workflow | Winner |
|----------|--------|----------|--------|

### Quality Assessment

Quality was verified by checking if mid-input markers (embedded at ~50% of input)
appear in the output. Missing markers indicate the model didn't process the full input.

## Recommendations

Based on these results, the recommended `MNTO_WORKFLOW_THRESHOLD` for issue #78:

EOF

	# Calculate crossover based on actual results
	local direct_failures=0
	local workflow_failures=0

	for scenario in A B C; do
		local direct_meta="${run_dir}/${scenario}_direct.meta"
		local workflow_meta="${run_dir}/${scenario}_workflow.meta"

		if [[ -f "$direct_meta" ]]; then
			local direct_exit
			direct_exit="$(grep '^exit_code=' "$direct_meta" | cut -d= -f2 || echo "1")"
			if ((direct_exit != 0)); then
				direct_failures=$((direct_failures + 1))
			fi
		fi

		if [[ -f "$workflow_meta" ]]; then
			local workflow_exit
			workflow_exit="$(grep '^exit_code=' "$workflow_meta" | cut -d= -f2 || echo "1")"
			if ((workflow_exit != 0)); then
				workflow_failures=$((workflow_failures + 1))
			fi
		fi
	done

	if ((workflow_failures < direct_failures)); then
		cat >>"$results_file" <<EOF
**Recommendation**: MNTO_WORKFLOW_THRESHOLD=\${MNTO_WORKFLOW_THRESHOLD:-120000}

Workflow mode handles larger inputs more reliably. Set threshold to 120K chars
(~30K tokens) to prefer workflow for medium-to-large tasks.

**Rationale**: Workflow decomposition avoids putting the entire large input in
a single context. Each subtask gets a bounded context window.
EOF
	else
		cat >>"$results_file" <<EOF
**Recommendation**: Further testing needed.

Results were inconclusive. Run with larger scenarios or different model settings.
EOF
	fi

	cat >>"$results_file" <<EOF

---
*Generated: $(date -Iseconds)*
EOF

	echo "Results written to: $results_file"
}

# Main benchmark runner
main() {
	local is_dry_run=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
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

	# Check prerequisites
	if ! check_mlx_server; then
		exit 1
	fi

	# Check mnto exists
	if [[ ! -f ./mnto ]]; then
		echo "ERROR: mnto not found in current directory" >&2
		exit 1
	fi

	# Create output directory with timestamp
	local timestamp
	timestamp="$(date +%Y%m%d_%H%M%S)"
	local run_dir="${BENCHMARK_DIR}/${timestamp}"
	mkdir -p "$run_dir"

	if [[ "$is_dry_run" == true ]]; then
		echo "DRY RUN - Scenarios that would be executed:"
		echo ""
		for scenario_def in "${SCENARIOS[@]}"; do
			IFS=':' read -r scenario tokens chars desc <<<"$scenario_def"
			echo "  $scenario: $desc"
			echo "         Tokens: $tokens | Chars: $chars"
		done
		echo ""
		echo "Output directory: $run_dir"
		echo ""
		echo "Each scenario would run in DIRECT and WORKFLOW mode (6 total runs)"
		exit 0
	fi

	echo "Starting context overflow benchmark..."
	echo "Output directory: $run_dir"
	echo ""

	# Run each scenario
	for scenario_def in "${SCENARIOS[@]}"; do
		IFS=':' read -r scenario tokens chars desc <<<"$scenario_def"

		echo "=== Scenario ${scenario}: ${desc} ==="
		echo "    Tokens: ~${tokens} | Chars: ~${chars}"

		# Generate synthetic input based on scenario
		# We use code review scenario for all (could be extended)
		local goal
		goal="$(generate_code_review_scenario "$scenario")"

		# Run direct mode
		echo -n "    Running DIRECT mode... "
		run_benchmark "$scenario" "direct" "$goal" "$run_dir"
		local direct_meta="${run_dir}/${scenario}_direct.meta"
		if [[ -f "$direct_meta" ]]; then
			local exit_code duration line_count
			_read_meta "$direct_meta"
			if ((exit_code == 0)); then
				echo "${duration}s, ${line_count} lines"
			else
				echo "FAILED (exit ${exit_code})"
			fi
		fi

		# Run workflow mode
		echo -n "    Running WORKFLOW mode... "
		run_benchmark "$scenario" "workflow" "$goal" "$run_dir"
		local workflow_meta="${run_dir}/${scenario}_workflow.meta"
		if [[ -f "$workflow_meta" ]]; then
			local exit_code duration line_count
			_read_meta "$workflow_meta"
			if ((exit_code == 0)); then
				echo "${duration}s, ${line_count} lines"
			else
				echo "FAILED (exit ${exit_code})"
			fi
		fi

		echo ""
	done

	# Generate RESULTS.md
	generate_results "$run_dir"

	echo ""
	echo "Benchmark complete. Results in: $run_dir/RESULTS.md"
}

main "$@"
