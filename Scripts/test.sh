#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Runs the unit tests of every Swift package on this Mac.
#   Scripts/test.sh            unit and replay tests
#   Scripts/test.sh --live     also tests that need MARIONETTE_TEST_HOST (with MARIONETTE_TEST_USER and
#                              MARIONETTE_TEST_PASSWORD; MARIONETTE_TEST_USER2 and MARIONETTE_TEST_PASSWORD2 name a second
#                              account for session select)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--live" ]]; then
    if [[ -z "${MARIONETTE_TEST_HOST:-}" ]]; then
        echo "Set MARIONETTE_TEST_HOST to the address of the test machine." >&2
        exit 2
    fi
else
    # Live tests run whenever a host is named; without --live nothing touches the network.
    unset MARIONETTE_TEST_HOST
fi

# OpenSSL is the one dependency SwiftPM cannot build; make sure it is there and current.
Scripts/build-deps.sh

# Swift Testing otherwise starts every test of a package at once: MarionetteKit's three hundred
# sessions then take 6 GB and queue on the one main actor, and on a CI runner with few cores tests
# that wait for a connection time out by the dozen. As many at a time as there are cores runs as fast.
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-$(sysctl -n hw.activecpu)}"

status=0
output="$(mktemp)"
trap 'rm -f "$output"' EXIT
# Prints the lines matching $1, and each issue or warning with the lines under it that say what
# was expected and what came: they are what a failure on CI has to be understood from.
summarise() {
    awk -v keep="$1" '
        /recorded (an issue|a warning)/ { print; details = 12; next }
        details > 0 && !/(Test|Suite) .*(started|passed|failed|recorded)|Test run/ { print; details--; next }
        { details = 0 }
        $0 ~ keep { print }
    ' "$output"
}
for manifest in Packages/*/Package.swift; do
    package="$(dirname "$manifest")"
    [[ -d "$package/Tests" ]] || continue
    echo "==> $package"
    if swift test --package-path "$package" >"$output" 2>&1; then
        summarise "Test run with"
    else
        status=1
        [[ -n "$(summarise "error:|failed|Test run with")" ]] && summarise "error:|failed|Test run with" || tail -20 "$output"
    fi
done
exit $status
