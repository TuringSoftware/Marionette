#!/bin/zsh
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Keeps the address, account and password of a Mac for the live tests in the login keychain, under
# a profile name, so that no command line, script or log has to hold them.
# Scripts/with-test-host.sh reads them back for one command.
#
#   Scripts/set-test-host.sh [profile]             asks for each; the password is not shown
#   Scripts/set-test-host.sh --delete [profile]
#
# The profile is "default" unless named. Run this in your own Terminal window: what you type there
# stays on this Mac.
set -euo pipefail

service="Marionette live test host"

if [[ "${1:-}" == --delete ]]; then
    profile="${2:-default}"
    for field in host user password; do
        security delete-generic-password -s "$service" -a "$profile/$field" >/dev/null 2>&1 || true
    done
    print "Removed profile \"$profile\"."
    exit 0
fi

profile="${1:-default}"
read -r "host?Address of the Mac: "
read -r "user?Account name on it: "
[[ -n "$host" && -n "$user" ]] || { print -u2 "Both are needed."; exit 1; }
security add-generic-password -U -s "$service" -a "$profile/host" -w "$host"
security add-generic-password -U -s "$service" -a "$profile/user" -w "$user"
print "Password for $user (security asks twice and shows nothing):"
security add-generic-password -U -s "$service" -a "$profile/password" -w
print "Saved as profile \"$profile\". Run a command with it: Scripts/with-test-host.sh${1:+ --profile $profile} <command>"
