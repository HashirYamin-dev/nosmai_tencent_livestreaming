#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
source tools/flutter_env.sh
PROFILE="${1:-host}"
[[ "$PROFILE" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || { echo 'Invalid profile.' >&2; exit 1; }
python3 tools/check_config.py "$ROOT/config/$PROFILE.json"
"${FLUTTER[@]}" build apk --release --dart-define-from-file="$ROOT/config/$PROFILE.json"
mkdir -p dist
cp build/app/outputs/flutter-apk/app-release.apk "dist/tencent-live-$PROFILE.apk"
echo "Created $ROOT/dist/tencent-live-$PROFILE.apk"
echo 'QA build only; uses the generated project debug signing key. Do not publish to a store.'
