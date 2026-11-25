#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Builds Marionette for a connected device, installs it and launches it. Stops at the first step
# that fails, so that a failed build is never followed by a launch of the app already there.
#
#   MARIONETTE_DEVELOPMENT_TEAM=<team id> MARIONETTE_PROVISIONING_PROFILE=<profile uuid> \
#       install-on-device.sh <device udid> [launch arguments…]
#
# The profile must cover llc.turing.Marionette and the device. `xcrun devicectl list devices` lists
# the devices. A locked device refuses the launch; the install has still succeeded.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
(( $# > 0 )) || { echo "usage: install-on-device.sh <device udid> [launch arguments…]" >&2; exit 2; }
device="$1"; shift
: "${MARIONETTE_DEVELOPMENT_TEAM:?the team identifier}" "${MARIONETTE_PROVISIONING_PROFILE:?the UUID of the provisioning profile}"

echo "==> Building"
xcodebuild build -project Marionette.xcodeproj -scheme Marionette -configuration Debug \
    -destination "id=$device" -derivedDataPath DerivedData-device -quiet \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$MARIONETTE_DEVELOPMENT_TEAM" \
    CODE_SIGN_IDENTITY="Apple Development" MARIONETTE_PROVISIONING_PROFILE="$MARIONETTE_PROVISIONING_PROFILE"

echo "==> Installing"
xcrun devicectl device install app --device "$device" --quiet \
    DerivedData-device/Build/Products/Debug-iphoneos/Marionette.app

echo "==> Launching"
if (( $# > 0 )); then
    xcrun devicectl device process launch --device "$device" --terminate-existing --quiet llc.turing.Marionette -- "$@"
else
    xcrun devicectl device process launch --device "$device" --terminate-existing --quiet llc.turing.Marionette
fi
