#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Builds Marionette for a connected device, installs it and launches it. Stops at the first step
# that fails, so that a failed build is never followed by a launch of the app already there.
#
#   install-on-device.sh [device udid] [launch arguments…]
#   install-on-device.sh -- [launch arguments…]      the device from .env
#
# The device and the development profile come from .env (MARIONETTE_DEVICE,
# MARIONETTE_DEVELOPMENT_PROFILE; see Scripts/env.sh), or from MARIONETTE_DEVELOPMENT_TEAM and
# MARIONETTE_PROVISIONING_PROFILE (the profile's UUID) when both are set. The profile must cover
# llc.turing.Marionette and the device. A locked device refuses the launch; the install has still
# succeeded.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
while IFS= read -r -d '' setting; do export "$setting"; done < <(Scripts/env.sh load)

device="${MARIONETTE_DEVICE:-}"
if [[ $# -gt 0 && "$1" != -* ]]; then
    device="$1"
    shift
fi
[[ "${1:-}" == -- ]] && shift
[[ -n "$device" ]] || { echo "No device: pass its UDID, or save the connected one with Scripts/env.sh set MARIONETTE_DEVICE --connected" >&2; exit 2; }

team="${MARIONETTE_DEVELOPMENT_TEAM:-}"
uuid="${MARIONETTE_PROVISIONING_PROFILE:-}"
if [[ -z "$team" || -z "$uuid" ]]; then
    [[ -n "${MARIONETTE_DEVELOPMENT_PROFILE:-}" ]] || {
        echo "No development profile: save one with Scripts/env.sh set MARIONETTE_DEVELOPMENT_PROFILE <path>" >&2; exit 2; }
    read -r uuid team < <(Scripts/provisioning-profile.sh development "$MARIONETTE_DEVELOPMENT_PROFILE" "$device") || exit 1
fi

# What xcodebuild and devicectl print can name the team, the profile and the device.
redact() { Scripts/redact.sh --device "$device" "$team" "$uuid"; }

echo "==> Building"
xcodebuild build -project Marionette.xcodeproj -scheme Marionette -configuration Debug \
    -destination "id=$device" -derivedDataPath DerivedData-device -quiet \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$team" \
    CODE_SIGN_IDENTITY="Apple Development" MARIONETTE_PROVISIONING_PROFILE="$uuid" 2>&1 | redact

echo "==> Installing"
xcrun devicectl device install app --device "$device" --quiet \
    DerivedData-device/Build/Products/Debug-iphoneos/Marionette.app 2>&1 | redact

echo "==> Launching"
if (( $# > 0 )); then
    xcrun devicectl device process launch --device "$device" --terminate-existing --quiet llc.turing.Marionette -- "$@" 2>&1 | redact
else
    xcrun devicectl device process launch --device "$device" --terminate-existing --quiet llc.turing.Marionette 2>&1 | redact
fi
