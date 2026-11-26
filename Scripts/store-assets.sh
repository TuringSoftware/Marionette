#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Makes the pictures for the App Store: screenshots, promo images, the product page header and the
# search result image. Docs/app-store-assets.md describes the whole procedure. Everything is read
# from and written to Artifacts/app-store/.
#
#   Scripts/store-assets.sh capture <simulator udid> <iphone|ipad|duo> <set> [display]
#       Brings the app to the states of one set and captures the simulator's display into
#       captures/<device>/. Sets: library, session-landscape, session-keyboard, docked.
#       The app must be built for testing into DerivedData/. Every set but library opens the
#       library's "Mac VM" (Scripts/add-test-computers.sh adds it), so run those through
#       Scripts/with-test-host.sh, one session at a time. "display" is the simulator display to
#       capture; for duo it defaults to primary-1, the inner display.
#       HOLD=<seconds> keeps the last state of "docked" on screen until captures/duo/hold.done exists.
#
#   Scripts/store-assets.sh stage | unstage
#       Through Scripts/with-test-host.sh: prepares the Mac the sessions show (its Dock hidden, a
#       document open in TextEdit), and puts it back.
#
#   Scripts/store-assets.sh cutout <screen capture> <X,Y,W,H>
#       Cuts the half-open iPhone Duo out of a screen capture of DeviceHub, from the region given in
#       the capture's pixels, into captures/duo/laptop-pose.png.
#
#   Scripts/store-assets.sh render [iphone|ipad|duo|creative|sheet|vectors]
#       Makes the finished pictures from the captures: screenshots/, previews/, creative/, proofs/
#       (the creative assets under Apple's art safe area), sheet.png (everything on one sheet) and
#       vectors/ (the device frames and the icon as SVG). Without an argument, all of them.
#       Needs Google Chrome; CHROME names another Chromium.
set -euo pipefail
cd "$(dirname "$0")/.."

kit="Tools/store-assets"
out="Artifacts/app-store"
tool="$out/.build/picture"
document="Monday planning.rtf"

