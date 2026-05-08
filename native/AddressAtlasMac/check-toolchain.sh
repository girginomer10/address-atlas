#!/usr/bin/env bash
set -euo pipefail

DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
BREW_SWIFT="/opt/homebrew/opt/swift/bin/swift"
CLT_DEVELOPER_DIR="/Library/Developer/CommandLineTools"

if [[ -n "$DEVELOPER_DIR" && "$DEVELOPER_DIR" != *"CommandLineTools"* ]] && xcodebuild -version >/dev/null 2>&1; then
  echo "Using $(xcodebuild -version | tr '\n' ' ')"
  exit 0
fi

if [[ -x "$BREW_SWIFT" && -d "$CLT_DEVELOPER_DIR" ]]; then
  echo "Using Homebrew Swift fallback: $(DEVELOPER_DIR="$CLT_DEVELOPER_DIR" "$BREW_SWIFT" --version | head -1)"
  echo "Full Xcode is still recommended for XCTest and notarized distribution builds."
  exit 0
fi

if [[ -z "$DEVELOPER_DIR" ]]; then
  echo "Full Xcode or Homebrew Swift is required to build Address Atlas Mac."
  echo "Install Xcode from the App Store, then run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  echo "Or install the Swift.org toolchain:"
  echo "  brew install swift"
  exit 2
fi

if [[ "$DEVELOPER_DIR" == *"CommandLineTools"* ]]; then
  echo "Address Atlas Mac needs full Xcode or Homebrew Swift, but xcode-select currently points to Command Line Tools:"
  echo "  $DEVELOPER_DIR"
  echo
  echo "Install Xcode from the App Store, open it once, then run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  echo "Or install the Swift.org toolchain:"
  echo "  brew install swift"
  exit 2
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "xcodebuild is not available. Install full Xcode or Homebrew Swift."
  exit 2
fi
