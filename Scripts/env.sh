#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Reads and writes .env, the git-ignored file of local settings that scripts and agent skills share
# (.env.example lists the keys). Values are never printed, so an agent can run this without a
# profile, a key or a device identifier reaching its conversation.
#
#   Scripts/env.sh check KEY…                    whether each is set, and whether a path exists
#   Scripts/env.sh set KEY VALUE                 saves VALUE; an empty VALUE clears the key
#   Scripts/env.sh set MARIONETTE_DEVICE --connected [model]
#                                                saves the reachable iPhone or iPad (whose model name
#                                                contains [model], when several are)
#   Scripts/env.sh load                          KEY=value pairs, NUL-separated, for a script to export
#
# A variable already set in the environment wins over the file. Values are literal: no quotes and no
# expansion, except a leading ~/ for the home folder. `set` saves a file's path as an absolute one; a
# relative path written into the file by hand is taken from the root of the clone.
# MARIONETTE_ENV_FILE names another file.
#
# To load the settings, from bash:
#   while IFS= read -r -d '' setting; do export "$setting"; done < <(Scripts/env.sh load)
# from zsh:
#   for setting in ${(0)"$(Scripts/env.sh load)"}; do export "$setting"; done
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
file="${MARIONETTE_ENV_FILE:-$root/.env}"
path_keys=" MARIONETTE_DEVELOPMENT_PROFILE MARIONETTE_DISTRIBUTION_PROFILE MARIONETTE_ASC_KEY "

usage() { sed -n '9,14p' "$0" | sed 's/^# //' >&2; exit 2; }
valid_key() { [[ "$1" =~ ^MARIONETTE_[A-Z0-9_]+$ ]] || { echo "Not a setting name: $1" >&2; exit 2; }; }

# The value of KEY in the file, empty if absent. The last line for a key wins, as it would in a shell.
from_file() {
    [[ -f "$file" ]] || return 0
    awk -v key="$1" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { printf "%s", value }' "$file"
}

is_path() { [[ "$path_keys" == *" $1 "* ]]; }

value_of() {
    local value="${!1:-}"
    [[ -n "$value" ]] || value="$(from_file "$1")"
    if [[ "$value" == "~/"* ]]; then
        value="$HOME/${value#\~/}"
    elif [[ -n "$value" && "$value" != /* ]] && is_path "$1"; then
        value="$root/$value"
    fi
    printf '%s' "$value"
}

save() {  # save KEY VALUE
    if [[ ! -f "$file" ]]; then
        (umask 077; if [[ -f "$root/.env.example" && -z "${MARIONETTE_ENV_FILE:-}" ]]; then cp "$root/.env.example" "$file"; else : >"$file"; fi)
        echo "Created $(basename "$file")"
    fi
    # The copy sits beside the file so that the move replaces it in one step; it must not outlive an
    # interrupted run, because it holds the settings and git does not ignore its name.
    updated="$(mktemp "$file.XXXXXX")"
    trap 'rm -f "$updated"' EXIT
    KEY="$1" VALUE="$2" awk '
        index($0, ENVIRON["KEY"] "=") == 1 { if (!done) print ENVIRON["KEY"] "=" ENVIRON["VALUE"]; done = 1; next }
        { print }
        END { if (!done) print ENVIRON["KEY"] "=" ENVIRON["VALUE"] }' "$file" >"$updated"
    mv "$updated" "$file"
    echo "$1 saved"
}

connected_device() {  # connected_device [model]
    local json devices count
    json="$(mktemp)"
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || { rm -f "$json"; echo "devicectl could not list devices." >&2; exit 1; }
    # A model named in full wins over models that merely contain it ("iPhone" against "iPhone 18 Pro").
    devices="$(jq -r --arg model "${1:-}" '[.result.devices[]
        | select(.hardwareProperties.reality == "physical" and .hardwareProperties.platform == "iOS"
            and .connectionProperties.tunnelState != "unavailable")
        | {udid: .hardwareProperties.udid, name: (.hardwareProperties.marketingName // "")}
        | select(.name | ascii_downcase | contains($model | ascii_downcase))]
        | (map(select(.name | ascii_downcase == ($model | ascii_downcase)))) as $exact
        | (if ($exact | length) > 0 then $exact else . end)[]
        | "\(.udid)\t\(.name)"' "$json")"
    rm -f "$json"
    count="$(grep -c . <<<"$devices" || true)"
    if [[ "$count" -ne 1 ]]; then
        if [[ "$count" -eq 0 ]]; then
            echo "No reachable device${1:+ whose model contains \"$1\"}. Connect it, unlock it and try again." >&2
        else
            echo "Several reachable devices; name one by model: Scripts/env.sh set MARIONETTE_DEVICE --connected <model>" >&2
            cut -f2 <<<"$devices" | sed 's/^/    /' >&2
        fi
        exit 1
    fi
    echo "Using the $(cut -f2 <<<"$devices")" >&2
    cut -f1 <<<"$devices"
}

command="${1:-}"
[[ $# -gt 0 ]] && shift
case "$command" in
    load)
        [[ -f "$file" ]] || exit 0
        awk -F= '/^MARIONETTE_[A-Z0-9_]+=/ { print $1 }' "$file" | sort -u | while read -r key; do
            [[ -n "${!key:-}" ]] && continue
            value="$(value_of "$key")"
            if [[ -n "$value" ]]; then printf '%s=%s\0' "$key" "$value"; fi
        done
        ;;
    set)
        [[ $# -ge 1 && $# -le 3 ]] || usage
        valid_key "$1"
        if [[ "${2:-}" == --connected ]]; then
            [[ "$1" == MARIONETTE_DEVICE ]] || { echo "--connected is only for MARIONETTE_DEVICE." >&2; exit 2; }
            device="$(connected_device "${3:-}")"
            save "$1" "$device"
        else
            [[ $# -le 2 ]] || usage
            [[ "${2:-}" != *$'\n'* ]] || { echo "A value cannot span lines." >&2; exit 2; }
            value="${2:-}"
            if [[ "$value" == "~/"* ]]; then
                value="$HOME/${value#\~/}"
            elif [[ -n "$value" && "$value" != /* ]] && is_path "$1"; then
                value="$PWD/$value"
            fi
            save "$1" "$value"
        fi
        ;;
    check)
        [[ $# -gt 0 ]] || usage
        status=0
        for key in "$@"; do
            valid_key "$key"
            value="$(value_of "$key")"
            if [[ -z "$value" ]]; then
                echo "$key: missing"; status=1
            elif is_path "$key" && [[ ! -f "$value" ]]; then
                echo "$key: no file at the saved path"; status=1
            else
                echo "$key: set"
            fi
        done
        exit $status
        ;;
    *) usage ;;
esac
