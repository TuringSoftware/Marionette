#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Everything a fresh clone needs before it builds: the pinned third-party sources (git submodules
# at upstream release tags, see .gitmodules), OpenSSL built for each platform, and the Xcode project.
#
# Needs Xcode (27.1 or later, with the iOS platform installed) and xcodegen (brew install xcodegen).
#
#   Scripts/bootstrap.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "error: $*" >&2; exit 1; }

echo "==> Checking tools"
[[ -d .git || -f .git ]] || fail "run this from a git clone; the dependencies are git submodules."
xcodebuild -version >/dev/null 2>&1 || fail "Xcode is needed. Install it, then: sudo xcode-select -s /Applications/Xcode.app"
xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
[[ "${xcode_version%%.*}" -ge 27 ]] || fail "Xcode 27.1 or later is needed (found $xcode_version)."
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || fail "the iOS platform is missing: Xcode → Settings → Components."
command -v perl >/dev/null || fail "perl is needed to configure OpenSSL."
command -v xcodegen >/dev/null || fail "xcodegen is needed to make the Xcode project: brew install xcodegen"
echo "    Xcode $xcode_version, xcodegen $(xcodegen --version | awk '{ print $NF }')"

echo "==> Fetching the pinned dependencies"
git submodule sync --quiet
# Shallow, and not recursive: only each pinned release commit is needed, not the projects' history
# or OpenSSL's own test suites.
git submodule update --init --depth 1
git submodule foreach --quiet 'printf "    %-60s %s\n" "$sm_path" "$(git describe --tags --always 2>/dev/null)"'

echo "==> Building OpenSSL"
Scripts/build-deps.sh

echo "==> Making the Xcode project"
xcodegen generate --quiet
echo "==> Done. Next: Scripts/test.sh, or open Marionette.xcodeproj"
