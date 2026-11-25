#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prepares simulators for testing by hand: installs the app and adds a Mac and, optionally, a VNC
# server to its library, through the app's own editor (the ManualTestSetup UI test). Computers
# already in the library are left alone.
#   MARIONETTE_TEST_HOST=… MARIONETTE_TEST_USER=… MARIONETTE_TEST_PASSWORD=… \
#   [MARIONETTE_TEST_VNC_ADDRESS=host:port [MARIONETTE_TEST_VNC_PASSWORD=…]] \
#       Scripts/add-test-computers.sh <simulator udid>…
# Scripts/with-test-host.sh sets the first three from the keychain. The app must already be built
# for testing into DerivedData/ (xcodebuild build-for-testing … -derivedDataPath DerivedData).
# Simulators are prepared one after another and left booted.
set -uo pipefail
cd "$(dirname "$0")/.."
(( $# > 0 )) || { echo "usage: Scripts/add-test-computers.sh <simulator udid>…" >&2; exit 2; }
[[ -n "${MARIONETTE_TEST_HOST:-}${MARIONETTE_TEST_VNC_ADDRESS:-}" ]] || { echo "Name a computer to add: see the header of this script." >&2; exit 2; }

status=0
for udid in "$@"; do
    echo "==> $udid"
    xcrun simctl boot "$udid" 2>/dev/null
    xcrun simctl bootstatus "$udid" -b >/dev/null
    TEST_RUNNER_MARIONETTE_TEST_HOST="${MARIONETTE_TEST_HOST:-}" TEST_RUNNER_MARIONETTE_TEST_USER="${MARIONETTE_TEST_USER:-}" \
        TEST_RUNNER_MARIONETTE_TEST_PASSWORD="${MARIONETTE_TEST_PASSWORD:-}" \
        TEST_RUNNER_MARIONETTE_SETUP_VNC_ADDRESS="${MARIONETTE_TEST_VNC_ADDRESS:-}" TEST_RUNNER_MARIONETTE_SETUP_VNC_PASSWORD="${MARIONETTE_TEST_VNC_PASSWORD:-}" \
        xcodebuild test-without-building -project Marionette.xcodeproj -scheme Marionette \
        -destination "platform=iOS Simulator,id=$udid" -derivedDataPath DerivedData \
        -only-testing:MarionetteUITests/ManualTestSetup -collect-test-diagnostics never 2>&1 \
        | grep --line-buffered -E "SETUP |Test Case .* (passed|failed|skipped)|error:|\*\* TEST"
    [[ "${PIPESTATUS[0]}" -eq 0 ]] || status=1
done
exit $status
