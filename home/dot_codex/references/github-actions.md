# GitHub Actions Rules

- Reuse common CI from `book000/templates` at `@master`; do not duplicate it. Pin step-level actions to full commit SHAs with matching version comments and let Renovate manage those pins.
- Use `node-version-file: .node-version`. Keep workflow step names English, imperative, sentence case, and emoji-free unless the file already consistently uses the established emoji convention.
- Set least-privilege `permissions` explicitly. Use a concurrency group that cancels superseded runs; include `github.event_name` when both `pull_request` and `pull_request_target` are possible. Do not cancel deployments that must finish.
- Never interpolate untrusted GitHub context directly into `run:`; pass it through `env:`. Avoid `pull_request_target` unless privileged fork-PR processing is essential; prefer `pull_request` or an artifact-only `workflow_run` design.
