---
name: protocol-research
description: Find out how Apple's Screen Sharing protocol or a Mac's Screen Sharing server behaves, and turn the finding into tested code and documentation. Use it when Marionette's Apple back end needs a message, behaviour or timing that is not yet in Docs/protocol/apple-screen-sharing.md, when the app behaves differently from Apple's Screen Sharing app, or when a third-party description of the protocol has to be checked.
---

# Protocol research

Everything known is in [Docs/protocol/apple-screen-sharing.md](../../../Docs/protocol/apple-screen-sharing.md).
Read its "Sources and evidence", the section on your topic, "Open questions" and "Tools" before
experimenting: the answer, or the experiment that already failed, may be there. Connecting to a
machine follows the `live-testing` skill.

## Ways to find out, cheapest first

1. **Ask the Mac with our own client.** `marionettectl probe`, and `session --trace` with a
   `--script`, whose `raw-bytes:` step sends any message. See "marionettectl" in
   [Docs/testing.md](../../../Docs/testing.md).
2. **Read the Mac's log.** It names most steps and every refusal. The predicates are in testing.md
   under "Debugging against a Mac". Query it soon after the event: under load it keeps only minutes.
3. **Watch Apple's viewer.** `marionettectl proxy` records what Screen Sharing.app and the Mac say
   to each other; the protocol reference's "Tools" section explains it.
   - Open the `vnc://` address, then click Continue on the warning; the session to read is the
     second connection's folder.
   - To act in the viewer's window from a script, build `tools/host-input.swift`. It moves the real
     pointer, so tell the person first. Click inside the window once before a drag, or nothing
     reaches the Mac. Synthetic ⌘-key shortcuts do not arrive as modified keys.
   - Stop an earlier proxy before starting one, and close only the session window you opened.
   - `tools/pointer-rate.py <capture>/<NN>` counts pointer-position rectangles per second in a
     capture, for the open question on that subject.
4. **Read the binaries.** The daemon and the agent are files:
   `/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd`
   and `ScreensharingAgent.bundle` beside it. `otool -tV <file>` disassembles them with string
   references annotated. Frameworks (`ScreenSharing.framework`, `AVConference.framework` under
   `/System/Library/PrivateFrameworks`) are not files: use `dyld_info -disassemble <path>`, and
   `tools/dyldread.c` to find a string's address or read the string at one. To read another Mac's
   build, copy the binary here; do not run developer tools on a test Mac.
5. **Read what others found.** The references are listed in the protocol reference. They are a
   starting point and have been wrong: confirm against a Mac before relying on one.

## Sources you may copy from

Code under MIT, BSD or Apache licences may be adapted with attribution, as "Dependencies" in the
[coding guide](../../../Docs/coding-guide.md) requires. AGPL and GPL projects and Apple's own source
are documentation only: read them, then write from what a Mac does. Never paste from them.

## Experiments that mean something

- Change one thing per run, and keep the Mac the same between runs. Many comparisons have been
  spoiled by a moved icon or a different starting state: take a screenshot before and after.
- Check the result on the Mac, not in the client.
- Know what the test machine cannot show (test-machines.md). A VM answering differently from a real
  Mac is a finding, not noise.
- Some input counts only when it is real: the Mac reports its pointer only for hardware mouse
  movement, and Finder starts a drag only if the pointer moves within half a second of the press.
- When a hypothesis fails, undo the changes made for it, unless a change brings the client closer to
  what Apple's viewer sends; say which you kept and why.

## From finding to code

1. Cut a fixture from the capture, byte for byte, and clear it of identifying details as
   [CONTRIBUTING.md](../../../CONTRIBUTING.md) requires.
2. Add the message to `ARDProtocol` with a parser test on the fixture.
3. Teach `ScriptedMac` the exchange and test the behaviour without a network.
4. Add a live test where the behaviour depends on a real Mac.
5. Record the finding in the protocol reference: in the section it belongs to, in the present tense,
   without dates, marked with how it is known (observed, captured, Mac log, static analysis,
   reference). Write what the Mac did, not what the code does. An unanswered question goes under
   "Open questions" with what was ruled out.
6. Remove tracing and experiment switches that have no further use.
