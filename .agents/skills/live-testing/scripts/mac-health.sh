#!/bin/zsh
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Says whether the test Mac's Screen Sharing daemon is still healthy: its CPU use, and how often it
# logged "SRP invalid step" in the last two minutes. A daemon stuck near 100 % with a growing count
# is hung and has to be restarted by someone with administrator rights on that Mac.
#
#   Scripts/with-test-host.sh [--profile NAME] .agents/skills/live-testing/scripts/mac-health.sh
set -euo pipefail
: "${MARIONETTE_MAC_SHELL:?run this through Scripts/with-test-host.sh}"

$MARIONETTE_MAC_SHELL '
pgrep -xq screensharingd || echo "screensharingd is not running (it starts on demand)"
for pid in $(pgrep -x screensharingd); do
    echo "screensharingd pid $pid: $(ps -o pcpu= -p $pid | tr -d " ") % CPU, up $(ps -o etime= -p $pid | tr -d " ")"
done
echo "\"SRP invalid step\" in the last 2 min: $(/usr/bin/log show --last 2m --style compact --predicate "process == \"screensharingd\"" 2>/dev/null | grep -c "SRP invalid step")"
'
