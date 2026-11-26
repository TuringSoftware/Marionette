---
name: app-store-assets
description: Make or update Marionette's App Store pictures - the screenshots for iPhone, iPad and iPhone Duo, the promo images, the product page header and the search result image - by capturing the real app in simulators and rendering the templates. Use it when asked for App Store screenshots, previews, promo or marketing images, a product page header or a search result image, when the app's look has changed and the pictures need retaking, and when the templates, feature list or phrases are to be changed.
---

# App Store assets

What is made, the sizes, the commands and the templates are in
[Docs/app-store-assets.md](../../../Docs/app-store-assets.md); read it first. The sessions are live
ones, so the [`live-testing`](../live-testing/SKILL.md) skill applies too. This page is the order of
work and the mistakes to avoid.

## Before capturing

- Changing only the templates, the feature list or a phrase needs no capture:
  `Scripts/store-assets.sh render` works from the captures already in `Artifacts/app-store/`.
- Make your own simulators, named so that they are plainly yours, and shut them down when you
  finish. Someone else's simulator holds their library and may be in use by another session.
- Capture from a clean checkout of what is being released, built for testing into `DerivedData/`.
  If another build or test run is using the project, wait for it.
- Run every session capture through `one-session.sh` and `Scripts/with-test-host.sh`, one simulator
  booted at a time.
- `stage` changes the Mac. Run `unstage` when the captures are done, also after a failure, and
  check that the Mac's Dock and `~/Documents` are as they were.

## The iPhone Duo and DeviceHub

The Duo's open poses are set by clicking in DeviceHub's window on the developer's Mac. That takes
their pointer and keyboard focus, so ask first, and do it only while they are away from the Mac.

- The Mac's screen locks when it has been idle, and then nothing can be clicked or captured. Start
  `caffeinate -d` before the first click and stop it afterwards. If the screen is already locked,
  ask the person to unlock it; do everything that needs no window meanwhile.
- DeviceHub offers no accessibility elements. Take a screen capture (`screencapture -x`), find the
  buttons under the device in it (rotate, then closed, half open, open), and click them with
  `scripts/pointer.swift`. Positions are in points, half the capture's pixels on a Retina display.
- Before each click, bring DeviceHub forward (`open -a`) and check that it is frontmost: a click
  meant for it must not land in the person's terminal.
- A screen capture shows the person's other windows and the names of their devices in DeviceHub's
  list. Look at it, use it, and keep it and what it shows out of the repository and your replies.
- Select your own simulator in DeviceHub's list; when you finish, set it closed and the zoom back.

## Looking at the result

- Read every capture before rendering, and `sheet.png` and each finished picture afterwards. Look
  for a keyboard left up from the last session, the Mac's Dock back on screen, the document window
  greyed behind Finder, a line of text selected, a menu open on the Mac, and a `-chevron` picture
  whose handle has already faded.
- No picture may show a real computer's name, an address or an account. The library is seeded for
  that reason; the session pictures show only the staged Mac's desktop.
- Check each finished picture's size and that it has no alpha channel (`sips -g pixelWidth -g
  pixelHeight -g hasAlpha`), and each proof for artwork outside Apple's art safe area.
- Captures and finished pictures stay in `Artifacts/`. Only templates, scripts and documents are
  committed.
