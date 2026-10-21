#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
source tools/flutter_env.sh
PROFILE="${1:-}"
if [[ ! "$PROFILE" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
  echo 'Usage: bash run.sh host DEVICE_ID [--release]'
  echo '       bash run.sh viewer DEVICE_ID [--release]'
  echo 'Find device IDs using flutter devices.'
  exit 1
fi
shift
CONFIG="$ROOT/config/$PROFILE.json"
python3 tools/check_config.py "$CONFIG"
ARGS=()
if [[ $# -gt 0 && "$1" != --* ]]; then
  ARGS+=(-d "$1")
  shift
fi
if [[ $# -eq 0 ]]; then ARGS+=(--debug); fi
exec "${FLUTTER[@]}" run "${ARGS[@]}" --dart-define-from-file="$CONFIG" "$@"
