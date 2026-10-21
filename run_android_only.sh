#!/usr/bin/env bash
# TENCENT_ANDROID_ONLY_RUNNER_V1
# Only ready physical Android/Android wireless devices from ADB are eligible.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
PROFILE="${1:-host}"
REQUESTED="${2:-}"
if [[ $# -gt 2 || ( "$PROFILE" != host && "$PROFILE" != viewer ) ]]; then
  echo 'Usage: bash run_android_only.sh host [ANDROID_SERIAL]'
  echo '       bash run_android_only.sh viewer [ANDROID_SERIAL]'
  exit 2
fi
[[ -f run.sh && -f config/"$PROFILE".json ]] || {
  echo "ERROR: run.sh or config/$PROFILE.json missing. Run configure.sh first." >&2
  exit 1
}
ADB="$(python3 - "$ROOT" <<'PY'
import os, shutil, sys
from pathlib import Path
root = Path(sys.argv[1])
candidates = []
props = root / 'android/local.properties'
if props.is_file():
    for line in props.read_text().splitlines():
        if line.strip().startswith('sdk.dir='):
            value = line.strip().split('=', 1)[1]
            value = value.replace('\\ ', ' ').replace('\\:', ':').replace('\\\\', '\\')
            candidates.append(str(Path(value).expanduser() / 'platform-tools/adb'))
for var in ('ANDROID_HOME', 'ANDROID_SDK_ROOT'):
    if os.environ.get(var):
        candidates.append(str(Path(os.environ[var]) / 'platform-tools/adb'))
candidates.append(str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
on_path = shutil.which('adb')
if on_path:
    candidates.append(on_path)
for value in candidates:
    if Path(value).is_file() and os.access(value, os.X_OK):
        print(value)
        break
else:
    sys.exit('ERROR: Android SDK platform-tools/adb not found.')
PY
)"
"$ADB" start-server
LIST="$("$ADB" devices -l)"
printf '\n%s\n\n' "$LIST"
IDS=()
while IFS= read -r serial; do
  [[ -n "$serial" ]] && IDS+=("$serial")
done < <(printf '%s\n' "$LIST" | awk '$2 == "device" && $1 !~ /^emulator-/ { print $1 }')
if [[ ${#IDS[@]} -eq 0 ]]; then
  echo 'STOP: No ready physical Android phone detected by ADB.' >&2
  echo 'unauthorized: unlock the phone and accept Allow USB debugging.' >&2
  echo 'offline/empty list: reconnect the data cable and check USB debugging.' >&2
  echo 'No iPhone, macOS, Chrome, or emulator will be selected.' >&2
  exit 3
fi
SERIAL=''
if [[ -n "$REQUESTED" ]]; then
  for item in "${IDS[@]}"; do
    if [[ "$item" == "$REQUESTED" ]]; then SERIAL="$item"; break; fi
  done
  [[ -n "$SERIAL" ]] || { echo "STOP: $REQUESTED is not a ready physical Android device." >&2; exit 3; }
elif [[ ${#IDS[@]} -eq 1 ]]; then
  SERIAL="${IDS[0]}"
else
  echo "Select the Android phone for the $PROFILE profile:"
  for ((i=0; i<${#IDS[@]}; i++)); do printf '  %d) %s\n' "$((i+1))" "${IDS[$i]}"; done
  printf 'Phone number: '
  read -r PICK
  INDEX=-1
  for ((i=0; i<${#IDS[@]}; i++)); do
    if [[ "$PICK" == "$((i+1))" ]]; then INDEX="$i"; break; fi
  done
  [[ "$INDEX" -ge 0 ]] || { echo 'STOP: Invalid selection.' >&2; exit 2; }
  SERIAL="${IDS[$INDEX]}"
fi
[[ "$("$ADB" -s "$SERIAL" get-state)" == device ]] || {
  echo 'STOP: Selected Android disconnected. Reconnect it and retry.' >&2; exit 3;
}
printf '\nProfile: %s | Android device: %s\n' "$PROFILE" "$SERIAL"
exec bash "$ROOT/run.sh" "$PROFILE" "$SERIAL"
