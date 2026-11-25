#!/bin/zsh
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Runs a command that opens a session to a test machine while holding a lock, so that agents and
# terminals working in the same checkout never hold two sessions at once. Waits up to an hour for
# the lock.
#
#   .agents/skills/live-testing/scripts/one-session.sh <command> [arguments…]
set -euo pipefail
(( $# > 0 )) || { print -u2 "usage: one-session.sh <command> [arguments…]"; exit 2; }
exec lockf -t 3600 "${TMPDIR:-/tmp}/marionette-live-session.lock" "$@"
