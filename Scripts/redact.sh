#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Copies standard input to standard output with each value given replaced by ‹id›, so that a
# script's output can be shown without the team, profile, key or device identifiers in it. Anything
# shaped like a UUID or a device UDID is replaced too, and so are the names in the list of
# destinations xcodebuild prints when it cannot find the one it was given.
#
#   <command> 2>&1 | Scripts/redact.sh [--device <udid>] [value…]
#
# --device also replaces the device's name and its CoreDevice identifier, which devicectl and
# xcodebuild print in their errors.
set -euo pipefail

values=()
while [[ $# -gt 0 ]]; do
    if [[ "$1" == --device && $# -ge 2 ]]; then
        values+=("$2")
        json="$(mktemp)"
        if xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1; then
            while IFS= read -r value; do values+=("$value"); done < <(jq -r --arg udid "$2" \
                '.result.devices[] | select(.hardwareProperties.udid == $udid) | .identifier, .deviceProperties.name | values' "$json")
        fi
        rm -f "$json"
        shift 2
    else
        values+=("$1")
        shift
    fi
done

# Longest first, so that a value inside another is not half replaced; values under three characters
# are left alone, so that they do not take every such letter with them.
REDACT="$(printf '%s\n' ${values[@]+"${values[@]}"})" perl -e '
    $| = 1;
    my @values = sort { length $b <=> length $a } grep { length $_ >= 3 } split /\n/, $ENV{REDACT};
    while (my $line = <STDIN>) {
        $line =~ s/\Q$_\E/‹id›/gi for @values;
        $line =~ s/\b[0-9A-F]{8}-(?:[0-9A-F]{4}-){3}[0-9A-F]{12}\b/‹id›/gi;
        $line =~ s/\b[0-9A-F]{8}-[0-9A-F]{16}\b/‹id›/gi;
        $line =~ s/\b[0-9a-f]{40}\b/‹id›/gi;
        $line =~ s/\bname:[^,}]*/name:‹name›/g if $line =~ /\{ platform:/;
        print $line;
    }'
