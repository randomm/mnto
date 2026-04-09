# Test setup helpers for mnto integration tests

export MNTO="${BATS_TEST_DIRNAME}/.."

# Mock apfel command (for backend tests only)
mock_apfel() {
	case "$1" in
	-p)
		echo "abc Introduction: An overview of the project, 100 words"
		echo "def Conclusion: Summary and next steps, 50 words"
		;;
	*)
		echo "mock response"
		;;
	esac
}
export -f mock_apfel

# Mock infer command (for integration tests)
mock_infer() {
	case "$1" in
	planner)
		echo "abc Introduction: An overview of the project, 100 words"
		echo "def Conclusion: Summary and next steps, 50 words"
		;;
	*)
		echo "mock response"
		;;
	esac
}
export -f mock_infer
