# Design Workflow Rules

Rules for the design phase of any non-trivial change: turning a source of intent (a GitHub Issue, a GlitchTip issue, a user request) into an approved spec, then a reviewed plan, then implementation.

## Principle

Finding facts is the agent's responsibility. Decisions are the user's responsibility.

## Fact / Decision Separation

**Fact**: anything confirmable from the repository, official documentation, or a command/test/PoC, or already established in an accepted spec. Never ask the user about a Fact — go find it.

**Decision**: product requirements, UX preferences, trade-offs, scope boundaries, and irreversible policy choices. These are the only things `AskUserQuestion` is for.

Before asking the user anything, classify it. If it is a Fact, go verify it yourself instead of asking.

## Clarifying Questions

A clarifying question directed at the user must go through `AskUserQuestion`, never as plain prose — and only the main agent can call it. A sub-agent cannot call `AskUserQuestion` itself: if it hits a real Decision it cannot resolve alone, it reports the question (with options where applicable) back to the main agent in its output, and the main agent relays it to the user via `AskUserQuestion`.

## Intent Contract

Before writing a spec, establish: Outcome, Success criteria, Scope, Non-goals, Constraints, Accepted facts, Assumptions, and Remaining unknowns. Do not re-ask the user something the source Issue (or ticket) already states clearly — read it first.

## Decision Dependency / Frontier

Batch every independent Decision into a single `AskUserQuestion` round instead of asking one at a time. Do not ask a dependent Decision before its prerequisite Decision is resolved — resolve the frontier in dependency order. Avoid recommendation-driven anchoring: when a Decision is a purely subjective preference, present the options neutrally rather than steering the user toward one.

## Alternative Exploration

Do not manufacture two or three options as a formality on every Decision. Compare multiple approaches only when materially different designs actually exist, evaluated on axes such as correctness, operational risk, migration complexity, maintainability, performance, compatibility, implementation size, and rollbackability. Always evaluate YAGNI — the simplest approach that satisfies the Intent Contract wins by default.

## Spec Synthesis

An empty Decision frontier does not by itself mean the spec is done. Synthesize the individual answers into one coherent design, covering (where applicable): Outcome, Success Criteria, Scope, Non-goals, Constraints & Established Facts, Assumptions & Unknowns, Components/Data Flow/Interfaces, Invariants, Failure/Retry/Recovery, Persistence & Migration, Security & Trust Boundaries, Performance & Production Scale, External & Cross-repository Contracts, Rollout & Rollback, Observability, Acceptance Criteria, and a Decision Log. Acceptance Criteria must be observable or testable — not aspirational prose.

## Spec Review Contract

Dispatch the existing `spec-reviewer` sub-agent (`Agent` tool, `subagent_type: spec-reviewer`) against the spec file before asking the user to approve it. This rule owns who calls the reviewer and when; the agent's own checklist owns what it checks.

Review dimensions: requirement coverage, internal consistency, architecture/contract consistency, invariants, concurrency/ordering/idempotency, persistence/migration/data-loss risk, failure/retry/recovery, security/trust boundaries, performance/production scale, external API/cross-repository contracts, rollout/rollback/observability, acceptance-criteria testability, and assumptions/unknowns.

Split findings into:

- **BLOCKER** — implementation cannot proceed safely: a missing or contradictory requirement, a correctness violation, a data-loss risk, a security-boundary violation, an unsafe migration, an impossible external contract, a direct path to an operational outage, or Acceptance Criteria that cannot verify the real requirement.
- **NON-BLOCKING** — naming preference, optional optimization, future extensibility, style, or an out-of-scope improvement.

Never block approval on NON-BLOCKING findings alone.

Completion condition: **fresh-context executability** — could an implementing agent with no memory of this conversation start safely from just the repository and this spec, with no further user-intent questions needed? If yes, the spec is ready for human approval.

## Human Approval

