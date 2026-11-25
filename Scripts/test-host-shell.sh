#!/bin/zsh
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Runs its argument as a shell command on the Mac named by MARIONETTE_TEST_HOST, over SSH, signed in
# as MARIONETTE_TEST_USER with MARIONETTE_TEST_PASSWORD. Scripts/with-test-host.sh sets all three
# and points MARIONETTE_MAC_SHELL here.
#
# The password goes to ssh through its askpass hook (this same script, called by ssh with
# MARIONETTE_ASKPASS set), never on a command line. A Mac not seen before is trusted on first
# contact and remembered in ~/.ssh/known_hosts; a changed key is refused.
set -euo pipefail

if [[ -n "${MARIONETTE_ASKPASS:-}" ]]; then
    print -r -- "${MARIONETTE_TEST_PASSWORD:?}"
    exit 0
fi

: "${MARIONETTE_TEST_HOST:?}" "${MARIONETTE_TEST_USER:?}" "${MARIONETTE_TEST_PASSWORD:?}"
MARIONETTE_ASKPASS=1 SSH_ASKPASS="${0:A}" SSH_ASKPASS_REQUIRE=force exec ssh \
    -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
    -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "$MARIONETTE_TEST_USER@$MARIONETTE_TEST_HOST" "$1"
