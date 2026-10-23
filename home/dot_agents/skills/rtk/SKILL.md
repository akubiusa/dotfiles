---
name: rtk
description: Reference skill for using Rust Token Killer's analysis, history, discovery, and raw proxy commands.
---

# RTK

In Codex, Claude's hook-based automatic command rewriting is unavailable. Run `rtk` explicitly, and only when needed.

```bash
rtk --version
rtk gain
rtk gain --history
rtk discover
rtk proxy <command>
```

- `rtk gain`: aggregate token savings.
- `rtk gain --history`: per-command history.
- `rtk discover`: analysis targeting Claude Code history; state explicitly that it does not cover Codex history.
- `rtk proxy`: run the raw command without filtering. Do not use it to bypass commands that require a safety check.

If `rtk gain` fails, check with `which rtk` and `rtk --version` whether a same-named Rust Type Kit is on the PATH.
