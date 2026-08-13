#!/bin/bash
# Powerline daemon 起動ラッパー。tmux.conf から呼ばれる。
#
# get_argparser() のみを monkeypatch し、daemon 本体の main() は無改変で実行する。
#
# ponytail: 差し替え対象は get_argparser() の 1 関数のみ。
# upstream が Python 3.14 に対応すれば feature detection が成功し、fallback は自動的に使われなくなる。
set -euo pipefail

PYTHON3="${POWERLINE_DAEMON_LAUNCH_PYTHON3:-/usr/bin/python3}"
DAEMON="${POWERLINE_DAEMON_LAUNCH_DAEMON:-/usr/bin/powerline-daemon}"

# PATH 上の python3 は mise shim を指しうるため、shebang と同じ /usr/bin/python3 を明示的に固定する。
if "$PYTHON3" -c 'from powerline.commands.daemon import get_argparser as g; g()' >/dev/null 2>&1; then
  exec "$DAEMON" "$@"
fi

exec "$PYTHON3" - "$@" <<PYEOF
import argparse
import runpy
import sys

import powerline.commands.daemon as d

DAEMON = "$DAEMON"


def get_argparser(ArgumentParser=argparse.ArgumentParser):
    p = ArgumentParser(description="Daemon that improves powerline performance.")
    p.add_argument("--quiet", "-q", action="store_true")
    p.add_argument("--socket", "-s")
    ex = p.add_mutually_exclusive_group()
    ex.add_argument("--kill", "-k", action="store_true")
    # Python 3.14 では mutually-exclusive-group への add_argument_group() がネストとして拒否される。
    # --foreground/--replace は元々 --kill と排他ではないため、トップレベルへ移しても挙動は同一。
    p.add_argument("--foreground", "-f", action="store_true")
    p.add_argument("--replace", "-r", action="store_true")
    return p


d.get_argparser = get_argparser
sys.argv[0] = DAEMON
runpy.run_path(DAEMON, run_name="__main__")
PYEOF
