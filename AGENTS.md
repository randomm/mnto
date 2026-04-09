# mnto — Agent Guidelines

This document defines the engineering standards, workflow, and conventions for the mnto project.

---

## Context7 Protocol

Before writing ANY code, check context7 for current documentation:
- Library APIs and syntax
- Framework patterns and best practices
- Configuration options

Training data may be outdated. Context7 provides authoritative, up-to-date docs.

---

## Minimalist Engineering Philosophy

**Every line of code is a liability.** Before creating anything:

- **LESS IS MORE**: Question necessity before creation
- **Challenge Everything**: Ask "Is this truly needed?" before implementing
- **Minimal Viable Solution**: Build the simplest thing that fully solves the problem
- **No Speculative Features**: Don't build for "future needs" - solve today's problem
- **Prefer Existing**: Reuse existing code/tools before creating new ones
- **One Purpose Per Component**: Each function/module should do one thing well

### Pre-Creation Challenge (MANDATORY)

Before creating ANY code, ask:
1. Is this explicitly required by the GitHub issue?
2. Can existing code/tools solve this instead?
3. What's the SIMPLEST way to meet the requirement?
4. Will removing this break core functionality?
5. Am I building for hypothetical future needs?

**If you cannot justify the necessity, DO NOT CREATE IT.**

---

## Pre-Push Quality Gates

**NOTE: No CI is configured. Local checks are the ONLY verification.**

Before ANY `git push`, all checks must pass locally:

```bash
# 1. Syntax check
bash -n mnto

# 2. ShellCheck
shellcheck mnto lib/*.bash

# 3. Formatting
shfmt -w mnto lib/*.bash test/*.bats

# 4. Tests
bats test/
```

Fix locally before pushing. There is no remote verification pipeline.

---

## Testing Standards

**Framework**: Bats-core (Bash Automated Testing System)

**MVP Phase**:
- Integration tests only
- Unit tests not required yet
- Mock `apfel` CLI in all tests

**Test Structure**:
```
test/
  setup.bats          # Shared fixtures and helpers
  integration.bats    # End-to-end workflow tests
  harness.bats        # Draft-verify loop tests
  planning.bats       # Planner and blackboard tests
```

**Key Testing Guidelines**:
- Mock all external dependencies (`apfel`, `vipune`)
- Test blackboard state transitions directly
- Verify status file updates per state machine
- Test retry logic and failure paths

---

## Code Style & Conventions

**Shebang**: `#!/usr/bin/env bash`

**Strict Mode**: All scripts must use:
```bash
set -euo pipefail
```

**ShellCheck Compliance**: All scripts must pass ShellCheck (SC1000, SC1008 rules)

**Function Naming**:
- `verb_noun` style (e.g., `next_task`, `set_status`, `prev_final`)
- Private internal functions: `_internal_name`
- Export public functions explicitly

**Variable Naming**:
- Lowercase with underscores: `task_id`, `retry_count`
- Constants: `UPPER_CASE`
- Readonly: `declare -r TASK_ID="..."`

**Error Handling**:
- Check exit codes explicitly when needed
- Use `|| die "message"` pattern for critical failures
- Never ignore errors silently

**Comments**:
- Comments explain WHY, not WHAT
- Inline comments for non-obvious logic only
- Function headers: `# Usage: next_task <task_id>`

---

## Git Workflow

**Branch Naming**:
- Features: `feature/{issue-number}-description`
- Fixes: `fix/{issue-number}-bug-description`

**Commit Messages**: Conventional commits
```
feat(#123): implement planner with apfel integration
fix(#456): handle missing apfel binary gracefully
docs: update AGENTS.md with testing standards
```

**PR Workflow**:
- Link PR to issue with `Fixes #123` in body
- Include issue number in commit messages
- All local checks must pass before merge (no CI pipeline exists)
- Adversarial review required for all PRs

**Never**:
- Commit directly to main/master
- Push without issue linkage
- Bypass pre-commit hooks

---

## Documentation Policy

