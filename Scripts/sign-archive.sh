#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Signs an unsigned Marionette archive, such as the one each GitHub Actions run builds, and either
# installs it on a device or uploads it to App Store Connect.
#
#   Scripts/sign-archive.sh device <archive> [--profile <development profile>] [--device <udid>]
#   Scripts/sign-archive.sh upload <archive> [--profile <App Store profile>] [--key <AuthKey_<key id>.p8>]
#                                  [--issuer <issuer id>] [--key-id <key id>]
#   Scripts/sign-archive.sh check device|upload      checks the settings without signing anything
#
# <archive> is a .xcarchive or a .zip holding one (the workflow's artifact). Settings not given as
# options come from .env (see Scripts/env.sh): MARIONETTE_DEVELOPMENT_PROFILE and MARIONETTE_DEVICE
# for a device; MARIONETTE_DISTRIBUTION_PROFILE, MARIONETTE_ASC_KEY, MARIONETTE_ASC_ISSUER and,
# when the key's file name does not give it, MARIONETTE_ASC_KEY_ID for an upload. The signing
# certificate (Apple Development or Apple Distribution) must be in the login keychain. The team,
# profile, device and key identifiers are kept out of everything this prints.
set -euo pipefail
# No cd: relative paths in the arguments are the caller's.
scripts="$(cd "$(dirname "$0")" && pwd)"
bundle_id="llc.turing.Marionette"

usage() { sed -n '8,11p' "$0" | sed 's/^# //' >&2; exit 2; }
fail() { echo "error: $*" >&2; exit 1; }

while IFS= read -r -d '' setting; do export "$setting"; done < <("$scripts/env.sh" load)

mode="${1:-}"
[[ $# -gt 0 ]] && shift
checking=0
if [[ "$mode" == check ]]; then
    checking=1
    mode="${1:-}"
    [[ $# -gt 0 ]] && shift
    archive=""
else
    archive="${1:-}"
    [[ $# -gt 0 ]] && shift
    [[ -n "$archive" ]] || usage
fi
[[ "$mode" == device || "$mode" == upload ]] || usage

if [[ "$mode" == device ]]; then
    profile="${MARIONETTE_DEVELOPMENT_PROFILE:-}"
else
    profile="${MARIONETTE_DISTRIBUTION_PROFILE:-}"
fi
device="${MARIONETTE_DEVICE:-}"
key="${MARIONETTE_ASC_KEY:-}"
issuer="${MARIONETTE_ASC_ISSUER:-}"
key_id="${MARIONETTE_ASC_KEY_ID:-}"
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || usage
    case "$1" in
        --profile) profile="$2" ;;
        --device) [[ "$mode" == device ]] || usage; device="$2" ;;
        --key) [[ "$mode" == upload ]] || usage; key="$2" ;;
        --issuer) [[ "$mode" == upload ]] || usage; issuer="$2" ;;
        --key-id) [[ "$mode" == upload ]] || usage; key_id="$2" ;;
        *) usage ;;
    esac
    shift 2
done

# MARK: - Settings

if [[ "$mode" == device ]]; then
    [[ -n "$profile" ]] || fail "no development profile: pass --profile, or save one with Scripts/env.sh set MARIONETTE_DEVELOPMENT_PROFILE <path>"
    [[ -n "$device" ]] || fail "no device: pass --device, or save the connected one with Scripts/env.sh set MARIONETTE_DEVICE --connected"
    read -r uuid team < <("$scripts/provisioning-profile.sh" development "$profile" "$device") || exit 1
    certificate="Apple Development"
else
    [[ -n "$profile" ]] || fail "no App Store profile: pass --profile, or save one with Scripts/env.sh set MARIONETTE_DISTRIBUTION_PROFILE <path>"
    [[ -n "$key" ]] || fail "no App Store Connect API key: pass --key, or save one with Scripts/env.sh set MARIONETTE_ASC_KEY <path to the .p8>"
    [[ -n "$issuer" ]] || fail "no issuer ID: pass --issuer, or save it with Scripts/env.sh set MARIONETTE_ASC_ISSUER <issuer id>"
    [[ -f "$key" ]] || fail "the API key is not where its path says."
    grep -q "BEGIN PRIVATE KEY" "$key" || fail "the API key file is not a .p8 private key."
    if [[ -z "$key_id" ]]; then
        key_id="$(basename "$key" .p8)"
        key_id="${key_id#AuthKey_}"
        [[ "$(basename "$key")" == AuthKey_*.p8 ]] || fail "the key's file name does not give its ID: pass --key-id, or save it with Scripts/env.sh set MARIONETTE_ASC_KEY_ID <key id>"
    fi
    read -r uuid team < <("$scripts/provisioning-profile.sh" app-store "$profile") || exit 1
    certificate="Apple Distribution"
