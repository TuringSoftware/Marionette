#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Live app checks that need the Mac's side looked at too: session select, the clipboard both ways,
# sending a file over Screen Sharing and, by name only, dragging files off the Mac's desktop
# (testDraggingAFileFromTheMacOntoTheWell), dragging them from the Files app onto it (iPad:
# testDroppingFromTheFilesAppOntoTheMac) and High Performance across trips to the background
# (testHighPerformanceAcrossTheBackground). Runs the UI tests one at a time on one simulator and
# checks the Mac over SSH. Scripts/with-test-host.sh sets everything below from the keychain.
#   MARIONETTE_TEST_HOST=… MARIONETTE_TEST_USER=… MARIONETTE_TEST_PASSWORD=… [MARIONETTE_TEST_USER2=… MARIONETTE_TEST_PASSWORD2=…] \
#   MARIONETTE_MAC_SHELL='<command that runs its argument as a shell command on the Mac>' \
#       Scripts/live-app-checks.sh <simulator udid> [test name…]
# The app must already be built for testing into DerivedData/ (xcodebuild build-for-testing … -derivedDataPath DerivedData).
set -uo pipefail
cd "$(dirname "$0")/.."
udid="$1"; shift
tests=("$@")
[[ ${#tests[@]} -eq 0 ]] && tests=(testSessionSelectLogInAsSelf testNativeFileSend testClipboardBothWays)
: "${MARIONETTE_TEST_HOST:?}" "${MARIONETTE_TEST_USER:?}" "${MARIONETTE_TEST_PASSWORD:?}" "${MARIONETTE_MAC_SHELL:?}"
runner="llc.turing.Marionette.UITests.xctrunner"
mac() { $MARIONETTE_MAC_SHELL "$1"; }

xcrun simctl boot "$udid" 2>/dev/null
xcrun simctl bootstatus "$udid" -b >/dev/null
app="$(find DerivedData/Build/Products -maxdepth 2 -name Marionette.app -path '*iphonesimulator*' | head -1)"
xcrun simctl install "$udid" "$app"
status=0
nonce="$(date +%s)"

run() {  # run <test> [extra TEST_RUNNER_ assignments…]
    local test="$1"; shift
    env TEST_RUNNER_MARIONETTE_TEST_HOST="$MARIONETTE_TEST_HOST" TEST_RUNNER_MARIONETTE_TEST_USER="$MARIONETTE_TEST_USER" \
        TEST_RUNNER_MARIONETTE_TEST_PASSWORD="$MARIONETTE_TEST_PASSWORD" "$@" \
        xcodebuild test-without-building -project Marionette.xcodeproj -scheme Marionette \
        -destination "platform=iOS Simulator,id=$udid" -derivedDataPath DerivedData \
        "-only-testing:MarionetteUITests/LiveConnectionTests/$test" -collect-test-diagnostics never 2>&1 \
        | grep --line-buffered -E "LIVE |Test Case .* (passed|failed)|error:|\*\* TEST"
    return "${PIPESTATUS[0]}"
}

markers() { echo "$(xcrun simctl get_app_container "$udid" "$runner" data 2>/dev/null)/Documents/LiveMarkers"; }

wait_marker() {  # wait_marker <name> <seconds> [pid of the test, which gives up the wait if it ends]
    local deadline=$(( $(date +%s) + $2 ))
    while [[ $(date +%s) -lt $deadline ]]; do
        [[ -f "$(markers)/$1" ]] && return 0
        [[ -n "${3:-}" ]] && ! kill -0 "$3" 2>/dev/null && return 1
        sleep 1
    done
    return 1
}

for test in "${tests[@]}"; do
    echo "==> $test"
    case "$test" in
    testSessionSelectLogInAsSelf)
        run "$test" TEST_RUNNER_MARIONETTE_TEST_USER2="${MARIONETTE_TEST_USER2:-}" TEST_RUNNER_MARIONETTE_TEST_PASSWORD2="${MARIONETTE_TEST_PASSWORD2:-}" || status=1
        ;;
    testNativeFileSend)
        name="marionette-live-upload-$nonce.txt"
        container="$(xcrun simctl get_app_container "$udid" llc.turing.Marionette data)"
        mkdir -p "$container/Documents"
        echo "sent from Marionette at $nonce" > "$container/Documents/$name"
        run "$test" TEST_RUNNER_MARIONETTE_UPLOAD_NAME="$name" || status=1
        got="$(mac "cat ~/Downloads/$name" 2>/dev/null)"
        if [[ "$got" == "sent from Marionette at $nonce" ]]; then echo "    Mac: ~/Downloads/$name arrived intact"
        else echo "    Mac: ~/Downloads/$name is missing or different: '$got'"; status=1; fi
        mac "rm -f ~/Downloads/$name" >/dev/null 2>&1
        rm -f "$container/Documents/$name"
        ;;
    testClipboardBothWays)
        rm -rf "$(markers)"
        run "$test" TEST_RUNNER_MARIONETTE_CLIPBOARD_NONCE="$nonce" &
        pid=$!
        if wait_marker pasted 240 "$pid"; then
            sleep 2
            got="$(mac pbpaste 2>/dev/null)"
            if [[ "$got" == "marionette-device-$nonce" ]]; then echo "    Mac: the paste control's text arrived"
            else echo "    Mac: clipboard is '$got', not marionette-device-$nonce"; status=1; fi
            mac "printf %s marionette-mac-$nonce | pbcopy"
            arrived=0
            for _ in $(seq 1 60); do
                if [[ "$(xcrun simctl pbpaste "$udid" 2>/dev/null)" == "marionette-mac-$nonce" ]]; then arrived=1; break; fi
                sleep 1
            done
            if [[ $arrived -eq 1 ]]; then
                echo "    device: the Mac's copy arrived"
                touch "$(markers)/mac-copy-arrived"
            else
                echo "    device: clipboard is '$(xcrun simctl pbpaste "$udid" 2>/dev/null)', not marionette-mac-$nonce"; status=1
            fi
        else
            echo "    the test never pasted"; status=1
        fi
        if wait_marker pasted-again 120 "$pid"; then
            sleep 2
            got="$(mac pbpaste 2>/dev/null)"
            if [[ "$got" == "marionette-device2-$nonce" ]]; then echo "    Mac: ⌘V's text arrived"
            else echo "    Mac: clipboard is '$got', not marionette-device2-$nonce"; status=1; fi
        fi
        wait "$pid" || status=1
        ;;
    testDraggingAFileFromTheMacOntoTheWell)
        # A file on the Mac's desktop, dragged onto the app's drop well: it arrives here whole and
        # the Mac keeps its own. MARIONETTE_DRAG_NAME and MARIONETTE_DRAG_POSITION say which file
        # and where in the picture it is, if not where the test expects it.
        name="${MARIONETTE_DRAG_NAME:-wfh-drag-test.txt}"
        container="$(xcrun simctl get_app_container "$udid" llc.turing.Marionette data)"
        rm -f "$container/Documents/$name"
        before="$(mac "wc -c < ~/Desktop/$name" 2>/dev/null | tr -d ' ')"
        if [[ -z "$before" ]]; then echo "    Mac: ~/Desktop/$name is not there to drag"; status=1; continue; fi
        run "$test" TEST_RUNNER_MARIONETTE_DRAG_NAME="$name" TEST_RUNNER_MARIONETTE_DRAG_POSITION="${MARIONETTE_DRAG_POSITION:-0.935,0.381}" || status=1
        after="$(mac "wc -c < ~/Desktop/$name" 2>/dev/null | tr -d ' ')"
        if [[ "$after" == "$before" ]]; then echo "    Mac: ~/Desktop/$name is still there ($after bytes)"
        else echo "    Mac: ~/Desktop/$name was $before bytes and is now '${after:-gone}'"; status=1; fi
        # Running the test installs the app afresh, which gives it a new container.
        container="$(xcrun simctl get_app_container "$udid" llc.turing.Marionette data)"
        got="$(wc -c < "$container/Documents/$name" 2>/dev/null | tr -d ' ')"
        if [[ "$got" == "$before" ]]; then echo "    device: $name arrived whole ($got bytes)"
        else echo "    device: $name is '${got:-missing}' bytes, not $before"; status=1; fi
        rm -f "$container/Documents/$name"
        ;;
    testDroppingFromTheFilesAppOntoTheMac)
        # A file and a folder in On My iPad, dragged from the Files app onto the Mac: the file into
        # the folder ~/Desktop/dnd, the folder onto the desktop, and the file onto the menu bar,
        # which must leave nothing behind. MARIONETTE_DROP_FOLDER_POSITION says where dnd shows.
        storage="$(xcrun simctl get_app_container "$udid" com.apple.DocumentsApp groups | awk -F'\t' '$1 == "group.com.apple.FileProvider.LocalStorage" { print $2 }')/File Provider Storage"
        local_dir="$storage/Drop Test"
        rm -rf "$local_dir"
        mkdir -p "$local_dir/wfh-drop-folder/inner"
        head -c 300000 /dev/urandom | base64 > "$local_dir/wfh-drop-file.txt"
        printf 'first %s\n' "$nonce" > "$local_dir/wfh-drop-folder/a.txt"
        printf 'second, inside %s\n' "$nonce" > "$local_dir/wfh-drop-folder/inner/b.txt"
        file_sum="$(shasum -a 256 < "$local_dir/wfh-drop-file.txt" | cut -d' ' -f1)"
        clean_mac() { mac "rm -f ~/Desktop/dnd/wfh-drop-file.txt ~/Desktop/wfh-drop-file.txt; rm -rf ~/Desktop/wfh-drop-folder ~/Desktop/dnd/wfh-drop-folder" >/dev/null 2>&1; }
        clean_mac
        run "$test" TEST_RUNNER_MARIONETTE_DROP_FOLDER_POSITION="${MARIONETTE_DROP_FOLDER_POSITION:-0.935,0.093}" || status=1
        got="$(mac "shasum -a 256 < ~/Desktop/dnd/wfh-drop-file.txt" 2>/dev/null | cut -d' ' -f1)"
        if [[ "$got" == "$file_sum" ]]; then echo "    Mac: the file landed in ~/Desktop/dnd, intact"
        else echo "    Mac: ~/Desktop/dnd/wfh-drop-file.txt is missing or different"; status=1; fi
        got="$(mac "cat ~/Desktop/wfh-drop-folder/a.txt ~/Desktop/wfh-drop-folder/inner/b.txt" 2>/dev/null)"
        if [[ "$got" == "first $nonce"$'\n'"second, inside $nonce" ]]; then echo "    Mac: the folder landed on the desktop with what is inside it"
        else echo "    Mac: ~/Desktop/wfh-drop-folder is missing or different: '$got'"; status=1; fi
        if mac "test -e ~/Desktop/wfh-drop-file.txt" 2>/dev/null; then echo "    Mac: the refused drop left a file on the desktop"; status=1
        else echo "    Mac: the refused drop left nothing"; fi
        clean_mac
        rm -rf "$local_dir"
        ;;
    testHighPerformanceAcrossTheBackground)
        # Something moving on the Mac (a Terminal window printing the time), the app sent to the
        # background three times, and the Mac's agent ended during the third.
        terminal_was_running=0
        mac "pgrep -xq Terminal" 2>/dev/null && terminal_was_running=1
        mac "printf '#!/bin/zsh\nwhile :; do print -n \"\$(date +%%T) \$RANDOM\$RANDOM \"; sleep 0.05; done\n' > ~/wfh-motion.command; chmod +x ~/wfh-motion.command; open -a Terminal ~/wfh-motion.command" >/dev/null 2>&1
        sleep 3
        rm -rf "$(markers)"
        run "$test" &
        pid=$!
        if wait_marker backgrounded 600 "$pid"; then
            sleep 3
            if mac "pkill -x ScreensharingAgent" 2>/dev/null; then echo "    Mac: ended ScreensharingAgent while the app was away"
            else echo "    Mac: no ScreensharingAgent to end"; status=1; fi
            touch "$(markers)/dropped"
        else
            echo "    the test never went to the background a third time"; status=1
        fi
        wait "$pid" || status=1
        mac "pkill -f wfh-motion.command; rm -f ~/wfh-motion.command" >/dev/null 2>&1
        [[ $terminal_was_running -eq 0 ]] && mac "pkill -x Terminal" >/dev/null 2>&1
        ;;
    *)
        run "$test" || status=1
        ;;
    esac
done

mkdir -p Artifacts/screenshots/live
if container="$(xcrun simctl get_app_container "$udid" "$runner" data 2>/dev/null)"; then
    cp "$container"/Documents/Screenshots/live-*.png Artifacts/screenshots/live/ 2>/dev/null
fi
xcrun simctl shutdown "$udid"
exit $status
