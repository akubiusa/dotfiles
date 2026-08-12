#!/bin/bash
# Powerline daemon 起動ラッパー
#
# tmux.conf から呼ばれ、以下を行う:
#   1. native の /usr/bin/powerline-daemon が Python 3.14 の argparse
#      非互換で起動できるかを feature detection する。
#   2. native が動く場合はそのまま exec する。
#   3. native が動かない場合、powerline.commands.daemon.get_argparser()
#      のみを nested argument group を使わない同等のパーサーへ
#      monkeypatch した上で、本来の /usr/bin/powerline-daemon の
#      main() をそのまま実行する (daemon化・socket bind等は無改変)。
#
# ponytail: 差し替え対象は get_argparser() の1関数のみ。
#   upstream/Ubuntu パッケージが Python 3.14 対応した後は feature
#   detection が成功するため、本 fallback は自動的に使われなくなる。
set -euo pipefail

PYTHON3="${POWERLINE_DAEMON_LAUNCH_PYTHON3:-/usr/bin/python3}"
DAEMON="${POWERLINE_DAEMON_LAUNCH_DAEMON:-/usr/bin/powerline-daemon}"

# PATH 上の python3 は mise の shim を指す可能性があり、
# /usr/bin/powerline-daemon 自身の shebang (/usr/bin/python3) と
# 異なるバージョンで判定すると誤判定するため、明示的に固定する。
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
    # Python 3.14 では mutually-exclusive-group への
    # add_argument_group() がネストとして拒否される。
    # --foreground/--replace は元コードでも互いに排他ではなく
    # (--kill との排他は main() 側の明示チェックで行われる)、
    # ネストせずトップレベルへ追加しても挙動は同一。
    p.add_argument("--foreground", "-f", action="store_true")
    p.add_argument("--replace", "-r", action="store_true")
    return p


d.get_argparser = get_argparser
sys.argv[0] = DAEMON
runpy.run_path(DAEMON, run_name="__main__")
PYEOF
