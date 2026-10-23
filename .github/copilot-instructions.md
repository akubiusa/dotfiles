# GitHub Copilot Instructions

This repository manages dotfiles and AI agent settings with chezmoi.
During code review, prioritize checking the points below.

## Project overview

- Purpose: manage shell settings, tmux settings, notification settings, and AI agent settings as chezmoi templates.
- Shell scripts under `tests/` run syntax checks, unit tests, and integration tests, and CI runs them automatically on pull_request via `.github/workflows/` (unit-test.yml / integration-test.yml / pr-checks.yml). Locally, run `chezmoi apply` on Docker and check the result.

## What to check in particular during review

### chezmoi file naming rules (easy to get wrong)

- `executable_foo.sh` becomes `foo.sh` after deployment, so the `executable_` prefix is removed. Check that settings that reference a path from outside, such as `settings.json`, do not use a path containing `executable_`.
- `dot_foo` becomes `.foo` after deployment.
- `symlink_foo` becomes a symbolic link, and the file content is the link target.
- Do not use workaround patterns such as `symlink_executable_`.

### Secrets

- Check that tokens, webhook URLs, passwords, and the like are not committed in plain text.
- `~/.env` and `~/.gitconfig.local` are outside repository management. Include only samples such as `.env.example` / `.gitconfig.local.example`.
- When changing the pre-commit hook (`home/dot_config/git/hooks/executable_pre-commit`) or the allowlist in `home/dot_gitleaks.toml`, check that the false-positive suppression is not so broad that it disables detection of real secrets.
- The `gitleaks` command itself has no direct install logic in `install.sh`; a pinned version is installed via mise (see "Tools managed by mise" below). When updating the version, check that the real-detection test in `tests/integration/test_gitleaks.sh` passes.

### Keeping tests in sync

- When changing `update.sh` or the systemd updater unit, keep the AI CLI throttle, the concurrency lock, `Persistent=true` on the timer, the drift target backup before non-interactive updates, and `mise install` against the managed global config, and verify with `tests/unit/test_update.sh` and `tests/integration/test_chezmoi_apply.sh`. If the backup fails, do not apply, and manage the systemd unit as a chezmoi source under `home/dot_config/systemd/user/`.
- When changing or deleting notification and hook scripts such as `home/dot_codex/` and `home/dot_claude/scripts/`, check that the corresponding tests under `tests/unit/`, `tests/integration/`, and `tests/syntax/` do not retain stale references.
- When renaming or deleting a managed file, check whether `home/.chezmoiremove` needs an update so that the old target does not remain. Do not make the whole of `.claude` / `.codex` `exact_`, which would delete runtime state.

### Tools managed by mise

- CLI tools such as `gh`, `ghq`, `roots`, and `gitleaks` are installed via `mise` based on the declarations in `home/dot_config/mise/config.toml`. gitleaks uses a verified exact version and is updated by Renovate's mise manager. Check that no direct install logic has been added to `install.sh`.
- When changing the mise version hard-coded in `install.sh` (`MISE_VERSION`), check that it does not conflict with the corresponding `regexManagers` entry in `renovate.json`.

### Agent definitions

- For newly added agent definitions (`home/dot_claude/agents/*.md`), check that the `tools` field restricts the allowed tools to the minimum necessary (for example, that a read-only status-check agent is not needlessly granted write tools).

## Coding conventions

- This file is written entirely in English. The canonical language policy is the root `AGENTS.md`; the following is a summary of it.
- Commit message `<description>`, code comments, PRs / Issues, and documentation are written in Japanese; error messages are written in English. Markdown under `home/dot_claude/` and `home/dot_codex/`, and this file, are written in English.
- Insert a half-width space between Japanese and alphanumeric characters.
- Match the structure and naming patterns of existing files.

## Tech stack

- Language: Bash
- Tools: chezmoi, git, tmux, jq, mise

## Documentation consistency

- Check that changes do not contradict the rules described in `README.md` / `CLAUDE.md`.
