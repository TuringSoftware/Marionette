#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs ONE live UI test against a real Mac and collects its screenshots into Artifacts/screenshots/live/.
#   MARIONETTE_TEST_HOST=… MARIONETTE_TEST_USER=… MARIONETTE_TEST_PASSWORD=… Scripts/live-ui-test.sh <simulator udid> <test name>
# Test names: testHighPerformance, testStandardAdaptive, testSSHTunnelWithFiles, testVNC (which also
# needs MARIONETTE_TEST_VNC_ADDRESS, host:port of a VNC server that is not a Mac, and
# MARIONETTE_TEST_VNC_PASSWORD).
# One viewer at a time can hold a High Performance session: never run two of these at once. The app
# must already be built for testing (Scripts/screenshots.sh does that, or xcodebuild build-for-testing).
set -euo pipefail
cd "$(dirname "$0")/.."
udid="$1"; test="$2"
: "${MARIONETTE_TEST_HOST:?}" "${MARIONETTE_TEST_USER:?}" "${MARIONETTE_TEST_PASSWORD:?}"
runner="llc.turing.Marionette.UITests.xctrunner"
# The runner's files can only be looked up while the simulator is booted, so boot it here rather
# than let xcodebuild boot it and shut it down again.
booted_here=0
if ! xcrun simctl list devices booted | grep -q "$udid"; then
    xcrun simctl boot "$udid"
    booted_here=1
fi
xcrun simctl bootstatus "$udid" -b >/dev/null
TEST_RUNNER_MARIONETTE_TEST_HOST="$MARIONETTE_TEST_HOST" TEST_RUNNER_MARIONETTE_TEST_USER="$MARIONETTE_TEST_USER" TEST_RUNNER_MARIONETTE_TEST_PASSWORD="$MARIONETTE_TEST_PASSWORD" \
    TEST_RUNNER_MARIONETTE_TEST_VNC_ADDRESS="${MARIONETTE_TEST_VNC_ADDRESS:-}" TEST_RUNNER_MARIONETTE_TEST_VNC_PASSWORD="${MARIONETTE_TEST_VNC_PASSWORD:-}" \
    xcodebuild test-without-building -project Marionette.xcodeproj -scheme Marionette \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath DerivedData \
    "-only-testing:MarionetteUITests/LiveConnectionTests/$test" -collect-test-diagnostics never 2>&1 \
    | grep --line-buffered -E "LIVE |Test Case .* (passed|failed)|error:|\*\* TEST" || true
mkdir -p Artifacts/screenshots/live
if container="$(xcrun simctl get_app_container "$udid" "$runner" data 2>/dev/null)"; then
    for file in "$container"/Documents/Screenshots/live-*.png; do
        [[ -f "$file" ]] && cp "$file" Artifacts/screenshots/live/
    done
fi
ls Artifacts/screenshots/live/
if [[ "$booted_here" -eq 1 ]]; then xcrun simctl shutdown "$udid"; fi
