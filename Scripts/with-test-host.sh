#!/bin/zsh
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Runs one command against a Mac saved by Scripts/set-test-host.sh, without its details appearing
# anywhere they could be read back from:
#
# - MARIONETTE_TEST_HOST, MARIONETTE_TEST_USER and MARIONETTE_TEST_PASSWORD are set from the
#   keychain for the command only;
# - MARIONETTE_MAC_SHELL is set to Scripts/test-host-shell.sh, which signs in to the Mac over SSH
#   with the same account (Remote Login must be on there for the tests that use it);
# - everything the command prints, standard error included, passes through a filter that writes
#   ‹host›, ‹user› and ‹password› in place of the three values. This matters: a UI test logs the
#   text it types, the password included.
#
#   Scripts/with-test-host.sh [--profile NAME] <command> [arguments…]
#
# For example:
#   Scripts/with-test-host.sh --profile studio Scripts/test.sh --live
#   Scripts/with-test-host.sh --profile studio Scripts/live-app-checks.sh <simulator udid>
#
# What the command writes to files (xcresult bundles, its own logs) is not filtered.
set -euo pipefail

here="${0:A:h}"
service="Marionette live test host"
profile=default
if [[ "${1:-}" == --profile ]]; then
    profile="${2:?a profile name}"
    shift 2
fi
(( $# > 0 )) || { print -u2 "usage: Scripts/with-test-host.sh [--profile NAME] <command> [arguments…]"; exit 2; }

stored() {
    security find-generic-password -s "$service" -a "$profile/$1" -w 2>/dev/null || {
        print -u2 "No $1 saved for profile \"$profile\". Save one with Scripts/set-test-host.sh ${profile:#default}"
        exit 2
    }
}
# Assigned before exported: `export X="$(…)"` would hide a failed lookup from `set -e`.
MARIONETTE_TEST_HOST="$(stored host)"
MARIONETTE_TEST_USER="$(stored user)"
MARIONETTE_TEST_PASSWORD="$(stored password)"
MARIONETTE_MAC_SHELL="$here/test-host-shell.sh"
export MARIONETTE_TEST_HOST MARIONETTE_TEST_USER MARIONETTE_TEST_PASSWORD MARIONETTE_MAC_SHELL

# Longest first, so that a value inside another is not half replaced. The password is always
# replaced; the address and account only from three characters, so that a one-letter account
# does not take every such letter with it.
"$@" 2>&1 | perl -e '
    $| = 1;
    my @pairs = sort { length $b->[0] <=> length $a->[0] }
        grep { length $_->[0] && ($_->[1] eq "‹password›" || length $_->[0] >= 3) }
        ([$ENV{MARIONETTE_TEST_PASSWORD}, "‹password›"], [$ENV{MARIONETTE_TEST_HOST}, "‹host›"], [$ENV{MARIONETTE_TEST_USER}, "‹user›"]);
    while (my $line = <STDIN>) {
        $line =~ s/\Q$_->[0]\E/$_->[1]/g for @pairs;
        print $line;
    }'
exit ${pipestatus[1]}