usage() { sed -n '5,30p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

picture() {
    if [[ ! -x "$tool" || "$kit/picture.swift" -nt "$tool" ]]; then
        mkdir -p "$(dirname "$tool")"
        swiftc -O "$kit/picture.swift" -o "$tool"
    fi
    "$tool" "$@"
}

# MARK: capture

capture() {
    (( $# >= 3 )) || usage
    local udid=$1 device=$2 set=$3 display=${4:-} method folder
    case "$set" in
        library) method=testLibrary ;;
        session-landscape) method=testSessionLandscape ;;
        session-keyboard) method=testSessionKeyboard ;;
        docked) method=testDocked ;;
        *) usage ;;
    esac
    [[ "$device" == iphone || "$device" == ipad || "$device" == duo ]] || usage
    if [[ "$device" == duo && -z "$display" ]]; then display=primary-1; fi
    folder="$PWD/$out/captures/$device"
    mkdir -p "$folder"
    rm -f "$folder"/*.request "$folder"/*.done

    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    # A new simulator covers the keyboard with a tip about slide typing, and one that has seen a
    # hardware keyboard shows only the bar above the keyboard.
    xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
    xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences HardwareKeyboardLastSeen -bool false
    xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences AutomaticMinimizationEnabled -bool false
    xcrun simctl ui "$udid" appearance light
    xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100

    # The test writes <name>.request and waits for <name>.done. "activate" asks for the Mac's
    # document window to come forward, not for a picture; "hold" is for a person to answer.
    ( while true; do
        for request in "$folder"/*.request; do
            [[ -e "$request" ]] || continue
            name="$(basename "$request" .request)"
            [[ "$name" == hold ]] && continue
            if [[ "$name" == activate ]]; then
                if [[ -n "${MARIONETTE_MAC_SHELL:-}" ]]; then "$MARIONETTE_MAC_SHELL" "open -a TextEdit" >/dev/null 2>&1 || true; fi
            else
                xcrun simctl io "$udid" screenshot ${display:+--display="$display"} "$folder/$name.png" >/dev/null 2>&1
                echo "    captured $name"
            fi
            rm -f "$request"
            touch "$folder/$name.done"
        done
        sleep 0.1
      done ) &
    local watcher=$!
    # shellcheck disable=SC2064
    trap "kill $watcher 2>/dev/null; wait $watcher 2>/dev/null || true; rm -f '$folder'/*.request '$folder'/*.done" EXIT

    local turns=1 landscape=0
    [[ "$device" == duo ]] && turns=0
    [[ "$device" == ipad ]] && landscape=1
    local status
    set +e
    env TEST_RUNNER_MARIONETTE_STORE_CAPTURES="$folder" TEST_RUNNER_MARIONETTE_STORE_THUMBNAILS="$PWD/$out/thumbnails" \
        TEST_RUNNER_MARIONETTE_STORE_TURNS="$turns" TEST_RUNNER_MARIONETTE_STORE_LIBRARY_LANDSCAPE="$landscape" \
        TEST_RUNNER_MARIONETTE_STORE_HOLD="${HOLD:-}" \
        xcodebuild test-without-building -project Marionette.xcodeproj -scheme Marionette \
        -destination "platform=iOS Simulator,id=$udid" -derivedDataPath DerivedData \
        -only-testing:"MarionetteUITests/StoreScreenshots/$method" -parallel-testing-enabled NO -collect-test-diagnostics never 2>&1 \
        | grep --line-buffered -E "STORE |Test Case .* (passed|failed|skipped)|error:|\*\* TEST"
    status=${PIPESTATUS[0]}
    set -e
    return "$status"
}

# MARK: the Mac in the pictures

# The app's control strip sits where a Mac's Dock is, so the Dock is hidden; and a bare desktop gives
# a session nothing to show, so a document is opened. What the Dock was set to is kept in a file on
# the Mac until unstage puts it back.
dock_note='Library/Caches/marionette-store-assets-dock'

stage() {
    : "${MARIONETTE_MAC_SHELL:?run this through Scripts/with-test-host.sh}"
    "$MARIONETTE_MAC_SHELL" "cat > ~/Documents/'$document'" < "$kit/$document"
    "$MARIONETTE_MAC_SHELL" "
        [ -f ~/$dock_note ] || (defaults read com.apple.dock autohide 2>/dev/null || echo 0) > ~/$dock_note
        defaults write com.apple.dock autohide -bool true && killall Dock
        open -a TextEdit ~/Documents/'$document'"
    echo "The Mac is staged: its Dock is hidden and \"$document\" is open in TextEdit."
}

unstage() {
    : "${MARIONETTE_MAC_SHELL:?run this through Scripts/with-test-host.sh}"
    "$MARIONETTE_MAC_SHELL" "
        killall TextEdit 2>/dev/null
        rm -f ~/Documents/'$document'
        [ -f ~/$dock_note ] || exit 0
        if [ \"\$(cat ~/$dock_note)\" = 1 ]; then defaults write com.apple.dock autohide -bool true; else defaults write com.apple.dock autohide -bool false; fi
        rm -f ~/$dock_note
        killall Dock"
    echo "The Mac is as it was."
}

# MARK: render

chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

# chrome_page <page with query> <width> <height> <chrome arguments…>
chrome_page() {
    local page=$1 width=$2 height=$3; shift 3
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --no-first-run \
        --user-data-dir="$(mktemp -d -t store-assets-chrome)" --window-size="$width,$height" --virtual-time-budget=8000 \
        "$@" "file://$PWD/$kit/templates/$page" 2>/dev/null
}

# page <page with query> <width> <height> <output under Artifacts/app-store> [scale]
# Renders a template at width × height CSS pixels, times scale, as an opaque sRGB PNG of exactly
# that many pixels.
page() {
    local page=$1 width=$2 height=$3 output="$out/$4" scale=${5:-1} raw
    raw="$(mktemp -t store-assets-page).png"
    # Headless Chrome now and then exits without a picture; a second try has always worked.
    for _ in 1 2 3; do
        chrome_page "$page" "$width" "$height" --force-device-scale-factor="$scale" --screenshot="$raw" >/dev/null || true
        [[ -s "$raw" ]] && break
        sleep 1
    done
    [[ -s "$raw" ]] || { echo "error: Chrome made no picture of $page" >&2; exit 1; }
    mkdir -p "$(dirname "$output")"
    picture flatten "$raw" "$output" --srgb --expect "$((width * scale))x$((height * scale))"
    rm -f "$raw"
    echo "    $output"
}

# shot <device> <capture> <output name> <accepted sizes>
shot() {
    local from="$out/captures/$1/$2.png" to="$out/screenshots/$1/$3.png"
    [[ -f "$from" ]] || { echo "    (no $from)"; return; }
    mkdir -p "$(dirname "$to")"
    picture flatten "$from" "$to" --expect "$4"
    echo "    $to"
}

# features <device> <preview width> <preview height> <screenshot width> <screenshot height>
features() {
    [[ -f "$out/captures/$1/session-landscape-chevron.png" ]] || { echo "    (no landscape session for $1)"; return; }
    page "promo.html?device=$1" "$2" "$3" "previews/$1/features-$2x$3.png"
    page "promo.html?device=$1" "$4" "$5" "previews/$1/features-$4x$5.png"
}

# vector <page with query> <output under Artifacts/app-store>: the SVG a page draws, as a file.
vector() {
    mkdir -p "$(dirname "$out/$2")"
    chrome_page "$1" 800 600 --dump-dom | /usr/bin/python3 -c '
import re, sys
found = re.search(r"<svg.*</svg>", sys.stdin.read(), re.S)
if not found: sys.exit("no drawing in the page")
print("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + found.group(0).replace(" class=\"device-frame\"", "").replace(" class=\"app-icon\"", ""))' > "$out/$2"
    echo "    $out/$2"
}

render() {
    local only=${1:-}
    wanted() { [[ -z "$only" || "$only" == "$1" ]]; }
    [[ -x "$chrome" ]] || { echo "error: Google Chrome is needed to render (or set CHROME to another Chromium)." >&2; exit 1; }
    case "$only" in ""|iphone|ipad|duo|creative|sheet|vectors) ;; *) usage ;; esac

    if wanted iphone; then
        echo "==> iPhone 6.3-inch"
        shot iphone library 01-library 1206x2622,2622x1206
        shot iphone session-landscape-toolbar 02-session-toolbar 2622x1206
        shot iphone session-keyboard-chevron 03-session-keyboard 1206x2622
        features iphone 886 1920 1206 2622
    fi
    if wanted ipad; then
        echo "==> iPad 13-inch"
        shot ipad library 01-library 2752x2064,2064x2752
        shot ipad session-landscape-toolbar 02-session-toolbar 2752x2064
        shot ipad session-keyboard-chevron 03-session-keyboard 2064x2752
        features ipad 1200 1600 2064 2752
    fi
    if wanted duo; then
        echo "==> iPhone Duo, inner display"
        shot duo library 01-library 2853x2007,2007x2853
        shot duo session-landscape-toolbar 02-session-toolbar 2853x2007
        shot duo session-keyboard-chevron 03-session-keyboard 2007x2853
        shot duo docked-keyboard 04-laptop-pose 2007x2853
        features duo 886 1920 2007 2853
        if [[ -f "$out/captures/duo/laptop-pose.png" ]]; then
            page "laptop.html" 886 1920 "previews/duo/tiny-laptop-886x1920.png"
            page "laptop.html" 2007 2853 "previews/duo/tiny-laptop-2007x2853.png"
        else
            echo "    (no $out/captures/duo/laptop-pose.png)"
        fi
    fi
    if wanted creative; then
        echo "==> Product page header and search results"
        local right=iphone
        [[ -f "$out/captures/duo/session-landscape-toolbar.png" ]] && right=duo
        # Drawn at half size and twice the scale, which is the same picture in less memory.
        page "header.html?right=$right" 1920 823 "creative/product-page-header-3840x1646.png" 2
        page "search.html?right=$right" 1920 1280 "creative/search-results-3840x2560.png" 2
        page "header.html?right=$right&guides=1" 1920 823 "proofs/product-page-header-safe-area.png"
        page "search.html?right=$right&guides=1" 1920 1280 "proofs/search-results-safe-area.png"
    fi
    if wanted vectors; then
        echo "==> Vector references"
        vector "frame.html?icon=1" "vectors/icon.svg"
        local device
        for device in iphone ipad duo; do
            vector "frame.html?device=$device" "vectors/$device-portrait.svg"
            vector "frame.html?device=$device&landscape=1" "vectors/$device-landscape.svg"
        done
    fi
    if wanted sheet; then
        echo "==> Sheet"
        page "sheet.html" 2400 3960 "sheet.png"
    fi
}

case "${1:-}" in
    capture) shift; capture "$@" ;;
    stage) stage ;;
    unstage) unstage ;;
    cutout)
        (( $# == 3 )) || usage
        mkdir -p "$out/captures/duo"
        picture cutout "$2" "$out/captures/duo/laptop-pose.png" --crop "$3"
        ;;
    render) shift; render "$@" ;;
    *) usage ;;
esac