fi
# A certificate's team is its subject's OU; the name in brackets is the holder's, not always the team.
has_certificate() {
    local folder hash
    folder="$(mktemp -d)"
    security find-certificate -a -c "$certificate: " -Z -p 2>/dev/null | awk -v folder="$folder" '
        /^SHA-1 hash:/ { file = folder "/" $3 }
        /BEGIN CERTIFICATE/ { writing = 1 }
        writing { print > file }
        /END CERTIFICATE/ { writing = 0; close(file) }'
    for hash in $(security find-identity -v -p codesigning | awk '/\)/ { print $2 }'); do
        if [[ -f "$folder/$hash" ]] && openssl x509 -in "$folder/$hash" -noout -subject | grep -Eq "OU ?= ?$team([,/]|$)"; then
            rm -rf "$folder"
            return 0
        fi
    done
    rm -rf "$folder"
    return 1
}
has_certificate || fail "no $certificate certificate for the profile's team in the keychain. Download it in Xcode: Settings > Accounts > Manage Certificates."

redact() {
    if [[ -n "$device" ]]; then
        "$scripts/redact.sh" --device "$device" "$uuid" "$team" "$key_id" "$issuer"
    else
        "$scripts/redact.sh" "$uuid" "$team" "$key_id" "$issuer"
    fi
}

if (( checking )); then
    echo "Settings for $mode are complete."
    exit 0
fi

# MARK: - Archive

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if [[ "$archive" == *.zip ]]; then
    ditto -x -k "$archive" "$work/unzipped" || fail "could not unpack $archive."
    archive="$(find "$work/unzipped" -maxdepth 2 -name '*.xcarchive' -type d | head -1)"
    [[ -n "$archive" ]] || fail "the zip holds no .xcarchive."
fi
[[ -f "$archive/Info.plist" ]] || fail "$archive is not an Xcode archive."
property() { plutil -extract "ApplicationProperties.$1" raw -o - "$archive/Info.plist"; }
[[ "$(property CFBundleIdentifier)" == "$bundle_id" ]] || fail "the archive is not Marionette."
version="$(property CFBundleShortVersionString)"
build="$(property CFBundleVersion)"
echo "==> Marionette $version ($build)"

# MARK: - Signing

export_archive() {  # export_archive <method> <destination> <output folder> [xcodebuild options…]
    local method="$1" destination="$2" output="$3"
    shift 3
    cat >"$work/options.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>$method</string>
    <key>destination</key><string>$destination</string>
    <key>signingStyle</key><string>manual</string>
    <key>teamID</key><string>$team</string>
    <key>signingCertificate</key><string>$certificate</string>
    <key>provisioningProfiles</key><dict><key>$bundle_id</key><string>$uuid</string></dict>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF
    if ! xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output" \
        -exportOptionsPlist "$work/options.plist" "$@" >"$work/export.log" 2>&1; then
        grep -E "error|Error|failed" "$work/export.log" | redact >&2 || tail -20 "$work/export.log" | redact >&2
        fail "xcodebuild could not sign the archive."
    fi
}

# Not plutil -extract, which reads the dots in "com.apple.developer.team-identifier" as a key path.
entitlement() { plutil -convert json -o - "$work/entitlements.plist" | jq -r --arg key "$1" '.[$key] // empty'; }

if [[ "$mode" == device ]]; then
    echo "==> Signing for development"
    export_archive debugging export "$work/export"
else
    echo "==> Signing for the App Store"
    export_archive app-store-connect export "$work/export"
fi
ipa="$(find "$work/export" -maxdepth 1 -name '*.ipa' | head -1)"
[[ -n "$ipa" ]] || fail "xcodebuild made no .ipa."
ditto -x -k "$ipa" "$work/ipa"
app="$work/ipa/Payload/Marionette.app"

# An archive built without signing carries no entitlements of its own, so check what the export gave
# the app before it goes anywhere.
codesign --verify --deep --strict "$app" || fail "the signed app does not verify."
codesign -d --entitlements - --xml "$app" >"$work/entitlements.plist" 2>/dev/null
[[ "$(entitlement application-identifier)" == *".$bundle_id" ]] || fail "the signed app has no application identifier."
[[ "$(entitlement com.apple.developer.team-identifier)" == "$team" ]] || fail "the signed app is not signed for the profile's team."
debuggable="$(entitlement get-task-allow)"
if [[ "$mode" == device ]]; then
    [[ "$debuggable" == true ]] || fail "the signed app cannot be debugged."
else
    [[ "$debuggable" != true ]] || fail "the signed app allows debugging, which the App Store refuses."
fi

# MARK: - Delivery

if [[ "$mode" == device ]]; then
    echo "==> Installing"
    xcrun devicectl device install app --device "$device" --quiet "$app" 2>&1 | redact || fail "the install failed."
    echo "==> Launching"
    # A locked device refuses the launch; the install has still succeeded.
    if ! xcrun devicectl device process launch --device "$device" --terminate-existing --quiet "$bundle_id" 2>&1 | redact; then
        echo "The app is installed but did not launch: unlock the device and open it." >&2
    fi
else
    echo "==> Uploading to App Store Connect"
    export_archive app-store-connect upload "$work/upload" \
        -authenticationKeyPath "$(cd "$(dirname "$key")" && pwd)/$(basename "$key")" \
        -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer"
    echo "Uploaded Marionette $version ($build). App Store Connect lists it once it has been processed."
fi
