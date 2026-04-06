# mnto — Blackboard Swarm for Small-Context LLMs

mnto (from memento) coordinates multiple stateless 3B-LLM agents through a filesystem blackboard. It uses on-device inference via apfel (zero cost, no API keys) and is implemented in pure bash.

## Requirements

### Required
- `bash` ≥ 4.0 (for associative arrays)
- `apfel` — on-device LLM inference CLI ([Arthur-Ficial/apfel](https://github.com/Arthur-Ficial/apfel))
- `bats` — bash automated testing system

### Optional
- `vipune` — semantic cross-reference
- `shellcheck` — static analysis (dev only)
- `shfmt` — shell formatter (dev only)

## Installation

Install missing dependencies via Homebrew:

```bash
brew install bats-core
brew install shellcheck
brew install shfmt
```

Note: `apfel` must be installed separately. See [Arthur-Ficial/apfel](https://github.com/Arthur-Ficial/apfel) for installation instructions.

## Quick Start

```bash
# Run a task
./mnto "write a README for project X"

# List all tasks
./mnto --list

# Resume a task by ID
./mnto --resume {tid}
```

## Development

Before pushing, all quality gates must pass locally:

```bash
# Syntax check
bash -n mnto

# Static analysis
shellcheck mnto lib/*.bash

# Format scripts
shfmt -w mnto lib/*.bash

# Run tests
bats test/
```

## Project Structure

```
mnto/
├── mnto                  # Main executable (bash script)
├── lib/                  # Shared library functions
│   ├── blackboard.bash   # Blackboard operations
│   ├── harness.bash      # Draft-verify loop
│   └── planner.bash      # Task decomposition
├── test/                 # Bats integration tests
│   ├── setup.bats        # Shared fixtures
│   ├── integration.bats  # End-to-end tests
│   └── harness.bats      # Loop logic tests
├── .bb/                  # Runtime state (blackboard, gitignored)
├── README.md             # This file
└── AGENTS.md             # Agent guidelines and conventions
```

## License

MIT

## Credits

- **apfel** by Arthur-Ficial
- **omppu** by Janni Turunen
- **vipune** by Janni Turunen
- Blackboard architecture — Erman et al. 1980 (Hearsay-II)