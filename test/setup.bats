# Test setup helpers for mnto integration tests

export MNTO="${BATS_TEST_DIRNAME}/.."

# Mock apfel command
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
