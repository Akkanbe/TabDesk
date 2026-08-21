#!/usr/bin/env bash
# 起動中の PoC アプリへ URL スキーム経由でコマンドを送る。
#   scripts/poc.sh status
#   scripts/poc.sh 'add?set=A&wid=123,456'
#   scripts/poc.sh 'show?set=B'
#   scripts/poc.sh 'bench?rounds=10&parallel=1'
# 結果は ~/Library/Logs/TabDeskPoC/poc.log に出る(scripts/poc.sh log で末尾表示)。
set -euo pipefail
cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  echo "usage: $0 <command[?query]> | log" >&2
  exit 1
fi
if [[ "$cmd" == "log" ]]; then
  tail -n "${2:-40}" "$HOME/Library/Logs/TabDeskPoC/poc.log"
  exit 0
fi
open -g "tabdeskpoc://$cmd"
