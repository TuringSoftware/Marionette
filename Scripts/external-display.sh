#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Attaches a 1920×1080 external display to a simulator, opens a simulated session in each external
# display mode, and saves what the device and the monitor show:
#   Artifacts/screenshots/external/<label>/<mode>-{device,monitor}.png
# Then runs the ExternalDisplayTests UI test (which skips without a monitor) and detaches the monitor.
#
#   Scripts/external-display.sh <simulator udid> <label>
# Expects the app to have been built with `xcodebuild build-for-testing … -derivedDataPath DerivedData`.
set -euo pipefail
cd "$(dirname "$0")/.."
udid="$1"
label="$2"
out="Artifacts/screenshots/external/$label"
mkdir -p "$out"
app="DerivedData/Build/Products/Debug-iphonesimulator/Marionette.app"

booted_here=0
if ! xcrun simctl list devices booted | grep -q "$udid"; then
    xcrun simctl boot "$udid"
    booted_here=1
fi
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
xcrun simctl io "$udid" screenConfig --display=2 power off >/dev/null 2>&1 || true
sleep 2
xcrun simctl io "$udid" screenConfig --display=2 geometry 1920x1080 >/dev/null

# The monitor is plugged in after the app has started, as it would be mid-session. A monitor that
# is already on when the app launches is not reliably reported to it by the simulator.
plug_in() {
    xcrun simctl io "$udid" screenConfig --display=2 power on >/dev/null
    sleep 6
}
unplug() {
    xcrun simctl io "$udid" screenConfig --display=2 power off >/dev/null
    sleep 2
}

for mode in mirror externalOnly dual; do
    for appearance in light dark; do
        xcrun simctl launch --terminate-running-process "$udid" llc.turing.Marionette \
            -MarionetteUITestMode -MarionetteScenario two-displays -MarionetteAutoConnect -MarionetteExternalMode "$mode" -MarionetteAppearance "$appearance" >/dev/null
        sleep 4
        plug_in
        xcrun simctl io "$udid" screenshot --display=2 "$out/$mode-monitor-$appearance.png" >/dev/null 2>&1
        xcrun simctl io "$udid" screenshot "$out/$mode-device-$appearance.png" >/dev/null 2>&1
        unplug
    done
done
xcrun simctl terminate "$udid" llc.turing.Marionette || true
echo "screenshots in $out"

( sleep 25; xcrun simctl io "$udid" screenConfig --display=2 power on >/dev/null ) &
xcodebuild test-without-building -project Marionette.xcodeproj -scheme Marionette -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath DerivedData -only-testing:MarionetteUITests/ExternalDisplayTests -parallel-testing-enabled NO \
    -collect-test-diagnostics never 2>&1 | grep -E "Test Case .*(passed|failed|skipped)|error:" || true

xcrun simctl io "$udid" screenConfig --display=2 power off >/dev/null
if [[ "$booted_here" -eq 1 ]]; then xcrun simctl shutdown "$udid"; fi
