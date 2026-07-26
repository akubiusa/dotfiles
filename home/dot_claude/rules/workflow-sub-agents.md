# Sub-Agent Delegation Strategy

**Default: direct action.** Delegate only when overhead is justified.

---

## Decision framework

```
Can I do this in ≤ 5 tool calls?
├─ YES → Do it yourself
└─ NO  → Genuine parallelism or specialization benefit?
    ├─ YES → Delegate
    │   ├─ Other independent work to do? → background mode
    │   └─ No other work?               → sync mode (or just do it yourself)
    └─ NO  → Do it yourself
```

## Quick reference

| Task type | Tool calls | Recommendation |
|---|---|---|
| File read | 1–2 | Direct |
| Simple edit | 2–3 | Direct |
| Single search | 1–2 | Direct |
| Multi-file analysis | 5–10 | Direct with structured approach |
| Cross-module investigation | 10–15 | Explore agent if parallel work exists |
| Full feature implementation | 15+ | general-purpose agent with planning |
| Security / code review | Any | Specialized agent (high signal-to-noise) |
| Claude Code prompt-file maintenance (`CLAUDE.md`, `AGENTS.md`, `rules/*.md`, `skills/*`, `agents/*.md`, hook scripts, `settings.json`) | Any | Always delegate — see carve-out below |

## Prompt-file maintenance carve-out

Claude Code's own prompt files (`CLAUDE.md`/`AGENTS.md`, `rules/*.md`, `skills/*`, `agents/*.md`, hooks, `settings.json`) get re-injected into every future session's context. Reading/editing them from the parent session leaves that exploration sitting in a context that persists for the rest of the conversation — so, regardless of tool-call count, delegate this work to an agent instead of doing it directly.

Parent session's job: define the task, pass along any research/decisions already gathered, review the agent's output, and own all user-facing Q&A (agents can't call `AskUserQuestion` — relay per `rules/superpowers.md`). Keep direct tool use to quick recon (`ls`/`grep`) for scoping only.

The agent has no memory of this rule file, so the dispatch prompt must restate the concrete scope and task inline — not just reference "this carve-out" by name.

When the prompt files being edited live under a chezmoi-managed dotfiles repo (source at `home/dot_*`, deployed to e.g. `~/.claude/`), always edit the chezmoi SOURCE path, never the deployed target path directly — direct edits to the deployed path get silently overwritten by the next `chezmoi apply`/`chezmoi update` (including automatic/scheduled runs), discarding the edit without warning.

## When to delegate ✅

1. **True parallelism** — independent threads that can run simultaneously.
2. **Specialized expertise** — security review, performance profiling.
3. **Large-scale investigation** — cross-cutting concerns across many modules.
4. **Context isolation** — verbose output or experimental approaches that would pollute main context.

## When NOT to delegate ❌

1. Task accomplishable in ≤ 5 direct tool calls.
2. No real parallel work to do while waiting.
3. High context dependency — frequent back-and-forth with current state.
4. One-off trivial operations (formatting, one-liner fixes).

## Anti-patterns

| Anti-pattern | Bad | Good |
|---|---|---|
| Micro-delegation | Launch agent to read one file | `view` directly |
| Background polling | launch background → immediately `read_agent(wait=true)` | Continue own work; retrieve on notification |
| Deep chains | A → B → C → D | Keep depth ≤ 2 levels |
| Excessive context passing | Shuttle 200 KB between agents | Keep large context in main, delegate only independent pieces |

## Planner–Generator–Evaluator pattern

For features spanning 5+ files or with security-critical paths:

1. **Planner** (`general-purpose`): break down requirements into subtasks.
2. **Generator** (main agent or worker): implement each subtask.
3. **Evaluator** (`security-review` / `code-review`): verify correctness, security, performance.

## Sub-agent model selection

| Role | Model | Tools |
|---|---|---|
| Coordinator | Opus | All |
| Implementation worker | Sonnet | Write, Edit, Bash |
| Verification worker | Opus | Read, Grep, Bash |
| Discovery worker | Haiku | Read, Grep |

## Handling Idle Notifications from Background Sub-Agents

The `Agent` tool runs sub-agents in the background by default and notifies
the parent session when one completes. If a sub-agent stops taking actions
without calling `SendMessage` to report completion, the harness may deliver
an **idle** notification instead of a **completed** one. Treat these as
distinct: an idle notification means the sub-agent went quiet without
finishing, not that it's done.

This applies whenever a background-mode sub-agent (the `Agent` tool's
default, or explicit `run_in_background: true`) sends an idle notification.
It does not apply to sync-mode (`run_in_background: false`) dispatches,
since those block the calling turn until the sub-agent returns.

**Follow-up procedure:**

1. On receiving an idle notification, immediately send that sub-agent one
   `SendMessage` nudge asking it to continue or report its current status.
2. If no `completed` notification arrives within a timeout (default 15
   minutes since the nudge; a calling skill may define its own threshold —
   that takes precedence over this default), set up a `CronCreate`
   check-in (default: every 15 minutes) if one isn't already running, to
   track outstanding sub-agents.
3. At each check-in, any sub-agent still not completed after its own
   timeout (default 30 minutes since the nudge) is stopped (e.g. via
   `TaskStop`) and re-dispatched once, with the same input.
4. If the re-dispatch also times out, mark that sub-agent's task as
   **unresolved** in the calling skill's final report — do not silently
   drop it — and move on with the rest of the work instead of waiting
   further.
5. Once every sub-agent is either completed or marked unresolved, delete
   the `CronCreate` check-in with `CronDelete`.

**Notes:**

- `CronCreate` jobs are session-scoped and auto-expire after 7 days (same
  constraint as `check-container-status`'s use of `CronCreate`).
- This rule sets the default cadence and retry count; it does not mandate
  a specific state-tracking mechanism. A calling skill that already tracks
  sub-agent progress (a state file like `STATE.md`, or the `Todo`/`Task`
  tools) may reuse that instead of inventing a new one.
