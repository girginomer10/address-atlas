#!/usr/bin/env bash
set -euo pipefail

DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"

if [[ -z "$DEVELOPER_DIR" ]]; then
  echo "Full Xcode is required to build Address Atlas Mac. Install Xcode from the App Store, then run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 2
fi

if [[ "$DEVELOPER_DIR" == *"CommandLineTools"* ]]; then
  echo "Address Atlas Mac needs full Xcode, but xcode-select currently points to Command Line Tools:"
  echo "  $DEVELOPER_DIR"
  echo
  echo "Install Xcode from the App Store, open it once, then run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 2
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "xcodebuild is not available. Install full Xcode and select it with xcode-select."
  exit 2
fi

echo "Using $(xcodebuild -version | tr '\n' ' ')"