The normal flow has exactly one human design gate: the completed spec. (Issue path: spec review → post to the Issue → `AskUserQuestion` approval. GlitchTip path: spec review → upload to Trilium → `AskUserQuestion` approval.)

Do not add extra gates: no approval to start discovery, no per-section approval, no "may I proceed" gate before the spec exists, no plan approval, no execution-mode choice, and no per-task approval.

## Plan Generation Contract

Each task in the plan needs at minimum: Files (Create/Modify/Test), Depends on, Change, Contracts/Invariants, a concrete Verification command with expected evidence, Stop Conditions, and Assumptions.

Size tasks so each is independently verifiable, has clear dependencies, and is something a reviewer could meaningfully reject on its own — not so large it hides multiple decisions, not so small it becomes bureaucratic overhead.

Do not embed full production/test code in the plan, and do not force uniform 2-5-minute microsteps. Do record exact values wherever a signature, schema, migration command, external API shape, or rollback command is fragile enough that an implementer paraphrasing it would break it.

## Plan Review Contract

Dispatch the existing `plan-reviewer` sub-agent (`Agent` tool, `subagent_type: plan-reviewer`) against the plan file. Review dimensions: spec requirement coverage, task dependency order, producer/consumer interface consistency, undefined type/function/schema references, migration/rollout order safety, whether verification actually proves the requirement, whether external assumptions are verified, presence of stop conditions, absence of scope creep, and that the plan does not override the spec.

The spec is authority; the plan is its implementation argument. There is no plan-approval gate — plan review fixes issues in place and execution proceeds once it completes.

## Implementation Execution

Whether execution runs on the main agent directly or via a sub-agent follows the existing decision framework in `rules/workflow-sub-agents.md` as-is. Do not invent a new selection mechanism for this, and never ask the user to choose the execution approach.

## Stop Conditions

Stop and ask the user only for one of these six reasons:

1. A new user-intent Decision is needed (see Fact / Decision Separation).
2. A destructive or irreversible operation.
3. A security-sensitive action that needs explicit approval.
4. A side effect outside the repository that would normally need approval — e.g. disabling or uninstalling a plugin on the live, running Claude Code installation, since that reaches outside the repo and affects sessions beyond this one.
5. The plan is fundamentally broken and every path forward would be a guess.
6. A required tool or sub-agent invocation fails with no safe automatic recovery, and only a human can decide how to proceed — e.g. a credential/permission blocker, or a review sub-agent (spec-reviewer/plan-reviewer) that cannot be dispatched at all.

Ordinary technical judgment calls proceed without asking.

## TDD Discipline

For behavior changes and bug fixes where an automated test is reasonably possible, follow RED → GREEN → REFACTOR. When an automated test is not feasible, document the alternative verification evidence directly in the plan task instead of skipping verification.

## Final Evidence Gate (Prompt-Only Contract)

Before creating a PR:

1. Record a snapshot `S` of: `HEAD`, staged state, tracked working-tree diff, untracked files, and the identity of the verification evidence collected so far.
2. Re-confirm the working tree still matches `S` while progressing through, in order: fresh full verification → secret check → deep-review/lite-review → diff/status/evidence check → a final check immediately before commit/PR.
3. If anything changes partway through this sequence, restart the whole gate from scratch rather than patching around the drift.
4. A sub-agent's own "done" or "tests pass" self-report is never itself completion evidence — the gate above must be run and its evidence inspected directly.

This gate is not automated with a helper script in this iteration; a helper script is the natural upgrade path via a follow-up Issue if manual comparison proves error-prone in practice.

## Local-Only Artifacts

Specs and plans are written to `.agent-work/specs/` and `.agent-work/plans/` (moved from the old `docs/superpowers/specs|plans/`). `.agent-work/` is excluded via the global `.gitignore`. Never `git add -f` these files, even after review — the durable record is the Issue comment or Trilium note, not the git history.

The old `docs/superpowers/` and `.superpowers/` `.gitignore` entries stay in place for now as a migration-period leftover.
