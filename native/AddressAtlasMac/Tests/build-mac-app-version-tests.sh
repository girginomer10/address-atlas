#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/build-mac-app.sh"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

grep -A1 '<key>LSMultipleInstancesProhibited</key>' "$SCRIPT" | grep -q '<true/>' || {
  echo "The packaged app must prohibit multiple Launch Services instances" >&2
  exit 1
}

assert_version() {
  local expected="$1"
  local actual
  actual="$(ADDRESS_ATLAS_BUILD_NUMBER="$expected" bash "$SCRIPT" --print-build-version)"
  [[ "$actual" == "$expected" ]] || {
    echo "Expected build version '$expected', got '$actual'" >&2
    exit 1
  }
}

for version in 1 42 9999 12.3 12.34.56; do
  assert_version "$version"
done

for invalid in 0 10000 1.234 1.2.345 1.2.3.4 v12 ' 12 '; do
  if ADDRESS_ATLAS_BUILD_NUMBER="$invalid" bash "$SCRIPT" --print-build-version >/dev/null 2>&1; then
    echo "Invalid build version '$invalid' was accepted" >&2
    exit 1
  fi
done

default_first="$(env -u ADDRESS_ATLAS_BUILD_NUMBER bash "$SCRIPT" --print-build-version)"
default_second="$(env -u ADDRESS_ATLAS_BUILD_NUMBER bash "$SCRIPT" --print-build-version)"
[[ "$default_first" == "$default_second" ]]
[[ "$default_first" =~ ^[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}$ ]]

# Exercise the actual script from a real depth-1 checkout. A shallow history
# must fail closed without an external build number, while an explicit CI/release
# number remains valid and does not depend on repository depth.
SOURCE_REPO="$TEMP_ROOT/source"
SHALLOW_REPO="$TEMP_ROOT/shallow"
mkdir -p "$SOURCE_REPO/native/AddressAtlasMac/Sources/AddressAtlasMac"
cp "$SCRIPT" "$SOURCE_REPO/native/AddressAtlasMac/build-mac-app.sh"
printf '%s\n' 'static let currentAppVersion = "0.2.0"' \
  > "$SOURCE_REPO/native/AddressAtlasMac/Sources/AddressAtlasMac/AppState.swift"
git -C "$SOURCE_REPO" init -q
git -C "$SOURCE_REPO" config user.name "Address Atlas Tests"
git -C "$SOURCE_REPO" config user.email "tests@address-atlas.invalid"
git -C "$SOURCE_REPO" add .
git -C "$SOURCE_REPO" commit -qm "fixture one"
printf '%s\n' 'second commit' > "$SOURCE_REPO/fixture.txt"
git -C "$SOURCE_REPO" add fixture.txt
git -C "$SOURCE_REPO" commit -qm "fixture two"
git clone -q --depth 1 "file://$SOURCE_REPO" "$SHALLOW_REPO"
SHALLOW_SCRIPT="$SHALLOW_REPO/native/AddressAtlasMac/build-mac-app.sh"

if env -u ADDRESS_ATLAS_BUILD_NUMBER bash "$SHALLOW_SCRIPT" --print-build-version >/dev/null 2>&1; then
  echo "Shallow clone unexpectedly derived a build version" >&2
  exit 1
fi
shallow_explicit="$(ADDRESS_ATLAS_BUILD_NUMBER=42 bash "$SHALLOW_SCRIPT" --print-build-version)"
[[ "$shallow_explicit" == "42" ]]

echo "build-mac-app version checks passed ($default_first)"
