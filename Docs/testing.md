# Testing

Run `Scripts/bootstrap.sh` once before anything below.

## Unit tests

```
Scripts/test.sh
```

Runs `swift test` for every package on this Mac. Nothing here touches the network: protocol code is
tested against recorded fixtures and scripted servers (`ScriptedMac` for Apple's protocol, a scripted
RFB server for LibVNCClient, an `sshd` on the loopback interface for SSH), and network conditions
are simulated with a seeded impairment layer. Every back end also has to pass the conformance suite in
`RemoteDesktopConformance`.

## UI tests and screenshots

UI tests run the app against a simulated back end, so they need no computer to connect to:

```
xcodebuild test -project Marionette.xcodeproj -scheme Marionette \
    -destination 'platform=iOS Simulator,name=iPhone 17'
Scripts/screenshots.sh                  # every screen, light and dark, on each simulator in the review matrix
Scripts/screenshots.sh "iPhone Duo"     # only devices whose name contains the argument
Scripts/external-display.sh <simulator udid> <label>   # attaches a monitor to the simulator and checks each mode
```

Screenshots are written to `Artifacts/screenshots/<device>/`.

The iPhone Duo simulator boots closed and cannot be opened from the command line, so only its outer
display can be captured. `-MarionetteFoldOverride` lays the session out as the app expects the system
to when the device is partly open; these screenshots say "Simulated fold" on screen and in their file
names.

### Launch arguments

| Argument | Effect |
|---|---|
| `-MarionetteScenario <name>` | Uses the simulated back end in the named scenario (`hp`, `standard`, `vnc`, `ssh`, `bad-password`, `host-key-changed`, `session-select`, `unreliable-network`, … ; see `ScenarioCatalog` in `Packages/MarionetteKit`). |
| `-MarionetteUITestMode` | A seeded library, a fixed clock and no animations. |
| `-MarionetteAutoConnect` | Opens the scenario's computer at launch. |
| `-MarionetteFoldOverride docked\|book` | Lays a session out as on a partly open iPhone Duo. |
| `-MarionetteAppearance light\|dark` | Forces the appearance (XCUITest does not apply the simulator's). |
| `-MarionetteClipboardMode explicit\|automatic\|off` | Overrides the clipboard setting. |
| `-MarionetteExternalMode mirror\|externalOnly\|dual` | Overrides the external display mode. |
| `-MarionetteWindowed` | Behaves as in a window smaller than the screen. |
| `-MarionetteDiagnostics` | Puts what UI tests read (zoom, display size, input received) in the remote display's accessibility value, also against a real computer. Implied by `-MarionetteUITestMode`. |

## Live tests

Live tests connect to a real Mac. It needs Screen Sharing and Remote Login turned on, and the account
must be allowed to use Screen Sharing.

```
MARIONETTE_TEST_HOST=<mac> MARIONETTE_TEST_USER=<account> MARIONETTE_TEST_PASSWORD=<password> Scripts/test.sh --live
Scripts/live-ui-test.sh <simulator udid> testHighPerformance      # one live UI test; screenshots to Artifacts/screenshots/live/
Scripts/live-app-checks.sh <simulator udid> [test name…]          # UI tests that also check the Mac's side over SSH
```

Optional variables: `MARIONETTE_TEST_USER2` and `MARIONETTE_TEST_PASSWORD2` name a second account for
session select; `MARIONETTE_TEST_VNC_ADDRESS` (`host:port`) and `MARIONETTE_TEST_VNC_PASSWORD` name a
VNC server that is not a Mac.

A Mac serves High Performance to one viewer at a time on fixed UDP ports, so run only one live session
at a time: package tests, UI tests, `marionettectl` and the app all count.

### Keeping credentials out of logs

Save a Mac's address, account and password in the login keychain once, then run commands through
`Scripts/with-test-host.sh`. It sets the variables above for that command only (and
`MARIONETTE_MAC_SHELL`, an SSH shell on the Mac), and replaces the three values with placeholders in
everything the command prints. UI tests log the text they type, passwords included, so this matters.

```
Scripts/set-test-host.sh studio                       # in your own terminal; asks for each value
Scripts/with-test-host.sh --profile studio Scripts/test.sh --live
Scripts/with-test-host.sh --profile studio Scripts/live-app-checks.sh <simulator udid> testHighPerformance
Scripts/set-test-host.sh --delete studio
```

## marionettectl

`Tools/marionettectl` drives the same back ends as the app from a terminal. Run it without arguments
for the full list of commands and options.

```
swift run --package-path Tools/marionettectl marionettectl probe <mac>
swift run --package-path Tools/marionettectl marionettectl session <mac> --mode hp --stats --trace
swift run --package-path Tools/marionettectl marionettectl session <mac> --mode hp --loss 1 --seed 7   # seeded packet loss
swift run --package-path Tools/marionettectl marionettectl session <mac> --backend vnc
swift run --package-path Tools/marionettectl marionettectl session <mac> --ssh --files
swift run --package-path Tools/marionettectl marionettectl proxy <mac> --output DIR
```

`proxy` stands in for the Mac on `127.0.0.1:55900` and records, in plaintext, what Apple's Screen
Sharing.app and the Mac say to each other: open `vnc://<user>:<password>@127.0.0.1:55900` and click
Continue when Screen Sharing warns that it cannot verify the server.

`session --script` plays input such as `"key:cmd+space; text:Terminal; key:return; wait:1500"`.

## Debugging against a Mac

- The Mac logs every step of a Screen Sharing session:
  `/usr/bin/log show --last 2m --predicate 'process == "screensharingd" OR process == "ScreensharingAgent"'`.
  Over SSH use the full path: `log` is a zsh builtin.
- For High Performance, the Mac's media engine logs the stream configuration, each RTCP report it
  reads and its rate controller's state: `--predicate 'process == "avconferenced"'`.
- On a busy host (several simulators booted alongside a Mac VM) logins slow down and High
  Performance sessions time out; check the load before trusting a live timing result.
