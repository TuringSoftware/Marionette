---
name: live-testing
description: Run Marionette's tests, marionettectl or the app against a real Mac or VNC server without leaking the machine's details or disturbing it. Use it whenever a task connects to a real computer - live package tests, live UI tests, a marionettectl session, a proxy capture, or checking a fix against a Mac - and when a live test fails for reasons that may lie in the test machine.
---

# Live testing

What to run is in [Docs/testing.md](../../../Docs/testing.md) ("Live tests", "marionettectl",
"Debugging against a Mac"); what the machines need is in
[Docs/test-machines.md](../../../Docs/test-machines.md). Read both. This page is how to do it safely.

## The machine's details stay secret

A test machine's address, account name, password and computer name must never appear in the
conversation, in a file in the repository, or in a commit.

- Never ask for them in the conversation. Ask the person to run `Scripts/set-test-host.sh [profile]`
  in their own terminal, and to tell you only the profile name.
- Run every command that needs them through `Scripts/with-test-host.sh [--profile NAME]`. Never read
  the keychain items yourself.
- The wrapper filters only what the command prints. Files a command writes are not filtered: result
  bundles, a proxy's `log.txt`, session logs, and screenshots that show a connection screen. Read
  such a file through the wrapper too (`Scripts/with-test-host.sh grep -a … file`), and do not open
  such a screenshot unless the task needs it.
- Other machines' addresses leak through tools the wrapper does not know. Pipe their output through
  `sed -E 's/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/‹address›/g'`.
- Do not search old logs or transcripts for a password. Ask.

## One session at a time

A Mac serves one viewer in High Performance, and every simulator shares this Mac's UDP ports.

- Wrap each command that opens a session in `scripts/one-session.sh`, so that parallel agents and
  terminals queue instead of colliding:
  `.agents/skills/live-testing/scripts/one-session.sh Scripts/with-test-host.sh Scripts/test.sh --live`.
  A plain SSH command to the machine needs no lock.
- Before a run, check `uptime` and `xcrun simctl list devices booted`. If someone has a session open
  in a simulator, a High Performance test will land in Standard: wait, or say so, rather than report
  a regression.
- Keep runs short, run long ones in the background with their output in a file, and give every
  `marionettectl` run a `--timeout`. A hung live run otherwise holds the Mac for good.
- Check a background run every 10 minutes. `swift test` holds its output back when it writes to a
  file, so a log that stops growing does not say which test hangs: `sample <pid> 1` on the
  `swiftpm-testing-helper` process does. A thread waiting in `recv` means the machine stopped
  answering; check that it still sends its banner before running the test again on its own.
- Run the UI tests one simulator at a time. Several at once starve the Mac VM beside them.

## Leave the machine as you found it

- Do only what the person has allowed on that machine. Permission to use a test VM is not permission
  to change the development Mac's settings, and nothing here permits `sudo` on someone's Mac: when a
  step needs it, give the person the command.
- Put back any setting you change. Remove files your run left in `~/Downloads` and on the desktop;
  the drag tests depend on the desktop staying exactly as test-machines.md lists it.
- On the development Mac, never close, quit or move the person's windows and apps. Close only the
  window you opened, by name.
- Tell the person about side effects you could not avoid, such as their clipboard being replaced.
- A Mac you want asleep must be left alone: any connection, SSH included, wakes it.

## After contact with an older Mac

Run `Scripts/with-test-host.sh [--profile NAME] .agents/skills/live-testing/scripts/mac-health.sh`
after anything experimental has talked to a Mac on macOS 15. If it shows the hang described in
test-machines.md, stop and ask the person to restart the service.

## When a live test fails

Rule these out before changing code:

| Symptom | Likely cause |
|---|---|
| High Performance test ran in Standard | another session holds the UDP ports, or the host is overloaded |
| Timeouts in several unrelated tests | host load; run the test again alone |
| A drag test presses on the wrong thing | the desktop changed; take a `marionettectl screenshot` and compare with test-machines.md |
| The second account's login is refused | it is not in the Screen Sharing access group |
| Session select is not offered | the second account is the one at the console |
| First connection to a real Mac is slow | it was asleep |

Then look at the Mac's own log, as testing.md describes, before guessing.

## When a person is needed

Some checks need a hand on the Mac's mouse, an unlocked device or a look at a real screen. Prefer a
VM and a script over someone's time. When you do ask, say exactly what to do and what to look for,
and ask once for everything.
