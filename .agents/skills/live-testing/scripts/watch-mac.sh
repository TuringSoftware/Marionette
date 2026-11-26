#!/bin/zsh
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Watches the test Mac's Screen Sharing daemon while a run is under way, and stops the run the moment
# the daemon hangs, so that nobody waits on a run that can no longer pass. Checks every 20 s while the
# process `pid` lives; on a hang it ends that process and everything it started, prints one line
# starting with HANG, and exits 1. Exits 0 when the run ends first.
#
#   Scripts/with-test-host.sh [--profile NAME] .agents/skills/live-testing/scripts/watch-mac.sh <pid>
set -uo pipefail
: "${MARIONETTE_MAC_SHELL:?run this through Scripts/with-test-host.sh}"
pid="${1:?the process id of the run to watch}"
health="$(dirname "$0")/mac-health.sh"

descendants() {
    local child
    for child in $(pgrep -P "$1"); do
        descendants "$child"
        echo "$child"
    done
}

while kill -0 "$pid" 2>/dev/null; do
    sleep 20
    report="$("$health" 2>&1 | tr '\n' ' ')"
    errors="$(sed -nE 's/.*last 2 min: ([0-9]+).*/\1/p' <<<"$report")"
    cpu="$(sed -nE 's/.*: ([0-9]+)(\.[0-9]+)? % CPU.*/\1/p' <<<"$report" | head -1)"
    # A hung daemon logs the error without end and keeps several cores busy.
    if (( ${errors:-0} > 0 && ${cpu:-0} > 50 )); then
        echo "HANG: $report"
        kill $(descendants "$pid") "$pid" 2>/dev/null
        exit 1
    fi
done
exit 0
