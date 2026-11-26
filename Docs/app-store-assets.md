# App Store assets

The screenshots, promo images, product page header and search result image for the App Store are
made by `Scripts/store-assets.sh` from pictures of the real app. Nothing it reads or writes is in
the repository except the templates: captures and finished pictures live in the git-ignored
`Artifacts/app-store/`.

## What is made

Sizes are Apple's, from the [screenshot](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/),
[app preview](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications)
and [creative asset](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications)
specifications. Every finished picture is an opaque PNG; the App Store refuses an alpha channel.

| Picture | iPhone 6.3-inch | iPad 13-inch | iPhone Duo, inner display |
|---|---|---|---|
| `01-library` | 1206 × 2622 | 2752 × 2064 | 2853 × 2007 |
| `02-session-toolbar`: full screen on its side, the control strip open | 2622 × 1206 | 2752 × 2064 | 2853 × 2007 |
| `03-session-keyboard`: upright, the system keyboard and its bar, the strip folded | 1206 × 2622 | 2064 × 2752 | 2007 × 2853 |
| `04-laptop-pose`: half open, the Mac keyboard below the fold | | | 2007 × 2853 |
| `features`: the feature list around a framed session | 886 × 1920, 1206 × 2622 | 1200 × 1600, 2064 × 2752 | 886 × 1920, 2007 × 2853 |
| `tiny-laptop`: the half-open device | | | 886 × 1920, 2007 × 2853 |

| Picture | Size | Apple's art safe area |
|---|---|---|
| `product-page-header` | 3840 × 1646 | 1646 × 661 at (1097, 493) |
| `search-results` | 3840 × 2560 | 2168 × 1030 at (836, 765) |

- The promo images come at the app preview size and at the screenshot size. An app preview on the
  App Store is a video: the first is the frame one would be built from, the second can be uploaded
  as a screenshot.
- The focal device and the phrase of the two creative assets stay inside the art safe area; what
  is in the wings may be cut off on a narrow screen. `proofs/` holds both with the area drawn in.
- Apple's [asset guidance](https://developer.apple.com/app-store/asset-best-practices/) decides the
  rest: the real interface, one idea for each picture, a short phrase, text large enough to read,
  no prices, awards or other platforms, and one look across every asset.

## Where things are

| Path | What |
|---|---|
| `Scripts/store-assets.sh` | Every step; run it without arguments for its commands |
| `App/MarionetteUITests/StoreScreenshots.swift` | Brings the app to each state; skips itself unless the script runs it |
| `Tools/store-assets/templates/` | One page for each composed picture, `style.css` for the look, `lib.js` for the device frames, the icon and the strings |
| `Tools/store-assets/picture.swift` | Removes the alpha channel; cuts a device out of a flat background |
| `Tools/store-assets/Monday planning.rtf` | The document open on the Mac in the session pictures |
| `Artifacts/app-store/captures/<device>/` | What the simulators showed |
| `Artifacts/app-store/thumbnails/` | Desktop pictures for the library's cards |
| `Artifacts/app-store/{screenshots,previews,creative,proofs,vectors}/`, `sheet.png` | The finished pictures |

## Capturing

