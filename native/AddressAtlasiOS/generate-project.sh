#!/usr/bin/env bash
# Regenerates AddressAtlasiOS.xcodeproj from project.yml. The generated project
# is committed so CI and Xcode users do not need xcodegen; run this after any
# project.yml change and commit the result.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required (brew install xcodegen)." >&2
  exit 69
fi

"$ROOT/scripts/write-version-xcconfig.sh"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" --quiet
echo "Generated $ROOT/AddressAtlasiOS.xcodeproj"
