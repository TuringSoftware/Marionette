---
name: run-app
description: Build, install and launch the Marionette app on an iOS simulator or a connected iPhone or iPad, against the simulated back end or a real computer, and look at the result. Use it to see a change working, reproduce a reported UI bug, prepare simulators or a device for someone to test by hand, or investigate a crash or freeze.
---

# Running the app

Commands, launch arguments and what simulators cannot do are in
[Docs/testing.md](../../../Docs/testing.md); read it first. This page adds the order of work and the
mistakes to avoid.

## Before building

- `Marionette.xcodeproj` is generated. Run `xcodegen generate` after adding, moving or removing a
  source file, but never while a build or test run is using the project.
- Give each concurrent job its own `-derivedDataPath` (`DerivedData` for tests and the scripts,
  `DerivedData-device` for a device). Two `xcodebuild` runs in one folder wait on each other or fail.
- Look at `xcrun simctl list devices booted` and `uptime` first. Use a simulator that is already
  booted if it suits; shut down the ones you booted when you finish, and leave the others as they
  were. Never erase a simulator: its library and settings may be someone's test set-up.

## On a simulator

1. Build once: the `build-for-testing` command under "Testing by hand" in testing.md.
2. Install and launch with the launch arguments you need:
   `xcrun simctl install <udid> DerivedData/Build/Products/Debug-iphonesimulator/Marionette.app`, then
   `xcrun simctl launch --terminate-running-process <udid> llc.turing.Marionette -MarionetteUITestMode -MarionetteScenario hp -MarionetteAutoConnect`.
   `-MarionetteUITestMode` replaces the library with seeded computers; leave it out to keep the
   simulator's own library.
3. Look: `xcrun simctl io <udid> screenshot <file>.png`, then read the picture.
4. To tap, type or reach a state the launch arguments do not give, write a temporary XCUITest that
   finds elements by accessibility identifier and saves screenshots, run it with `-only-testing`,
   and delete it afterwards. Existing tests in `App/MarionetteUITests` show the helpers.

To reproduce a bug reported from a device, reproduce it in a simulator first, with the same device
family and system version if you can, and fix it there. Then install on the device for the reporter
to confirm.

## On a device

`scripts/install-on-device.sh` builds, installs and launches, and stops if the build fails. Without
that check a failed build leaves the old app on the device and the launch looks like a success.

```
.agents/skills/run-app/scripts/install-on-device.sh [device udid] [launch arguments…]
```

- The device and the development profile come from `.env`. Run
  `Scripts/env.sh check MARIONETTE_DEVELOPMENT_PROFILE MARIONETTE_DEVICE` first.
- If the profile is missing, ask the person for the path to their development profile; do not pick
  one from the keychain or Xcode's folder yourself. Save it with
  `Scripts/env.sh set MARIONETTE_DEVELOPMENT_PROFILE <path>` once they agree, or when they ask you to
  remember it. Do the same when they say it has been renewed or replaced.
- If the device is missing, or the person names another one, save it with
  `Scripts/env.sh set MARIONETTE_DEVICE --connected [model]`, which keeps the identifier out of the
  conversation. Keep the team, the profile and the device identifier out of files, commits and
  reports.
- To try the build that GitHub Actions made rather than a local one, download the run's
  `Marionette.xcarchive` artifact (`gh run download <run id> -n Marionette.xcarchive -D <folder>`)
  and run `Scripts/sign-archive.sh device <folder>/Marionette.xcarchive.zip`.
- Signing needs a profile that covers the bundle identifier and that device. If none does, that is
  for the person to fix in their developer account.
- A locked device refuses the launch. The install has still happened: ask the person to open the app.
- "Developer App Certificate is not trusted" on launch has gone away on a second try.
- Use only the device you were asked to use.

## A crash or a freeze

- Start from what the person did last. Ask which control they touched, then reproduce that in a
  simulator, where the debugger and the logs are within reach.
- On a device, `xcrun devicectl device process launch --console …` shows the app's output. Attaching
  LLDB from a script does not hold the process. Crash logs come off with
  `xcrun devicectl device info files --device <udid> --domain-type systemCrashLogs` and
  `devicectl device copy from`. A system log archive (`log collect --device-udid`) needs root, so ask
  the person to run it.
- A freeze with the main thread inside SwiftUI's graph is usually a view update that re-enters
  itself; see "SwiftUI and UIKit" in the coding guide. A kill with `EXC_RESOURCE` is memory.
- To tell an app bug from a simulator bug, repeat the step with a plain system control in its place.

## Afterwards

Remove temporary tests, tracing and launch-argument switches you added. If strings changed, run
`Scripts/sync-string-catalogs.py`.