**The 200-PR Test**: Before creating documentation, ask: "Will this be true in 200 PRs?"
- **YES** → Document the principle (WHY)
- **NO** → Skip or use code comments (WHAT/HOW)

**Forbidden Files**:
- `PLAN.md`, `DESIGN.md`, `IMPLEMENTATION.md` — these rot and mislead
- Scratch files in repo root: `*_SUMMARY.md`, `ANALYSIS.md`, `NOTES.md`

**Valid Documentation**:
- `README.md` (repo root) — project overview, quick start
- `AGENTS.md` (repo root) — these guidelines
- `CHANGELOG.md` (repo root) — release notes
- `docs/` directory — long-lived documentation only

**Documentation Location**:
- Code-explaining comments → in the code
- System design → architecture notes in `docs/` or README
- Temporary thoughts → working notes outside repo, then delete

---

## Commands Reference

**Development**:
```bash
bash -n mnto           # Syntax check
./mnto "write a..."   # Run harness
```

**Testing**:
```bash
bats test/                   # Run all tests
bats test/integration.bats   # Run specific test file
bats --filter "planner" test/  # Run tests matching pattern
```

**Linting & Formatting**:
```bash
shellcheck mnto lib/*.bash       # Static analysis
shfmt -w mnto lib/*.bash         # Format scripts
shfmt -d mnto lib/*.bash         # Diff formatting only
```

**Git Operations** (use `oo` prefix):
```bash
oo git status          # Working tree status
oo git branch --show-current  # Current branch
oo git diff                 # Show changes
oo gh issue list            # List GitHub issues
oo gh issue view #123       # View specific issue
```

