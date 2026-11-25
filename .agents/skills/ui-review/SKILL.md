---
name: ui-review
description: Change or review Marionette's user interface the way the project expects - design against Apple's guidelines and the Screen Sharing app, judge the result from simulator screenshots on iPhone, iPad and iPhone Duo in light and dark, and keep accessibility, wording and tests in step. Use it for any change to a screen, control, toolbar, menu, gesture or user-visible text, and when asked to review how the app looks.
---

# UI review

The rules are the "Design", "Wording", "Accessibility" and "SwiftUI and UIKit" sections of the
[coding guide](../../../Docs/coding-guide.md). Read them before designing. This page is the working
loop.

## Before changing anything

- Open the Human Interface Guidelines page for the component, and see what the Screen Sharing app on
  a Mac does in the same situation. Those two decide; personal taste does not.
- Reproduce the present behaviour in a simulator first (the `run-app` skill), so that you can show
  before and after.
- Gestures and pointer handling break easily and are judged by feel on a device. Change them only
  when asked, make the smallest change that does it, and if the person says it got worse, revert it
  completely before trying anything else.

## Making the change

- Views stay thin: behaviour goes into `MarionetteKit` with a unit test, and the view calls it.
- A command in the session's control strip has a twin in the iPad menu bar (`MarionetteCommands`).
  Change both.
- Lay out for the narrowest case first: an iPhone in portrait, a closed iPhone Duo, an iPad window
  beside another app, and the largest accessibility text size.
- Give each new control its accessibility identifier and label as you write it, and update the UI
  tests that use the old ones.

## Looking at it

Judge from screenshots of the real app on the simulated back end, never from the code.

- `Scripts/screenshots.sh` takes the whole set; `MARIONETTE_SCREENSHOT_TESTS=testA,testB` limits it
  to the screens you changed, and an argument limits it to one device. See "UI tests and
  screenshots" in [Docs/testing.md](../../../Docs/testing.md).
- For a state the screenshot tests do not reach, use a temporary UI test as the `run-app` skill
  describes.
- Tile the pictures into one image and read it:
  `swift .agents/skills/ui-review/contact-sheet.swift <out.png> <cell width> <columns> <image>…`.
- Look at light and dark, and at an iPhone, an iPad and the iPhone Duo's outer display. Chrome that
  floats over the remote picture has to work over a black picture and over a bright one.
- Look for what reviewers have caught before: one control styled unlike its neighbours, a title
  that wraps to two lines, a row where some buttons wrapped and others did not, text explaining what
  the layout should have made obvious, and a control hidden behind the system's own bars.

Show the person only what changed, before and after, not the whole set again.

## What a simulator cannot show

The iPhone Duo's hinge and inner display, a real external monitor and how a gesture feels need a
device; testing.md lists the limits. Install the build with the `run-app` skill and tell the person
exactly which screens and poses to check and what they should see.

## Before calling it done

- Run the UI tests that cover the screens you touched, and the full suite before a pull request.
- If any text changed, run `Scripts/sync-string-catalogs.py` after a build.
- Check VoiceOver labels, Dynamic Type and contrast on the changed screens. Xcode installs agent
  skills for these under `~/Library/Developer/Xcode/CodingAssistant/ExportedPlugins`; use them when
  they are there.