The library is the simulated back end's `showcase` scenario: three Macs, and two more found on
the network. The sessions are real ones with a Mac, so [live testing](testing.md#live-tests)
applies: one session at a time, through `Scripts/with-test-host.sh`.

### Once

- Simulators: an iPhone 18 Pro and an iPad Pro 13-inch (M5) on iOS 27.0, and an iPhone Duo on
  iOS 27.2. Make new ones (`xcrun simctl create`) rather than use one whose library and settings
  someone depends on.
- Build for testing, and add the Mac to each simulator's library, as
  ["Testing by hand"](testing.md#testing-by-hand) describes. It is saved as "Mac VM", which is the
  name the session pictures open.
- Desktop pictures for the library's cards: a JPEG in `Artifacts/app-store/thumbnails/` named
  after a computer ("Studio Mac.jpg", "MacBook Pro.jpg", "Mac mini.jpg") becomes its thumbnail,
  cropped to the card's 16:10. Without one the card shows the simulated desktop. The pictures are
  Apple's and stay out of the repository. On a Mac running macOS 27,
  `/System/Library/Wallpapers/.default/DefaultAerial.heic` is the default desktop picture and
  `/System/Library/ExtensionKit/Extensions/NeptuneOneWallpaper.appex/Contents/Resources/TahoeLight.heic`
  is macOS 26's; macOS 15 draws its own and ships no still. Convert one with
  `sips -s format jpeg -Z 2048 <picture> --out "Artifacts/app-store/thumbnails/Studio Mac.jpg"`.

### An iPhone or an iPad

```
Scripts/with-test-host.sh Scripts/store-assets.sh stage
Scripts/store-assets.sh capture <simulator udid> iphone library
Scripts/with-test-host.sh Scripts/store-assets.sh capture <simulator udid> iphone session-landscape
Scripts/with-test-host.sh Scripts/store-assets.sh capture <simulator udid> iphone session-keyboard
Scripts/with-test-host.sh Scripts/store-assets.sh unstage
```

- `stage` hides the Mac's Dock, because the app's control strip sits exactly where the Dock is,
  and opens the document in TextEdit, so that the desktop has something on it. `unstage` closes
  TextEdit, removes the document and gives the Dock its setting back.
- Each session set captures the strip three times: open (`-toolbar`), folded to its handle
  (`-chevron`) and after the handle has faded (`-clean`).
- A touch on the Mac's desktop sends the document window behind Finder, and a pointer left on the
  bottom edge brings the Dock back. Before each picture the test therefore touches the window's
  title bar and the script opens TextEdit again over SSH.
- The pictures are the simulator's framebuffer (`simctl io screenshot`), already upright when the
  device is on its side. The status bar is set to 9:41 with a full battery.

### An iPhone Duo

The simulator has to be opened and turned in DeviceHub by hand:
["The iPhone Duo simulator"](testing.md#the-iphone-duo-simulator). Turn it before each capture,
because it ignores the rotation the test asks for.

| Pose in DeviceHub | Capture |
|---|---|
| Open, on its side | `library`, `session-landscape` |
| Open, upright | `session-keyboard` |
| Half open, upright | `docked` |

The laptop pose needs a person:

1. `HOLD=600 Scripts/with-test-host.sh Scripts/store-assets.sh capture <simulator udid> duo docked`
   opens the session and waits.
2. In DeviceHub's picture of the device, click the strip's keyboard control until the Mac keyboard
   is below the fold, then the strip's chevron. Wait for the handle to fade.
3. `xcrun simctl io <simulator udid> screenshot --display=primary-1 Artifacts/app-store/captures/duo/docked-keyboard.png`
   is the fourth screenshot.
4. Take a screen capture of DeviceHub (`screencapture -x <file>`) with the pointer away from the
   device, and cut the device out of it: `Scripts/store-assets.sh cutout <file> <X,Y,W,H>`, the
   region being a rectangle of DeviceHub's flat background around the device, in the capture's
   pixels. Zoom the device in first: this picture is enlarged for the largest promo image.
5. `touch Artifacts/app-store/captures/duo/hold.done` ends the session.

## Rendering

```
Scripts/store-assets.sh render            # everything
Scripts/store-assets.sh render creative   # or iphone, ipad, duo, creative, sheet, vectors
```

Rendering reads only the captures, so it can be repeated at any time. It needs Google Chrome, which
draws the pages, and nothing else beyond Xcode. A capture that is missing is skipped and named.

- The colours and the typeface are the tokens at the top of `style.css`. The feature list is in
  `promo.html`; `search.html` and `laptop.html` take `?phrase=`.
- Every length in a template is a fraction of the page's width, so a page renders at any size.
- The app icon in the pictures is composed from the layers of `AppIcon.icon` as the page loads,
  and follows the app's.
- With an iPhone Duo captured, the Duo takes the right wing of the header and the search result
  in place of a second iPhone.
- `vectors/` holds the device frames and the flat icon as SVG, for work in a drawing app. A frame's
  viewBox is the device in screen pixels, and its screen is the element `#screen`.
- `sheet.png` shows every finished picture together. Look at it, and at each picture at full
  size, before uploading anything.
