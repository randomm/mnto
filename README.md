# mnto — Blackboard Swarm for Small-Context LLMs

mnto (from memento) coordinates multiple stateless 3B-LLM agents through a filesystem blackboard. It uses on-device inference via apfel (zero cost, no API keys) and is implemented in pure bash.

## Requirements

### Required
- macOS arm64 (Apple Silicon)
- `bash` ≥ 4.0 (for associative arrays)
- `apfel` — on-device LLM inference CLI ([Arthur-Ficial/apfel](https://github.com/Arthur-Ficial/apfel))
- `bats` — bash automated testing system

### Optional
- `vipune` — semantic cross-reference
- `shellcheck` — static analysis (dev only)
- `shfmt` — shell formatter (dev only)

## Quick Start

```bash
# Run a task
./mnto "write a README for project X"

# List all tasks
./mnto --list

# Resume a task by ID
./mnto --resume {tid}
```

## Installation

### Manual Installation

```bash
git clone https://github.com/randomm/mnto.git
cd mnto
ln -s $(pwd)/mnto ~/.local/bin/mnto
```

## Workspace

mnto creates a `.mnto/` directory in your project root to store task state:

```
.mnto/
└── bb/              # Task state (blackboard)
```

This directory is gitignored by default.

## Cleanup

Remove old tasks to free up space:

```bash
mnto --clean              # Remove tasks older than 30 days
mnto --clean --days 7     # Remove tasks older than 7 days
mnto --clean --dry-run    # Show what would be deleted (safe preview)

mnto --prune              # Remove completed tasks only
mnto --prune --dry-run    # Show what would be pruned
```

The `--dry-run` flag is recommended for your first cleanup to verify what will be removed.

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
│   └── *.bats            # Additional test files
├── .mnto/bb/             # Runtime state (blackboard, gitignored)
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