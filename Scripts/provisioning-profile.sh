#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Checks that a provisioning profile can sign Marionette and installs it where Xcode looks for
# profiles. Prints "<profile uuid> <team id>" on standard output for the calling script, and
# explains any problem on standard error without naming the profile, the team or a device.
#
#   Scripts/provisioning-profile.sh development <profile> [device udid]
#   Scripts/provisioning-profile.sh app-store <profile>
#
# A development profile must allow debugging and, when a device is given, include it. An App Store
# profile must list no devices.
set -euo pipefail
bundle_id="llc.turing.Marionette"

kind="${1:-}"
profile="${2:-}"
device="${3:-}"
[[ ( "$kind" == development || "$kind" == app-store ) && -n "$profile" ]] || {
    sed -n '9,10p' "$0" | sed 's/^# //' >&2; exit 2; }
fail() { echo "The $kind profile $*" >&2; exit 1; }
[[ -f "$profile" ]] || fail "is not where its path says."

plist="$(mktemp)"
trap 'rm -f "$plist"' EXIT
security cms -D -i "$profile" -o "$plist" 2>/dev/null || fail "is not a provisioning profile."
get() { plutil -extract "$1" raw -o - "$plist" 2>/dev/null || true; }
has() { plutil -extract "$1" xml1 -o /dev/null "$plist" 2>/dev/null; }

plutil -extract Platform json -o - "$plist" 2>/dev/null | jq -e 'index("iOS") != null' >/dev/null || fail "is not for iOS."
uuid="$(get UUID)"
team="$(get TeamIdentifier.0)"
app_id="$(get Entitlements.application-identifier)"
debuggable="$(get Entitlements.get-task-allow)"
[[ -n "$uuid" && -n "$team" && -n "$app_id" ]] || fail "lacks a UUID, a team or an app identifier."

# ISO 8601 times in UTC compare correctly as strings.
[[ "$(get ExpirationDate)" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] || fail "has expired."
# The identifier is "<prefix>.<bundle id or a pattern ending in *>".
pattern="${app_id#*.}"
# shellcheck disable=SC2053 # the pattern is matched as a glob on purpose
[[ "$bundle_id" == $pattern ]] || fail "is for another app."

case "$kind" in
    development)
        [[ "$debuggable" == true ]] || fail "is not a development profile."
        has ProvisionedDevices || fail "lists no devices."
        if [[ -n "$device" ]]; then
            plutil -extract ProvisionedDevices json -o - "$plist" | jq -e --arg device "$device" \
                'map(ascii_downcase) | index($device | ascii_downcase) != null' >/dev/null || fail "does not include the device."
        fi
        ;;
    app-store)
        [[ "$debuggable" != true ]] || fail "is a development profile."
        ! has ProvisionedDevices || fail "lists devices, so it is for ad hoc distribution, not the App Store."
        ! has ProvisionsAllDevices || fail "is an enterprise profile."
        ;;
esac

installed="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$uuid.mobileprovision"
if ! cmp -s "$profile" "$installed"; then
    mkdir -p "$(dirname "$installed")"
    cp "$profile" "$installed"
fi
echo "$uuid $team"
