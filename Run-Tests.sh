#!/bin/bash -exu -o pipefail
# GCD-34: iOS-only test entry point for the Mobile Locker fork.
# Unit + contract tests live in the SPM test target (Package.swift).
#
# Note: when GCDWebServer.xcodeproj is present, xcodebuild prefers its schemes
# and hides SPM package schemes. This script runs tests from a temporary tree
# that excludes the Xcode project so the GCDWebServer-Package scheme is used.

ROOT="$(cd "$(dirname "$0")" && pwd)"
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
SCHEME="${SCHEME:-GCDWebServer-Package}"

if [[ -f "/usr/local/bin/xcpretty" ]]; then
  PRETTYFIER="xcpretty"
else
  PRETTYFIER="tee"
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gcdwebserver-tests.XXXXXX")"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Copy sources without the legacy Xcode project so SPM schemes resolve cleanly.
rsync -a \
  --exclude '.git' \
  --exclude '.build' \
  --exclude 'build' \
  --exclude 'GCDWebServer.xcodeproj' \
  --exclude '*.xcworkspace' \
  --exclude '.swiftpm' \
  "$ROOT/" "$WORKDIR/"

cd "$WORKDIR"
echo "Running SPM package tests ($SCHEME) on: $DESTINATION"
xcodebuild test \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  | $PRETTYFIER

echo "All tests completed successfully!"
