# Testing

Run `Scripts/bootstrap.sh` once before anything below. In the commands, replace each `<…>` with a
value; `xcrun simctl list devices available` lists the simulators and their identifiers.

## Local settings

Scripts read the settings that belong to one person's set-up from `.env` at the root of the clone,
which git ignores. `.env.example` lists the keys; a variable set in the environment wins over the file.

| Key | What it is | Used by |
|---|---|---|
| `MARIONETTE_DEVELOPMENT_PROFILE` | path to a development profile that covers `llc.turing.Marionette` and the device | building for a device, `Scripts/sign-archive.sh device` |
| `MARIONETTE_DEVICE` | the device's UDID | the same |
| `MARIONETTE_DISTRIBUTION_PROFILE` | path to an App Store profile for `llc.turing.Marionette` | `Scripts/sign-archive.sh upload` |
| `MARIONETTE_ASC_KEY`, `MARIONETTE_ASC_ISSUER` | path to an App Store Connect API key (`AuthKey_<key id>.p8`) and its issuer ID; `MARIONETTE_ASC_KEY_ID` when the file name does not give the key ID | the same |
| `MARIONETTE_TEST_HOST_PROFILE` | the keychain profile `Scripts/with-test-host.sh` uses without `--profile` | live tests |

```
Scripts/env.sh set MARIONETTE_DEVELOPMENT_PROFILE ~/Downloads/Marionette_Development.mobileprovision
Scripts/env.sh set MARIONETTE_DEVICE --connected [model]    # the iPhone or iPad that is connected
Scripts/env.sh check MARIONETTE_DEVELOPMENT_PROFILE MARIONETTE_DEVICE
```

`Scripts/env.sh` prints no values, so it can be run where its output is shared. A profile's team and
UUID are read from the profile itself.

## Unit tests

```
Scripts/test.sh
```

Runs `swift test` for every package on this Mac; `swift test --package-path Packages/<Name> --filter
<pattern>` runs one package or one test. Nothing here touches the network: protocol code is
tested against recorded fixtures and scripted servers (`ScriptedMac` for Apple's protocol, a scripted
RFB server for LibVNCClient, an `sshd` on the loopback interface for SSH), and network conditions
are simulated with a seeded impairment layer. Every back end also has to pass the conformance suite in
`RemoteDesktopConformance`.

## UI tests and screenshots

UI tests run the app against a simulated back end, so they need no computer to connect to. Run the
whole suite on an iPhone and on an iPad simulator.

```
xcodebuild test -project Marionette.xcodeproj -scheme Marionette \
    -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath DerivedData
Scripts/screenshots.sh                  # every screen, light and dark, on each simulator in the review matrix
Scripts/screenshots.sh "iPhone Duo"     # only devices whose name contains the argument
Scripts/external-display.sh <simulator udid> <label>   # attaches a monitor to the simulator and checks each mode
```

Screenshots are written to `Artifacts/screenshots/<device>/`.

The pictures for the App Store are made differently, from real sessions:
[App Store assets](app-store-assets.md).

The live tests, the manual set-up and the pasteboard measurement in the same test target skip
themselves unless their environment variables are set.

`xcodebuild` passes a variable to the tests only when its name starts with `TEST_RUNNER_`, which it
strips: `TEST_RUNNER_MARIONETTE_TEST_HOST=… xcodebuild test …`. The scripts do this.

### Donations

The Support Us sheet sells one non-consumable, `Donations.productID`; App Store Connect has to offer
it under the same identifier. In a simulator the App Store is stood in for by
`App/MarionetteUITests/Donations.storekit`: the scheme's Run action uses it when the app is run from
Xcode, and the UI tests load it with `SKTestSession`. An app launched with `simctl` has no store, and
the sheet shows the donation as unavailable.

### The iPhone Duo simulator

The simulator boots closed, showing its outer display. DeviceHub
(`Xcode.app/Contents/Applications/DeviceHub.app`) opens and turns it with the buttons under the
device: rotate, then closed, half open and open. `simctl` has no command for either. This is the
iOS 27.2 simulator; the iOS 27.1 one has not been tried.

- `xcrun simctl io <simulator udid> screenshot --display=primary-1 <file>` captures the inner
  display once the device is open: 2853 × 2007 pixels on its side, 2007 × 2853 upright.
  `--display=primary` is the outer display, 1398 × 2034.
- The simulator ignores `XCUIDevice.shared.orientation`, open or closed. Turn it with DeviceHub's
  rotate button before the test runs.
