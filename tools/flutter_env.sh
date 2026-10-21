#!/usr/bin/env bash
# Shared helper. FLUTTER_BIN can be the path to an FVM-managed flutter binary.
if [[ -n "${FLUTTER_BIN:-}" ]]; then
  FLUTTER=("$FLUTTER_BIN")
elif [[ -x .fvm/flutter_sdk/bin/flutter ]]; then
  FLUTTER=("$(cd .fvm/flutter_sdk/bin && pwd)/flutter")
elif [[ -f .fvmrc || -f .fvm/fvm_config.json ]] && command -v fvm >/dev/null 2>&1; then
  FLUTTER=(fvm flutter)
elif command -v flutter >/dev/null 2>&1; then
  FLUTTER=(flutter)
else
  echo "ERROR: Flutter is not in PATH. Set FLUTTER_BIN to your Flutter binary or use your configured FVM terminal." >&2
  exit 1
fi
