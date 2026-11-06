#!/bin/bash
# Runs the test suite with either Xcode or the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
args=(--build-system native)
DEV="$(xcode-select -p)"
if [[ "$DEV" == *CommandLineTools* ]]; then
  # With CLT only, SwiftPM doesn't find the Testing framework on its own.
  F="$DEV/Library/Developer/Frameworks"
  args+=(-Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F")
fi
exec swift test "${args[@]}" "$@"
