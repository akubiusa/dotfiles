#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELECTOR_SCRIPT="$ROOT_DIR/home/dot_bash_profile.d/executable_10-tmux-selector.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/home"

cat > "$TEST_DIR/bin/tmux" <<'EOF'
#!/bin/bash

case "$1" in
  list-sessions)
    cat "$TMUX_TEST_SESSIONS"
    ;;
  list-panes)
    printf '%s\n' '%1 1'
    ;;
  show-environment)
    printf '%s\n' 'TMUX_PROJECT_DIR=/tmp'
    ;;
  display-message)
    case "${@: -1}" in
      '#{pane_current_command}') printf '%s\n' 'bash' ;;
      '#{pane_current_path}') printf '%s\n' '/tmp' ;;
    esac
    ;;
  attach-session)
    printf '%s\n' "$3" > "$TMUX_TEST_ATTACHED"
    ;;
esac
EOF

cat > "$TEST_DIR/bin/fzf" <<'EOF'
#!/bin/bash

cat > "$TMUX_FZF_CAPTURE"
IFS= read -r selected < "$TMUX_FZF_CAPTURE"
printf '%s\n' "$selected"
EOF

cat > "$TEST_DIR/bin/tput" <<'EOF'
#!/bin/bash

printf '%s\n' 80
EOF

chmod +x "$TEST_DIR/bin/tmux" "$TEST_DIR/bin/fzf" "$TEST_DIR/bin/tput"

unset SSH_CONNECTION || true
export PATH="$TEST_DIR/bin:$PATH"
export HOME="$TEST_DIR/home"
export TMUX_SELECTOR_DISABLE_AUTO=1
export TMUX_MIN_WIDTH=999
export TMUX_SESSION_DELAY=0
export TMUX_TEST_SESSIONS="$TEST_DIR/sessions"
export TMUX_FZF_CAPTURE="$TEST_DIR/fzf-input"
export TMUX_TEST_ATTACHED="$TEST_DIR/attached"

# shellcheck disable=SC1090,SC1091
source "$SELECTOR_SCRIPT"

run_case() {
  local case_name="$1"
  local session_list="$2"
  local expected="$3"
  local expected_attach="$4"
  local actual attached

  printf '%s\n' "$session_list" > "$TMUX_TEST_SESSIONS"
  rm -f "$TMUX_FZF_CAPTURE" "$TMUX_TEST_ATTACHED"
  tmux_session_selector >/dev/null 2>&1

  actual="$(awk -F '\t' '$2 == "SESSION" { print $3 }' "$TMUX_FZF_CAPTURE")"
  attached="$(cat "$TMUX_TEST_ATTACHED")"
  if [[ "$actual" == "$expected" && "$attached" == "$expected_attach:" ]]; then
    echo "✅ $case_name passed"
  else
    echo "❌ $case_name failed"
    echo "Expected session order:"
    printf '%s\n' "$expected"
    echo "Actual session order:"
    printf '%s\n' "$actual"
    echo "Expected attach target: $expected_attach:"
    echo "Actual attach target: $attached"
    return 1
  fi
}

run_case \
  'numeric session order' \
  $'10|0|1|0\n2|0|1|0\n1|0|1|0' \
  $'1\n2\n10' \
  '1'

run_case \
  'nonnumeric slots and order' \
  $'10|0|1|0\ncustom-a|0|1|0\n2|0|1|0\ncustom-b|0|1|0\n1|0|1|0' \
  $'1\ncustom-a\n2\ncustom-b\n10' \
  '1'

run_case \
  'numeric ties retain input order' \
  $'2|0|1|0\n02|0|1|0\n1|0|1|0' \
  $'1\n2\n02' \
  '1'

run_case \
  'nonnumeric names retain order' \
  $'agentctl-z|0|1|0\ncustom-a|0|1|0' \
  $'agentctl-z\ncustom-a' \
  'agentctl-z'