- Half open and upright is the laptop pose: the system reports the fold, and a session docks, the
  picture above the fold and the input deck below. No launch argument is involved.
- In that pose XCUITest's touches miss the controls they are aimed at. A click in DeviceHub's
  picture of the device is a touch, and lands where it is made.
- DeviceHub takes clicks only while this Mac's screen is unlocked, and offers System Events no
  elements to find its buttons by: a script has to click positions. Keep the display awake
  (`caffeinate -d`) for as long as a run needs DeviceHub.

### What simulators cannot do

- The iPhone Duo simulator cannot be opened or turned from the command line, so
  `Scripts/screenshots.sh` captures only its outer display. `-MarionetteFoldOverride` lays the
  session out as the app expects the system to when the device is partly open; these screenshots
  say "Simulated fold" on screen and in their file names.
- Hardware key presses from XCUITest never arrive on the iPhone Duo simulator, so the tests that
  press keys fail there. Run the suite on other simulators and only Duo-specific tests on the Duo.
- The iOS 27.0 iPad simulator crashes while tiling windows; `testDroppingFromTheFilesAppOntoTheMac`
  runs on an iOS 26 iPad.
- Simulators share this Mac's network ports, so only one of them, or `marionettectl`, can hold a
  High Performance session at a time. The others get Standard.
- A hinge at an angle DeviceHub's poses do not offer, a real external monitor, HDR, a hardware
  keyboard on a Duo and hardware HEVC 4:4:4 decoding need a device.

## On a device

