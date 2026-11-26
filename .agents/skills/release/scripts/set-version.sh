#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Sets MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml and prints the change.
#
#   set-version.sh                    the same version, the next build number
#   set-version.sh <version>          that version, the next build number
#   set-version.sh <version> <build>
#
# The build number only goes up: App Store Connect refuses a build it has seen for a version.
# MARIONETTE_PROJECT_FILE names another file to edit.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
file="${MARIONETTE_PROJECT_FILE:-project.yml}"

current() { sed -nE "s/^    $1: \"([^\"]*)\"$/\1/p" "$file"; }
old_version="$(current MARKETING_VERSION)"
old_build="$(current CURRENT_PROJECT_VERSION)"
[[ -n "$old_version" && "$old_build" =~ ^[0-9]+$ ]] || { echo "project.yml has no version and build in the expected form." >&2; exit 1; }

version="${1:-$old_version}"
build="${2:-$((old_build + 1))}"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "A version is one to three numbers separated by dots: $version" >&2; exit 2; }
[[ "$build" =~ ^[0-9]+$ ]] || { echo "A build is a whole number: $build" >&2; exit 2; }
(( build > old_build )) || { echo "The build must be above $old_build." >&2; exit 2; }

sed -i '' -E \
    -e "s/^(    MARKETING_VERSION: )\"[^\"]*\"$/\1\"$version\"/" \
    -e "s/^(    CURRENT_PROJECT_VERSION: )\"[^\"]*\"$/\1\"$build\"/" "$file"
echo "$old_version ($old_build) -> $version ($build)"
