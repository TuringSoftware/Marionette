#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds Marionette, runs the screenshot UI tests on each simulator of the review matrix, and collects the
# PNGs into Artifacts/screenshots/<device>/<name>-<light|dark>.png.
#
#   Scripts/screenshots.sh                 every device, light and dark
#   Scripts/screenshots.sh "iPhone 17"     only the devices whose label contains the argument
#   MARIONETTE_SCREENSHOT_TESTS=testSession,testFiles Scripts/screenshots.sh     only these test methods
#
# The iPhone Duo simulator boots closed and nothing public can open it, so its inner display cannot be
# captured. The Duo pass therefore covers the outer display, plus the two partly-open poses laid out by
# the app's own -MarionetteFoldOverride stand-in; those files are named *-simulated-fold-*.png.
set -euo pipefail
cd "$(dirname "$0")/.."

# label | simulator name | runtime identifier suffix | extra test-runner environment
MATRIX=(
    "iPhone 17 (iOS 26.1)|iPhone 17|iOS-26-1|"
    "iPad Pro 13-inch M5 (iOS 27.0)|iPad Pro 13-inch (M5)|iOS-27-0|"
    "iPhone Duo outer display (iOS 27.1)|iPhone Duo|iOS-27-1|MARIONETTE_SCREENSHOT_FOLD=1"
)
FILTER="${1:-}"
DERIVED="DerivedData"
OUTPUT="Artifacts/screenshots"
RUNNER_BUNDLE_ID="llc.turing.Marionette.UITests.xctrunner"

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --quiet
elif [[ ! -d Marionette.xcodeproj ]]; then
    echo "error: Marionette.xcodeproj is generated from project.yml; install xcodegen (brew install xcodegen)." >&2
    exit 1
fi

udid_for() {
    xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
name, runtime = sys.argv[1], sys.argv[2]
for key, devices in json.load(sys.stdin)["devices"].items():
    if key.endswith(runtime):
        for device in devices:
            if device["name"] == name:
                print(device["udid"]); sys.exit(0)
sys.exit(1)' "$1" "$2"
}

echo "==> Building"
xcodebuild build-for-testing -project Marionette.xcodeproj -scheme Marionette \
    -destination "generic/platform=iOS Simulator" -derivedDataPath "$DERIVED" -quiet

status=0
for row in "${MATRIX[@]}"; do
    IFS='|' read -r label name runtime extra <<<"$row"
    if [[ -n "$FILTER" && "$label" != *"$FILTER"* ]]; then continue; fi
    if ! udid="$(udid_for "$name" "$runtime")"; then
        echo "warning: no simulator named '$name' on $runtime; skipping $label" >&2
        status=1
        continue
    fi
    echo "==> $label ($udid)"
    booted_here=0
    if ! xcrun simctl list devices booted | grep -q "$udid"; then
        xcrun simctl boot "$udid"
        booted_here=1
    fi
    xcrun simctl bootstatus "$udid" -b >/dev/null
    # A new simulator covers the keyboard with a one-time tip about slide typing.
    xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
    # Tests that press hardware keys leave the simulator believing a keyboard is attached, and it
    # then shows only the bar above the keyboard, not the keyboard.
    xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences HardwareKeyboardLastSeen -bool false
    xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences AutomaticMinimizationEnabled -bool false
    xcrun simctl uninstall "$udid" "$RUNNER_BUNDLE_ID" >/dev/null 2>&1 || true

    only=("-only-testing:MarionetteUITests/ScreenshotTests")
    if [[ -n "${MARIONETTE_SCREENSHOT_TESTS:-}" ]]; then
        only=()
        IFS=',' read -ra methods <<<"$MARIONETTE_SCREENSHOT_TESTS"
        for method in "${methods[@]}"; do only+=("-only-testing:MarionetteUITests/ScreenshotTests/$method"); done
    fi
    for appearance in light dark; do
        echo "    $appearance"
        xcrun simctl ui "$udid" appearance "$appearance"
        environment=("TEST_RUNNER_MARIONETTE_SCREENSHOT_APPEARANCE=$appearance")
        if [[ -n "$extra" ]]; then environment+=("TEST_RUNNER_$extra"); fi
        if ! env "${environment[@]}" xcodebuild test-without-building -project Marionette.xcodeproj -scheme Marionette \
            -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$DERIVED" "${only[@]}" \
            -parallel-testing-enabled NO -collect-test-diagnostics never 2>&1 \
            | grep --line-buffered -E "Test Case .* failed|error:|\*\* TEST|Executed .* tests" | sed 's/^/      /'; then
            status=1
        fi
        if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then status=1; fi
    done

    destination="$OUTPUT/$label"
    mkdir -p "$destination"
    if container="$(xcrun simctl get_app_container "$udid" "$RUNNER_BUNDLE_ID" data 2>/dev/null)" \
        && compgen -G "$container/Documents/Screenshots/*.png" >/dev/null; then
        # A full run replaces the device's set, so screenshots of removed tests do not linger.
        if [[ -z "${MARIONETTE_SCREENSHOT_TESTS:-}" ]]; then rm -f "${destination:?}"/*.png; fi
        cp "$container"/Documents/Screenshots/*.png "$destination/"
        # XCUITest captures the screen in its native orientation; stand landscape shots upright.
        for sideways in "$destination"/*-landscape-*.png; do
            if [[ -f "$sideways" ]] && [[ "$(sips -g pixelHeight "$sideways" | awk '/pixelHeight/ {print $2}')" -gt "$(sips -g pixelWidth "$sideways" | awk '/pixelWidth/ {print $2}')" ]]; then
                sips -r 270 "$sideways" >/dev/null
            fi
        done
        echo "    $(ls "$destination" | wc -l | tr -d ' ') files in $destination"
    else
        echo "error: no screenshots were produced for $label" >&2
        status=1
    fi
    xcrun simctl ui "$udid" appearance light >/dev/null 2>&1 || true
    if [[ "$booted_here" -eq 1 ]]; then xcrun simctl shutdown "$udid"; fi
done
exit $status