Run the Marionette scheme from Xcode, or, with the device and a development profile in
[local settings](#local-settings), build, install and launch from a terminal:

```
.agents/skills/run-app/scripts/install-on-device.sh [device udid] [launch arguments…]
```

or by hand:

```
xcodebuild build -project Marionette.xcodeproj -scheme Marionette -destination 'id=<device udid>' \
    -derivedDataPath DerivedData-device CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=<team id> \
    CODE_SIGN_IDENTITY="Apple Development" MARIONETTE_PROVISIONING_PROFILE=<profile uuid>
xcrun devicectl device install app --device <device udid> DerivedData-device/Build/Products/Debug-iphoneos/Marionette.app
xcrun devicectl device process launch --device <device udid> --terminate-existing llc.turing.Marionette
```

`xcrun devicectl list devices` lists the devices. Launching fails while the device is locked; the
install still succeeds. Launch arguments follow a `--`.

## Testing by hand

```
xcodebuild build-for-testing -project Marionette.xcodeproj -scheme Marionette \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData
Scripts/with-test-host.sh Scripts/add-test-computers.sh <simulator udid>…
```

installs the app on each simulator and adds the saved Mac, and the VNC server named by
`MARIONETTE_TEST_VNC_ADDRESS`, to its library through the app's own editor. The simulators are left
booted, ready to use.

### Launch arguments

| Argument | Effect |
|---|---|
| `-MarionetteScenario <name>` | Uses the simulated back end in the named scenario (`hp`, `standard`, `vnc`, `ssh`, `bad-password`, `host-key-changed`, `session-select`, `unreliable-network`, `showcase`, … ; see `ScenarioCatalog` in `Packages/MarionetteKit`). |
| `-MarionetteUITestMode` | A seeded library, a fixed clock and no animations. |
| `-MarionetteAutoConnect` | Opens the scenario's computer at launch. |
| `-MarionetteFoldOverride docked\|book` | Lays a session out as on a partly open iPhone Duo. |
| `-MarionetteAppearance light\|dark` | Forces the appearance (XCUITest does not apply the simulator's). |
| `-MarionetteClipboardMode explicit\|automatic\|off` | Overrides the clipboard setting. |
| `-MarionetteExternalMode mirror\|externalOnly\|dual` | Overrides the external display mode. |
| `-MarionetteWindowed` | Behaves as in a window smaller than the screen. |
| `-MarionetteThumbnails <folder>` | A JPEG in the folder named after a seeded computer (`Studio Mac.jpg`) is its thumbnail in the library. |
| `-MarionetteSessionCount <n>` | Starts as after `n` sessions, with no prompt answered: the donation tip shows from 10, and the system's review prompt is asked for when the fifth session ends. On a real device it replaces what the app had counted; `0` is a clean start. |
| `-MarionetteDiagnostics` | Puts what UI tests read (zoom, display size, input received) in the remote display's accessibility value, also against a real computer. Implied by `-MarionetteUITestMode`. Given by itself, it also keeps the prompts for a review and a donation away. |

## Live tests

Live tests connect to a real Mac. It needs Screen Sharing and Remote Login turned on, and the account
must be allowed to use Screen Sharing. [Test machines](test-machines.md) describes the Mac, the
second account, the desktop the drag tests expect and the VNC servers.

```
MARIONETTE_TEST_HOST=<mac> MARIONETTE_TEST_USER=<account> MARIONETTE_TEST_PASSWORD=<password> Scripts/test.sh --live
Scripts/live-ui-test.sh <simulator udid> testHighPerformance      # one live UI test; screenshots to Artifacts/screenshots/live/
Scripts/live-app-checks.sh <simulator udid> [test name…]          # UI tests that also check the Mac's side over SSH
```

Optional variables: `MARIONETTE_TEST_USER2` and `MARIONETTE_TEST_PASSWORD2` name a second account for
session select; `MARIONETTE_TEST_VNC_ADDRESS` (`host:port`) and `MARIONETTE_TEST_VNC_PASSWORD` name a
VNC server that is not a Mac.

A Mac serves High Performance to one viewer at a time on fixed UDP ports, so run only one live session
at a time: package tests, UI tests, `marionettectl` and the app all count. A High Performance test
that ends up in Standard usually means another session held the ports.

Live tests write to the Mac: files under `~/Downloads` and on the desktop, and its clipboard. The
clipboard test also replaces the clipboard of the Mac running the simulator.

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

`session --script` plays input such as `"key:cmd+space; text:Terminal; key:return; wait:1500"`. Every
step, including file drags, gestures and raw messages, is listed above `runInputScript` in
`Tools/marionettectl/Sources/marionettectl/Session.swift`.

- `--timeout` limits the whole run, not the connection attempt: keep it above `--seconds`.
- `proxy` prints every decrypted byte. Send its output to a file, and search `DIR/NN/log.txt` with
  `grep -a`; clipboard contents make it binary.
- A Mac ignores input for about 2 s after a login, so `session` holds scripted input until then.

## Debugging against a Mac

- The Mac logs every step of a Screen Sharing session:
  `/usr/bin/log show --last 2m --predicate 'process == "screensharingd" OR process == "ScreensharingAgent"'`.
  Over SSH use the full path: `log` is a zsh builtin.
- For High Performance, the Mac's media engine logs the stream configuration, each RTCP report it
  reads and its rate controller's state: `--predicate 'process == "avconferenced"'`.
- On a busy host (several simulators booted alongside a Mac VM) logins slow down and High
  Performance sessions time out; check the load before trusting a live timing result. Timing tests
  in the packages can time out under the same load and pass when run again alone.
- Check what the Mac received on the Mac (`pbpaste`, files on disk, typed text), not in the client.
- A wrong account and a wrong password look alike, and so does an account that may not use Screen
  Sharing.

## Continuous integration and releases

`.github/workflows/build.yml` runs on every push. One job builds an unsigned archive of the Release
configuration and keeps it as the run's `Marionette.xcarchive` artifact (a zip) for 30 days; the
other runs `Scripts/test.sh`. Caches are saved from `main` only: OpenSSL, keyed on its submodule
commit and the Xcode version, and Xcode's compilation cache for the archive, which is keyed on
content and so carries over to a fresh checkout.

`Scripts/sign-archive.sh` signs such an archive, or the zip of one, with the settings above:

```
gh run download <run id> -n Marionette.xcarchive -D <folder>
Scripts/sign-archive.sh device <folder>/Marionette.xcarchive.zip     # installs and launches on MARIONETTE_DEVICE
Scripts/sign-archive.sh upload <folder>/Marionette.xcarchive.zip     # uploads to App Store Connect
Scripts/sign-archive.sh check device|upload                          # checks the settings only
```

Options (`--profile`, `--device`, `--key`, `--issuer`, `--key-id`) override `.env`. The Apple
Development or Apple Distribution certificate for the profile's team must be in the login keychain.
The script refuses a profile that has expired, is for another app or is of the wrong kind, and checks
the signed app's entitlements before installing or uploading it.

To release, an agent follows the [`release` skill](../.agents/skills/release/SKILL.md): it raises the
build number in `project.yml` (`.agents/skills/release/scripts/set-version.sh [version] [build]`),
pushes the change to `main`, waits for the run to pass and uploads its archive.
