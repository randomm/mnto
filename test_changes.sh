#!/usr/bin/env bash
set -euo pipefail

cd /Users/janni/git/mnto/.worktrees/pr-53-fixes

echo "Testing _parse_openai_spec return format..."
source lib/openai.bash
result=$(_parse_openai_spec "openai:http://localhost:11434/v1:qwen3")
IFS=$'\t' read -r base_url model <<< "$result"
if [[ "$base_url" == "http://localhost:11434/v1" && "$model" == "qwen3" ]]; then
    echo "✓ _parse_openai_spec returns tab-separated values correctly"
else
    echo "✗ _parse_openai_spec failed"
    exit 1
fi

echo "Testing _resolve_backend with explicit env var..."
source lib/backend.bash
export MNTO_VERIFIER="openai:http://api.example.com/v1:gpt-4"
result=$(_resolve_backend verifier)
if [[ "$result" == "$MNTO_VERIFIER" ]]; then
    echo "✓ _resolve_backend respects ENV vars"
else
    echo "✗ _resolve_backend failed"
    exit 1
fi

echo "Testing _resolve_backend fallback chain..."
unset MNTO_VERIFIER MNTO_PROPOSER
export MNTO_MODEL="openai:http://fallback.com/v1:gpt-3.5"
result=$(_resolve_backend verifier)
if [[ "$result" == "$MNTO_MODEL" ]]; then
    echo "✓ _resolve_backend falls back to MNTO_MODEL"
else
    echo "✗ _resolve_backend fallback failed"
    exit 1
fi

echo "Testing _resolve_backend default to apfel..."
unset MNTO_VERIFIER MNTO_PROPOSER MNTO_MODEL
result=$(_resolve_backend planner)
if [[ "$result" == "apfel" ]]; then
    echo "✓ _resolve_backend defaults to apfel"
else
    echo "✗ _resolve_backend default failed"
    exit 1
fi

echo ""
echo "All basic validation tests passed!"