---

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
├── .mnto/bb/             # Runtime state (blackboard)
│   └── {task-id}/        # Per-task directory (gitignored)
├── README.md             # Project overview
├── AGENTS.md             # This file
└── .gitignore            # Excludes .mnto/bb/, apfel binary
```

**Key Invariants**:
- `.mnto/bb/` is gitignored (runtime state)
- All bash scripts must have `set -euo pipefail`
- `lib/` functions must be sourced in `mnto`
- Tests must mock external dependencies

---

## Quality Standards

**Coverage Thresholds**:
- **Post-MVP**: Minimum 80% coverage (TBD after Phase 4 validation)
- **Current Phase**: Integration tests sufficient

**Boy Scout Rule**: Every PR must not degrade module quality
- ShellCheck errors: stable or improved
- Test coverage: stable or improved
- No new bypasses or workarounds

**Forbidden Bypasses**:
- Never disable ShellCheck errors
- Never exit without `set -euo pipefail` unless justified
- Never swallow errors with `|| true` without comment

---

## Dependencies

**Required**:
- `bash` ≥ 4.0 (for associative arrays)
- `apfel` — on-device LLM inference CLI
- `bats` — bash automated testing system

**Optional**:
- `vipune` — semantic cross-reference
- `coreutils` — GNU utilities for consistency
- `shellcheck` — static analysis (dev only)
- `shfmt` — shell formatter (dev only)

**NOT ALLOWED**:
- Python, Python libraries
- Node.js, npm, Node packages
- Ruby, gems
- Databases (PostgreSQL, SQLite, etc.)
- Any compiled language

---

## MVP Scope Discipline

**IN SCOPE (Phase 1-4)**:
- Sequential draft-verify loop
- Blackboard filesystem state machine
- Basic stitch step
- `apfel` integration for all inference
- Optional `vipune` integration
- Resumable tasks with `--resume {tid}`

**OUT OF SCOPE**:
- Parallel subtask execution
- Streaming or interactive CLI
- External model integration (except planning)
- Web UI or API
- Database storage
- Advanced stitching (pairs, context overflow handling)

**Rationale**: MVP targets proof-of-concept. Quality features come later.

---

## Agent Hierarchy

**Project Manager (@PM)**: Orchestrates only, never executes code
- Reads GitHub issues
- Delegates to specialists
- Coordinates workflow
- Enforces quality gates

**Developer (@developer)**:
- Implements features and fixes bugs
- Writes tests (TDD when applicable)
- Follows project conventions
- Returns when local checks pass

**Operations (@ops)**:
- All git and GitHub operations
- Kamal deployment (if added)
- Infrastructure changes
- Commits and pushes code

**Code Review Specialist (@code-review-specialist)**:
- Reviews all PRs
- Ensures quality standards
- Checks for security issues
- Provides actionable feedback

**Explorer (@explore)**:
- Conducts research tasks
- Investigates alternatives
- Analyzes architecture decisions
- No issue required for research

---

## Issue-Driven Development

**CRITICAL: NO WORK WITHOUT GITHUB ISSUES**

Every development task must:
1. Have a GitHub issue created first
2. Link to issue in branch name: `feature/{number}-description`
3. Reference issue in commits: `feat(#123): description`
4. Include `Fixes #123` in PR body

**Issue Creation Template**:
```markdown
### Task Description
[Brief description of work to be done]

### Quality Gates (Non-Negotiable)
- [ ] Tests written (integration tests for MVP)
- [ ] Linting passes (shellcheck, shfmt)
- [ ] Documentation updated as needed
- [ ] Local verification complete

### Acceptance Criteria
- [ ] Specific requirement 1
- [ ] Specific requirement 2
```

**Use Single Quotes for --body** (safest for multi-line):
```bash
oo gh issue create --title "fix: description" --body '### Task Description
What needs to be done.

### Quality Gates
[ ] Tests written
[ ] Linting passes
'
```

**Research Tasks**: Skip issue creation (no code changes)

---

## Local Quality Gates

Before ANY `git push`:
1. All tests pass (0 failures)
2. Coverage meets threshold (80%+ post-MVP)
3. ShellCheck passes (0 errors)
4. Formatting applied (`shfmt -w`)
5. Syntax validates (`bash -n`)

**Fix locally before pushing.** There is no remote verification pipeline.

---

## Pre-Commit Verification

Before EVERY commit:
- [ ] Syntax check passes: `bash -n mnto`
- [ ] ShellCheck passes: `shellcheck mnto lib/*.bash`
- [ ] Formatting applied: `shfmt -w mnto lib/*.bash`
- [ ] Tests pass: `bats test/`
- [ ] NOT using `|| true` without justification
- [ ] NOT disabling `set -euo pipefail`

**IF ANY CHECK FAILS**: Fix before committing. NEVER bypass.

---

## Module Size Limits

- **Hard limit**: 500 lines per file (exceptions require justification)
- **Ideal target**: 300 lines or fewer
- **Refactor trigger**: File exceeds 500 lines or has 3+ distinct responsibilities

**Example**: `mnto` > 500 lines with planning + harness + stitching logic → split into `lib/planner.bash`, `lib/harness.bash`, `lib/stitcher.bash`

---

## Adversarial Review Gate

**@developer**: Return to PM when local checks pass. Do NOT attempt adversarial review.

**@PM** (after developer returns — mandatory):
1. Obtain diff via `oo git diff HEAD`
2. Dispatch @adversarial-developer with: diff, issue number, changed files list, one-sentence description
3. Wait for **APPROVED** verdict before dispatching @ops
4. If **ISSUES_FOUND** or **CRITICAL_ISSUES_FOUND**: send back to @developer, re-dispatch adversarial after fixes (up to 3 re-dispatches total)
5. @ops does NOT commit or merge until **APPROVED**

**This gate is MANDATORY** — PM enforces it. Developer returning is the trigger, not the executor.

---

## Open Questions & Future Directions

**Post-MVP Decisions**:
1. Coverage threshold (post-Phase 4 validation)
2. Unit test introduction (only if integration tests insufficient)
3. Parallel execution architecture (requires redesign)
4. Streaming mode for interactive use (significant UX shift)

**To Be Documented Later**:
- Performance benchmarks (apfel call timing, total runtime)
- Token budget optimization strategies
- Advanced stitching algorithms for context overflow
- External model integration patterns

---

**Last Updated**: 2026-04-05
**Valid Against**: Draft v1 (pre-implementation)