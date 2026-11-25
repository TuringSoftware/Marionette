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

status=0
output="$(mktemp)"
trap 'rm -f "$output"' EXIT
for manifest in Packages/*/Package.swift; do
    package="$(dirname "$manifest")"
    [[ -d "$package/Tests" ]] || continue
    echo "==> $package"
    if swift test --package-path "$package" >"$output" 2>&1; then
        grep -E "Test run with" "$output" || true
    else
        status=1
        grep -E "error:|recorded an issue|failed|Test run with" "$output" || tail -20 "$output"
    fi
done
exit $status
